# Sun's Dusk addon module — template

A checklist and three skeleton files. Everything here was learned by shipping
`Scarves` (which crashed the game on first release) and `Goggles`.

## 1. There is no `.omwscripts`. Ever.

Sun's Dusk loads modules by **scanning directories**, not from a manifest:

```lua
sd_g.lua:43   vfs.pathsWithPrefix("scripts/SunsDusk/settings/")
sd_g.lua:56   vfs.pathsWithPrefix("scripts/SunsDusk/global_modules/")
sd_p.lua:390  vfs.pathsWithPrefix("scripts/SunsDusk/player_modules/p_")
```

Installing a module means **dropping files into those directories**. The VFS
merges data directories, so a separate mod folder works.

> Declaring a module file in your own manifest as well is **fatal**. OpenMW
> allows a script path exactly one set of flags; a second declaration aborts
> before the main menu — the whole game, not just the mod. Run
> `tools/check_manifest.py` on any manifest you do ship.

## 2. Layout

```
YourMod/
  scripts/SunsDusk/settings/yourmod_settings.lua      loaded by sd_g.lua (GLOBAL)
  scripts/SunsDusk/global_modules/g_yourmod.lua       loaded by sd_g.lua (GLOBAL)
  scripts/SunsDusk/player_modules/p_yourmod.lua       loaded by sd_p.lua (PLAYER)
  YourMod.esp                                         items
  YourMod_abilities.esp                               SPEL records, if any
```

## 3. Context follows the loader, not the filename

| file | `---@omw-context` |
|---|---|
| `settings/*.lua` | **`global`** — `sd_g.lua` requires it |
| `global_modules/g_*.lua` | `global` |
| `player_modules/p_*.lua` | `player` |

A file called `*_settings.lua` looks like it belongs in `menu`. It does not.
Annotating it `menu` is wrong and will flag its `world` usage.

## 4. The settings file runs in BOTH contexts

`sd_g.lua` requires it in global context, where `world` is set and it takes the
`registerGroup` branch. Registering the **page** needs a non-global context,
and `sd_p.lua` only requires `sd_settings` by name — so your player module must
`require` your settings file itself. That is what `sd_p.lua:381` does, and it
also guarantees your setting globals exist before the module reads them.

## 5. Host globals — do not re-require them

Sun's Dusk assigns these as globals deliberately (`sd_p.lua` lines 6-20), and
`require` shares the requiring script's environment:

```
core  types  util  world  I  animation  async  storage  MODNAME
saveData  typesActorInventorySelf  typesActorSpellsSelf
G_eventHandlers  G_onFrameJobs  G_onFrameJobsSluggish
G_onLoadJobs  G_UiModeChangedJobs  G_settingsChangedJobs
log
```

`G_globalSettingDefaults` is **not** one of them — Scarves writes to it and
nothing reads it. Check a bus name against `sd_p.lua` before using it:
`table.insert(nil, fn)` is a load-time crash.

Static checkers will report these as undeclared. Pass the list via `--globals`.

## 6. Bus writes must append, never replace

```lua
G_eventHandlers.YourMod_equipped = onEquipped        -- field write, safe
table.insert(G_onFrameJobsSluggish, onSluggishFrame) -- append, safe
G_settingsChangedJobs = G_settingsChangedJobs or {}  -- create-if-absent, safe
G_settingsChangedJobs.yourMod = fn

G_onLoadJobs = { onLoad }                            -- NEVER. Destroys every
                                                     -- other module's hooks.
```

## 7. Worn state is set by activation, not inferred

Keep it in `saveData`, written only when your ItemUsage handler reports a swap.
Deriving it by scanning for an `_eq` record makes **looting** one equal to
wearing it. Reconcile against the inventory on the sluggish list; never replace
state with a scan.

## 8. A missing SPEL record fails silently

`if core.magic.spells.records[id]` is the right guard, and it is also why
Scarves shipped a release where no bonus worked: the item plugin had 320 MISC
records and zero SPEL. **Log once** when the record is absent.

## 9. Per-frame budget

Use `G_onFrameJobsSluggish`, not `G_onFrameJobs`, for anything polling. The
cell sweep is expensive — trigger it only when your own reconcile finds a worn
record actually missing, never on equip/unequip.

## 10. No `pcall`

A new one needs a nameable category: documented recovery, cleanup/rethrow, host
isolation, or capability probing. "Defensive" is not a category. Neither
`Scarves` nor `Goggles` contains one.

## Checklist

- [ ] No `.omwscripts` for module files
- [ ] Three files in the three scanned directories
- [ ] `---@omw-context` on each, matching the loader
- [ ] Player module `require`s its own settings file
- [ ] Every `G_*` name verified against `sd_p.lua`
- [ ] Bus writes append or field-write; none replace
- [ ] Worn state from activation, reconciled not inferred
- [ ] SPEL records actually in the plugin; absence logged
- [ ] Zero `pcall`
- [ ] `luacheck`, `globalcheck --globals ...`, `ctxcheck` all clean
