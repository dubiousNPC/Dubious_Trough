# ShootFirst (example mod)

A minimal damaging projectile spell for OpenMW 0.51+, built as a worked
example on **Spell Framework Plus (SF+)**, with an optional **BeamFX**
visual flourish and optional **OSSC** quick-cast integration.

ShootFirst does not implement any hotkey, key binding, or custom
animation-playback logic of its own. It is a pure spell + a listener on
SF+'s event bus. Casting mechanics belong to other mods:

- **Spell Framework Plus (SF+)** is a **hard requirement**. It is the
  framework — not something reimplemented here — that turns a cast of
  this spell into a real physical projectile (collision, hit detection,
  auto-derived vanilla-style bolt/cast/hit VFX & sound from the
  `firedamage` magic effect) and that fires the `MagExp_CastRequest` /
  `MagExp_OnMagicHit` events this mod listens to.
- **OSSC** (Oblivion-Style Spell Casting) is **optional** and only
  checked for, never required. OSSC is the mod that owns the quick-cast
  hotkey and per-school/per-range animation selection; *OSSC* is the one
  that requires SF+, not ShootFirst. This mod does not know or care how
  a cast was initiated — it just listens for the events SF+ produces
  once a cast happens.

## Requirements

- OpenMW **0.51+**
- **Spell Framework Plus** (`SPELL_FRAMEWORK_PLUS.omwscripts`) — **hard
  requirement**, must be enabled and loaded *before*
  `ShootFirst.omwscripts`. If it's missing, ShootFirst logs an error at
  startup and the spell falls back to being an inert vanilla spell (see
  below) — nothing crashes, but none of the projectile/VFX behavior
  happens.
- **BeamFX** (`beamfx.omwscripts`) — optional. Adds a short beam flash on
  cast and impact. If absent, ShootFirst runs with no beam visuals (see
  `beamfx_adapter.lua`).
- **OSSC** — optional, checked for at startup (informational log only;
  no behavior branches on it in code, since OSSC's own settings UI is
  what actually decides which animation plays for a given school/range).

## How casting works

**With OSSC installed:** the player selects Shoot First like any spell
and presses OSSC's quick-cast key. OSSC plays whichever animation group
the player has assigned to Destruction/Target spells in its settings
(default: `quickcast`) and, at that animation's release key, calls
`core.sendGlobalEvent('MagExp_CastRequest', {...})`. SF+'s own global
script is what actually launches the projectile from that event —
ShootFirst just overhears the same event (filtered to its own spell ID)
to add a short BeamFX cast flash, and overhears `MagExp_OnMagicHit` to
add a BeamFX impact flash.

**Without OSSC installed:** there is no quick-cast key, so nothing
above happens — this is intended, not a degraded fallback path to build
around. The player casts Shoot First the ordinary way (ready the spell,
then cast as usual), and the engine handles it as a completely normal
vanilla Destruction/Target spell, using its own default spellcasting
animation. That vanilla cast path never touches SF+ or `MagExp_*`
events at all, so it never produces a physical projectile or a BeamFX
flourish — it just applies Fire Damage the ordinary vanilla way. This
*is* the "fallback animation similar to regular spellcasting": there is
nothing to build for it, since it's simply the game's default behavior
for any spell that doesn't go through SF+.

### Packaged animation group

ShootFirst is intended to ship a `quickcast`-named animation asset
(matching OSSC's default slot for Destruction/Target spells) for players
who want a distinctive quick-cast motion when using OSSC. Authoring the
actual `.nif`/`.kf` animation asset is outside the scope of this Lua
script package — nothing here fabricates one. Without a custom asset
installed, OSSC simply uses whatever `quickcast` animation is already on
the player's skeleton (vanilla or from another animation replacer).

## File layout

```
ShootFirst.omwscripts
scripts/shootfirst/
  global.lua           -- spell record, SF+ requirement check, OSSC
                          presence check, BeamFX flourish on cast/hit
  beamfx_adapter.lua    -- unmodified copy of BeamFX's official consumer
                           adapter template (lazy registration, provider-
                           reset recovery, retry/backoff, graceful no-op
                           if BeamFX isn't installed)
```

## Design notes

- `global.lua` never calls `I.MagExp.launchSpell` itself. SF+'s own
  global script already registers a handler on `MagExp_CastRequest` that
  does exactly that; OpenMW's global event bus delivers the same event
  to every global script's matching handler, so ShootFirst only needs to
  listen in and filter by spell ID — calling `launchSpell` a second time
  here would double-launch the projectile.
- The spell record is created dynamically at runtime via
  `core.magic.spells.createRecordDraft` + `world.createRecord` (same
  pattern used by the "Kinetic Forces" example mod for its dynamic Light
  record), so ShootFirst ships as pure Lua with no accompanying
  `.omwaddon` plugin. The generated ID is cached across saves and
  re-validated against `core.magic.spells.records` on load.
- The OSSC check uses `core.contentFiles.has(...)`, which is available
  in any script context, rather than reading OSSC's player-storage
  settings section — global scripts cannot access `storage.playerSection`
  at all (it's player/menu-context only), and content-file presence is
  a simpler, sufficient signal for a purely informational log line.
