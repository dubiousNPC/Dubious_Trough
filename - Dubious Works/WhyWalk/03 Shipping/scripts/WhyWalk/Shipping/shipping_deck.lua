---@omw-context none
--[[
    shipping_deck.lua -- who the ship carries while they walk its deck

    Pure: no openmw requires. The global script owns the geometry (it built
    the hull's transform and carries the player rigidly with it); this decides,
    each frame, WHETHER to carry.

    THE PATTERN (measured on Watercraft and Ben's Skyships, 2026-11-12): take
    the player's offset from the hull from where they stand NOW, move the hull,
    put the player at the new hull plus that offset. Their own walking happens
    between frames, so it survives. Both mods held 0.0 drift standing and kept
    the engine's walk pace.

    WHO IS ABOARD is decided by what the player stands on, as Watercraft does
    (GetStandingPC), never by a radius, as Skyships does: its 2,500-unit radius
    drags a swimmer beside the hull along with it. The player script casts down
    from the player's feet and reports the change ("footing"); the global
    script cannot cast rays.

      * on the vessel                 -> carried
      * not on it, within GRACE of
        last being on it              -> carried: a jump, or the ray missing a
                                         plank between two others. Watercraft
                                         lets a jump inherit the hull's speed
                                         and landed 22 behind; carrying through
                                         the jump lands where it took off
      * swimming                      -> not carried; after RESCUE_SWIM the
                                         crew haul them back aboard
      * otherwise (adrift on a rock,
        a sandbar)                    -> not carried; after RESCUE_ADRIFT, the
                                         same
      * no report yet                 -> carried. A missing player script (or
                                         one from an older version) must leave
                                         the passenger aboard, not overboard.

    A passenger ship does not stop because its passenger left their spot:
    the voyage runs on regardless (Watercraft's coasting-only deck is the
    counter-example).
]]

local M = {}

M.TUNING = {
    GRACE         = 1.5,   -- seconds carried after the last footing on the hull
    RESCUE_SWIM   = 2.0,   -- seconds in the water before being hauled aboard
    RESCUE_ADRIFT = 4.0,   -- seconds off the hull, not swimming, likewise
}

---@param now number simulation seconds
function M.new(now)
    return { lastAboard = now, adrift = 0, footing = nil }
end

---Record what the player script reported. `f` is { onVessel = bool,
---swimming = bool } or nil.
function M.setFooting(st, f)
    st.footing = f
end

---One frame. Returns 'carry', 'free' or 'rescue'.
---@param st table from M.new
---@param dt number
---@param now number
function M.step(st, dt, now)
    local f = st.footing
    if f == nil then
        st.lastAboard, st.adrift = now, 0
        return 'carry'
    end
    if f.onVessel and not f.swimming then
        st.lastAboard, st.adrift, st.wet = now, 0, false
        return 'carry'
    end
    -- At the surface the engine's swimming flag flickers from frame to frame
    -- (measured on the gondola, 2026-11-12: true/false every 0.06 s). Once
    -- they have been in the water, only standing on the hull again counts:
    -- the jump grace must not drag a swimmer along for a frame at a time.
    if f.swimming then st.wet = true end
    if not f.swimming and not st.wet and now - st.lastAboard <= M.TUNING.GRACE then
        return 'carry'
    end
    st.adrift = st.adrift + dt
    local limit = f.swimming and M.TUNING.RESCUE_SWIM or M.TUNING.RESCUE_ADRIFT
    if st.adrift >= limit then
        st.adrift = 0
        st.lastAboard = now
        -- Until the player script reports the new footing, assume aboard.
        st.footing = nil
        st.wet = false
        return 'rescue'
    end
    return 'free'
end

---Where a carried passenger goes: their offset from the hull's last pose,
---in that pose's own frame (yaw AND roll, so someone at the rail rises and
---falls with the deck as it heels), put back on the hull's new pose.
---`from` and `to` are { pos = Vector3, rot = Transform }; `p` the player's
---position now. Only methods of the values passed are used, so this stays
---free of requires.
function M.carry(from, to, p)
    return to.pos + to.rot:apply(from.rot:inverse():apply(p - from.pos))
end

return M
