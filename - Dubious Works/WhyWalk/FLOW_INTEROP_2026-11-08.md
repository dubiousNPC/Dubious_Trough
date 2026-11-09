# WhyWalk on real Morrowind data (2026-11-08)

Run in OpenMW 0.52 on Morrowind, Tribunal and Bloodmoon, with the real
WhyWalk.esp, Flow v0.86 and Hookshot, using real key presses and vanilla
bindings (Jump is E, Activate is Space). Every Flow interop check passed:
- a real guar ride yields FLOW;
- E at a lip while mounted leaves FLOW Idle, and the dismount hands it back;
- a real rowboat boarded through `WWBoats_RequestBoard` yields FLOW;
- E at the helm leaves FLOW Idle, and leaving hands it back.

The run also found three WhyWalk issues:

## Fixed: Space jumped and dismounted at once (Core)
The mount's jump was the literal Space key, read in `onKeyPress`. In
Morrowind's default bindings Space is Activate, and the Activate handler,
`requestMount`, dismounts a mounted rider. So one press sent a jump and a
dismount, and the rider was dismounted. In-engine on a guar: "DISMOUNTED by
Space".

The fix reads the mount's jump from the **Jump trigger**, the same way
Activate is read, so it follows the player's binding (E by default). Activate
still dismounts, as the README documents.
- `tools/test_riderflow.lua` gains 5 checks (12 total). Without the fix, 2 of
  them fail.
- The README's control table is updated.

## Found, not fixed: the mount's jump does nothing (Core)
The engine gives creatures no jump. `MWWorld::Class::getJump` returns 0, only
`Npc` overrides it, and `CharacterController` zeroes the vertical push when it
is 0. A real `guar` and `guar_feral` rose 0 units, both from the Jump key and
from a direct `WhyWalk_Control {jump}`. So `controls.jump` on the mount can
never work. A working mount jump needs a scripted arc again, which is a design
decision. It is documented under Known limitations.

## Fixed: a Lua error on every boarding of a static boat (Boats)
`board()` runs in an event handler and teleports the copy that `takeOver` just
made. The same frame's `onUpdate` then teleported it again, and the engine
refused: "Object is either removed or already in the process of
teleporting". `onUpdate` now skips the boarding frame, keyed on
`core.getSimulationTime()`, which is the same throughout one frame.

The test stub now refuses a second teleport in one frame wherever a test walks
real frame order. The new check fails without the fix, and Boats passes
69/69.
