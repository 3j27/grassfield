"""Offline test of the P3 frame statistics (tests/visual/frame-stats.py) on synthetic frame streams."""
import contextlib
import importlib.util
import io
import os
import sys
import tempfile

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("frame_stats", os.path.join(here, "frame-stats.py"))
fs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fs)

failures = []


def quiet(argv):
    with contextlib.redirect_stdout(io.StringIO()):
        return fs.main(argv)


def check(name, ok):
    if not ok:
        failures.append(name)
        print("FAIL", name)
    else:
        print("PASS", name)


def stream(start_us, count, interval_us, spikes=()):
    """count frames from start_us; the frames whose index is in spikes take twice the interval."""
    out, t = [], start_us
    for i in range(count):
        step = interval_us * 2 if i in spikes else interval_us
        t += step
        out.append((t, step))
    return out


def write(lines):
    f = tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False)
    f.write("\n".join(lines) + "\n")
    f.close()
    return f.name


# Parsing: comments and junk are ignored.
check("read_frames ignores comments and junk", fs.read_frames("# frames 2\n100 16666\nx y\n200 16667\n") == [(100, 16666), (200, 16667)])
check("read_events turns ns into us", fs.read_events("open 5000000\nclose abc\nclose 9000\n") == [("open", 5000), ("close", 9)])
check("read_events keeps an event's own window (ms to us)", fs.read_events("open 5000000 366.7 900\n") == [("open", 5000, 366700)])

