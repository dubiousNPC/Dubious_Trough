"""Runs ReAnimation's own check_all.py against the Katar build.

check_all binds SRC/OUT/ALL_KFS/REFERENCE from build_compat at import time and loads the
rig reference at module level, so those are redirected before it is imported.
"""
import os, sys
TOOLS=os.environ['FBACOMPAT_TOOLS']
sys.path.insert(0, TOOLS)
import build_compat
build_compat.SRC = sys.argv[1]
build_compat.OUT = sys.argv[2]
build_compat.REFERENCE = sys.argv[3]
build_compat.ALL_KFS = sorted(n for n in os.listdir(build_compat.SRC) if n.lower().endswith('.kf'))
import check_all
for n in check_all.MERGED:
    check_all.check(n)
