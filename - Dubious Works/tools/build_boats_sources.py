#!/usr/bin/env python3
"""build_boats_sources.py -- extract every movement number the boat module is
built on, straight out of the reference mods, into data/boats_sources.json.

Generated, not hand-maintained (RESEARCH 4.3). Every value carries the file and
line it came from, the raw number, and the conversion to canonical units:

    distance  world units (u)         speed   u/s
    angle     radians                 rate    rad/s
    accel     u/s^2                   drag    1/s (exponential decay constant)

Frame-coupled sources are converted at the frame rate the source itself
assumes, and say so:
    Immersive Travel (OpenMW shim)   omw_speed.lua  OMW_TARGET_FPS = 60
    Skyships                         deltaMult = 1 per frame, dt*80 in low-fps mode -> 80
    Stormrider                       SRE_SpeedFPSMult = dt * SRE_SpeedFPSMod (72)
    Aetherius's Outpost              per-frame increments, no dt -> 60 assumed
    Rideable Silt Striders           units per frame -> 60 assumed

Text-sourced constants (Lua and MWScript) are located by regex and the script
FAILS if a pattern stops matching, so a changed source cannot silently leave a
stale number in the database.

Usage:  build_boats_sources.py <extracted-uploads-dir> <stormrider.json> [out.json]
"""
import json
import math
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import nifbox  # noqa: E402

SRC = sys.argv[1]
STORMRIDER_JSON = sys.argv[2]
OUT = sys.argv[3] if len(sys.argv) > 3 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)), '..', 'data', 'boats_sources.json')

IT_DIR = os.path.join(SRC, 'Immersive_Travel', 'Immersive Travel', 'MWSE', 'mods', 'rfuzzo', 'ImmersiveTravel')
IT_MESH = os.path.join(SRC, 'Immersive_Travel', 'Immersive Travel', 'Meshes')
SKY = os.path.join(SRC, 'BensMods_Skyships', 'BensMods_Skyships', 'scripts', 'bensmodz_ss_global.lua')
RSS = os.path.join(SRC, 'BensMods_RideableSiltstriders', 'BensMods_RideableSiltstriders', 'scripts', 'bensmodz_rss_global.lua')
AO_G = os.path.join(SRC, "Aetheriuss_Outpost", "Aetherius's Outpost", 'scripts', 'AetheriusOutpost2', 'ShipManagement_G.lua')
AO_P = os.path.join(SRC, "Aetheriuss_Outpost", "Aetherius's Outpost", 'scripts', 'AetheriusOutpost2', 'PlayerControls_p.lua')
YOG_DIR = [d for d in os.listdir(SRC) if d.startswith('Your_Own_Gondola')][0]
YOG_JSON = os.path.join(SRC, YOG_DIR, 'YourOwnGondola.json')
YOG_NIF = os.path.join(SRC, YOG_DIR, 'Meshes', 'GV_Gondola.nif')
SRE_MESH = os.path.join(SRC, '00_Core', '00 Core', 'Meshes', 'SRE')

failures = []


def rel(path):
    return os.path.relpath(path, SRC).replace(os.sep, '/')


def find(path, pattern, text=None, group=1, flags=0):
    """Return (number, line) for the first regex match, or record a failure."""
    body = text if text is not None else open(path, encoding='latin-1').read()
    m = re.search(pattern, body, flags)
    if not m:
        failures.append('%s: pattern not found: %s' % (rel(path) if text is None else path, pattern))
        return None, None
    line = body.count('\n', 0, m.start()) + 1
    return float(m.group(group)), line


def val(raw, unit, canonical, canonical_unit, formula, src, line=None, note=None):
    out = {'raw': raw, 'unit': unit, 'value': canonical, 'canonicalUnit': canonical_unit,
           'formula': formula, 'source': src}
    if line is not None:
        out['line'] = line
    if note:
        out['note'] = note
    return out


def r(x, n=4):
    return None if x is None else round(x, n)


