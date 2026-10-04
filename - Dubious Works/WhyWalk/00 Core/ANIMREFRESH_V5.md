# AnimRefresh v5 — the UiModeChanged fix, and why the number moved

## The bug

v4 registered `UiModeChanged` under `engineHandlers`. It is an **event**, sent
to player scripts by OpenMW's built-in scripts, so the engine rejected it:

```
[E] Not supported handler 'UiModeChanged' in
    L@0x1[scripts/animrefresh/animrefresh_v4.lua]
```

One line per game, and v4's Rest/Travel/Training/Jail refresh — one of the four
things v4 was written to add — **never ran**, in any mod shipping that file.
Confirmed against the OpenMW reference: `UiModeChanged` appears on the
*events* page ("built-in scripts send to player the event `UiModeChanged` with
arguments `oldMode`, `newMode` and `arg`") and on no handler list.

It is now registered under `eventHandlers`.

## Why v5 and not a corrected v4

Every mod bundles this file at **one shared VFS path**, so exactly one copy
exists at runtime: whichever data directory wins. A corrected v4 and an
uncorrected v4 are the same path, so which one a player gets is decided by
their install order rather than by which is right — and nothing in the game
says which they got. Installing a mod that still had the old copy above one
with the fix would silently take the fix away from the whole suite.

Raising the number gives the fixed copy a path of its own. The `>=` guard then
makes it win over any older copy still installed, in **either** load order.
This is the rule the versioned filename exists for (RESEARCH §1.8: "any change
to delivery behaviour must raise the number").

A stale v4 left in a mod that has not been updated is then harmless: it
registers, loses the guard and runs inert with no subscribers. It still logs
the "Not supported handler" line, so that line now tells you *which mod is
behind* instead of reporting a live bug.

## Nothing else changed

v5 is v4 plus the handler move and the version bump. Same contract, same
`{ verify = true }` option, same readiness protocol, same timings. Subscribers
need no changes.

## Why the tests passed on a broken file

The v4 contract test called `AR.engineHandlers.UiModeChanged(...)` directly, so
it exercised a table the engine refuses to read, and reported ALL PASS. The
test now asserts the wiring itself:

```lua
local bad = {}
for k in pairs(H) do if not k:match('^on%u') then bad[#bad + 1] = k end end
check('engineHandlers holds only engine handler names', #bad == 0, ...)
check('UiModeChanged is registered as an event handler', type(E.UiModeChanged) == 'function')
```

Run against the old v4 file those two fail, along with the version check.

## New checker: `tools/check_handlers.py`

Nothing in the toolchain looked at handler names, which is why a one-line
mistake survived a full sweep. The new checker **loads** each module and
inspects the table it returns — the same table the engine reads — rather than
pattern-matching the source, because no regex reliably separates a table key
from an assignment inside an inline `function() ... end` handler.

It enforces four rules, with names checked against the documented handler set
and against the file's `---@omw-context`:

| finding | meaning |
|---|---|
| `EVENT-AS-HANDLER` | a known event under `engineHandlers` (this bug) |
| `NOT-A-HANDLER` | a non-`on*` name under `engineHandlers`; the engine rejects it |
| `UNKNOWN-HANDLER` | an `on*` name not in the documented set — a typo |
| `WRONG-CONTEXT` | e.g. `onPlayerAdded` in a player script |
| `HANDLER-AS-EVENT` | an engine handler under `eventHandlers`; never called |

It reports how many keys it inspected, so a clean run over nothing cannot look
like a pass, and it says when a file could not be loaded and was therefore not
inspected.

```
python3 tools/check_handlers.py scripts
python3 tools/check_handlers.py scripts --skip multiCheckbox.lua   # vendored
```

## Porting to a mod that still ships v4

1. Delete `scripts/AnimRefresh/AnimRefresh_v4.lua`, add `AnimRefresh_v5.lua`.
2. In the `.omwscripts`, change the filename on the `PLAYER:` line. One path,
   one flag set — do not add a second line.
3. Copy `tools/check_handlers.py` and `tools/test_animrefresh.lua`, and point
   any other test at the new filename (`grep -rn AnimRefresh_v4 tools`).
4. Run `check_handlers.py scripts`, `check_load.py scripts` and
   `test_animrefresh.lua`. Subscriber code needs no changes.
