# Why the skeleton dropdown was invisible

## The cause

The settings group declares `l10n = 'IED'`. That means `name` and `description`
on every setting in it are **localisation keys**, not display text. The old
setting passed literal prose:

```lua
key         = 'SHEATHBONES',
name        = 'Sheath bones',
description = 'Which skeleton bones sheathed gear attaches to.\n\n' .. ...,
renderer    = 'select',
argument    = { items = { 'auto', 'standard', 'sem' } },
```

Neither string is a key in `en.yaml`, so neither resolved. And the `argument`
had **no `l10n` field**: the built-in `select` renderer resolves each item
through localisation too, so `auto`, `standard` and `sem` all came back empty
and the control had nothing to draw.

Every other setting in the group used real keys (`setting_shownpcs`,
`setting_showammo`, …) and rendered fine — which is exactly why only this one
went missing. It was not a renderer problem; it was the only setting in the
file not written to the group's own convention.

The relay chain was never at fault. `SHEATHBONES` → `sheathBones` →
`cfg:get('sheathBones')` was consistent end to end.

## What it is now

```
Base slots        [ Standard  ▾ ]
```

| Option | Bones | Notes |
|---|---|---|
| **Standard** (default) | the original `_sh` sheathing slots | The bones OpenMW's own weapon sheathing uses. `Bip01 LongBladeOneHand` carries both long blades and one-hand axes. |
| **Alternative** | the `_Sem` slots from `semaroBones.nif` | Positioned for sheathed gear rather than reused from the sheathing rig. Axes get `Bip01 AxeOneHandSem`, so the standard long-blade/axe collision disappears. |

Both `name`/`description` and the two option labels are now real keys in
`l10n/IED/en.yaml`.

### The `auto` option is gone, but the probe is not

You asked for two options, so there are two. The per-actor skeleton probe that
`auto` used is kept and given a better job: **Alternative probes before
committing.**

The `_Sem` bones only exist where `semaroBones.nif` was actually merged into
that actor's skeleton. A creature, or an NPC on a third-party replacer, may not
have them — and attaching to a bone that is not there is a *silent* no-show.
So Alternative confirms `Bip01 LongBladeOneHandSem` exists on that specific
actor and falls back to Standard where it does not, rather than showing nothing.

This is still per actor, not global, because a cell can hold a mix. The probe
is cached per actor and re-asked only when the setting changes.

## SuperSelect3

Bundled at `scripts/SuperSettingsRenderers/SuperSelect3.lua`, verbatim and
unmodified, the same way AnimRefresh is shipped.

It is **optional**. It advertises itself by writing to the session-lifetime
`InstalledSettingsRenderers` storage section as it loads, and `settings.lua`
falls back to the engine's built-in `select` when that flag is absent. Deleting
the folder degrades the dropdown to arrows and changes nothing else.

It must load **before** `settings.lua` — entries in one `.omwscripts` run in
written order, and the flag is read at registration time — so the manifest lists
it first:

```
MENU:   scripts/SuperSettingsRenderers/SuperSelect3.lua
MENU:   scripts/show-all-weapons/settings.lua
```

If SuperSettingsRenderers is also installed standalone, delete that line and the
bundled folder; IED will find the standalone copy.

## Verification

| Sweep | Result |
|---|---|
| `luacheck.py` | 8 files, 0 failures |
| `check_names.py` | clean |
| `api_sweep.py` | nothing unrecognised |
| l10n keys used vs defined | **0 missing, 0 unused** |
| raw prose where a key is expected | **none remaining** |
| `pcall` in `show-all-weapons/` | **none** |

`tools/test_ied.lua` — 14/14 pass, five of them new:

```
standard uses the original _sh slot
alternative uses the _Sem slot
alternative gives axes their own bone, so no collision
alternative falls back to standard when the Sem bones are absent
unset baseSlots behaves as standard
```

The mock had to be updated in two ways to be worth anything here. It now reads
settings **through the subscribe callback** rather than mutating the config
table directly, because `common.lua` caches config rather than reading it live —
a test that pokes the table tests a path the engine never takes. And its
`addVfx` asserts a VFS path that exists in the mock VFS, per RESEARCH §4.1.
