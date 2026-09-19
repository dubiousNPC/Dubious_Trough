# Install — read this first

**Each module folder is its own data directory.** This is the whole reason the
items were not equipping.

```
data="…/SD_Modules/00 Core"
data="…/SD_Modules/Scarves"
data="…/SD_Modules/Eyewear"

content=SD_Gear.omwaddon
content=SD_Scarves.esp
content=SD_Scarves_abilities.esp
content=SD_Goggles.esp
```

Load **after** Sun's Dusk.

## Why it has to be this way

These modules ship no `.omwscripts` and no `LUAL` record — by design, because
Sun's Dusk loads its own modules by scanning the VFS:

```lua
-- sd_g.lua:43, :56
for filename in vfs.pathsWithPrefix("scripts/SunsDusk/global_modules/") do
    require((filename:gsub("%.lua$", ""):gsub("/", ".")))
end
-- sd_p.lua:390  -> scripts/SunsDusk/player_modules/p_*
```

The prefix is matched against the **VFS path**, so
`scripts/SunsDusk/global_modules/g_scarves.lua` has to sit at the VFS root.
That happens only when `Scarves/` itself is the `data=` entry.

Point `data=` at `SD_Modules/` instead and the VFS path becomes
`Scarves/scripts/SunsDusk/global_modules/g_scarves.lua`. The prefix never
matches, nothing is required, the `ItemUsage` handler is never registered — and
using an item does nothing, **with no error, because no code ran**.

That is exactly the reported symptom: the item simply will not equip, and the
log is clean.

## Confirming it loaded

Both modules now log one line as they load:

```
[SD Scarves] module loaded; ItemUsage handler registering
[SD Eyewear] module loaded; ItemUsage handler registering
```

**No line means the module is not installed**, not that it is broken. A silent
non-install is indistinguishable from a silent bug, and that cost a round trip
here.

## Plugin note

`SD_Gear.omwaddon` (110 MISC) and `SD_Scarves.esp` (320 MISC) both define the
same 110 records — `SD_Gear`'s ids are a strict subset. Whichever loads later
wins. That is harmless while the definitions agree, but it is a duplicate the
next edit can desynchronise: if `SD_Gear` is meant to supersede `SD_Scarves.esp`,
drop the older plugin rather than shipping both.
