#!/usr/bin/env python3
"""Mutation fuzzing of the session helpers' readers (ADR-0041 step 5, T-1): what another process, a file or the
compositor hands them must never crash them, hang them or make them act outside their contract.

  python3 -I tests/fuzz/fuzz_helpers.py ROOT TMP [scenario...]      (run by tests/fuzz/helpers_fuzz.sh)
  GF_FUZZ_ITERATIONS (default 1500; scenarios that start a process run a fifth of it), GF_FUZZ_SEED (default 1)

Scenarios (each prints one "[fuzz]" line and PASS/FAIL lines; a finding names the seed and the iteration):
  crash-watch     packaging/bin/grassfield-crash-watch: journal entries (the four real fixtures mutated: field types,
                  cgroup paths, unit names), desktop entries (mutated files in a scratch data dir), cgroup.events files,
                  locale names. Contract: a candidate's signal is a SIG name or empty, its cgroup is under the user's
                  app.slice, a described app has a name, a desktop id ends in .desktop and names a real file, a cgroup
                  state is one of four words, nothing raises.
  session-end     packaging/bin/grassfield-session-end: `hyprctl -j clients` answers mutated. Contract: windows() is
                  None or a list of (address, class, title) strings, close_windows() dispatches only
                  hl.dsp.window.close for a 0x hex address and nothing else, app_names() returns strings,
                  bounded_seconds() stays finite and inside its bounds.
  battery-watch   packaging/bin/grassfield-battery-watch: sysfs files mutated. Contract: read_battery() is None or
                  (int, str); next_warning() and level_for() answer a level of 20, 10, 5 or None.
  anr-dialog      the client-matching program inside packaging/session-bin/hyprland-dialog, with `hyprctl -j clients`
                  mutated and random titles. Contract: it prints nothing (the stock dialog runs) or exactly a pid above 1,
                  0 or 1, and a class without a newline; an exception prints nothing.
  lock-status     the jq filter of `omarchy-shell lock status` (packaging/shims/omarchy-shell) on mutated monitor lists.
                  Contract (fail closed): "secure" only when the answer is a non-empty list of objects whose
                  solitaryBlockedBy is an array holding "LOCK". Needs jq.
  sleep-lock-gate packaging/systemd/sleep-lock-gate with WAYLAND_DISPLAY and HYPRLAND_INSTANCE_SIGNATURE mutated, a stub
                  systemctl answering "failed". Contract: it skips Omarchy's sleep lock (exit 1) only when the session's
                  socket or its instance directory is certainly absent (an absolute, well-formed path whose parent is
                  searchable and which does not exist, not even as a dangling link); anything else runs it.
Standard library only.
"""
import importlib.machinery
import importlib.util
import io
import json
import math
import os
import re
import subprocess
import sys
import traceback

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mutate import Mutator  # noqa: E402

