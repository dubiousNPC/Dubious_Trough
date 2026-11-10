#!/bin/bash
# check_all.sh -- every CAKE check. Run from the package root.
#   LUAJIT=/path/to/luajit  COD3X=/path/to/cod3x  MW_DATA=/path/to/Data\ Files  (all optional)
cd "$(dirname "$0")/.."
S="00 Core/scripts"; F=0
run() { echo "--- $1"; shift; "$@" || F=$((F+1)); }
run "syntax (Lua 5.4)"            python3 tools/luacheck.py "$S"/cake/*.lua "$S"/AnimRefresh/*.lua
run "undefined and unused names"  python3 tools/check_names.py "$S"/cake/*.lua
run "globals"                     python3 tools/globalcheck.py "00 Core"
run "load under stubs"            python3 tools/check_load.py "00 Core"
run "manifest"                    python3 tools/check_manifest.py "00 Core/CAKE.omwscripts"
run "cross-reference sweep"       python3 tools/sweep.py
run "registry is current"         bash -c 'cp "00 Core/scripts/cake/cake_shared.lua" /tmp/cake_shared.$$ &&
                                    python3 tools/gen_cake_shared.py >/dev/null &&
                                    cmp -s /tmp/cake_shared.$$ "00 Core/scripts/cake/cake_shared.lua"; r=$?;
                                    cp /tmp/cake_shared.$$ "00 Core/scripts/cake/cake_shared.lua"; rm -f /tmp/cake_shared.$$;
                                    [ $r = 0 ] && echo "cake_shared.lua matches the plugins" || echo "STALE: re-run tools/gen_cake_shared.py"; exit $r'
run "worn models attach"          python3 tools/check_meshes.py
echo "--- bones dubiousBones.nif adds (info)"
python3 tools/nif_bones.py "00 Core"/animations/*/dubiousBones.nif | grep "NOT ON" | sort -u
[ -n "$COD3X" ] && run "API against Cod3x" python3 tools/api_sweep.py "$S" "$COD3X"
run "integration (Lua 5.4)"       python3 tools/luarun.py tools/test_integration.lua
if [ -n "$LUAJIT" ]; then
  run "integration (LuaJIT)"      "$LUAJIT" tools/test_integration.lua
  echo "--- syntax (LuaJIT)"
  for f in "$S"/cake/*.lua "$S"/AnimRefresh/*.lua; do "$LUAJIT" -e "assert(loadfile('$f'))" || F=$((F+1)); done; echo "ok"
fi
echo; [ $F = 0 ] && echo "ALL CHECKS PASSED" || echo "$F CHECK(S) FAILED"; exit $F
