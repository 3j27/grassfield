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
for p in (fa, ev, fb):
    os.unlink(p)

sys.exit(1 if failures else 0)
