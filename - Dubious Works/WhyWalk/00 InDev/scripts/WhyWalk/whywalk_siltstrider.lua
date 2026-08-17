---@omw-context none
--[[
    whywalk_siltstrider.lua -- CATALOGUE ONLY, NOT WIRED IN

    Nothing requires this file. It is the silt strider material from two
    sources, recorded so the eventual WhyWalk implementation does not have to
    re-derive it. Register it in WhyWalk.omwscripts only when the strider path
    actually ships; until then it costs nothing because it is never loaded.

    SOURCES
      [B] Rideable Silt Striders (bensmodz)  -- native OpenMW Lua, rough
      [R] Immersive Travel (rfuzzo)          -- MWSE + compat shim, precise

    Where the two disagree, [R] wins on numbers and [B] wins on OpenMW API.

    ========================================================================
    MEASURED MOUNT DATA  [R] mounts/a_siltstrider.json, c_siltstrider.json
    ========================================================================
    The two files are byte-identical; the a_/c_ prefix is an activator vs
    creature variant of the same body, so there is one set of numbers.

        mesh              r\Siltstrider.nif
        offset            -1220        reference-to-ground
        sway              1            lowest of any mount in that pack
        speed             3            slowest of any mount in that pack
        turnspeed         30
        forwardAnimation  "runForward" the MOUNT's own gait group
        nodeName          "Body"       slots are relative to this niNode
        nodeOffset        (0, 56, 1005)
        sound             Silt_1, Silt_2, Silt_3   (loopSound = false)

        guideSlot     (0, 10, 1223)   animationGroup "idle5"   -- the caravaner
        hiddenSlot    (0, 0, 1000)                             -- parked actors
        passenger 1   (0, 80, 1223)   animationGroup {}
        passenger 2   (-81, 30, 1230) animationGroup {}
        passenger 3   (81, 40, 1230)  animationGroup {}

    CORRECTION TO whywalk_shared.PROFILE[SILT_STRIDER]
    Current value there is saddle.up = 1300, estimated from [B]. The measured
    value is 1223 for the front seat, and it is not a single point: there are
    three passenger positions spread +/-81 on X. Use 1223 and treat the lateral
    offsets as a multi-slot problem, which WhyWalk's one-saddle PROFILE cannot
    express yet (see SCHEMA GAP below).

    Also note the guide slot has an animation group ("idle5") but the PASSENGER
    slots have empty ones -- in that mod passengers are simply placed, not
    posed. WhyWalk poses the rider, so the passenger slots need groups invented
    rather than copied.

    ========================================================================
    SCHEMA GAP -- what [R]'s MountData has that WhyWalk's PROFILE does not
    ========================================================================
    [R]'s types.lua is a properly annotated schema and is a better data model
    than the flat PROFILE table. Fields worth adopting, in rough value order:

      slots[]          multiple ride positions per mount, each with its own
                       position AND animationGroup list. WhyWalk supports one
                       saddle and one animation set per mount TYPE; this is
                       per-SLOT. Needed for passengers, and for any mount where
                       the rider sits somewhere other than dead centre.
      nodeName +       slots resolved relative to a named niNode rather than
      nodeOffset       the object origin. This is why [R]'s numbers survive
                       mesh replacers and [B]'s do not.
      guideSlot        a second occupant that is not the player. Nothing in
                       WhyWalk models an NPC riding along.
      hiddenSlot       where to park actors that should exist but not render.
      clutter[]        attached props with position + orientation (the boats
                       use it for crates and lanterns; striders use none).
      sway             periodic lateral lean, scaled per mount. Cheap, adds a
                       lot; constants below.
      forwardAnimation the MOUNT's gait group. WhyWalk deliberately leaves gait
                       to the engine, so this is informational -- but it does
                       tell you the vanilla strider gait is "runForward".
      idList[]         list of record ids sharing one mount definition, i.e.
                       exactly WhyWalk's MOUNT_TYPE_BY_RECORD inverted.
      hasFreeMovement  per-mount flag for "steerable off-route". Both boats
                       have it; neither strider does.
      scale            render scale multiplier.

    SWAY  [R] main.lua:20-23, 663-702
        SWAY_MAX_AMPL    3      max lean in a turn
        SWAY_AMPL_CHANGE 0.01   how fast lean converges
        SWAY_FREQ        0.12   oscillation frequency
        SWAY_AMPL        0.014  base amplitude, multiplied by mount.sway
    Applied as amplitude * sin(2*pi*FREQ*t), clamped to MAX_AMPL*amplitude,
    and eased toward the target by AMPL_CHANGE per step rather than snapping.
    For a strider (sway = 1) this is deliberately almost imperceptible; the
    boats run 3-4.

    ========================================================================
    ROUTE NETWORK -- compared
    ========================================================================
    [B]  9 origin NPCs, 33 routes, 1356 points. Vanilla Vvardenfell only.
         Keyed travelData[originNpcRecordId][destinationName], includes cost.
    [R]  242 route files, 5810 points across four services:
             Caravaner (silt strider)   49 routes, 2305 points
             Shipmaster (boat)         105 routes, 2297 points
             Gondolier (gondola)        40 routes,  942 points
             Riverstrider (TR)           8 routes,  266 points
         Keyed by filename "Origin_Destination.json", value is a flat array of
         {x,y,z}. No cost in the file -- price is computed at runtime.

    [R] covers far more ground: Tamriel Rebuilt mainland (Almas Thirr,
    Andothren, Necrom, Bosmora, Omaynis, Sailen, Vhul, Aimrah, Arvud, Menaan,
    Hlan Oek, Tel Gilan, Ranyon-ruhn, Molag Ruhn) plus Telvanni Isles for the
    riverstrider. [B] is vanilla-only but its routes carry fares and it is
    already native OpenMW.

    Two [R] Caravaner files are EMPTY (0 points): Necrom_Sailen and
    Sailen_Bosmora. Two more are duplicated with differing point counts
    (Gnisis_Ald-ruhn 71 and 72, Gnisis_Khuul 29 and 30) because the same route
    appears in more than one of the uploaded archives. Deduplicate on import
    and drop the empties, or the strider will teleport to origin on those legs.

    PRICING  [R] omw_main.lua reimplements OpenMW's own travel price formula:
        disposition, weighted luck/personality/mercantile, fatigue term,
        fTravelMult, and (1 + nFollowers). If fares matter, take this over
        [B]'s hardcoded per-route gold -- it is the engine's actual maths.

    ========================================================================
    COMPATIBILITY -- why [R] cannot simply be adopted
    ========================================================================
    [R] is an MWSE mod running under a compatibility shim, not a native OpenMW
    mod. The .omwscripts loads omw_main.lua, which calls
    I.mwse2omw:initMod{...}, requires "omw_mwse_nocontext", and then hands off
    to the unmodified MWSE main.lua. Throughout it uses tes3ui.createMenu,
    tes3referenceAdapter, tes3vector3, and getmetatable(x).base to unwrap
    shimmed objects, and it writes to _G.

    omw_speed.lua is the clearest tell:

        return speed * currentDt * OMW_TARGET_FPS * speedMult   -- 60

    The movement model is written in per-frame steps assuming 60fps, and the
    shim multiplies by dt*60 to approximate frame independence. WhyWalk
    integrates against dt directly, so none of [R]'s movement code transfers --
    only its DATA does.

    VERDICT
      Take from [R]: mount measurements, the MountData schema, sway constants,
        the route point sets, the pricing formula.
      Take from [B]: core.land.getHeightAt for ground without raycasts, the
        MWScript-globals rider bridge, runtime record creation via
        createRecordDraft/createRecord/createObject.
      Take from neither: the movement loop. [R]'s is frame-step based, [B]'s is
        a 492-line onUpdate.

    ========================================================================
    IMPLEMENTATION NOTE
    ========================================================================
    A silt strider is a vehicle, not a mount, and the difference matters. It
    has a guide NPC, multiple passengers, a fixed route, and no player steering
    on-route. That is a different mode from "mount a creature and steer it",
    and shoehorning it into PROFILE/saddle would distort both.

    Suggested shape when it ships: a separate VEHICLE mode sharing WhyWalk's
    session, pin and animation layers, but with slots[] instead of a single
    saddle and a route walker instead of steering input. The rider animation
    layer needs no change -- SILT_STRIDER already resolves to a sitting group.
]]

return {
    -- Deliberately empty. Turn the notes above into data when the strider path
    -- is actually built; shipping half a schema now would only be rewritten.
}