# ---------------------------------------------------------------------------
# Immersive Travel (rfuzzo), OpenMW shim
# ---------------------------------------------------------------------------
IT_FPS, _ = find(os.path.join(IT_DIR, 'omw_speed.lua'), r'OMW_TARGET_FPS\s*=\s*(\d+)')
it_sway = {}
for key, pat in (('SWAY_MAX_AMPL', r'SWAY_MAX_AMPL\s*=\s*([\d.]+)'),
                 ('SWAY_AMPL_CHANGE', r'SWAY_AMPL_CHANGE\s*=\s*([\d.]+)'),
                 ('SWAY_FREQ', r'SWAY_FREQ\s*=\s*([\d.]+)'),
                 ('SWAY_AMPL', r'SWAY_AMPL\s*=\s*([\d.]+)')):
    v, line = find(os.path.join(IT_DIR, 'main.lua'), pat)
    it_sway[key] = {'raw': v, 'line': line}

data_defects = []


def load_lenient(path):
    """Strict JSON first; on failure, retry with trailing commas removed and
    record the defect -- the file is broken for any strict reader in game."""
    text = open(path, encoding='utf-8').read()
    try:
        return json.loads(text)
    except json.JSONDecodeError as err:
        data_defects.append({'file': rel(path), 'error': str(err),
                             'impact': 'strict JSON parsers reject this file'})
        return json.loads(re.sub(r',(\s*[}\]])', r'\1', text))


it_mounts = {}
for name in sorted(os.listdir(os.path.join(IT_DIR, 'mounts'))):
    path = os.path.join(IT_DIR, 'mounts', name)
    data = load_lenient(path)
    mid = name[:-5]
    spd, turn, sway = data.get('speed'), data.get('turnspeed'), data.get('sway')
    entry = {
        'file': rel(path),
        'mesh': data.get('mesh'),
        'hasFreeMovement': data.get('hasFreeMovement', False),
        'sound': data.get('sound'),
        'loopSound': data.get('loopSound'),
        'speed': val(spd, 'u/frame@%dfps' % IT_FPS, r(spd * IT_FPS), 'u/s',
                     'speed * OMW_TARGET_FPS  (omw_speed.adjustSpeed: speed*dt*60)', rel(path)),
        'turnRate': val(turn, 'turnspeed', r(turn * IT_FPS / 10000.0), 'rad/s',
                        'turnspeed * OMW_TARGET_FPS / 10000  (main.lua: angle = adjustSpeed(turnspeed)/10000 per tick)',
                        rel(path)),
        'swayAmplitude': val(sway, 'sway factor', r(sway * it_sway['SWAY_AMPL']['raw'], 5), 'rad',
                             'sway * SWAY_AMPL (%.3f)' % it_sway['SWAY_AMPL']['raw'], rel(path)),
        'waterOffset': val(data.get('offset'), 'u', data.get('offset'), 'u',
                           'mount.position = spline point + (0,0,offset)', rel(path)),
        'guideSlot': (data.get('guideSlot') or {}).get('position'),
        'hiddenSlot': (data.get('hiddenSlot') or {}).get('position'),
        'slots': [{'position': s['position'], 'animationGroup': s.get('animationGroup'),
                   'animationFile': s.get('animationFile')} for s in data.get('slots', [])],
        'clutter': data.get('clutter', []),
    }
    for k in ('nodeName', 'nodeOffset', 'forwardAnimation'):
        if k in data:
            entry[k] = data[k]
    it_mounts[mid] = entry

it_services = {}
for name in sorted(os.listdir(os.path.join(IT_DIR, 'services'))):
    data = load_lenient(os.path.join(IT_DIR, 'services', name))
    it_services[name[:-5]] = {'mount': data.get('mount'), 'class': data.get('class'),
                              'override_mount': data.get('override_mount')}
it_routes = {}
for service in ('Gondolier', 'Shipmaster', 'Caravaner', 'T_Mw_RiverstriderService'):
    d = os.path.join(IT_DIR, service)
    if not os.path.isdir(d):
        continue
    files = sorted(os.listdir(d))
    pts = [len(json.load(open(os.path.join(d, f)))) for f in files]
    it_routes[service] = {'routes': len(files), 'points': sum(pts),
                          'emptyRoutes': [f for f, n in zip(files, pts) if n == 0]}

