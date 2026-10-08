#!/bin/sh
# Every check this module has, from the module root:  sh tools/check_all.sh [cod3x-dir]
# Regenerating the source data needs the reference mods; see BOATS_README.md.
set -e
cd "$(dirname "$0")/.."
S=scripts/WhyWalk/Boats

python3 -I tools/check_load.py     $S/*.lua
python3 -I tools/check_handlers.py $S/*.lua
python3 -I tools/globalcheck.py    $S/*.lua
python3 -I tools/check_manifest.py WhyWalk_Boats.omwscripts
if [ -n "$1" ]; then python3 -I tools/ctxcheck.py "$1" $S/*.lua; fi
python3 -I tools/luarun.py tools/test_boats.lua
python3 -I tools/luarun.py tools/test_boats_scripts.lua
python3 -I tools/check_db_sources.py
python3 -I tools/gen_database_doc.py
