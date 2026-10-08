---@omw-context player
--[[
    boats_pose.lua -- the pilot's stance aboard

    Separate from the helm (ways-of-working: animation apart from gameplay; no
    requires between the two). Reacts to WWBoats_PoseStart / _PoseStop and to
    perspective changes through AnimRefresh. No per-frame handler.

    The pilot is moving under engine control, so the engine plays walk or run
    on them. The pose holds every bone group at PRIORITY.Hit: above Movement,
    so the legs stand (or sit) still while the boat carries them, and below
    Weapon, Block, Knockdown and Torch, so fighting, casting and torches work
    from the boat. Not Scripted: that pauses every other animation (RESEARCH
    3.2).
]]

local self = require('openmw.self')
local anim = require('openmw.animation')
local I    = require('openmw.interfaces')

local db = require('scripts.WhyWalk.Boats.boats_db')

local REFRESH_KEY = 'WhyWalkBoats'
local LOOPS = 999999   -- playBlended's loops must be >= 0; -1 is invalid, not infinite

local posed = nil      -- pose name while aboard
local group = nil      -- the group actually playing
local reportedMissing = {}

local function resolve(pose)
    local candidates = db.POSES[pose] or db.POSES.stand
    for _, g in ipairs(candidates) do
        if anim.hasGroup(self, g) then return g end
        if not reportedMissing[g] then
            reportedMissing[g] = true
            print("[WhyWalk Boats] pose group '" .. g .. "' is not on this skeleton; using the next one.")
        end
    end
    return nil
end

local function play()
    local g = resolve(posed)
    if not g then return end
    if group and group ~= g then anim.cancel(self, group) end
    anim.playBlended(self, g, {
        startKey = 'start', stopKey = 'stop',
        priority = anim.PRIORITY.Hit,
        blendMask = anim.BLEND_MASK.All,
        loops = LOOPS, forceLoop = true, autoDisable = false,
    })
    group = g
end

local function stop()
    if group then anim.cancel(self, group) end
    group = nil
end

-- A perspective switch rebuilds the animation object and drops the pose.
-- Returning false asks AnimRefresh to deliver again: the model was not ready.
local function onPerspective()
    if not posed then return end
    play()
    if group and not anim.isPlaying(self, group) then return false end
end

local function onPoseStart(data)
    posed = data and data.pose or 'stand'
    play()
    if I.AnimRefresh and I.AnimRefresh.subscribe then
        I.AnimRefresh.subscribe(REFRESH_KEY, onPerspective)
    end
end

local function onPoseStop()
    posed = nil
    stop()
    if I.AnimRefresh and I.AnimRefresh.unsubscribe then
        I.AnimRefresh.unsubscribe(REFRESH_KEY)
    end
end

-- A looping pose survives a save/load while this script's memory of it does
-- not (WhyWalk build review, section 3), so its name is saved and cancelled
-- on load. boats_player re-poses if the save was made afloat.
local function onSave()
    return { group = group }
end

local function onLoad(data)
    if data and data.group then anim.cancel(self, data.group) end
    posed, group = nil, nil
    if I.AnimRefresh and I.AnimRefresh.unsubscribe then
        I.AnimRefresh.unsubscribe(REFRESH_KEY)
    end
end

return {
    eventHandlers = {
        WWBoats_PoseStart = onPoseStart,
        WWBoats_PoseStop  = onPoseStop,
    },
    engineHandlers = {
        onSave = onSave,
        onLoad = onLoad,
    },
}