# ---------------------------------------------------------------------------
# Ben's Skyships
# ---------------------------------------------------------------------------
SKY_FPS = 80
sky = {}
for key, pat, unit, conv, unit2, formula in (
    ('accel', r'skyshipSpeed = math\.min\(skyshipSpeed \+ ([\d.]+) \* deltaMult', 'u/frame^2@80',
     lambda v: v * SKY_FPS * SKY_FPS, 'u/s^2', 'raw * 80 * 80'),
    ('maxSpeed', r'skyshipSpeed \+ [\d.]+ \* deltaMult, ([\d.]+) \+ upgrade_shipSpeed', 'u/frame@80',
     lambda v: v * SKY_FPS, 'u/s', 'raw * 80'),
    ('brake', r'skyshipSpeed = math\.max\(skyshipSpeed - ([\d.]+) \* deltaMult', 'u/frame^2@80',
     lambda v: v * SKY_FPS * SKY_FPS, 'u/s^2', 'raw * 80 * 80'),
    ('turnTargetRate', r'skyshipRotTarget = skyshipRotTarget \+ ([\d.]+) \* deltaMult', 'rad/frame@80',
     lambda v: v * SKY_FPS, 'rad/s', 'raw * 80  (rate the TARGET heading moves)'),
    ('turnResponse', r'skyshipRot = skyshipRot \+ \(\(skyshipRotTarget - skyshipRot \+ math\.pi\) % \(2\*math\.pi\) - math\.pi\) \* dt \* \((\d+)',
     '1/s', lambda v: v, '1/s', 'heading eases toward target: d/dt = error * 1'),
    ('verticalSpeed', r'if input_jump then moveVertical = ([\d.]+) \* deltaMult', 'u/frame@80',
     lambda v: v * SKY_FPS, 'u/s', 'raw * 80'),
    ('terrainClearance', r'SILVERCASCADE_TERRAIN_CLEARANCE = (\d+)', 'u', lambda v: v, 'u', 'raw'),
    ('terrainProbeDistance', r'SILVERCASCADE_TERRAIN_PROBE_DISTANCE = (\d+)', 'u', lambda v: v, 'u', 'raw'),
    ('deckAttachRadius', r'SILVERCASCADE_DECK_ATTACHMENT_RADIUS = (\d+)', 'u', lambda v: v, 'u', 'raw'),
    ('restTravelThreshold', r'SILVERCASCADE_REST_TRAVEL_THRESHOLD = ([\d.]+)', 's game', lambda v: v, 's', 'raw'),
):
    v, line = find(SKY, pat)
    if v is not None:
        sky[key] = val(v, unit, r(conv(v)), unit2, formula, rel(SKY), line)
sky['notes'] = [
    'deltaMult is 1 per frame unless low-fps mode (dt*80): the reference is frame-coupled at 80 fps.',
    'Speed only increases with Forward and decreases with Backward; there is no reverse (min 0).',
    'Heading eases toward a target that the rudder moves, so turns start and stop softly.',
    'Safe height = max(terrain + 2500, sea level when both here and 8192u ahead are over water).',
    'Deck carry: the player offset is re-measured in ship-local axes every frame, so you can walk the deck in flight.',
    'Rest/wait: game-time jumps over 5 s are integrated in 4096u steps against the same safe-height rule.',
]