period = 1e6 / 60
smooth = stream(1_000_000, 200, round(period))
events = [("open", 1_000_000 * 1000), ("close", (1_000_000 + 1_500_000) * 1000)]
s = fs.stats(fs.phase(smooth, [(n, t // 1000) for n, t in events], "open", 700000), period, 1.2)
check("a steady 60 Hz stream is 100 % on time", s is not None and s["share"] == 1.0)
check("the window holds about 42 frames", s is not None and 40 <= s["count"] <= 44)

# One dropped frame in ~42 is 97.6 %: still a pass; four are 90 %: a fail.
few = stream(1_000_000, 200, round(period), spikes={3})
s = fs.stats(fs.phase(few, [("open", 1_000_000)], "open", 700000), period, 1.2)
check("one dropped frame in the window stays above 95 %", s is not None and 0.95 <= s["share"] < 1.0)
many = stream(1_000_000, 200, round(period), spikes={3, 8, 13, 18})
s = fs.stats(fs.phase(many, [("open", 1_000_000)], "open", 700000), period, 1.2)
check("four dropped frames are below 95 %", s is not None and s["share"] < 0.95)
check("the worst interval is the dropped one", s is not None and abs(s["max_ms"] - 2 * period / 1000) < 0.1)

# An event's own window (the animation, D-5 2026-10-24): frames after it are not counted, however late.
late = stream(1_000_000, 22, round(period)) + [(1_000_000 + 22 * round(period) + 90_000, 90_000)]
s = fs.stats(fs.phase(late, [("open", 1_000_000, 22 * round(period))], "open", 700000), period, 1.2)
check("a stall after the event's own window is not counted", s is not None and s["share"] == 1.0)
s = fs.stats(fs.phase(late, [("open", 1_000_000)], "open", 700000), period, 1.2)
check("the same stall inside the default window is", s is not None and s["share"] < 1.0)

# Empty input.
check("no frame in the window gives no statistics", fs.stats([], period, 1.2) is None)
check("percentile of nothing is 0", fs.percentile([], 0.95) == 0)

# End to end through main(): exit status 0 for smooth, 1 for dropped frames, 2 for unusable input.
fa = write("%d %d" % f for f in smooth)
ev = write(["open %d" % (1_000_000 * 1000), "close %d" % ((1_000_000 + 1_500_000) * 1000)])
check("main: smooth stream exits 0", quiet(["x", fa, ev, "60"]) == 0)
fb = write("%d %d" % f for f in many)
check("main: a stream with dropped frames exits 1", quiet(["x", fb, ev, "60"]) == 1)
check("main: no refresh rate exits 2", quiet(["x", fa, ev, "0"]) == 2)
check("main: too few arguments exits 2", quiet(["x"]) == 2)
# --info=PREFIX (the shared edge's drag, ADR-0036 D34 as amended): such a phase is reported, never judged, and left out of
# "all"; the others keep the 95 % gate.
mixed = stream(1_000_000, 200, round(period)) + stream(3_000_000, 200, round(period), spikes={3, 8, 13, 18, 23, 28})
fm = write("%d %d" % f for f in mixed)
em = write(["open %d" % (1_000_000 * 1000), "shared-edge %d" % (3_000_000 * 1000)])
check("main: a phase with dropped frames fails without --info", quiet(["x", fm, em, "60"]) == 1)
check("main: the same phase under --info is not judged", quiet(["x", fm, em, "60", "--info=shared-edge"]) == 0)
out = io.StringIO()
with contextlib.redirect_stdout(out):
    fs.main(["x", fm, em, "60", "--info=shared-edge"])
check("main: --info prints the phase as INFO and keeps the others judged",
      "INFO shared-edge:" in out.getvalue() and "PASS open:" in out.getvalue() and "PASS all:" in out.getvalue())
eb = write(["open %d" % (3_000_000 * 1000), "shared-edge %d" % (1_000_000 * 1000)])
check("main: --info leaves the other phases' dropped frames judged", quiet(["x", fm, eb, "60", "--info=shared-edge"]) == 1)
# Integrator review of a6d04df (MINOR 3): an --info phase with no frame in its window was measured by nothing: it fails.
en = write(["open %d" % (1_000_000 * 1000), "shared-edge %d" % (9_000_000 * 1000)])
check("main: an --info phase with no frame fails", quiet(["x", fa, en, "60", "--info=shared-edge"]) == 1)

# frame-attribution.py --gate=PREFIX: the long frames the compositor caused fail the scenario, client-paced ones do not.
spec_a = importlib.util.spec_from_file_location("frame_attribution", os.path.join(here, "frame-attribution.py"))
fa_mod = importlib.util.module_from_spec(spec_a)
spec_a.loader.exec_module(fa_mod)
p_us = round(period)
# Ten frames, the sixth 3 periods long: its render began late (client) or took long (compositor).
frames_long = [(1_000_000 + i * p_us, p_us) for i in range(1, 6)] + [(1_000_000 + 8 * p_us, 3 * p_us)] + [(1_000_000 + (8 + i) * p_us, p_us) for i in range(1, 5)]
renders_client = [(1_000_000 + i * p_us - 4000, 3000) for i in range(1, 6)] + [(1_000_000 + 8 * p_us - 4000, 3000)] + [(1_000_000 + (8 + i) * p_us - 4000, 3000) for i in range(1, 5)]
renders_comp = [(b, 3000) for b, _ in renders_client[:5]] + [(1_000_000 + 5 * p_us + 1000, 40000)] + [(b, 3000) for b, _ in renders_client[6:]]
f_long = write("%d %d" % f for f in frames_long)
r_client = write("%d %d" % r for r in renders_client)
r_comp = write("%d %d" % r for r in renders_comp)
m_none = write([])
ev_edge = write(["shared-edge %d 400 0" % (1_000_000 * 1000)])


def attribution(argv):
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        return fa_mod.main(argv)


# The plugin's own work in every frame of the drag (200 us each): the gate needs it recorded (D34 gate, (a)).
w_small = write("%d %d" % (1_000_000 + i * p_us + 1000, 200) for i in range(0, 13))
gate = ["--gate=shared-edge", "--beats=250", "--work=" + w_small]
check("attribution: a client-paced long frame passes the shared edge's gate",
      attribution(["x", f_long, r_client, m_none, ev_edge, "60", "700"] + gate) == 0)
check("attribution: a long frame the compositor caused fails it",
      attribution(["x", f_long, r_comp, m_none, ev_edge, "60", "700"] + gate) == 1)
check("attribution: without --gate it only reports", attribution(["x", f_long, r_comp, m_none, ev_edge, "60", "700"]) == 0)
check("attribution: no render spans cannot pass the gate",
      attribution(["x", f_long, m_none, m_none, ev_edge, "60", "700"] + gate) == 1)
check("attribution: too few arguments exits 2", attribution(["x", f_long]) == 2)
check("attribution: a bad beat count exits 2", attribution(["x", f_long, r_client, m_none, ev_edge, "60", "700", "--beats=x"]) == 2)

# Integrator review of a6d04df (MAJOR 2): a main-loop stall before the render shows only as a late render. The long frame
# above began its render 2 periods late; a 50 ms stall of the loop in that wait (a late beat) is the compositor's, as is
# the plugin's own work there over the budget. A stall that is the render itself (a beat late because the loop rendered)
# is not counted twice.
long_start = 1_000_000 + 5 * p_us
s_pre = write(["%d %d" % (long_start + 1000, 30000)])
s_short = write(["%d %d" % (long_start + 1000, 5000)])
render_late = renders_client[5][0]
s_render = write(["%d %d" % (render_late - 500, 4000)])
w_pre = write(["%d %d" % (long_start + 2000, 15000)])
check("attribution: a stall of the loop before the render fails the gate (the synthetic pre-render stall)",
      attribution(["x", f_long, r_client, m_none, ev_edge, "60", "700", "--stalls=" + s_pre] + gate) == 1)
check("attribution: the plugin's own work over the budget before the render fails it",
      attribution(["x", f_long, r_client, m_none, ev_edge, "60", "700", "--work=" + w_pre] + gate) == 1)
check("attribution: a short stall (under the budget) leaves the late render the client's",
      attribution(["x", f_long, r_client, m_none, ev_edge, "60", "700", "--stalls=" + s_short] + gate) == 0)
check("attribution: a beat held by the render itself is not counted again",
      attribution(["x", f_long, r_client, m_none, ev_edge, "60", "700", "--stalls=" + s_render] + gate) == 0)
check("attribution: no loop beats cannot pass the gate (a stall could not be seen)",
      attribution(["x", f_long, r_client, m_none, ev_edge, "60", "700", "--gate=shared-edge", "--work=" + w_small]) == 1)
check("attribution: held time is the union of the spans, outside the renders",
      fa_mod.held(0, 100, [(10, 30), (20, 30), (80, 40)], [(30, 10)]) == 50)
# Integrator nested pass of ce82fd3: each compositor-caused frame is listed with the loop's held time split into stalls
# (with the main thread's CPU share in them: a waiting thread is not the compositor working) and the plugin's work.
check("attribution: a stall's CPU share is its CPU over its length plus one beat",
      fa_mod.stall_cpu(0, 10_000, [(0, 10_000, 11_000)]) == 10_000 and fa_mod.stall_cpu(0, 10_000, [(0, 10_000, 550)]) == 500)
check("attribution: no CPU known, no CPU share", fa_mod.stall_cpu(0, 10_000, [(0, 10_000, None)]) is None)
s_cpu = write(["%d %d %d" % (long_start + 1000, 30000, 1500)])
detail = io.StringIO()
with contextlib.redirect_stdout(detail):
    fa_mod.main(["x", f_long, r_client, m_none, ev_edge, "60", "700", "--stalls=" + s_cpu, "--work=" + w_pre, "--gate=shared-edge", "--beats=250"])
text = detail.getvalue()
check("attribution: the compositor-caused frame is listed with its stalls, their CPU share and the plugin's work",
      "compositor (render began" in text and "stalls 30.0 ms" in text and "on its CPU for about 1.5 ms" in text
      and "the plugin's work 15.0 ms" in text)
check("attribution: the scenario's compositor-caused frames are summed",
      "its 1 compositor-caused long frame(s) in the animation, in total: loop stalls 30.0 ms" in text)
ev_far = write(["shared-edge %d 400 0" % (9_000_000 * 1000)])
check("attribution: a gated scenario with no frame in its animation fails",
      attribution(["x", f_long, r_client, m_none, ev_far, "60", "700"] + gate) == 1)

# Integrator re-review of ce82fd3. Python mutants P5 (a long frame with no render in it: the loop's held time alone decides)
# and P8 (a stall after its render began does not count before it); and the probe's resolution: a 12 ms hold before a 3 ms
# render is recorded at most one beat (1 ms) short, 11 ms, and still fails.
r_none_long = write("%d %d" % r for r in renders_client[:5] + renders_client[6:])
check("attribution: a long frame with no render, the loop held over the budget, is the compositor's",
      attribution(["x", f_long, r_none_long, m_none, ev_edge, "60", "700", "--stalls=" + s_pre] + gate) == 1)
check("attribution: a long frame with no render and the loop free is other",
      attribution(["x", f_long, r_none_long, m_none, ev_edge, "60", "700"] + gate) == 0)
r_early = write("%d %d" % r for r in renders_client[:5] + [(long_start + 2000, 3000)] + renders_client[6:])
s_after = write(["%d %d" % (long_start + 6000, 34000)])
check("attribution: a stall after the render began does not count before it",
      attribution(["x", f_long, r_early, m_none, ev_edge, "60", "700", "--stalls=" + s_after] + gate) == 0)
s_hold = write(["%d %d" % (long_start + 34000, 11000)])
check("attribution: a 12 ms hold (recorded 11 ms) before a 3 ms render fails",
      attribution(["x", f_long, r_client, m_none, ev_edge, "60", "700", "--stalls=" + s_hold] + gate) == 1)

# The D34 gate restated by the integrator (2026-10-28): (a) the plugin's own work at most 1 ms in every frame of the drag;
# (b) its compositor-caused long frames per second at most 1.25 times the baseline's (Hyprland's own resize of one of the
# same windows, the same glide).
def scenario(base, comp):
    fr = [(base + i * p_us, p_us) for i in range(1, 6)] + [(base + 8 * p_us, 3 * p_us)] + [(base + (8 + i) * p_us, p_us) for i in range(1, 5)]
    late = (base + 5 * p_us + 1000, 40000) if comp else (base + 8 * p_us - 4000, 3000)
    rs = [(base + i * p_us - 4000, 3000) for i in range(1, 6)] + [late] + [(base + (8 + i) * p_us - 4000, 3000) for i in range(1, 5)]
    return fr, rs


def run_pair(edge_comp, base_comp, with_baseline=True, extra=()):
    fe, re_ = scenario(1_000_000, edge_comp)
    fb_, rb_ = scenario(3_000_000, base_comp)
    evs = ["shared-edge %d 400 0" % (1_000_000 * 1000)] + (["edge-baseline %d 400 0" % (3_000_000 * 1000)] if with_baseline else [])
    files = [write("%d %d" % f for f in fe + fb_), write("%d %d" % r for r in sorted(re_ + rb_)), write(evs)]
    rc = attribution(["x", files[0], files[1], m_none, files[2], "60", "700", "--baseline=edge-baseline"] + gate + list(extra))
    for f in files:
        os.unlink(f)
    return rc


check("gate (b): as many compositor-caused long frames per second as the baseline pass", run_pair(True, True) == 0)
check("gate (b): more than 1.25 times the baseline's fail", run_pair(True, False) == 1)
check("gate (b): none on either side pass", run_pair(False, False) == 0)
check("gate (b): a baseline not measured fails", run_pair(False, False, with_baseline=False) == 1)
w_big = write(["%d %d" % (1_000_000 + 2 * p_us + 2000, 1500)])
check("gate (a): the plugin's own work over 1 ms in one frame fails", run_pair(False, False, extra=["--work=" + w_big]) == 1)
w_ok = write(["%d %d" % (1_000_000 + 2 * p_us + 2000, 700)])
check("gate (a): 0.9 ms in one frame passes", run_pair(False, False, extra=["--work=" + w_ok]) == 0)
check("gate (a): no work of the plugin recorded in the animation fails",
      attribution(["x", f_long, r_client, m_none, ev_edge, "60", "700", "--gate=shared-edge", "--beats=250"]) == 1)
verdict = io.StringIO()
with contextlib.redirect_stdout(verdict):
    fe, re_ = scenario(1_000_000, True)
    fb_, rb_ = scenario(3_000_000, True)
    vf = [write("%d %d" % f for f in fe + fb_), write("%d %d" % r for r in sorted(re_ + rb_)),
          write(["shared-edge %d 400 0" % (1_000_000 * 1000), "edge-baseline %d 400 0" % (3_000_000 * 1000)])]
    fa_mod.main(["x", vf[0], vf[1], m_none, vf[2], "60", "700", "--baseline=edge-baseline"] + gate)
check("gate: the verdict names both parts with their numbers",
      "PASS shared-edge: (a) the plugin's own work at most 0.60 ms in a frame (gate: 1 ms); (b) 1 compositor-caused long frame(s) in 0.40 s, 2.5/s, "
      "2.50/s per resized window (1), against edge-baseline's 1 in 0.40 s, 2.5/s, 2.50/s per resized window (1) (gate: 3.12/s per window)"
      in verdict.getvalue())
# D34 final (integrator, 2026-10-29): the rate per resized window. The drag resizes two windows, the baseline one: twice the
# baseline's rate is the same per window and passes; without --resizes it is 2 times the baseline's and fails.
fe, re_ = scenario(1_000_000, True)
fb_, rb_ = scenario(3_000_000, True)
pw = [write("%d %d" % f for f in fe + fb_), write("%d %d" % r for r in sorted(re_ + rb_)),
      write(["shared-edge %d 400 0" % (1_000_000 * 1000), "edge-baseline %d 800 0" % (3_000_000 * 1000)])]
per_window = ["x", pw[0], pw[1], m_none, pw[2], "60", "700", "--baseline=edge-baseline"] + gate
check("gate (b): twice the baseline's rate fails when both resize one window", attribution(per_window) == 1)
check("gate (b): twice the baseline's rate passes per resized window (the drag resizes two)",
      attribution(per_window + ["--resizes=shared-edge=2", "--resizes=edge-baseline=1"]) == 0)
check("gate (b): a bad window count exits 2", attribution(per_window + ["--resizes=shared-edge=0"]) == 2)

for p in (fa, ev, fb, fm, em, eb, en, f_long, r_client, r_comp, m_none, ev_edge, s_pre, s_short, s_render, w_pre, ev_far, s_cpu,
          w_small, r_none_long, r_early, s_after, s_hold, w_big, w_ok, *vf, *pw):
    os.unlink(p)

sys.exit(1 if failures else 0)
