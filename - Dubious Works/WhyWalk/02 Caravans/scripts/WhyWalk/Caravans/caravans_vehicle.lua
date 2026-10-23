---@omw-context local
--[[
    caravans_vehicle.lua -- the vehicle's own gait, while it is being placed

    Registered CUSTOM and attached with addScript when a journey starts,
    removed when it ends, so a parked vehicle carries no code.

    WHY THIS FILE HAS TO EXIST AT ALL

    Because the vehicle is PLACED, not driven. caravans_path.lua explains why
    it has to be (the route runs through the body, 1220 units above the feet),
    and the consequence is the one the 2026-10-04 T-pose cost a round trip to
    learn:

        OpenMW's character controller picks a creature's locomotion group from
        the movement IT is asked to perform. A teleport is not movement, so
        the controller is never asked, never selects a group, and an actor
        with no active group renders at BIND POSE.

    Core's mount script solved that by not placing the creature at all -- it
    writes `controls` and lets the engine move it. A route vehicle cannot do
    that, so it is back to playing the gait by hand, which is what Devilish
    Guar Riding does and why its guar animates.

    `loops` IS A LARGE FINITE NUMBER, NOT -1

    Cod3x's contract for playBlended is `loops` - a number >= 0, default 0.
    `-1` is outside it. Both the mount script (2026-10-08) and ridingAnim
    (2026-10-09) shipped `loops = -1` meaning "forever" and played nothing or
    played once; DGR passes 999999 for the same intent and its guar animates.
    Writing it out here so the third occurrence is the last.
]]

local self      = require('openmw.self')
local animation = require('openmw.animation')
local I         = require('openmw.interfaces')

local db = require('scripts.WhyWalk.Caravans.caravans_db')

local EV_START = 'WWCaravans_VehicleStart'
local EV_STOP  = 'WWCaravans_VehicleStop'

-- See the header. 999999 loops at a few seconds each outlasts any journey by
-- several orders of magnitude.
local LOOPS = 999999

local gaitGroup = nil      -- the group currently playing, nil when stopped

-- ---------------------------------------------------------------------------
-- PRIORITY
-- ---------------------------------------------------------------------------
-- PRIORITY.Scripted, and the reasoning changed on 2026-10-17.
--
-- Core's mount script uses PRIORITY.Default and argues that a ridden
-- creature's locomotion is its OWN, so it should sit where the character
-- controller would have put it and lose fights it ought to lose. That is
-- right for a creature the engine is moving.
--
-- This creature is not being moved by the engine; it is being placed, frame
-- by frame, and there is no circumstance in which something else should be
-- animating it mid-journey. Default would be deleted outright by anything
-- sharing it -- the Boats priority work found that a uniform priority is
-- deleted by a same-priority animation rather than merely outranked -- and a
-- single hit landing on the strider would strip its gait for the rest of the
-- journey.
--
-- The old objection to Scripted was that it pauses every other animation.
-- That was WRONG and was corrected in the same pass: the pausing comes from
-- mPlayScriptedOnly, which the engine sets only from the MWScript animation
-- queue, never from a Lua priority. So Scripted here costs nothing it used to
-- be thought to cost.
--
-- The gait is cancelled explicitly on stop, so a vehicle that dies or is
-- dismissed is free to play its own animations again.
local function gaitPriority()
    return animation.PRIORITY.Scripted
end

---Play `group` if the skeleton has it, falling back through the chain.
---
---Checked with hasGroup rather than hoped for, because playBlended on a group
---the skeleton lacks is a silent no-op -- the whole of the 2026-10-22
---fallback bug. A vehicle whose mesh has no `runforward` gets `walkforward`,
---then `idle`, and if it has none of them it renders static and the journey
---still works.
local FALLBACK = { "runforward", "walkforward", "idle" }

local function resolveGait(preferred)
    if preferred and animation.hasGroup(self, preferred) then return preferred end
    for _, g in ipairs(FALLBACK) do
        if animation.hasGroup(self, g) then return g end
    end
    return nil
end

local function playGait(preferred)
    local group = resolveGait(preferred)
    if not group then return end
    if group == gaitGroup then return end

    local previous = gaitGroup
    gaitGroup = group

    local opts = {
        loops       = LOOPS,
        forceLoop   = true,
        priority    = gaitPriority(),
        blendMask   = animation.BLEND_MASK.All,
        autoDisable = false,
    }
    -- The interface form where it exists, so animation mods that hook
    -- playBlendedAnimation see this too (the DGR pattern); the base module
    -- otherwise.
    if I.AnimationController and I.AnimationController.playBlendedAnimation then
        I.AnimationController.playBlendedAnimation(group, opts)
    else
        animation.playBlended(self, group, opts)
    end

    if previous and previous ~= group then animation.cancel(self, previous) end
end

local function stopGait()
    if gaitGroup then
        animation.cancel(self, gaitGroup)
        gaitGroup = nil
    end
end

-- ---------------------------------------------------------------------------
-- EVENTS
-- ---------------------------------------------------------------------------

local function onVehicleStart(data)
    -- The vehicle is placed every frame, so its own AI must not also be
    -- issuing movement. One call, as Core's mount script does; physics and
    -- the character controller keep running, which is what lets the gait
    -- play at all.
    self:enableAI(false)

    local vehicleId = data and data.vehicle
    local v = db.vehicle(vehicleId)
    playGait(v and v.gait)
end

local function onVehicleStop()
    stopGait()
    self:enableAI(true)
end

-- ---------------------------------------------------------------------------
-- SAVE / LOAD
-- ---------------------------------------------------------------------------

-- A journey does not survive a load; caravans_global aborts it and puts the
-- player down. What CAN survive is this script still being attached, because
-- addScript persists in the save -- so the load path restores the creature to
-- its own devices rather than assuming a journey is still running.
--
-- enableAI(true) unconditionally: a save written mid-journey and loaded would
-- otherwise leave a strider with its AI off forever, and the whole point of
-- the 2026-10-08 mount-script onSave fix was that a looping animation
-- outlives the script's memory of it. onSave records the group so onLoad can
-- cancel the right one.
local function onSave()
    return { gait = gaitGroup }
end

local function onLoad(data)
    local held = data and data.gait
    if held then animation.cancel(self, held) end
    gaitGroup = nil
    self:enableAI(true)
end

return {
    eventHandlers = {
        [EV_START] = onVehicleStart,
        [EV_STOP]  = onVehicleStop,
    },
    engineHandlers = {
        onSave = onSave,
        onLoad = onLoad,
    },
}