# ---------------------------------------------------------------------------
# Rideable Silt Striders (Ben)
# ---------------------------------------------------------------------------
rss = {}
for key, pat, note in (
    ('maxSpeed', r'local striderMaxSpeed = (\d+)', 'u/frame; frame-coupled, 60 fps assumed'),
    ('approachRate', r'travelSpeed = travelSpeed \+ dt \* ([\d.]+) \* \(striderMaxSpeed - travelSpeed\)', 'exponential approach rate, 1/s'),
    ('coastDecel', r'elseif travelSpeed > 0 then travelSpeed = travelSpeed - dt', 'u/frame per second'),
    ('riderDrop', r'targetTravelPos \+ util\.vector3\(0,0,-(\d+)\)', 'strider origin below rider'),
):
    if key == 'coastDecel':
        body = open(RSS, encoding='latin-1').read()
        m = re.search(pat, body)
        if not m:
            failures.append('%s: pattern not found: %s' % (rel(RSS), pat))
            continue
        rss[key] = val(1.0, 'u/frame/s', 60.0, 'u/s^2', '1 u/frame per s * 60', rel(RSS),
                       body.count('\n', 0, m.start()) + 1, note)
        continue
    v, line = find(RSS, pat)
    if v is None:
        continue
    if key == 'maxSpeed':
        rss[key] = val(v, 'u/frame', v * 60, 'u/s', 'raw * 60', rel(RSS), line, note)
    else:
        rss[key] = val(v, '', v, '', 'raw', rel(RSS), line, note)

# ---------------------------------------------------------------------------
# Aetherius's Outpost (reference only)
# ---------------------------------------------------------------------------
ao = {}
v, line = find(AO_G, r'local increment = ([\d.]+) \* dt')
if v is not None:
    ao['linearAccel'] = val(v, 'u/frame^2@60', r(v * 3600), 'u/s^2', 'raw * 60 * 60 (dt is hard-coded to 1)', rel(AO_G), line,
                            'Applies to forward, side and vertical alike; no speed cap in practice.')
v, line = find(AO_G, r'local decreaseBy = ([\d.]+)')
if v is not None:
    ao['drag'] = val(v, 'retain/frame@60', r(-math.log(v) * 60), '1/s', '-ln(raw) * 60', rel(AO_G), line,
                     'Released axes decay geometrically; this is the reference for coasting.')
v, line = find(AO_G, r'increment = ([\d.]+) \* dt\s*\n\s*if keyData\["RotatePlus"\]')
if v is not None:
    ao['angularAccel'] = val(v, 'deg/frame^2@60', r(math.radians(v) * 3600), 'rad/s^2', 'rad(raw) * 60 * 60', rel(AO_G), line)
for key, pat in (('slow', r'slow = \{ forward = (\d+)'), ('medium', r'medium = \{ forward = (\d+)'),
                 ('fast', r'fast = \{ forward = (\d+)')):
    v, line = find(AO_P, pat)
    if v is not None:
        ao['flightGear_' + key] = val(v, 'u/s', v, 'u/s', 'raw (onFrame, scaled by dt)', rel(AO_P), line)
ao['notes'] = [
    'Momentum on every axis, including strafe and yaw, with drag when released: the "excellent flight" feel.',
    'Hull collision: paired inner/outer marker objects, one castRay per pair; any hit sends ShipHit.',
    'Deck detection: a 1000u downward ray from the player picks the object stood on.',
]

# ---------------------------------------------------------------------------
# Your Own Gondola (GrumblingVomit)
# ---------------------------------------------------------------------------
yog_records = json.load(open(YOG_JSON))
yog_script = next(r_['text'] for r_ in yog_records if r_['type'] == 'Script').replace('\r', '')
yog_acti = next(r_ for r_ in yog_records if r_['type'] == 'Activator')
yog = {'activator': {'id': yog_acti['id'], 'name': yog_acti['name'], 'mesh': yog_acti['mesh'],
                     'script': yog_acti['script']}}
v, line = find('YourOwnGondola.json:GV_PlayerGondScript', r'Rotate x,\s*(\d+)', text=yog_script)
yog['pitchRate'] = val(v, 'deg/s', r(math.radians(v), 5), 'rad/s', 'MWScript Rotate is per second', 'GV_PlayerGondScript', line)
v, line = find('YourOwnGondola.json:GV_PlayerGondScript', r'set swingTime to (\d+)', text=yog_script)
yog['swingTime'] = val(v, 's', v, 's', 'up 1T, down 2T, up 1T: period 4T', 'GV_PlayerGondScript', line)
if v is not None and yog['pitchRate']['raw'] is not None:
    yog['pitchAmplitude'] = val(yog['pitchRate']['raw'] * v, 'deg', r(math.radians(yog['pitchRate']['raw'] * v), 5), 'rad',
                                'pitchRate * swingTime (triangle wave)', 'GV_PlayerGondScript', line)
    yog['pitchPeriod'] = val(4 * v, 's', 4 * v, 's', '4 * swingTime', 'GV_PlayerGondScript', line)
