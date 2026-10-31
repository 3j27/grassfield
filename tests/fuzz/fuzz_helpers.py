#!/usr/bin/env python3
"""Mutation fuzzing of the session helpers' readers (ADR-0041 step 5, T-1): what another process, a file or the
compositor hands them must never crash them, hang them or make them act outside their contract.

  python3 -I tests/fuzz/fuzz_helpers.py ROOT TMP [scenario...]      (run by tests/fuzz/helpers_fuzz.sh)
  GF_FUZZ_ITERATIONS (default 1500; scenarios that start a process run a fifth of it), GF_FUZZ_SEED (default 1),
  GF_FUZZ_TRACE=1 prints the whole traceback of a finding

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
                  Contract (fail closed): "secure" only when the answer, as jq reads it, is exactly one non-empty list of
                  objects whose solitaryBlockedBy is an array holding "LOCK". Needs jq.
  sleep-lock-gate packaging/systemd/sleep-lock-gate with WAYLAND_DISPLAY and HYPRLAND_INSTANCE_SIGNATURE mutated, a stub
                  systemctl answering "failed". Contract: it skips Omarchy's sleep lock (exit 1) only when the session's
                  socket or its instance directory is certainly absent (an absolute, well-formed path whose parent is
                  searchable and which does not exist, not even as a dangling link); anything else runs it.
  update-check    packaging/bin/grassfield-update-check with stub children (nothing runs): checkupdates' and pacman -Q's
                  output, vercmp's answer, the failures and last-success files, the release notes document, pacman.conf
                  and the repository file, the BUILD-DEPS record and the local database
                  entry behind the toolkit comparison (ADR-0041 step 2b). Contract: nothing raises (parse_notes raises ValueError or UnicodeDecodeError
                  only, which its caller catches); the state is one of the documented ones; the other updates are
                  counted as listed, sorted, without Grassfield's or Omarchy's packages; every time is None or ISO 8601;
                  the output line stays under the 256 KiB cap and is JSON; the failures file holds a plausible time
                  afterwards; a release of the notes has a well-formed version, date and plain-text notes; the toolkit
                  lists each tracked package pacman names once, in the record's order, with its version in pacman's
                  grammar, a time or None, the record's version or None, and moved null without a record, true when the
                  record does not name it, else the compare keys' difference.
Standard library only; the same seed mutates the same inputs (a scenario's seed is a crc32 of its name, never hash()).
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
import zlib

sys.dont_write_bytecode = True
# Nothing here may reach the owner's session: the runner (helpers_fuzz.sh) starts this program without these, as
# scripts/dev/isolated.sh does, and a direct run drops them too (the integrator's review of 265e6c7, minor 5). The
# session-end scenario also replaces its module's run() before any window is closed.
for _name in ("HYPRLAND_INSTANCE_SIGNATURE", "WAYLAND_DISPLAY", "DISPLAY", "DBUS_SESSION_BUS_ADDRESS", "DBUS_SYSTEM_BUS_ADDRESS"):
    os.environ.pop(_name, None)
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
        # A stable per-scenario seed: hash() of a str is randomised per process, and python3 -I ignores PYTHONHASHSEED, so
        # two runs of one seed gave different inputs (the integrator's review of 265e6c7, major 2).
        self.mutator = Mutator(SEED ^ zlib.crc32(name.encode("utf-8")))
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
                if os.environ.get("GF_FUZZ_TRACE") and self.findings <= 8:
                    traceback.print_exc()
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
    dispatch = re.compile(r'^hl\.dsp\.window\.close\(\{ window = "address:0x[0-9a-fA-F]{1,16}" \}\)\Z')

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
    jqf = re.search(r"jq -e -s '([^']*)'", text).group(1)
    jq = ["jq", "-e", "-s", jqf]
    locked = [{"name": "DP-1", "solitaryBlockedBy": ["LOCK"]}, {"name": "eDP-1", "solitaryBlockedBy": ["LOCK", "FULLSCREEN"]}]
    corpus = [json.dumps(locked).encode(), json.dumps(locked[:1]).encode(), b"[]", json.dumps([{"name": "DP-1", "solitaryBlockedBy": []}]).encode(),
              json.dumps([{"name": "DP-1", "solitaryBlockedBy": "UNLOCKED"}]).encode(), json.dumps({"a": locked[0]}).encode()]

    def oracle(raw):
        """True: must be secure; False: must not be. The shape is judged on jq's own reading of the bytes (`jq -c .`, the
        parser the filter runs on): a lone surrogate escape, nesting past 256 levels, nan, inf, +1, 01, .5, 5., a byte
        order mark and bytes that are not UTF-8 are then decided as jq decides them, where Python's json would differ (a
        false finding on a lone surrogate at 10 000 iterations, the integrator's review of 265e6c7, minor 3; the number
        tokens, its merge review of #62). What is under test is the filter, not a second JSON parser: a garbled key name
        is not a monitor without LOCK (the structure decides, never the bytes of a name). Several values (one line each
        from jq), or none, are not one list."""
        r = subprocess.run(["jq", "-c", "."], input=raw, capture_output=True, timeout=20)
        if r.returncode != 0:
            return False
        try:
            doc = json.loads(r.stdout.decode("utf-8", "replace"))
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
        r = subprocess.run(jq, input=raw, capture_output=True, timeout=20)
        if (r.returncode == 0) != oracle(raw):
            sc.finding("the corpus itself is read against the contract", raw)
    for raw in (b'[{"solitaryBlockedBy":["WINDOWED"]}] [{"solitaryBlockedBy":["LOCK"]}]', b'4294967296[{"solitaryBlockedBy":["LOCK"]}]',
                b'[{"solitaryBlockedBy":["LOCK"]}] 1', b"", b" \n"):
        if subprocess.run(jq, input=raw, capture_output=True, timeout=20).returncode == 0 or oracle(raw):
            sc.finding("several JSON values, or none, read as secure", raw)
    # jq reads these number tokens where Python's json does not: the oracle must follow jq (a locked list stays secure).
    for raw in (b'[{"solitaryBlockedBy":["LOCK"],"x":nan}]', b'[{"solitaryBlockedBy":["LOCK"],"x":inf}]', b'[{"solitaryBlockedBy":["LOCK"],"x":+1}]',
                b'[{"solitaryBlockedBy":["LOCK"],"x":01}]', b'[{"solitaryBlockedBy":["LOCK"],"x":.5}]', b'[{"solitaryBlockedBy":["LOCK"],"x":5.}]',
                b'\xef\xbb\xbf[{"solitaryBlockedBy":["LOCK"]}]'):
        if (subprocess.run(jq, input=raw, capture_output=True, timeout=20).returncode == 0) != oracle(raw):
            sc.finding("the oracle and jq disagree on a token jq reads", raw)

    def body(i):
        mut = sc.mutator
        raw = mut.mutate(mut.rng.pick(corpus), corpus, 65536)
        r = subprocess.run(jq, input=raw, capture_output=True, timeout=20)
        secure = r.returncode == 0
        if secure and not oracle(raw):
            sc.finding("secure without exactly one list of objects each listing LOCK", raw)
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


# ---------------------------------------------------------------------------------------------------------------------
def update_check():
    sc = Scenario("update-check", ITER)
    m = load(ROOT + "/packaging/bin/grassfield-update-check", "updatecheck")
    cache = os.path.join(TMP, "update-cache")
    health = os.path.join(cache, "health-db")
    os.makedirs(health, exist_ok=True)
    now = 1800000000.0
    gap = m.BLOCKING_GAP

    def version_key(v):
        return [int(x) for x in re.findall(r"[0-9]+", v)]

    class Stub:
        """The checker's children: every program answers from the table (vercmp compares digit runs; pacman -Q answers
        for the packages of `installed`, with their line mutated when `installed_text` is set), nothing runs."""

        def __init__(self):
            self.answers = {}
            self.installed = {"grassfield-desktop": "0.4.0-1", "omarchy": "4.1.0-1"}
            self.installed_text = None

        def run(self, argv, env=None, timeout=None):
            if argv[0] == "vercmp" and "vercmp" not in self.answers:
                a, b = version_key(argv[1]), version_key(argv[2])
                return 0, "%d\n" % ((a > b) - (a < b)), ""
            if argv[0] == "pacman" and argv[1] == "-Q":
                if argv[2] not in self.installed:
                    return 1, "", "error: package '%s' was not found\n" % argv[2]
                return 0, self.installed_text or "%s %s\n" % (argv[2], self.installed[argv[2]]), ""
            return self.answers.get(argv[0], (1, "", ""))

        def stop(self):
            pass

    updates = "linux 6.18.1-1 -> 6.18.2-1\ngrassfield-desktop 0.4.0-1 -> 0.5.0-1\nomarchy 4.1.0-1 -> 4.2.0-1\nfoot 1.21.0-1 -> 1.22.0-1\n"
    upd_corpus = [updates, "", "grassfield-desktop 0.4.0-1 -> 0.5.0-1\n", ":: checking\nlinux 6.18.1-1 -> 6.18.2-1\n"]
    installed_corpus = ["grassfield-desktop 0.4.0-1\n", "", "error: package 'x' was not found\n"]
    notes = {"version": 1, "channel": "stable", "releases": [
        {"version": "0.5.0-1", "date": "2026-10-20", "notes": {"en": "Stability.\nFixes.", "fr": "Stabilit\u00e9."}},
        {"version": "0.4.1-1", "date": "2026-10-01", "notes": {"en": "Fixes."}}]}
    notes_corpus = [json.dumps(notes).encode(), json.dumps({"version": 1, "releases": []}).encode()]
    fail_corpus = [b'{"first": 1799999000}', b'{"first": 1700000000}', b'{"first": 1e999}', b'{"first": "x"}', b"", b"[]", b'{"first": true}']
    succ_corpus = [b"1799990000\n", b"", b"x", b"1e999", b"-5"]
    conf_corpus = ["[options]\nHoldPkg = pacman\n[core]\nInclude = /etc/pacman.d/mirrorlist\n[grassfield]\nInclude = /etc/pacman.d/grassfield.conf\n",
                   "# Grassfield\nServer = https://repo.example/stable/$arch\nServer = https://mirror.example/stable/$arch # mirror\n",
                   "Server=https://repo.example/beta/$arch\n", ""]
    base = "https://repo.example"
    record_corpus = [b"qt6-base 6.11.2-1\nquickshell 0.3.1-1\nhyprland 0.56.2-1\naquamarine 0.9.3-1\nkcoreaddons 6.20.0-1\n", b"", b"qt6-base 1:6.12.0-1\n"]
    desc_corpus = [b"%NAME%\nqt6-base\n\n%VERSION%\n6.12.0-1\n\n%INSTALLDATE%\n1793000500\n\n%VALIDATION%\npgp\n\n", b"%INSTALLDATE%\n\n", b""]
    toolkit_versions = ["6.11.2-1", "6.12.0-1", "0.3.1-1", "0.3.2-1", "0.56.2-1", "1:0.9.3-1", "6.20.0-1", None]
    m.BUILD_DEPS = os.path.join(TMP, "update-record")
    m.PACMAN_LOCAL = os.path.join(TMP, "update-local")
    word = re.compile(r"^\S+$")
    iso = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
    states = {"available", "up-to-date", "not-set-up", "failed"}

    def checker(stub, offline=False):
        return m.Checker(cache, offline, now, stub)

    def emitted(result):
        out = io.StringIO()
        saved = sys.stdout
        try:
            sys.stdout = out
            m.emit(result)
        finally:
            sys.stdout = saved
        line = out.getvalue()
        assert line.endswith("\n") and line.count("\n") == 1 and len(line.encode("utf-8")) <= m.OUTPUT_CAP, len(line)
        return json.loads(line)

    def check_updates(r, omarchy):
        assert r["state"] in states, r["state"]
        packages = r.get("otherPackages", [])
        assert isinstance(r["others"], int) and r["others"] == len(packages), (r["others"], len(packages))
        names = [p["name"] for p in packages]
        assert names == sorted(names) and len(set(names)) == len(names), names
        for p in packages:
            assert set(p) == {"name", "installed", "available"} and all(isinstance(p[k], str) and word.match(p[k]) for k in p), p
            assert not p["name"].startswith("grassfield-") and p["name"] != omarchy, p
        for side in ("grassfield", "omarchy"):
            for k in ("installed", "available"):
                assert r[side][k] is None or (isinstance(r[side][k], str) and word.match(r[side][k])), r[side]
        assert r["lastSuccessAt"] is None or iso.match(r["lastSuccessAt"]), r["lastSuccessAt"]
        assert r["grassfield"]["notes"] == [] and r["grassfield"]["notesError"] in (None, "unavailable")
        emitted(r)

    def check_failed(c, r):
        assert r["state"] in ("failed", "blocking"), r["state"]
        assert r["retryAt"] is None or iso.match(r["retryAt"]), r["retryAt"]
        assert r["episode"] is None or (isinstance(r["episode"], int) and 0 <= r["episode"] <= now), r["episode"]
        assert r["lastSuccessAt"] is None or iso.match(r["lastSuccessAt"]), r["lastSuccessAt"]
        if r["error"] != "offline":  # offline, the episode is not counted and the file is left alone
            kept = json.loads(m.read_text(c.path("failures")))["first"]
            assert isinstance(kept, (int, float)) and not isinstance(kept, bool) and c.plausible(int(kept)) is not None, kept
        emitted(r)

    def check_notes(out):
        assert isinstance(out, list) and len(out) <= m.NOTES_MAX, out
        versions = [r["version"] for r in out]
        assert len(set(versions)) == len(versions) and versions == sorted(versions, key=version_key, reverse=True), versions
        for r in out:
            assert set(r) == {"version", "date", "notes"} and m.VERSION.fullmatch(r["version"]) and m.DATE.fullmatch(r["date"]), r
            assert set(r["notes"]) in ({"en"}, {"en", "fr"}), r["notes"]
            for text in r["notes"].values():
                assert isinstance(text, str) and len(text) <= m.NOTE_CHARS and not m.UNSAFE.search(text), text

    # The corpus itself: a success reads the three updates, an old failure is blocking, the notes are read, the file is read.
    stub = Stub()
    stub.answers = {"checkupdates": (0, updates, "")}
    r = checker(stub).system_updates(None, {"grassfield-desktop", "grassfield-keyring"})
    if r["state"] != "available" or r["others"] != 2 or r["grassfield"]["available"] != "0.5.0-1" or r["omarchy"]["available"] != "4.2.0-1":
        sc.finding("the corpus itself is not read as the contract says", r)
    c = checker(stub)
    c.health_error = ""
    m.write_text(c.path("failures"), '{"first": 1700000000}')
    if c.health_failed()["state"] != "blocking":
        sc.finding("the corpus itself: an old failure is not blocking", c.result)
    c = checker(stub)
    c.result["channel"] = "stable"
    if [x["version"] for x in c.parse_notes(notes_corpus[0], "0.4.0-1", "0.5.0-1")] != ["0.5.0-1", "0.4.1-1"]:
        sc.finding("the corpus itself: the notes are not read", notes_corpus[0])
    if m.servers(conf_corpus[1]) != ["https://repo.example/stable/$arch", "https://mirror.example/stable/$arch"] or m.sections(conf_corpus[0]) != 1 \
            or m.channel_of(m.servers(conf_corpus[1])[0], base) != "stable":
        sc.finding("the corpus itself: the configuration is not read", conf_corpus)

    def check_toolkit(out, stub):
        # What installed() answers for each tracked package: the stub's version, or the mutated line's second word when
        # that line names the package (as the reader demands), else nothing; a version outside pacman's grammar is not
        # listed.
        expected = {}
        for name, v in stub.installed.items():
            parts = (stub.installed_text or "%s %s\n" % (name, v)).split()
            if len(parts) == 2 and parts[0] == name and m.RECORD_VERSION.match(parts[1]):
                expected[name] = parts[1]
        assert isinstance(out, dict) and set(out) == {"record", "packages"} and isinstance(out["record"], bool), out
        packages = out["packages"]
        assert isinstance(packages, list), out
        assert [p["name"] for p in packages] == [n for n in m.TRACKED if n in expected], (packages, expected)
        for p in packages:
            assert set(p) == {"name", "installed", "installedAt", "built", "moved"}, p
            assert p["installed"] == expected[p["name"]], (p, expected[p["name"]])
            assert p["installedAt"] is None or iso.match(p["installedAt"]), p
            if not out["record"]:
                assert p["built"] is None and p["moved"] is None, p
            elif p["built"] is None:
                assert p["moved"] is True, p
            else:
                assert m.RECORD_VERSION.match(p["built"]) and p["moved"] == (m.compare_key(p["name"], p["built"]) != m.compare_key(p["name"], p["installed"])), p

    def body(i):
        mut = sc.mutator
        stub = Stub()
        if i % 5 == 4:
            with open(m.BUILD_DEPS, "wb") as f:
                f.write(mut.mutate(mut.rng.pick(record_corpus), record_corpus, 8192))
            stub.installed = {}
            for name in m.TRACKED:
                v = mut.rng.pick(toolkit_versions)
                if v is not None:
                    stub.installed[name] = mut.text(v, [], 64) if mut.rng.below(4) == 0 else v
            if mut.rng.below(4) == 0:
                stub.installed_text = mut.text(mut.rng.pick(installed_corpus), installed_corpus, 4096)
            entry = os.path.join(m.PACMAN_LOCAL, "qt6-base-6.12.0-1")
            os.makedirs(entry, exist_ok=True)
            with open(os.path.join(entry, "desc"), "wb") as f:
                f.write(mut.mutate(mut.rng.pick(desc_corpus), desc_corpus, 65536))
            if mut.rng.below(8) == 0:
                try:
                    os.unlink(m.BUILD_DEPS)
                except FileNotFoundError:
                    pass
            out = checker(stub).toolkit()
            check_toolkit(out, stub)
            return any(p["moved"] for p in out["packages"])
        if i % 5 == 0:
            stub.answers = {"checkupdates": (mut.rng.pick([0, 2, 1]), mut.text(mut.rng.pick(upd_corpus), upd_corpus, 65536), "")}
            if mut.rng.below(4) == 0:
                stub.installed_text = mut.text(mut.rng.pick(installed_corpus), installed_corpus, 4096)
            if mut.rng.below(4) == 0:
                stub.installed["omarchy-dev"] = "4.1.0-1"
            c = checker(stub, mut.rng.coin())
            r = c.system_updates(mut.rng.pick([None, "not-set-up"]), set(mut.rng.pick([["grassfield-desktop", "grassfield-keyring"], []])))
            # Omarchy's package is omarchy-dev when that one is installed (the two conflict: a real checkupdates never lists
            # the other one too); the stub's installed set says which name the result must not count among the others.
            check_updates(r, "omarchy-dev" if "omarchy-dev" in stub.installed else "omarchy")
            return r["state"] == "available"
        if i % 5 == 1:
            c = checker(stub, mut.rng.below(4) == 0)
            with open(c.path("failures"), "wb") as f:
                f.write(mut.mutate(mut.rng.pick(fail_corpus), fail_corpus, 65536))
            with open(c.path("last-success"), "wb") as f:
                f.write(mut.mutate(mut.rng.pick(succ_corpus), succ_corpus, 65536))
            c.health_error = "x"
            r = c.health_failed()
            check_failed(c, r)
            return r["state"] == "blocking"
        if i % 5 == 2:
            if mut.rng.below(4) == 0:
                stub.answers["vercmp"] = (0, mut.text(mut.rng.pick(["1", "0", "-1", "x"]), [], 64), "")
            c = checker(stub)
            c.result["channel"] = mut.rng.pick(["stable", "beta", "custom", None])
            raw = mut.mutate(mut.rng.pick(notes_corpus), notes_corpus, m.NOTES_CAP + 64)
            try:
                out = c.parse_notes(raw, mut.rng.pick(["0.4.0-1", None, "0.5.0-1"]), mut.rng.pick(["0.5.0-1", "0.4.1-2"]))
            except (ValueError, UnicodeDecodeError):
                return False
            check_notes(out)
            return bool(out)
        text = mut.text(mut.rng.pick(conf_corpus), conf_corpus, 65536)
        listed = m.servers(text)
        assert isinstance(listed, list) and all(isinstance(s, str) and "\n" not in s for s in listed), listed
        count = m.sections(text)
        assert isinstance(count, int) and count >= 0, count
        assert m.channel_of(listed[0] if listed else "", mut.rng.pick([base, "", "file:///srv/repo"])) in ("stable", "beta", "custom")
        return bool(listed)

    sc.run(body)


SCENARIOS = [("crash-watch", crash_watch), ("session-end", session_end), ("battery-watch", battery_watch), ("anr-dialog", anr_dialog),
             ("lock-status", lock_status), ("sleep-lock-gate", sleep_lock_gate), ("update-check", update_check)]
for name, fn in SCENARIOS:
    if want(name):
        if name == "lock-status" and not any(os.access(os.path.join(d, "jq"), os.X_OK) for d in os.environ.get("PATH", "").split(":")):
            print("SKIP: lock-status (jq not installed)")
            continue
        fn()
sys.exit(status)
