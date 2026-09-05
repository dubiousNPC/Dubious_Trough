# Why nothing happened, and what changed

## The bug: the mesh path was never a VFS path

`cake_shared.lua` carried the mesh path baked in from the plugin:

```lua
model = 'RV\\Ashmask1.nif'
```

and `cake_player.lua` handed that straight to `animation.addVfx`.

A plugin's `MODL` subrecord is a **raw path relative to `meshes/`**, with the
author's original backslashes and casing. The Lua API's `record.model` is a
**VFS path** — Cod3x documents it as exactly that — which means
`meshes/`-prefixed, forward slashes, lowercased:

```
plugin MODL      RV\Ashmask1.nif
record.model     meshes/rv/ashmask1.nif
```

Those are different strings. `addVfx` was being given a path that does not
exist in the VFS, so it attached nothing. No error, no mesh, no log line — the
item was consumed, the `_eq` record was created, the state was set correctly,
and absolutely nothing appeared. "The item does nothing when selected."

**This was my doing.** Two sessions ago I removed the path normalisation from
the generator on the grounds that these meshes belong to other mods and their
paths should be reproduced verbatim. That reasoning is right for the *plugin*
and wrong for the *Lua registry*: the plugin stores raw MODL, the API speaks
VFS, and the four assertions I added to guard "path fidelity" were guarding the
wrong invariant. They asserted the registry matched the plugin, which it did,
while the thing that actually had to match was the engine.

### The fix

`cake_shared.lua` gains `M.meshFor(types, equippedId)`, which reads the model
off the record at runtime:

```lua
function M.meshFor(types, equippedId)
    local record = types.Miscellaneous.record(equippedId)
    return record and record.model or nil
end
```

Both `cake_player.lua` and `cake_npc.lua` now call it. `entry.model` is kept in
the registry as documentation of what the plugin declares, and is no longer
read at runtime by anything.

This is what Sun's Dusk and Bardcraft both do, and it is more robust than any
normalisation: it is correct by construction, and it survives someone editing
the plugin without regenerating the registry.

### Guarded against

The mock `addVfx` in `tools/test_integration.lua` now **rejects a non-VFS
path**, and three assertions were added:

```
mesh is resolved from the record, not from the baked plugin path
the baked registry path is NOT what gets attached
the attached path is a VFS path
```

The old test passed because its mock returned `m/<id>.nif` for `record.model`
and never compared the two forms. A mock that accepts anything tests nothing.

---

## Check this first

If items still do nothing, **check which plugin is enabled.** The registry is
generated from the `dbs_` scheme, and only one of the three shipped plugins
has those records:

| Plugin | Records | Registry base ids present | `_eq` ids present |
|---|---|---|---|
| `CAKE.esp` | 368 | **128 / 128** | **128 / 128** |
| `CAKE34.esp` | 22 | 0 / 128 | 0 / 128 |
| `CAKE402.esp` | 163 | 0 / 128 | 0 / 128 |

`CAKE402.esp` is the iteration with the `_eq`-on-display-name fault: 160 unique
ids, none prefixed `dbs_`, no `_eq` records at all. With it loaded instead of
`CAKE.esp`, `CAKE.get(item.recordId)` misses on every item and the handler
returns without doing anything — the same symptom, a different cause.

Either enable `CAKE.esp`, or convert `plugins_fixed/CAKEv4_2.json` back to an
`.esp` and use that.

---

## pcall audit

14 `pcall`s. **12 removed, 2 kept.** Each removal is an error that will now
surface in the log instead of being swallowed — which is the whole reason this
bug took a session to find.

### Removed

| Where | Call | Why the pcall was wrong |
|---|---|---|
| `cake_player` ×1, `cake_npc` ×1 | `anim.addVfx` | The one that hid this bug. A bad path or bone must be loud. |
| `cake_player` ×1, `cake_npc` ×1 | `anim.hasBone` | Documented for any actor; cannot throw on a valid one. |
| `cake_player` ×1, `cake_npc` ×1 | `anim.removeVfx` | Removing an id that was never added is a no-op. |
| `cake_player` | `inv:countOf` | Documented method on an inventory we just obtained. |
| `cake_global` | `obj:getBoundingBox` | Documented `GameObject` method on an object just enumerated from the cell. |
| `cake_anim` | `anim.playBlended` | Playing a group the skeleton lacks is a no-op, not an error. |
| `cake_anim` | `anim.cancel` | Cancelling a group that is not playing is a no-op. |
| `cake_settings` | `storage.playerSection` | Available in menu context, creates on demand. An absent renderer is a nil `get`, which is the case being tested anyway. |
| `cake_player` (earlier) | `item.type.records[id]` | Already gone; replaced by `record()`. |

### Kept

**`AnimRefresh_v1.lua` — `pcall(callback, mode, previous)`.** Calls into
*third-party* code. A subscriber throwing must not stop delivery to the others,
and the error is printed with the subscriber's key, not swallowed. This is the
legitimate use: isolating a boundary you do not control.

**`cake_player.lua` — `pcall(require, 'scripts.cake.cake_anim')`.**
`cake_anim.lua` is documented as deletable, so a missing module is a supported
state rather than a fault, and `require` has no non-throwing form. Now prints a
line when it fails instead of failing silently.

### The rule

A `pcall` is warranted when calling code you do not control, or when failure is
a supported state you have documented. Everywhere else it converts a diagnosable
crash into an undiagnosable silence, and on a mod whose entire output is "a mesh
appears", silence is indistinguishable from working.

---

## Sweeps

All clean after the change:

- `luacheck.py` — 7 files, 0 syntax errors
- `check_names.py` — no undefined names, no unused requires
- `sweep.py` — settings/categories/events/l10n/orphans all cross-referenced
- `api_sweep.py` **(new)** — every `module.member` call checked against the
  Cod3x stubs; nothing unrecognised. Worth keeping, since a misspelled API in a
  pcall-wrapped call is exactly this bug again.
- `test_shared.lua` — 21 registry assertions
- `test_integration.lua` — 38 assertions, now including the VFS-path guards