v, line = find('YourOwnGondola.json:GV_PlayerGondScript', r'SetPos, Z, (0)\b', text=yog_script)
yog['boatZ'] = val(v, 'u', v, 'u', 'boat origin held at z 0 (sea level)', 'GV_PlayerGondScript', line)
yog['notes'] = [
    'The PLAYER moves (ModWaterWalking 1) and the boat is SetPos-ed under them every frame.',
    'Boat heading = player heading: mouse-look steers.',
    'Exit when the player Z rises above 0 (walked onto land), or by activating the boat.',
    'stopsound footWaterLeft/Right every frame: walking on water otherwise splashes.',
]

# ---------------------------------------------------------------------------
# Stormrider Expanded (Kellick Stormcrow, SuperCrumpets)
# ---------------------------------------------------------------------------
sr_records = json.load(open(STORMRIDER_JSON))
sr_scripts = {r_['id']: r_['text'].replace('\r', '') for r_ in sr_records if r_['type'] == 'Script'}
sr_globals = {r_['id']: r_.get('value') for r_ in sr_records if r_['type'] == 'GlobalVariable'}
SR_FPS_MOD = sr_globals.get('SRE_SpeedFPSMod')
stats_text = sr_scripts['SC_SRE_ShipStats']
sr_ships = {}
for m in re.finditer(r'(?im)^\s*set\s+(KS_SR_Boat|KS_SR_Ship|SC_NewShip\d\d|SC_NewBoat00)_(\w+)\s+to\s+([-\d.]+)', stats_text):
    prefix, field, num = m.group(1), m.group(2), float(m.group(3))
    sr_ships.setdefault(prefix, {})[field] = {'raw': num, 'line': stats_text.count('\n', 0, m.start()) + 1}
sr_names = {'KS_SR_Boat': 'Rowboat', 'KS_SR_Ship': 'Stormrider', 'SC_NewBoat00': 'Fishing Boat',
            'SC_NewShip01': 'Galleon', 'SC_NewShip02': 'Cutter', 'SC_NewShip03': 'Empire Trade Ship',
            'SC_NewShip04': 'Nord Trade Ship', 'SC_NewShip05': 'LongBoat', 'SC_NewShip06': 'Dunmer Small Ship',
            'SC_NewShip07': 'Altmer Trade Ship', 'SC_NewShip08': 'Bosmer Ship', 'SC_NewShip09': 'Redguard Ship'}
sr_acti = {r_['id']: r_ for r_ in sr_records if r_['type'] == 'Activator'}
sr_mesh_by_prefix = {'KS_SR_Boat': sr_acti['KS_SR_Boat']['mesh'], 'KS_SR_Ship': sr_acti['KS_SR_Ship']['mesh'],
                     'SC_NewBoat00': sr_acti['SC_O_NewBoat00']['mesh']}
for i in range(1, 10):
    key = 'SC_NewShip%02d' % i
    acti = sr_acti.get('SC_O_NewShip%02d' % i)
    if acti:
        sr_mesh_by_prefix[key] = acti['mesh']

# Sailing seat per ship from SC_SRE_Var's autoselect blocks; boat Z from each ship script.
var_text = sr_scripts['SC_SRE_Var']
seat = {}
for block in re.finditer(r'if \( SC_Autoselectedship == (\d+) \)(.*?)\nendif', var_text, re.S | re.I):
    code, body = int(block.group(1)), block.group(2)
    who = re.search(r'set SC_AselShip_Angle to (\w+?)_Angle', body)
    pos = [re.search(r'SailingPos%s to\s+([-\d.]+)' % ax, body) for ax in 'xyz']
    if who and all(pos):
        seat[who.group(1)] = {'autoselect': code, 'x': float(pos[0].group(1)), 'y': float(pos[1].group(1)),
                              'z': float(pos[2].group(1)), 'line': var_text.count('\n', 0, block.start()) + 1}
