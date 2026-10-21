#!/usr/bin/env bash
# Mutation checks of the Notifications focus resolver and key guards: every mutant below must make a shipped test FAIL.
# Offscreen only (no compositor). Takes about 10 minutes (a mutant stops at the first shipped test that fails).
#
#   tests/tools/mutate-notifications.sh                run every mutant, print "MUTANT <name> | <test> | CAUGHT/SURVIVED | <first FAIL line>"
#   tests/tools/mutate-notifications.sh --only M3,M11  run these mutants
#   tests/tools/mutate-notifications.sh --against REV  run the focus tests against shell/notifications/NotificationList.qml of git revision
#                                                      REV (violation counts of an older implementation)
# Mutants are applied to a scratch copy under .dev/ (removed on exit and on INT/TERM); the working tree is never edited,
# so an interrupted run leaves nothing behind. Exit 0 when every mutant was caught, 1 otherwise.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
export MUT_ROOT=$root
unset QT_QPA_PLATFORMTHEME
exec python3 -I - "$@" <<'PY'
import atexit, os, signal, subprocess, sys, tempfile, shutil

R = os.environ['MUT_ROOT'] + '/'
# Mutants and old revisions are applied to a scratch copy of shell/, ui/ and the tests (S), never to the working tree: an
# interruption (INT, TERM, even KILL) cannot leave a mutant in the sources. The compiled plugins and translations stay in R.
os.makedirs(R + '.dev', exist_ok=True)
S = tempfile.mkdtemp(prefix='mutate-', dir=R + '.dev') + '/'
for d in ('shell', 'ui'):
    shutil.copytree(R + d, S + d, symlinks=True)
os.makedirs(S + 'tests/shell')
os.makedirs(S + 'tests/unit')
for d in ('notif_center_list', 'notif_center_random', 'notif_center_random2'):
    shutil.copytree(R + 'tests/shell/' + d, S + 'tests/shell/' + d, symlinks=True)
shutil.copy(R + 'tests/unit/tst_buttonkeys.qml', S + 'tests/unit/')


def cleanup(*_):
    shutil.rmtree(S.rstrip('/'), ignore_errors=True)


atexit.register(cleanup)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
signal.signal(signal.SIGINT, lambda *_: sys.exit(130))
NL = S + 'shell/notifications/NotificationList.qml'
BT = S + 'ui/Grassfield/Ui/Button.qml'
L, RN, RN2, UNIT = 'tests/shell/notif_center_list', 'tests/shell/notif_center_random', 'tests/shell/notif_center_random2', 'unit'


def run_qs(d):
    tmp = tempfile.mkdtemp(dir=R + '.dev')
    try:
        os.makedirs(tmp + '/runtime', mode=0o700)
        os.makedirs(tmp + '/cache', mode=0o700)
        env = {k: v for k, v in os.environ.items() if k not in ('WAYLAND_DISPLAY', 'HYPRLAND_INSTANCE_SIGNATURE', 'QT_QPA_PLATFORMTHEME', 'DBUS_SESSION_BUS_ADDRESS')}
        env.update(QT_QPA_PLATFORM='offscreen', QML_IMPORT_PATH=S + 'ui:' + R + '.dev/build/qml', GRASSFIELD_TRANSLATIONS_DIR=R + '.dev/translations',
                   GRASSFIELD_LANG='en', XDG_RUNTIME_DIR=tmp + '/runtime', XDG_CACHE_HOME=tmp + '/cache', GRASSFIELD_DEV='1',
                   GRASSFIELD_STATE_HOME=tmp + '/state', GRASSFIELD_CONFIG_HOME=tmp + '/config')
        r = subprocess.run(['timeout', '150', 'qs', '-p', S + d, '--no-color'], capture_output=True, text=True, env=env, cwd=S)
        lines = [l for l in (r.stdout + r.stderr).splitlines() if 'notif-center-' in l]
        return lines[-1].strip()[:240] if lines else 'NO RESULT (exit %d): %s' % (r.returncode, (r.stdout + r.stderr)[-160:])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def run_unit():
    env = dict(os.environ, QML_XHR_ALLOW_FILE_READ='1', QT_QPA_PLATFORM='offscreen')
    env.pop('QT_QPA_PLATFORMTHEME', None)
    r = subprocess.run(['/usr/lib/qt6/bin/qmltestrunner', '-import', 'ui', '-input', 'tests/unit/tst_buttonkeys.qml'], cwd=S, capture_output=True, text=True, env=env)
    return '; '.join(l for l in r.stdout.splitlines() if l.startswith('FAIL') or l.startswith('Totals'))[:240]


def run(t):
    return run_unit() if t == UNIT else run_qs(t)


