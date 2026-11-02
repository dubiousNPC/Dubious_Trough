#!/bin/sh
# Every check this module has, from the module root:  sh tools/check_all.sh [cod3x-dir]
set -e
cd "$(dirname "$0")/.."
S=scripts/WhyWalk

python3 -I tools/luacheck.py        $S/*.lua tools/*.lua
python3 -I tools/check_load.py      $S/*.lua
python3 -I tools/check_handlers.py  $S/*.lua
python3 -I tools/globalcheck.py     $S/*.lua
python3 -I tools/check_declorder.py $S/*.lua
python3 -I tools/check_names.py     $S/*.lua
python3 -I tools/check_manifest.py  WhyWalk.omwscripts
python3 -I tools/check_anims.py     $S/*.lua
# ctxcheck and check_enums both read the Cod3x annotations.
if [ -n "$1" ]; then python3 -I tools/ctxcheck.py    "$1" $S/*.lua; fi
if [ -n "$1" ]; then python3 -I tools/check_enums.py "$1" $S/*.lua; fi
python3 -I tools/luarun.py tools/test_resolveanim.lua
python3 -I tools/luarun.py tools/test_ridinganim.lua
python3 -I tools/luarun.py tools/test_saddlebox.lua
python3 -I tools/luarun.py tools/test_mountcontrols.lua
# Regenerating whywalk_creatures.lua needs the compiled profile; see CREATURES.md
python3 -I tools/gen_creatures.py tools/creatures_all.csv > /dev/null