script_by_prefix = {'KS_SR_Boat': 'KS_SR_Boat_Script', 'KS_SR_Ship': 'KS_SR_Ship_Script',
                    'SC_NewBoat00': 'SC_NewBoat00_Script'}
for i in range(1, 10):
    script_by_prefix['SC_NewShip%02d' % i] = 'SC_NewShip%02d' % i


def sailing_z(text):
    m = re.search(r'Set the sailing motion.*?(?:^|\n)\s*setPos, z, ([-\d.]+)', text, re.S | re.I)
    return float(m.group(1)) if m else None


catalogue_sr = {}
for prefix, fields in sorted(sr_ships.items()):
    def f(name):
        return fields.get(name, {}).get('raw')
    script = sr_scripts.get(script_by_prefix.get(prefix, ''), '')
    boat_z = sailing_z(script)
    entry = {'name': sr_names.get(prefix), 'mesh': sr_mesh_by_prefix.get(prefix),
             'script': script_by_prefix.get(prefix), 'fields': fields}
    if f('BaseSpeed') is not None:
        entry['baseSpeed'] = val(f('BaseSpeed'), 'speedf', f('BaseSpeed') * SR_FPS_MOD, 'u/s',
                                 'speedf * SRE_SpeedFPSMod (%g)' % SR_FPS_MOD, 'SC_SRE_ShipStats', fields['BaseSpeed']['line'],
                                 'speed with no wind')
    if f('SpeedLimit') is not None:
        entry['speedLimit'] = val(f('SpeedLimit'), 'speedf', f('SpeedLimit') * SR_FPS_MOD, 'u/s',
                                  'speedf * %g' % SR_FPS_MOD, 'SC_SRE_ShipStats', fields['SpeedLimit']['line'],
                                  'cap with full wind, scaled by hull damage')
    if f('Accel') is not None:
        entry['accel'] = val(f('Accel'), 'speedf/s', f('Accel') * SR_FPS_MOD, 'u/s^2', 'raw * %g' % SR_FPS_MOD,
                             'SC_SRE_ShipStats', fields['Accel']['line'])
    if f('Decel') is not None:
        entry['decel'] = val(f('Decel'), 'speedf/s', f('Decel') * SR_FPS_MOD, 'u/s^2', 'raw * %g' % SR_FPS_MOD,
                             'SC_SRE_ShipStats', fields['Decel']['line'])
    if f('Turnrate') is not None:
        if prefix == 'KS_SR_Boat':
            entry['turnRate'] = val(f('Turnrate'), 'deg/s', r(math.radians(f('Turnrate'))), 'rad/s',
                                    'MWScript rotate z is per second; only while speed != 0',
                                    'SC_SRE_ShipStats', fields['Turnrate']['line'])
        else:
            entry['turnRatePerSpeed'] = val(f('Turnrate'), 'deg/s per speedf', r(math.radians(f('Turnrate'))), 'rad/s per speedf',
                                            'TurnRate = Turnrate * speedf (min SRE_ShipMinTurnRate %s deg/s once speedf >= 1)'
                                            % sr_globals.get('SRE_ShipMinTurnRate'),
                                            'SC_SRE_ShipStats', fields['Turnrate']['line'])
    if boat_z is not None:
        entry['waterOffset'] = val(boat_z, 'u', boat_z, 'u', 'boat setPos z while sailing (sea level 0)', script)
    if prefix in seat:
        s = seat[prefix]
        entry['pilotSeat'] = {'raw': s, 'note': 'x/y are multiplied by the heading sin/cos: a distance along the bow axis. z is absolute.'}
    catalogue_sr[prefix] = entry

