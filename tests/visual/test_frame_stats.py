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


check("attribution: a client-paced long frame passes the shared edge's gate",
      attribution(["x", f_long, r_client, m_none, ev_edge, "60", "700", "--gate=shared-edge"]) == 0)
check("attribution: a long frame the compositor caused fails it",
      attribution(["x", f_long, r_comp, m_none, ev_edge, "60", "700", "--gate=shared-edge"]) == 1)
check("attribution: without --gate it only reports", attribution(["x", f_long, r_comp, m_none, ev_edge, "60", "700"]) == 0)
check("attribution: no render spans cannot pass the gate",
      attribution(["x", f_long, m_none, m_none, ev_edge, "60", "700", "--gate=shared-edge"]) == 1)
check("attribution: too few arguments exits 2", attribution(["x", f_long]) == 2)

for p in (fa, ev, fb, fm, em, eb, f_long, r_client, r_comp, m_none, ev_edge):
    os.unlink(p)

sys.exit(1 if failures else 0)
