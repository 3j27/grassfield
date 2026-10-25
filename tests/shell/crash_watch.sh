#!/usr/bin/env bash
# grassfield-crash-watch follows the macOS model: "<App> quit unexpectedly" only for the top process of an application scope.
# Journal entries recorded with `journalctl -o json MESSAGE_ID=fc2e22bc6ee647b6b90729ab34a250b1` in the owner's real session
# (2026-10-25, tests/shell/crash_watch/real-*.json; only the large dump fields are dropped) are the input; /proc is a fake tree.
# Nothing here talks to a session: notify-send, systemd-run, uwsm-app and journalctl are stubs on PATH.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/crash-watch.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }

mkdir -p "$tmp/bin"
cat >"$tmp/bin/notify-send" <<'SH'
#!/bin/sh
echo "notify-send $*" >>"$FAKE_LOG"
[ -n "${FAKE_SLEEP:-}" ] && sleep "$FAKE_SLEEP"
printf '%s' "${FAKE_ANSWER:-}"
SH
printf '#!/bin/sh\necho "systemd-run $*" >>"$FAKE_LOG"\n' >"$tmp/bin/systemd-run"
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/uwsm-app"
cat >"$tmp/bin/journalctl" <<'SH'
#!/bin/sh
cat "$FAKE_JOURNAL"
SH
chmod +x "$tmp/bin"/*

cat >"$tmp/test.py" <<'PY'
import copy, glob, importlib.machinery, importlib.util, json, os, sys, time
sys.dont_write_bytecode = True  # no __pycache__ in packaging/bin (it would be packaged)
root, tmp = sys.argv[1], sys.argv[2]
loader = importlib.machinery.SourceFileLoader("crash", root + "/packaging/bin/grassfield-crash-watch")
spec = importlib.util.spec_from_loader("crash", loader); m = importlib.util.module_from_spec(spec); loader.exec_module(m)
fx = root + "/tests/shell/crash_watch/"
def load(pid):
    e = json.load(open(fx + "real-%s.json" % pid)); e["_UID"] = str(uid); return e
uid = os.getuid()
SPOTIFY = "/user.slice/user-1000.slice/user@1000.service/app.slice/app-graphical.slice/app-Hyprland-spotify-1191618a.scope"
FOOT = "/user.slice/user-1000.slice/user@1000.service/app.slice/app-graphical.slice/app-Hyprland-foot-d359984a.scope"
proc = tmp + "/proc"
def fake(pid, cgroup, comm="x"):
    os.makedirs("%s/%d" % (proc, pid), exist_ok=True)
    open("%s/%d/cgroup" % (proc, pid), "w").write("0::%s\n" % cgroup)
    open("%s/%d/comm" % (proc, pid), "w").write(comm + "\n")
def status(entry, ppid):
    entry = copy.deepcopy(entry)
    entry["COREDUMP_PROC_STATUS"] = "".join(l + "\n" if not l.startswith("PPid:") else "PPid:\t%s\n" % ppid
                                            for l in entry["COREDUMP_PROC_STATUS"].splitlines())
    return entry
# Desktop entries (Spotify with a French name, foot without) in a fake data dir.
data = tmp + "/share"; os.makedirs(data + "/applications")
open(data + "/applications/spotify.desktop", "w").write("[Desktop Entry]\nType=Application\nName=Spotify\nName[fr]=Spotify fr\nName[fr_CA]=Spotify ca\nExec=spotify %U\n[Desktop Action x]\nName=No\n")
open(data + "/applications/foot.desktop", "w").write("[Desktop Entry]\nType=Application\nName=Foot\nExec=foot\n")
open(data + "/applications/hidden.desktop", "w").write("[Desktop Entry]\nType=Application\nHidden=true\nName=Hidden\n")
env_en = {"XDG_DATA_HOME": tmp + "/none", "XDG_DATA_DIRS": data, "LANG": "en_US.UTF-8"}
env_fr = dict(env_en, LANG="fr_FR.UTF-8")
def interesting(e, last=None, now=1000.0, env=env_en):
    return m.interesting(e, uid, {} if last is None else last, now, proc, env)

gpu, qml = load(2602), load(128224)
# Real values of this boot: gpu helper PPid 2576 (spotify's zygote, same scope), qml PPid 128215 (the shell in foot's scope).
assert m.parent_pid(gpu) == 2576 and m.parent_pid(qml) == 128215
fake(2576, SPOTIFY, "spotify"); fake(128215, FOOT, "bash")
out = {}
out["terminal-child"] = interesting(qml)
out["helper-same-exe"] = interesting(gpu)
# The same helper once its parent is gone or elsewhere is the top process (an application quitting by crash).
top = status(gpu, 2558)  # 2558 is not in the fake tree: dead
out["main-dead-parent"] = interesting(top)
fake(2558, "/user.slice/user-1000.slice/user@1000.service/app.slice/app-graphical.slice/wayland-wm-app-daemon.service", "uwsm")
out["main-parent-outside"] = interesting(top)
fake(2558, SPOTIFY + "/sub", "spotify")
out["child-in-subcgroup"] = interesting(top)
fake(2558, "/user.slice/user-1000.slice/user@1000.service/app.slice/app-graphical.slice/uwsm.service")
out["pid1-parent"] = interesting(status(gpu, 1))
out["status-bytes"] = interesting(dict(top, COREDUMP_PROC_STATUS=list(b"PPid:\t2558\n")))  # binary-encoded field: still read
out["french-name"] = interesting(top, env=env_fr)
out["no-entry-name"] = interesting(top, env={"XDG_DATA_DIRS": tmp + "/none", "XDG_DATA_HOME": tmp + "/none"})
out["hidden-entry"] = m.desktop_entry("hidden", env_en)
# Services (the shell is 37 of this boot's dumps, a portal 1) and a login-session process: never.
quick, portal = load(1549372), load(3298)
assert "wayland-wm@hyprland.desktop.service" in quick["COREDUMP_CGROUP"]
out["shell-service"] = interesting(quick)
out["portal-service"] = interesting(portal)
out["service-parent-outside"] = interesting(status(quick, 1))
sess = copy.deepcopy(gpu); sess["COREDUMP_CGROUP"] = "/user.slice/user-1000.slice/session-2.scope"; sess["COREDUMP_USER_UNIT"] = ""
out["login-scope"] = interesting(status(sess, 1))
other_user = status(gpu, 1); other_user["_UID"] = str(uid + 1)
out["other-user"] = interesting(other_user)
bad = {}
for name, entry in {
    "empty": {}, "list": [], "none": None, "str": "x",
    "no-ppid": {k: v for k, v in top.items() if k != "COREDUMP_PROC_STATUS"},
    "ppid-garbage": status(top, "x; rm -rf"),
    "ppid-negative": status(top, "-1"),
    "status-list": dict(top, COREDUMP_PROC_STATUS=[1, 2, 3]),
    "cgroup-int": dict(top, COREDUMP_CGROUP=12),
    "cgroup-none": dict(top, COREDUMP_CGROUP=None),
    "unit-mismatch": dict(top, COREDUMP_USER_UNIT="app-other-1.scope"),
    "bad-pid": dict(top, COREDUMP_PID="x; rm"),
    "uid-garbage": dict(top, _UID="root"),
    "exe-none": dict(top, COREDUMP_EXE=None, COREDUMP_COMM=None),
    "own": dict(top, COREDUMP_EXE="/usr/lib/grassfield/grassfield-crash-watch"),
}.items():
    try:
        bad[name] = interesting(entry)
    except Exception as exc:  # noqa
        bad[name] = "RAISED %r" % exc
for k, v in out.items():
    print("case", k, None if v is None else (v["name"], v["key"], v["desktop_id"]) if isinstance(v, dict) else v)
print("bad", sorted(k for k, v in bad.items() if v is not None) or "none-announced", [v for v in bad.values() if isinstance(v, str)] or "no-raise")
# An application id that is not a plain file name never reaches the file system or uwsm-app.
print("traversal", [m.desktop_entry(a, env_en) for a in ("../x", "a/b", "", ".hidden", "x..y", "spotify\n")])
# Scope names (systemd.unit(5) escaping; the journal field holds the escaped name).
print("scope", m.app_scope({"COREDUMP_CGROUP": SPOTIFY.rsplit("/", 1)[0] + "/app-Hyprland-gtk\\x2dlaunch-27c3252d.scope"})[:2],
      m.app_scope({"COREDUMP_CGROUP": SPOTIFY.rsplit("/", 1)[0] + "/app-foo-123.scope"})[:2],
      m.app_scope({"COREDUMP_CGROUP": SPOTIFY.rsplit("/", 1)[0] + "/app-a-b-c-d.scope"})[:2],
      m.app_scope({"COREDUMP_CGROUP": SPOTIFY.rsplit("/", 1)[0] + "/app-flatpak-org.x.Y-99.scope"})[:2],
      m.app_scope({"COREDUMP_CGROUP": "/system.slice/app-foo-1.scope"}))
# Flatpak: a bwrap parent in the same scope is not an application process; a bash parent is.
FP = SPOTIFY.rsplit("/", 1)[0] + "/app-flatpak-org.x.Y-99.scope"
fake(500, FP, "bwrap"); fake(501, FP, "bash")
print("flatpak", m.parent_in_scope(500, FP, "flatpak", proc), m.parent_in_scope(501, FP, "flatpak", proc), m.parent_in_scope(500, FP, "Hyprland", proc))

# Dedupe and cap.
ledger = m.Ledger()
first = ledger.reserve(top, uid, 1000.0, proc, env_en)
again = ledger.reserve(top, uid, 1030.0, proc, env_en)
nine = ledger.reserve(top, uid, 1540.0, proc, env_en)
later = ledger.reserve(top, uid, 1601.0, proc, env_en)
print("dedupe", first and first["name"], again, nine, later and later["name"])
ledger = m.Ledger(); ledger.reserve(top, uid, 1000.0, proc, env_en); ledger.release(first or {"key": "spotify", "at": 1000.0})
print("release", ledger.reserve(top, uid, 1001.0, proc, env_en) is not None)
ledger = m.Ledger(); names = []
for i in range(8):
    e = status(gpu, 2558); e["COREDUMP_CGROUP"] = SPOTIFY.replace("spotify-1191618a", "app%d-1" % i); e["COREDUMP_USER_UNIT"] = "app-Hyprland-app%d-1.scope" % i
    names.append(ledger.reserve(e, uid, 2000.0 + i, proc, env_en) is not None)
print("cap", names)
ledger = m.Ledger()
for i in range(6):
    e = status(gpu, 2558); e["COREDUMP_CGROUP"] = SPOTIFY.replace("spotify-1191618a", "app%d-1" % i); e["COREDUMP_USER_UNIT"] = "app-Hyprland-app%d-1.scope" % i
    ledger.reserve(e, uid, 2000.0 + i, proc, env_en)
print("cap-hour-later", ledger.reserve(top, uid, 2000.0 + 3700, proc, env_en) is not None)
print("under_cap", m.under_cap([0.0, 10.0, 20.0, 30.0, 40.0, 50.0], 100.0), m.under_cap([0.0, 10.0, 20.0, 30.0, 40.0, 50.0], 3700.0), m.under_cap([0.0] * 5, 100.0))

# Strings: every source string has a French translation of its own, with the same placeholders.
src = [m.TITLE, m.BODY, m.REOPEN]
fr = m.CATALOG["fr"]
print("catalog", sorted(fr) == sorted(src), all(fr[s] and fr[s] != s and fr[s].count("%s") == s.count("%s") for s in src),
      m.tr(m.REOPEN, m.locale_names({"LANG": "fr_FR.UTF-8"})), m.tr(m.REOPEN, m.locale_names({"LANG": "C"})),
      m.tr(m.REOPEN, m.locale_names({"LANG": "de_DE.UTF-8"})), m.tr(m.REOPEN, m.locale_names({"LC_ALL": "en_US", "LANG": "fr"})),
      m.tr(m.REOPEN, m.locale_names({"GRASSFIELD_LANG": "fr", "LANG": "en_US.UTF-8"})), m.locale_names({"LANG": "fr_CA.UTF-8@euro"}))

# Announce with stubs: Reopen only with a known entry and an answer.
os.environ["PATH"] = tmp + "/bin:" + os.environ["PATH"]
log = tmp + "/log"; os.environ["FAKE_LOG"] = log
def run_announce(notice, answer, env):
    open(log, "w").close(); os.environ["FAKE_ANSWER"] = answer
    shown = m.announce(notice, "SIGSEGV", env)
    return shown, open(log).read().splitlines()
shown, lines = run_announce({"name": "Spotify", "key": "spotify", "desktop_id": "spotify.desktop"}, "reopen", env_fr)
print("reopen", shown, len(lines), "-A reopen=Rouvrir" in lines[0], "« Spotify » a quitt" in lines[0], "(SIGSEGV)" in lines[0], "systemd-run --user --collect --quiet -- " in lines[1], lines[1].endswith("uwsm-app -- spotify.desktop"))
shown, lines = run_announce({"name": "Spotify", "key": "spotify", "desktop_id": "spotify.desktop"}, "", env_en)
print("dismissed", shown, len(lines), "Spotify quit unexpectedly" in lines[0], "-A reopen=Reopen" in lines[0])
shown, lines = run_announce({"name": "qml", "key": "qml", "desktop_id": None}, "reopen", env_en)
print("no-entry", shown, len(lines), " -A " in lines[0] or " -w " in lines[0])

# The loop never waits for a notice: a notify-send that takes 3 s does not delay the next entries or the end of the stream.
a = status(gpu, 2558); b = status(gpu, 2558)
b["COREDUMP_CGROUP"] = SPOTIFY.replace("spotify-1191618a", "foot-77"); b["COREDUMP_USER_UNIT"] = "app-Hyprland-foot-77.scope"
json.dump(a, open(tmp + "/journal", "w")); open(tmp + "/journal", "a").write("\nnot json\n"); open(tmp + "/journal", "a").write(json.dumps(b) + "\n[]\n")
os.environ["FAKE_JOURNAL"] = tmp + "/journal"; os.environ["FAKE_SLEEP"] = "3"; os.environ["FAKE_ANSWER"] = ""
open(log, "w").close()
t0 = time.monotonic(); rc = m.main(); elapsed = time.monotonic() - t0
time.sleep(0.5)
print("loop", rc, elapsed < 2.0, len(open(log).read().splitlines()))
PY
out=$(python3 -I "$tmp/test.py" "$root" "$tmp" 2>&1) || { echo "$out"; echo "FAIL: the crash-watch test program ran"; exit 1; }
has() { grep -qxF -- "$1" <<<"$out"; }

desc="a command run from a terminal (qml --version in foot, real dump 128224) gives no notice"
check has "case terminal-child None"
desc="a helper with the application's own exe (Spotify GPU process, real dump 2602, parent alive in the scope) gives no notice"
check has "case helper-same-exe None"
desc="the application's top process crashing is announced: parent gone, parent outside the scope, parent pid 1; named by the entry"
check has "case main-dead-parent ('Spotify', 'spotify', 'spotify.desktop')"
check has "case main-parent-outside ('Spotify', 'spotify', 'spotify.desktop')"
check has "case pid1-parent ('Spotify', 'spotify', 'spotify.desktop')"
check has "case status-bytes ('Spotify', 'spotify', 'spotify.desktop')"
desc="a parent in a sub-cgroup of the scope still makes the crash a child's"
check has "case child-in-subcgroup None"
desc="the name is the desktop entry's localized Name (fr_FR falls back to fr), the executable's name without an entry, nothing for a hidden entry"
check has "case french-name ('Spotify fr', 'spotify', 'spotify.desktop')"
check has "case no-entry-name ('spotify', 'spotify', None)"
check has "case hidden-entry None"
desc="services (the shell: this boot's 37 dumps, a portal), login-session scopes and other users' crashes give no notice, even with a parent outside"
check bash -c 'for c in shell-service portal-service service-parent-outside login-scope other-user; do grep -qxF "case $c None" <<<"$1" || exit 1; done' _ "$out"
desc="unknown or malformed fields never announce and never raise"
check has "bad none-announced no-raise"
desc="an application id that is not a plain file name is never looked up"
check has "traversal [None, None, None, None, None, None]"
desc="scope names: escaped dashes, launcher optional, malformed names still an app scope without id, non-app cgroups refused"
check has "scope ('Hyprland', 'gtk-launch') ('', 'foo') ('', '') ('flatpak', 'org.x.Y') None"
desc="Flatpak: a bwrap parent in the scope is not an application process (only for the flatpak launcher)"
check has "flatpak False True True"
desc="dedupe: one per application per 10 minutes, again after; a failed delivery frees its slot"
check has "dedupe Spotify None None Spotify"
check has "release True"
desc="at most 6 notices an hour in all, and the window slides"
check has "cap [True, True, True, True, True, True, False, False]"
check has "cap-hour-later True"
check has "under_cap False True True"
desc="strings: fr catalog complete and different from the source, same placeholders; language from GRASSFIELD_LANG, LC_ALL, LANG; C and unknown stay English"
check has "catalog True True Rouvrir Reopen Reopen Reopen Rouvrir ['fr_CA@euro', 'fr_CA', 'fr@euro', 'fr']"
desc="Reopen: a translated action with a known entry; the answer starts uwsm-app in a transient unit; no click, no start; no entry, no action"
check has "reopen True 2 True True True True True"
check has "dismissed True 1 True True"
check has "no-entry True 1 False"
desc="the loop is not blocked by notices that wait for a click (3 s notify-send, two apps, junk lines: done in under 2 s, both shown)"
check has "loop 1 True 2"

exit $fail