# The rowboat is not in SC_SRE_Var's numbered blocks the same way; read it from its own branch.
row_seat = re.search(r'if \( SC_Autoselectedship == 1 \) ;Rowboat(.*?)\nendif', var_text, re.S)
if row_seat:
    zz = re.search(r'SailingPosz to (\d+)', row_seat.group(1))
    catalogue_sr['KS_SR_Boat']['pilotSeat'] = {'raw': {'x': 0, 'y': 0, 'z': float(zz.group(1))},
                                               'note': 'player at boat origin, both at z 2'}
rb = sr_scripts['KS_SR_Boat_Script']
m = re.search(r'set KS_SR_Boat_Speedf\s+to (-1)', rb)
if m:
    catalogue_sr['KS_SR_Boat']['reverseSpeed'] = val(-1.0, 'speedf', -SR_FPS_MOD, 'u/s',
                                                     'menu "Reverse" sets speedf -1', 'KS_SR_Boat_Script',
                                                     rb.count('\n', 0, m.start()) + 1)
else:
    failures.append('KS_SR_Boat_Script: reverse speed not found')
m = re.search(r'KS_SR_Boat_Distance > (\d+)', rb)
if m:
    catalogue_sr['KS_SR_Boat']['collisionDrift'] = val(float(m.group(1)), 'u', float(m.group(1)), 'u',
                                                       'player/boat separation that counts as a hit (player blocked by geometry)',
                                                       'KS_SR_Boat_Script', rb.count('\n', 0, m.start()) + 1)
sr_wind = {
    'SpeedFPSMod': SR_FPS_MOD, 'ShipMinSpeedLimit': sr_globals.get('SRE_ShipMinSpeedLimit'),
    'ShipMinTurnRate': sr_globals.get('SRE_ShipMinTurnRate'), 'ReverseSpeed': sr_globals.get('SRE_ReverseSpeed'),
    'notes': [
        'Wind direction re-targets on weather change and drifts up to 30 deg per game hour (SC_WindAngleScript).',
        'Sail polar: BestPoint / ClosestPoint (deg off the wind) per ship; inside ClosestPoint the ship decelerates at 2x Decel.',
        'MaxSpeed = BaseSpeed + windSpeed * WindBonusMult * sailingSkill * polar(angle); capped at SpeedLimit * hull/durability.',
        'Rowboat: WindBonusMult 0, BestPoint 180, ClosestPoint 0 -- oars only.',
    ],
}

# ---------------------------------------------------------------------------
# Mesh measurements
# ---------------------------------------------------------------------------
# Which end is the bow is NOT readable from geometry: the gondola's narrow end
# is its stern. It is read from how each source mod moves the mesh.
IT_BOW = ('+Y', 'Immersive Travel moves its _rot meshes along the object +Y axis (mount.forwardDirection)')
SR_BOW = ('-Y', 'Stormrider sets object angle = travel angle - 180 (KS_SR_Boat_Script / SC_NewBoat00_Script)')
BOW_AXIS = {
    'x/ex_gondola_01_rot.nif': IT_BOW, 'x/ex_gondola_rpnr_01_rot.nif': IT_BOW,
    'x/ex_longboat_rot.nif': IT_BOW, 'x/ex_de_ship_rot.nif': IT_BOW,
    'gv_gondola.nif': ('+Y', 'identical end profiles to x/ex_gondola_01_rot.nif, only translated'),
    'sre/sc_newboat00.nif': SR_BOW, 'sre/sc_newship05.nif': SR_BOW, 'sre/ks_sr_ship.nif': SR_BOW,
}

