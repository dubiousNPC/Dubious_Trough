---@omw-context local
--[[
    whywalk_mount.lua -- the mount controller

    WHAT CHANGED, AND WHY IT IS SMALLER THAN WHAT IT REPLACES

    This file used to play locomotion animations on the creature by hand while
    whywalk_global.lua teleported it. That whole arrangement is gone. The
    creature is now DRIVEN, not placed: this script writes

        self.controls.movement
        self.controls.sideMovement
        self.controls.yawChange
        self.controls.run
        self.controls.jump

    and OpenMW's character controller does the rest. Everything the old
    arrangement reimplemented is now the engine's job and is simply correct:

        gait selection and blending     collision with world and actors
        root motion and footfalls       gravity, falling, landing
        animation playback speed        step up / step down
        water and swim handling         slopes, stairs, ledges
        pathing-aware movement          interiors, with no special case

    Four reported bugs die with it. The T-pose (the controller was never asked
    to move the creature, so it never chose a group), the total absence of
    collision (nothing was asking the physics system anything), the interior
    fall-through (the heightmap has no interiors, and the landing clamp was the
    only thing that cleared `airborne`), and the jitter (two actors being
    teleported to computed positions once per frame, each a frame behind).

    WHY NOT DGR'S APPROACH

    Devilish Guar Riding is the reference for how riding should FEEL, and it
    does not do this -- it teleports the creature and plays the animation
    itself, with nine raycasts per frame for collision. That works, and it is
    the reason DGR feels solid, but it is a hand-written character controller
    sitting next to the engine's own.

    The thing being chased is "the natural vanilla movement and animation of
    the guar". DGR approximates it: it picks a group from a gait band and
    scales playback speed with a tuned curve (`0.92 + min(1, s) * 0.36`).
    Driving the controls gets the real thing, because the engine selects and
    speeds the creature's gait the same way it does for every other creature in
    the game -- and it costs a handful of field writes instead of nine rays.

    WHAT DGR DID THAT IS KEPT

    The one thing worth copying outright is `self:enableAI(false)`. Without it
    the creature's own AI keeps issuing movement and fights every control write.
    Cod3x documents enableAI as "Enables or disables standard AI", which is the
    decision layer only -- physics, collision and the character controller all
    continue to run, which is exactly the split this file needs. It is one call
    on mount and one on dismount, not a per-frame suppression.

    NOTE ON THE OLD ANIMATION CODE, BECAUSE IT EXPLAINS THE T-POSE TWICE OVER

    The previous version called playBlended with `loops = -1`, intending
    "forever". Cod3x's contract for playBlended is:

        `loops` - a number >= 0, the number of times the animation should
                  loop after the first play (default: 0)

    `-1` is outside that range. So even once the creature HAD an animation
    script, the group it played was not a looping one -- it ran once, or not at
    all, and the actor dropped back to bind pose. DGR passes `loops = 999999`
    for the same intent, which is why its guar animates and ours did not.

    Recording it because the lesson outlives the code: `-1` means "infinite" in
    plenty of APIs, and it means "invalid" in this one. None of the checkers
    catch an out-of-range constant.

    PER-FRAME COST

    One `onUpdate`, attached only while this creature is ridden, whose first
    statement returns when it is not. While riding it performs five field
    assignments and no allocation, no API calls, no queries. The controls have
    to be restated each frame -- that is how the engine consumes them -- and
    this is the floor for a driven actor. It replaces: nine raycasts, two
    teleports, a heightmap query and a hand-integrated gravity step, per frame.

    ATTACHMENT

    Registered CUSTOM, attached with addScript on mount and removed on
    dismount, so an unridden creature carries no code at all.
]]

local self   = require('openmw.self')
local types  = require('openmw.types')
local shared = require('scripts.WhyWalk.whywalk_shared')

local STATE = shared.STATE

-- See the long note at TUNING.suppressMountAI. This is the first thing to flip
-- if a mount refuses to move, and it is a switch rather than a code edit
-- precisely because it cannot be settled outside the game.
local SUPPRESS_AI = shared.TUNING.suppressMountAI ~= false

local EV_START   = 'WhyWalk_MountStart'
local EV_STOP    = 'WhyWalk_MountStop'
local EV_CONTROL = 'WhyWalk_MountControl'

-- The rider's pose, sent to the player script (ridingAnim.lua consumes it).
local EV_ANIM_STATE = 'WhyWalk_AnimState'

-- Commanded intent, replaced wholesale when a control event arrives. The
-- player script sends on CHANGE only, so a straight-line gallop generates no
-- events at all; these values simply persist and get restated to the engine.
local mounted  = false
local throttle = 0        -- -1..1, forward positive
local steer    = 0        -- -1..1, right positive
local gallop   = false
local turnRate = 2.6      -- radians/sec at full steer, from the mount profile

-- Set by an event, consumed by the next frame, cleared immediately. A jump is
-- an edge, not a state: `controls.jump` held true would retrigger forever.
local jumpPending = false

-- The player, so the derived rider state can be sent to it. Arrives with
-- MountStart; nil outside a ride.
local rider = nil
local lastState = nil

local function clearControls()
    local c = self.controls
    c.movement     = 0
    c.sideMovement = 0
    c.yawChange    = 0
    c.pitchChange  = 0
    c.run          = false
    c.sneak        = false
    c.jump         = false
end

