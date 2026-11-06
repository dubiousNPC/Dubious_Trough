# WhyWalk and Parkourwind FLOW (2026-11-05)

FLOW v0.86 publishes `I.Flow`. All three modules now stand FLOW down while they
hold the player, and hand it back when they let go. Without FLOW installed,
nothing changes.

## What went wrong without it

A held player is never grounded: the engine skips the physics step of an actor
that is placed every frame. FLOW read that as a jump in progress, and it ran its
airborne ladder on the player. These cases were reproduced in FLOW's
`tools/sim/test_interop.lua` against FLOW v0.85:

| module | what happened |
|---|---|
| Core | Space, which is the mount's jump, put the rider into FLOW's LedgeHang off the saddle (`pwwallhangidle` over the riding pose) |
| Core | a mount leaping off a cliff played Skydive on the rider, then a knockdown Stumble on landing |
| Caravans | a passenger pressing Jump at the howdah went into LedgeHang: Levitate 200 and a snap to the lip, while `caravans_global` pins them to the slot |
| Boats | the same ladder runs against the hull and rigging; a ledge grab teleports the pilot off the deck |

## The change

| file | yield | resume |
|---|---|---|
| `00 Core/.../whywalk_player.lua` | `onMounted`, before `lockControls` | `onDismounted` after `releaseControls`; `onLoad` |
| `01 Boats/.../boats_player.lua` | `onBoarded`, before `lockControls` | `onLeft` (including a hand-off to Core); `onLoad` |
| `02 Caravans/.../caravans_player.lua` | `onStarted` | `onArrived`, `onAborted`, `onLoad` |

Owners are `WhyWalk.Core`, `WhyWalk.Boats` and `WhyWalk.Caravans`. Yields are
counted per owner, so in a Boats-to-Core hand-off, Core's yield and Boats'
resume can arrive in either order.

**The yield comes before the lock.** `overrideMovementControls` is one flag
shared by every mod, and FLOW releases its own hold on it as it stands down.
That write has to land before WhyWalk's, not over it.

## Tests

- **Core:** `tools/test_riderflow.lua`, new, 7 checks, run by `check_all.sh`.
  It loads the real `whywalk_player`, checks the yield comes before the lock and
  the resume after the release, and that a ride still works with no FLOW.
- **Boats:** `test_boats_scripts.lua` gains 4 checks: the boarding order, the
  leaving order, the hand-off, and load.
- **Caravans:** `test_intercept.lua` gains 4 checks: departure, arrival, abort,
  and load.
- **In engine,** OpenMW 0.52 RC1, suite `test_flowinterop`: 6/6. FLOW, Core,
  Boats, Caravans and Hookshot load together on one player with no Lua errors.
  Covered:
  - `I.Flow` is reachable;
  - a real `WhyWalk_Mounted` / `WhyWalk_Dismounted` pair yields and resumes;
  - so does a real caravan journey;
  - so do overlapping ride and journey holders;
  - so does the `Flow_Yield` event sent from a global script.

## Also corrected

`02 Caravans/tools/check_luajit.py` flagged `table.move` and `utf8.*` as missing
in LuaJIT. Both exist in the engine: `table.move` is a LuaJIT 2.1 built-in, and
OpenMW provides `utf8`. The checker reported Hookshot's `hookshot_util.lua` for
a call that works. Both entries are removed from the list.