meshes = {}
for label, path, source in (
    ('x/ex_gondola_01_rot.nif', os.path.join(IT_MESH, 'x', 'Ex_Gondola_01_rot.nif'), 'Immersive Travel'),
    ('x/ex_gondola_rpnr_01_rot.nif', os.path.join(IT_MESH, 'x', 'Ex_Gondola_RPNR_01_rot.nif'), 'Immersive Travel'),
    ('x/ex_longboat_rot.nif', os.path.join(IT_MESH, 'x', 'Ex_longboat_rot.nif'), 'Immersive Travel'),
    ('x/ex_de_ship_rot.nif', os.path.join(IT_MESH, 'x', 'Ex_DE_ship_rot.nif'), 'Immersive Travel'),
    ('gv_gondola.nif', YOG_NIF, 'Your Own Gondola'),
    ('sre/sc_newboat00.nif', os.path.join(SRE_MESH, 'SC_NewBoat00.nif'), 'Stormrider Expanded'),
    ('sre/sc_newship05.nif', os.path.join(SRE_MESH, 'SC_NewShip05.nif'), 'Stormrider Expanded'),
    ('sre/ks_sr_ship.nif', os.path.join(SRE_MESH, 'KS_SR_Ship.nif'), 'Stormrider Expanded'),
):
    blocks = nifbox.parse(path)
    ext = nifbox.extents(blocks)
    rb_, cb_ = nifbox.box(ext['render']), nifbox.box(ext['collision'])
    pts = ext['render']
    lo, hi = rb_[0][1], rb_[1][1]
    length = hi - lo

    def end_profile(a, b):
        zs = [p[2] for p in pts if a <= p[1] <= b]
        ws = [abs(p[0]) for p in pts if a <= p[1] <= b]
        return {'zMax': round(max(zs), 1), 'halfWidth': round(max(ws), 1)}
    neg, pos = end_profile(lo, lo + 0.12 * length), end_profile(hi - 0.12 * length, hi)
    meshes[label] = {
        'source': source, 'file': rel(path),
        'render': {'min': rb_[0], 'max': rb_[1], 'vertices': len(ext['render'])},
        'collision': ({'min': cb_[0], 'max': cb_[1], 'vertices': len(ext['collision'])} if cb_ else None),
        'rootCollisionNode': any(b.get('type') == 'RootCollisionNode' for b in blocks.values()),
        'endMinusY': neg, 'endPlusY': pos,
        'bowAxis': BOW_AXIS[label][0], 'bowEvidence': BOW_AXIS[label][1],
    }

# Cross-check that GV_Gondola is the IT gondola re-origined, and by how much.
gv, itg = meshes['gv_gondola.nif']['render'], meshes['x/ex_gondola_01_rot.nif']['render']
meshes['gv_gondola.nif']['originInRotFrame'] = [
    round(itg['min'][0] - gv['min'][0], 1), round(itg['min'][1] - gv['min'][1], 1), round(itg['min'][2] - gv['min'][2], 1)]
meshes['gv_gondola.nif']['note'] = ('Same hull as x/ex_gondola_01_rot.nif (identical extents and end profiles), '
                                   'translated so the origin sits aft and at the floor. originInRotFrame is where '
                                   'GV_Gondola.nif\'s origin falls in the _rot mesh\'s coordinates.')

out = {
    'generatedBy': 'tools/build_boats_sources.py',
    'conventions': {
        'distance': 'world units (u)', 'speed': 'u/s', 'angle': 'rad', 'rate': 'rad/s',
        'accel': 'u/s^2', 'drag': '1/s, v *= exp(-drag*dt)',
        'frame': 'x right, y forward (bow), z up -- the vessel frame used by boats_db.lua',
    },
    'dataDefects': data_defects,
    'immersiveTravel': {'fps': IT_FPS, 'sway': it_sway, 'mounts': it_mounts, 'services': it_services,
                        'routes': it_routes},
    'skyships': sky,
    'rideableSiltStriders': rss,
    'aetheriusOutpost': ao,
    'yourOwnGondola': yog,
    'stormrider': {'globals': sr_wind, 'ships': catalogue_sr},
    'meshes': meshes,
}

if failures:
    print('EXTRACTION FAILURES:', file=sys.stderr)
    for f_ in failures:
        print('  ' + f_, file=sys.stderr)
    sys.exit(1)

os.makedirs(os.path.dirname(os.path.abspath(OUT)), exist_ok=True)
with open(OUT, 'w') as fh:
    json.dump(out, fh, indent=1, sort_keys=False)
print('wrote %s: %d IT mounts, %d Stormrider vessels, %d meshes' % (OUT, len(it_mounts), len(catalogue_sr), len(meshes)))