def caught(out):
    return 'FAIL' in out and 'PASS' not in out


# (name, file, text to find, replacement, tests that must fail)
MUTANTS = [
    ('M1 queueResolve is a no-op', NL, 'Qt.callLater(list.resolveFocus);', '/* no */', [L, RN, RN2]),
    ('M2 usable() ignores visibility and enabled', NL, 'return it !== null && it !== undefined && it.visible && it.enabled;', 'return it !== null && it !== undefined;', [L, RN, RN2]),
    ('M3 Clear All key guard off', NL, 'if (!ctl.visible || !ctl.enabled || (ctl.gate && !ctl.gate())) {', 'if (false) {', [L]),
    ('M4 focusAfterGone gets no old order', NL, 'list.snapRows.map(r => r.key), rows);', '[], rows);', [L]),
    ('M5 no forceLayout in the resolver', NL, '        list.forceLayout();\n        const who = list.focusId;', '        const who = list.focusId;', [L]),
    ('M6 focus-back rule reverted', NL, '                cur.forceActiveFocus();\n                list.settle(cur);', '                list.focusId = null;', [L, RN, RN2]),
    ('M7 Delete clears from any control', NL, 'else if (clear && (row.activeFocus || closeButton.activeFocus))', 'else if (clear)', [L]),
    ('M8 Button guard widened to every key', BT, '''        if (event.key !== Qt.Key_Space && event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter)
            return;''', '''        if (!root.visible || !root.enabled) {
            event.accepted = true;
            return;
        }
        if (event.key !== Qt.Key_Space && event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter)
            return;''', [UNIT]),
    ('M9 Button guard removed', BT, '        if (root.visible && root.enabled)\n            root.clicked();', '        root.clicked();', [UNIT]),
    ('M10 identity rank not refreshed on resolve', NL, '        who.rank = list.rankIn(rows, who.key);\n        list.focusId = who;', '        who.rank = list.focusId !== null && list.focusId.key === who.key ? list.focusId.rank : list.rankIn(rows, who.key);\n        list.focusId = who;', [L, RN, RN2]),
    ('M11 settled rows not refreshed on resolve', NL, '        list.focusId = who;\n        list.snapRows = rows;', '        list.focusId = who;', [L]),
    ('M12 Clear All swallows every key while hidden', NL, 'event.accepted = activation;', 'event.accepted = true;', [L]),
    ('M13 no key-time check for the card (handler and clearCard)', NL, [('if (!item.actable(row)) {', 'if (false) {'), ('if (removing || !list.liveKey(key))', 'if (removing)')], None, [L]),
    ('M14 no key-time check for sender actions', NL, 'if (item.actable(rowContent))', 'if (true)', [L]),
    ('M15 Return from a stray child opens the card', NL, 'if (open && row.activeFocus)', 'if (open)', [L]),
]


def git_show(rev, path):
    return subprocess.run(['git', 'show', rev + ':' + path], cwd=R, capture_output=True, text=True, check=True).stdout


args = sys.argv[1:]
status = 0
if args[:1] == ['--against']:
    rev = args[1]
    orig = open(NL).read()
    try:
        open(NL, 'w').write(git_show(rev, 'shell/notifications/NotificationList.qml'))
        only_t = args[2] if len(args) > 2 else ''  # optional substring of the test directory, e.g. random2
        for t in (RN, RN2, L):
            if only_t not in t:
                continue
            print('AGAINST %s | %s | %s' % (rev, t, run_qs(t)), flush=True)
    finally:
        open(NL, 'w').write(orig)
    sys.exit(0)
only = None
if args[:1] == ['--only']:
    only = set(a.strip() for a in args[1].split(','))
for name, path, a, b, tests in MUTANTS:
    if only is not None and name.split()[0] not in only:
        continue
    orig = open(path).read()
    try:
        pairs = a if isinstance(a, list) else [(a, b)]
        mutated = orig
        missing = [x for x, _ in pairs if x not in mutated]
        if missing:
            print('MUTANT %s | PATTERN NOT FOUND (update the script): %s' % (name, missing[0]), flush=True)
            status = 1
            continue
        for x, y in pairs:
            mutated = mutated.replace(x, y, 1)
        open(path, 'w').write(mutated)
        for t in tests:
            out = run(t)
            ok = caught(out)
            status |= 0 if ok else 1
            print('MUTANT %s | %s | %s | %s' % (name, t, 'CAUGHT' if ok else 'SURVIVED', out), flush=True)
            if ok:
                break  # one test that fails is enough
    finally:
        open(path, 'w').write(orig)
print('done, status', status, flush=True)
sys.exit(status)
PY