ROOT, TMP = sys.argv[1], sys.argv[2]
ONLY = set(sys.argv[3:])
SEED = int(os.environ.get("GF_FUZZ_SEED") or 1)
ITER = int(os.environ.get("GF_FUZZ_ITERATIONS") or 1500)
SUB_ITER = max(100, ITER // 5)
status = 0


def load(path, name):
    loader = importlib.machinery.SourceFileLoader(name, path)
    spec = importlib.util.spec_from_loader(name, loader)
    m = importlib.util.module_from_spec(spec)
    loader.exec_module(m)
    return m


def printable(data, n=160):
    if isinstance(data, bytes):
        data = data.decode("utf-8", "replace")
    s = "".join(c if 32 <= ord(c) < 127 else "\\x%02X" % (ord(c) & 0xFF) for c in str(data)[:n])
    return s + ("...(%d chars)" % len(str(data)) if len(str(data)) > n else "")


class Scenario:
    def __init__(self, name, iterations):
        self.name, self.iterations, self.findings, self.accepted, self.rejected = name, iterations, 0, 0, 0
        self.mutator = Mutator(SEED ^ (hash(name) & 0xFFFFFFFF))
        self.i = 0

    def finding(self, what, data=""):
        global status
        self.findings += 1
        status = 1
        if self.findings <= 8:
            print("FAIL: %s: %s (seed %d, iteration %d): %s" % (self.name, what, SEED, self.i, printable(data)))

    def run(self, body):
        """body(i) returns True when the reader accepted the input; an exception is a finding."""
        for self.i in range(self.iterations):
            try:
                ok = body(self.i)
            except Exception:
                self.finding("exception", traceback.format_exc().strip().splitlines()[-1])
                ok = False
            if ok:
                self.accepted += 1
            else:
                self.rejected += 1
        print("[fuzz] %s: iterations=%d accepted=%d rejected=%d findings=%d seed=%d" % (self.name, self.iterations, self.accepted, self.rejected, self.findings, SEED))
        print(("PASS: %s: no finding" if self.findings == 0 else "FAIL: %s: %d findings") % ((self.name,) if self.findings == 0 else (self.name, self.findings)))


def want(name):
    return not ONLY or name in ONLY


# ---------------------------------------------------------------------------------------------------------------------
def crash_watch():
    sc = Scenario("crash-watch", ITER)
    m = load(ROOT + "/packaging/bin/grassfield-crash-watch", "crash")
    uid = os.getuid()
    fx = ROOT + "/tests/shell/crash_watch/"
    entries = []
    for f in sorted(os.listdir(fx)):
        if f.startswith("real-") and f.endswith(".json"):
            e = json.load(open(fx + f))
            for k in ("COREDUMP_CGROUP", "COREDUMP_PROC_CGROUP"):
                if k in e:
                    e[k] = e[k].replace("1000", str(uid))
            e["COREDUMP_UID"] = str(uid)
            e["_UID"] = str(uid)
            entries.append(e)
    corpus = [json.dumps(e).encode() for e in entries]
    data = os.path.join(TMP, "crash-data")
    apps = os.path.join(data, "applications")
    os.makedirs(apps, exist_ok=True)
    cg = os.path.join(TMP, "crash-cg")
    os.makedirs(cg, exist_ok=True)
    open(os.path.join(cg, "cgroup.controllers"), "w").write("cpu memory\n")
    env = {"XDG_DATA_DIRS": data, "HOME": os.path.join(TMP, "crash-home"), "LANG": "fr_FR.UTF-8"}
    seeds = [
        b"[Desktop Entry]\nType=Application\nName=Spotify\nName[fr]=Spotify\nExec=spotify %U\nTryExec=spotify\nStartupWMClass=spotify\n",
        b"[Desktop Entry]\nType=Application\nName=Files\nExec=env GF=1 grassfield-files %f\nNoDisplay=false\n",
        b"[Desktop Entry]\nType=Application\nName=Hidden\nExec=obsidian\nHidden=true\n[Desktop Action new]\nName=New\nExec=obsidian --new\n",
    ]
    names = ["spotify.desktop", "org.grassfield.Files.desktop", "md.obsidian.Obsidian.desktop"]
    prefix = "/user.slice/user-%d.slice/user@%d.service/app.slice/" % (uid, uid)
    sig = re.compile(r"SIG[A-Z0-9]{1,12}")
    states = {"gone", "empty", "populated", "unknown"}

    def body(i):
        mut = sc.mutator
        # 1. a journal entry: as text (a parse that fails is a rejection, never a crash) and as a dict with mutated values
        text = mut.mutate(mut.rng.pick(corpus), corpus, 65536)
        try:
            entry = json.loads(text)
        except ValueError:
            entry = dict(mut.rng.pick(entries))
            k = mut.rng.pick(sorted(entry))
            entry[k] = mut.rng.pick([None, 1.5, -1, [1, 2, 300, -4], {"a": 1}, mut.text(str(entry[k]), [], 4096), [0x41] * mut.rng.below(50), True, 10 ** 30])
        accepted = False
        if isinstance(entry, dict):
            for v in list(entry.values())[: 8]:
                assert isinstance(m.text_of(v), str)
                n = m.number(v)
                assert n is None or isinstance(n, int)
            t = m.trusted(entry)
            if t:
                assert m.text_of(entry.get("_SYSTEMD_UNIT")).startswith("systemd-coredump@") and m.text_of(entry.get("MESSAGE_ID")) == m.COREDUMP_MESSAGE_ID
            scope = m.app_scope(entry, uid)
            assert scope is None or (len(scope) == 3 and all(isinstance(x, str) for x in scope) and scope[2].startswith(prefix))
            cand = m.candidate(entry, uid)
            if cand is not None:
                accepted = True
                assert cand["signal"] == "" or sig.fullmatch(cand["signal"]), cand
                assert cand["exe"] and not cand["exe"].startswith("grassfield-crash-"), cand
                assert cand["cgroup"].startswith(prefix), cand
                info = m.describe(cand, env)
                assert isinstance(info["name"], str) and info["name"], info
                if info["desktop_id"] is not None:
                    assert info["desktop_id"].endswith(".desktop") and info["desktop_id"] in names, info
        # 2. the unit name reader on its own
        unit = mut.text(mut.rng.pick(["app-Hyprland-spotify-1191618a.scope", "app-flatpak-com.spotify.Client-123.scope", "app-uwsm-org.gnome.Nautilus\\x2dfoo-ab12cd34.scope"]), [], 512)
        ps = m.parse_scope(unit)
        assert ps is None or (len(ps) == 2 and all(isinstance(x, str) for x in ps))
        assert isinstance(m.unescape_unit(unit), str)
        # 3. a desktop entry file with mutated content, then the lookup by id and by binary
        k = mut.rng.below(len(names))
        with open(os.path.join(apps, names[k]), "wb") as f:
            f.write(mut.mutate(seeds[k], seeds, 70000))
        keys = m.read_entry(os.path.join(apps, names[k]), ["fr", "en"])
        assert keys is None or (isinstance(keys, dict) and keys["name"])
        if keys is not None:
            binary, generic = m.exec_binary(keys)
            assert isinstance(binary, str) and isinstance(generic, bool)
        found = m.desktop_entry(mut.rng.pick(["spotify", "org.grassfield.Files", "obsidian", mut.text("spotify", [], 64)]), env)
        assert found is None or (found[0] in names and isinstance(found[1], str) and found[1])
        # 4. a cgroup.events file
        cgdir = os.path.join(cg, prefix.lstrip("/"), "app-x-1.scope")
        os.makedirs(cgdir, exist_ok=True)
        with open(os.path.join(cgdir, "cgroup.events"), "wb") as f:
            f.write(mut.mutate(mut.rng.pick([b"populated 1\nfrozen 0\n", b"populated 0\nfrozen 0\n"]), [], 4096))
        st = m.scope_state(prefix + "app-x-1.scope", cg)
        assert st in states, st
        # 5. locale names
        names_out = m.locale_names({"LANG": mut.text(mut.rng.pick(["fr_FR.UTF-8@euro", "C", "en_US", ""]), [], 128)})
        assert isinstance(names_out, list) and all(isinstance(x, str) for x in names_out)
        return accepted

    sc.run(body)


# ---------------------------------------------------------------------------------------------------------------------
def session_end():
    sc = Scenario("session-end", ITER)
    m = load(ROOT + "/packaging/bin/grassfield-session-end", "sessionend")
    clients = [
        {"address": "0x55d0c0a1b2c0", "class": "foot", "title": "~", "pid": 4242, "mapped": True},
        {"address": "0x55d0c0a1b2c1", "class": "org.grassfield.Files", "title": "Documents — Files", "pid": 4243},
        {"address": "0x55d0c0a1b2c2", "class": None, "title": None},
    ]
    corpus = [json.dumps(clients).encode(), b"[]", json.dumps(clients[:1]).encode()]
    state = {"stdout": "", "calls": []}
    dispatch = re.compile(r'^hl\.dsp\.window\.close\(\{ window = "address:0x[0-9a-fA-F]+" \}\)$')

    def fake_run(argv, **kw):
        state["calls"].append(list(argv))
        return subprocess.CompletedProcess(argv, 0, state["stdout"], "")

    m.run = fake_run

    def body(i):
        mut = sc.mutator
        state["stdout"] = mut.mutate(mut.rng.pick(corpus), corpus, 65536).decode("utf-8", "replace")
        state["calls"] = []
        ws = m.windows()
        assert ws is None or (isinstance(ws, list) and all(isinstance(w, tuple) and len(w) == 3 and all(isinstance(x, str) for x in w) for w in ws)), ws
        if ws:
            names = m.app_names(ws)
            assert isinstance(names, list) and all(isinstance(x, str) for x in names)
            state["calls"] = []
            m.close_windows(ws)
            for argv in state["calls"]:
                assert argv[:2] == ["hyprctl", "dispatch"] and len(argv) == 3 and dispatch.match(argv[2]), argv
        sec = m.bounded_seconds(mut.text(mut.rng.pick(["15", "0.5", "nan", "inf", "-1", "1e400", ""]), [], 64), 15.0, 1.0, 3600.0)
        assert isinstance(sec, float) and math.isfinite(sec) and 1.0 <= sec <= 3600.0, sec
        return ws is not None

    sc.run(body)


# ---------------------------------------------------------------------------------------------------------------------
def battery_watch():
    sc = Scenario("battery-watch", ITER)
    m = load(ROOT + "/packaging/bin/grassfield-battery-watch", "battery")
    base = os.path.join(TMP, "power")
    os.makedirs(os.path.join(base, "BAT0"), exist_ok=True)

    def body(i):
        mut = sc.mutator
        with open(os.path.join(base, "BAT0", "capacity"), "wb") as f:
            f.write(mut.mutate(mut.rng.pick([b"17\n", b"100\n", b"0\n"]), [], 1 << 20))
        with open(os.path.join(base, "BAT0", "status"), "wb") as f:
            f.write(mut.mutate(mut.rng.pick([b"Discharging\n", b"Charging\n", b"Full\n"]), [], 4096))
        r = m.read_battery(base)
        assert r is None or (isinstance(r, tuple) and isinstance(r[0], int) and isinstance(r[1], str)), r
        cap = mut.rng.pick([-5, 0, 3, 5, 9, 10, 19, 20, 21, 100, 10 ** 12, -(10 ** 12)])
        lvl = m.level_for(cap)
        assert lvl in (None, 20, 10, 5), lvl
        level, keep = m.next_warning(mut.rng.pick([None, 20, 10, 5]), cap, mut.rng.pick(["Discharging", "Charging", mut.text("Discharging", [], 32)]))
        assert level in (None, 20, 10, 5) and keep in (None, 20, 10, 5), (level, keep)
        return r is not None

    sc.run(body)


# ---------------------------------------------------------------------------------------------------------------------
def anr_dialog():
    sc = Scenario("anr-dialog", ITER)
    text = open(ROOT + "/packaging/session-bin/hyprland-dialog", encoding="utf-8").read()
    start = text.index("python3 -I -c '") + len("python3 -I -c '")
    end = text.index("' \"$body\" \"$unknown\"", start)
    program = compile(text[start:end], "hyprland-dialog(inline)", "exec")
    clients = [{"address": "0x1", "class": "foot", "title": "~", "pid": 4242}, {"address": "0x2", "class": "chromium", "title": "a - b", "pid": 4300},
               {"address": "0x3", "class": "x", "title": "", "pid": 4400}]
    corpus = [json.dumps(clients).encode(), b"[]"]
    bodies = ["~ - foot", "a - b - chromium", "(unknown) - x", "x - foot - chromium"]

    def matcher(stdin, argv_body):
        out = io.StringIO()
        saved = sys.stdin, sys.stdout, sys.argv
        raised = False
        try:
            sys.stdin, sys.stdout, sys.argv = io.StringIO(stdin), out, ["-c", argv_body, "(unknown)"]
            try:
                exec(program, {"__name__": "__anr__"})
            except Exception:
                raised = True
        finally:
            sys.stdin, sys.stdout, sys.argv = saved
        return raised, out.getvalue()

    for seed_body, want_pid in (("~ - foot", "4242"), ("a - b - chromium", "4300"), ("(unknown) - x", "4400")):
        raised, printed = matcher(corpus[0].decode(), seed_body)
        if raised or not printed.startswith(want_pid + "\n"):
            sc.finding("the corpus itself is not matched (%s)" % seed_body, printed)

    def body(i):
        mut = sc.mutator
        # One side at a time half of the time, so the accepting path (a mutated list that still names the window, or a mutated
        # title against the real list) is exercised too.
        side = mut.rng.below(3)
        stdin = corpus[0].decode() if side == 1 else mut.mutate(mut.rng.pick(corpus), corpus, 65536).decode("utf-8", "replace")
        argv_body = mut.rng.pick(bodies) if side == 2 else mut.text(mut.rng.pick(bodies), bodies, 512)
        out = io.StringIO()
        saved = sys.stdin, sys.stdout, sys.argv
        raised = False
        try:
            sys.stdin, sys.stdout, sys.argv = io.StringIO(stdin), out, ["-c", argv_body, "(unknown)"]
            try:
                exec(program, {"__name__": "__anr__"})
            except Exception:
                raised = True
        finally:
            sys.stdin, sys.stdout, sys.argv = saved
        printed = out.getvalue()
        if raised:
            assert printed == "", "printed before the exception: " + printed
            return False
        if printed == "":
            return False
        lines = printed.split("\n")
        assert len(lines) == 4 and lines[3] == "", printed
        assert lines[0].isdigit() and int(lines[0]) > 1 and lines[1] in ("0", "1") and "\n" not in lines[2], printed
        return True

    sc.run(body)


# ---------------------------------------------------------------------------------------------------------------------
def lock_status():
    sc = Scenario("lock-status", SUB_ITER)
    text = open(ROOT + "/packaging/shims/omarchy-shell", encoding="utf-8").read()
    jqf = re.search(r"jq -e '([^']*)'", text).group(1)
    locked = [{"name": "DP-1", "solitaryBlockedBy": ["LOCK"]}, {"name": "eDP-1", "solitaryBlockedBy": ["LOCK", "FULLSCREEN"]}]
    corpus = [json.dumps(locked).encode(), json.dumps(locked[:1]).encode(), b"[]", json.dumps([{"name": "DP-1", "solitaryBlockedBy": []}]).encode(),
              json.dumps([{"name": "DP-1", "solitaryBlockedBy": "UNLOCKED"}]).encode(), json.dumps({"a": locked[0]}).encode()]

    def oracle(raw):
        # jq reads bytes that are not UTF-8 with replacement characters, as the oracle does here: a garbled key name is not a
        # monitor without LOCK (the structure decides, never the bytes of a name).
        try:
            doc = json.loads(raw.decode("utf-8", "replace"))
        except ValueError:
            return False
        if not isinstance(doc, list) or not doc:
            return False
        for mon in doc:
            if not isinstance(mon, dict):
                return False
            sb = mon.get("solitaryBlockedBy")
            if not isinstance(sb, list) or "LOCK" not in sb:
                return False
        return True

    for raw in corpus:
        r = subprocess.run(["jq", "-e", jqf], input=raw, capture_output=True, timeout=20)
        if (r.returncode == 0) != oracle(raw):
            sc.finding("the corpus itself is read against the contract", raw)

    def body(i):
        mut = sc.mutator
        raw = mut.mutate(mut.rng.pick(corpus), corpus, 65536)
        r = subprocess.run(["jq", "-e", jqf], input=raw, capture_output=True, timeout=20)
        secure = r.returncode == 0
        if secure and not oracle(raw):
            sc.finding("secure without LOCK on every monitor of a list of objects", raw)
        if not secure and oracle(raw):
            sc.finding("not secure although every monitor lists LOCK", raw)
        return secure

    sc.run(body)


# ---------------------------------------------------------------------------------------------------------------------
def sleep_lock_gate():
    sc = Scenario("sleep-lock-gate", SUB_ITER)
    run = os.path.join(TMP, "gate-run")
    os.makedirs(os.path.join(run, "hypr", "sig-live"), exist_ok=True)
    open(os.path.join(run, "wayland-live"), "w").close()
    if not os.path.lexists(os.path.join(run, "dangling")):
        os.symlink(os.path.join(run, "nowhere"), os.path.join(run, "dangling"))
    sbin = os.path.join(TMP, "gate-bin")
    os.makedirs(sbin, exist_ok=True)
    with open(os.path.join(sbin, "systemctl"), "w") as f:
        f.write("#!/bin/sh\ncase \"$*\" in *ActiveState*) echo failed ;; *SubState*) echo failed ;; *) exit 9 ;; esac\n")
    os.chmod(os.path.join(sbin, "systemctl"), 0o755)
    gate = ROOT + "/packaging/systemd/sleep-lock-gate"
    seeds_wd = ["wayland-1", "wayland-live", "wayland-gone", run + "/wayland-live", run + "/absent-abs", "dangling", "../escape", ".hidden", ""]
    seeds_sig = ["sig-live", "sig-gone", "abc123_1700000000_123456", ".dot", "a/b", "x" * 300, ""]
    name_ok = re.compile(r"[A-Za-z0-9_.-]+")

    def absent(p):
        if len(p) > 4096 or not p.startswith("/") or ".." in p or "\n" in p:
            return False
        if any(len(c) > 255 for c in p.split("/")):
            return False
        parent = p.rsplit("/", 1)[0] or "/"
        if not os.path.isdir(parent) or not os.access(parent, os.X_OK):
            return False
        return not os.path.exists(p) and not os.path.lexists(p)

    def certainly_absent(wd, sig):
        if wd:
            if wd.startswith("/"):
                sock = wd
            elif "/" in wd or wd.startswith("."):
                sock = None
            else:
                sock = run + "/" + wd
            if sock is not None and absent(sock):
                return True
        if sig and name_ok.fullmatch(sig) and not sig.startswith(".") and absent(run + "/hypr/" + sig):
            return True
        return False

    def gate_exit(wd, sig):
        env = {"PATH": sbin + ":/usr/bin:/bin", "GRASSFIELD_SESSION": "1", "XDG_RUNTIME_DIR": run, "WAYLAND_DISPLAY": wd, "HYPRLAND_INSTANCE_SIGNATURE": sig}
        return subprocess.run(["sh", gate], env=env, capture_output=True, timeout=20)

    for wd, sig, want in (("wayland-gone", "sig-live", 1), ("wayland-live", "sig-live", 0), ("wayland-live", "sig-gone", 1), ("dangling", "sig-live", 0), ("../escape", "", 0)):
        if gate_exit(wd, sig).returncode != want:
            sc.finding("the corpus itself is not decided as the contract says", (wd, sig, want))

    def body(i):
        mut = sc.mutator
        wd = mut.text(mut.rng.pick(seeds_wd), seeds_wd, 600).replace("\x00", "")
        sig = mut.text(mut.rng.pick(seeds_sig), seeds_sig, 600).replace("\x00", "")
        r = gate_exit(wd, sig)
        if r.returncode not in (0, 1):
            sc.finding("exit %d" % r.returncode, (wd, sig, r.stderr))
        skipped = r.returncode == 1
        if skipped and not certainly_absent(wd, sig):
            sc.finding("skipped Omarchy's sleep lock although nothing is certainly absent", (wd, sig))
        return skipped

    sc.run(body)


SCENARIOS = [("crash-watch", crash_watch), ("session-end", session_end), ("battery-watch", battery_watch), ("anr-dialog", anr_dialog),
             ("lock-status", lock_status), ("sleep-lock-gate", sleep_lock_gate)]
for name, fn in SCENARIOS:
    if want(name):
        if name == "lock-status" and not any(os.access(os.path.join(d, "jq"), os.X_OK) for d in os.environ.get("PATH", "").split(":")):
            print("SKIP: lock-status (jq not installed)")
            continue
        fn()
sys.exit(status)