-- ---------------------------------------------------------------------------
-- RIDER STATE
-- ---------------------------------------------------------------------------
-- Which pose the RIDER should hold. This moved here from whywalk_global.lua
-- for a context reason and stayed for a correctness one.
--
-- The context reason: it needs `types.Actor.isOnGround`, which Cod3x documents
-- as "Can be called only from a local script" with an LObject parameter. A
-- global script cannot call it. This script is LOCAL on the creature.
--
-- The correctness reason: the pose should follow what the creature actually
-- does, not what the player asked for. Under the old teleport model those were
-- the same thing by construction. Now the engine can refuse -- a mount pressed
-- into a wall has a throttle of 1 and a speed of 0 -- and the rider should be
-- sitting still, not pedalling.
--
-- getCurrentSpeed is the engine's own number, so there is no integration here
-- and no threshold tuning beyond deciding where walking becomes galloping.
-- Walk speed is read from the creature rather than hard-coded, so a slow guar
-- and a fast one both reach "gallop" at their own run speed.
local IDLE_SPEED_EPSILON = 5     -- units/sec; below this the mount is standing

local function currentState()
    -- Airborne first: a jumping or falling mount is neither walking nor idle.
    if not types.Actor.isOnGround(self) then return STATE.JUMP end

    local speed = types.Actor.getCurrentSpeed(self)
    if not speed or speed < IDLE_SPEED_EPSILON then return STATE.IDLE end

    -- Direction comes from the commanded throttle rather than from comparing
    -- velocity to heading. The engine has no velocity field to read, and the
    -- throttle's SIGN is reliable even when its magnitude is being ignored --
    -- the creature cannot be moving backwards while being told to go forward.
    if throttle < 0 then return STATE.REVERSE end

    -- Gallop above the creature's own walk speed, with a little headroom so
    -- the boundary does not flicker at exactly walking pace.
    local walk = types.Actor.getWalkSpeed(self)
    if walk and speed > walk * 1.15 then return STATE.GALLOP end
    return STATE.WALK
end

local function reportState()
    if not rider or not rider:isValid() then return end
    local st = currentState()
    if st == lastState then return end
    lastState = st
    rider:sendEvent(EV_ANIM_STATE, { state = st })
end

-- ---------------------------------------------------------------------------
-- EVENTS
-- ---------------------------------------------------------------------------

local function onMountStart(data)
    mounted  = true
    throttle, steer, gallop = 0, 0, false
    jumpPending = false
    rider    = data and data.player
    lastState = nil
    turnRate = (data and tonumber(data.turnRate)) or turnRate

    -- The creature's own AI would otherwise keep issuing its own movement and
    -- overwrite these controls. Disabling standard AI leaves physics and the
    -- character controller running, which is the whole point.
    if SUPPRESS_AI then self:enableAI(false) end
    clearControls()
end

local function onMountStop()
    mounted = false
    throttle, steer, gallop = 0, 0, false
    jumpPending = false
    rider, lastState = nil, nil

    -- Order matters: stop commanding it before handing control back, or the
    -- last written movement persists into the first AI frame and the creature
    -- walks off.
    clearControls()
    if SUPPRESS_AI then self:enableAI(true) end
end

local function onMountControl(data)
    if not mounted or type(data) ~= 'table' then return end

    if data.jump then
        jumpPending = true
        return
    end

    throttle = tonumber(data.throttle) or 0
    steer    = tonumber(data.steer) or 0
    gallop   = data.gallop == true
end

-- ---------------------------------------------------------------------------
-- THE PER-FRAME HANDLER
-- ---------------------------------------------------------------------------

local function onUpdate(dt)
    if not mounted then return end
    if dt <= 0 then return end

    local c = self.controls

    -- `movement` is documented as +1 forward / -1 backward, and intermediate
    -- magnitudes scale the speed, so passing the throttle straight through
    -- gives analog control for free. Speed itself comes from the creature's
    -- own Speed stat, which is what makes this vanilla: a slow guar is slow
    -- because it is a slow guar, not because a profile table said 600.
    c.movement = throttle

    -- `run` picks the run speed and the run animation together. Reverse is
    -- deliberately never a run: there is no backward run in Morrowind's
    -- creature sets, and asking for one yields the walkback group played too
    -- fast.
    c.run = gallop and throttle > 0

    -- yawChange is a per-frame DELTA in radians, positive = right. Scaling by
    -- dt is what keeps the turn rate framerate-independent.
    c.yawChange = steer ~= 0 and (steer * turnRate * dt) or 0

    -- One frame of true, then down. The engine takes the edge and applies its
    -- own jump arc, gravity and landing -- including in interiors, which is
    -- the whole reason the hand-rolled arc is gone.
    if jumpPending then
        c.jump = true
        jumpPending = false
    else
        c.jump = false
    end

    -- Sent on CHANGE only, so a straight-line gallop costs one comparison per
    -- frame and no event traffic.
    reportState()
end

-- ---------------------------------------------------------------------------
-- SAVE / LOAD
-- ---------------------------------------------------------------------------

-- A ride does not survive a load: whywalk_global rebuilds the session and
-- re-sends MountStart. What CAN survive is this script still being attached,
-- because addScript persists in the save. If that happens the creature would
-- come back with standard AI still disabled and the last controls still set --
-- a statue, or a creature walking into a wall forever. So the load path
-- assumes no ride and restores the creature to its own devices; a genuine
-- resume re-disables AI a frame later.
local function onLoad()
    mounted = false
    throttle, steer, gallop = 0, 0, false
    jumpPending = false
    rider, lastState = nil, nil
    clearControls()
    -- Unconditional on purpose, unlike the other two sites. A save written
    -- while suppressMountAI was true and loaded after it was set to false
    -- would otherwise leave this creature's AI off forever.
    self:enableAI(true)
end

return {
    eventHandlers = {
        [EV_START]   = onMountStart,
        [EV_STOP]    = onMountStop,
        [EV_CONTROL] = onMountControl,
    },
    engineHandlers = {
        onUpdate = onUpdate,
        onLoad   = onLoad,
    },
}
