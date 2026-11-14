"""Shipping carries a copy of Caravans' route walker. Fail if the two differ.

The walker is pure and module-agnostic, and keeping one copy per module means
neither module needs the other installed. The cost is drift, so this makes it
a test failure rather than a surprise. When Caravans is not alongside (a
Shipping-only checkout) there is nothing to compare and it says so."""
import hashlib, os, sys
here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
pairs = [('scripts/WhyWalk/Shipping/shipping_path.lua', '../02 Caravans/scripts/WhyWalk/Caravans/caravans_path.lua')]
bad = 0
for mine, theirs in pairs:
    a, b = os.path.join(here, mine), os.path.normpath(os.path.join(here, theirs))
    if not os.path.exists(b):
        print('skip: %s not found' % theirs); continue
    ha = hashlib.sha256(open(a, 'rb').read()).hexdigest()
    hb = hashlib.sha256(open(b, 'rb').read()).hexdigest()
    if ha != hb:
        print('DRIFT: %s differs from %s' % (mine, theirs)); bad += 1
    else:
        print('same: %s' % mine)
sys.exit(1 if bad else 0)
