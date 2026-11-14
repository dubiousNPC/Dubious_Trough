#!/bin/sh
# Every check this module has, from the module root:  sh tools/check_all.sh [cod3x-dir]
# Regenerating the route data needs Immersive Travel; see SHIPPING_README.md.
set -e
cd "$(dirname "$0")/.."
S=scripts/WhyWalk/Shipping

python3 -I tools/luacheck.py        $S/*.lua tools/*.lua
python3 -I tools/check_load.py      $S/*.lua
python3 -I tools/check_handlers.py  $S/*.lua
python3 -I tools/globalcheck.py     $S/*.lua
python3 -I tools/check_declorder.py $S/*.lua
python3 -I tools/check_names.py     $S/*.lua
python3 -I tools/check_manifest.py  WhyWalk_Shipping.omwscripts
python3 -I tools/check_luajit.py    $S/*.lua
python3 -I tools/check_shared.py
if [ -n "$1" ]; then python3 -I tools/ctxcheck.py    "$1" $S/*.lua; fi
if [ -n "$1" ]; then python3 -I tools/check_enums.py "$1" $S/*.lua; fi
python3 -I tools/luarun.py tools/test_shipping.lua
python3 -I tools/luarun.py tools/test_intercept.lua
