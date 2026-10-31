# packaging/bin/grassfield-capture against fakes (run by tests/shell/capture.sh as `python3 -I check.py <root> <tmp>`).
# The fakes answer as the real tools do (review of step 8): slurp gives a fed box for a click inside it and a 1x1 area for a
# click elsewhere (its minimum), notify-send prints the notice's id then the action and, sent SIGINT while it waits, closes its
# notice and ends.
import json
import os
import re
import subprocess
import sys
import time

root, tmp = sys.argv[1:3]
failed = False


def check(ok, desc):
    global failed
    print(("PASS: " if ok else "FAIL: ") + desc, flush=True)
    failed = failed or not ok


def write(path, text, mode=0o755):
    with open(path, "w") as f:
        f.write(text)
    os.chmod(path, mode)


fake, quiet, home, log = (os.path.join(tmp, d) for d in ("fake", "fake-no-notify", "home", "log"))
for d in (fake, quiet, home, log):
    os.makedirs(d)
helper = os.path.join(root, "packaging/bin/grassfield-capture")
source = open(helper).read()
# The same helper, waiting 2 s instead of WAIT_SECONDS for a click on its notice.
short = os.path.join(tmp, "grassfield-capture-short")
write(short, re.sub(r"^WAIT_SECONDS = [0-9]+$", "WAIT_SECONDS = 2", source, flags=re.M))

# The colours are the tokens' (capture.*), as slurp takes them.
tokens = json.load(open(os.path.join(root, "ui/tokens/tokens.json")))["capture"]
m = re.search(r"^COLOURS = (\{.*\})$", source, re.M)
colours = json.loads(m.group(1)) if m else {}
check(colours == {k: tokens[k]["value"] for k in ("veil", "selection", "border", "box")}
      and re.search(r"^BORDER_WIDTH = %d$" % tokens["borderWidth"]["value"], source, re.M) is not None,
      "the crosshair's colours and width are ui/tokens/tokens.json's capture.* [%r]" % colours)
slurp_argv = ["-b", colours["veil"], "-s", colours["selection"], "-c", colours["border"], "-B", colours["box"],
              "-w", str(tokens["borderWidth"]["value"])]

# Fakes: each records its argv (and stdin) as one JSON line; behaviour from FAKE_* variables.
for name in ("grim", "slurp", "wl-copy", "notify-send", "hyprctl", "xdg-user-dir", "pkill", "systemd-run", "uwsm-app", "gdbus"):
    write(os.path.join(fake, name), r'''#!/usr/bin/python3 -I
import json, os, re, signal, sys, time
name = os.path.basename(sys.argv[0])
data = sys.stdin.buffer.read().decode("utf-8", "replace") if name in ("slurp", "wl-copy") else ""
def record(**extra):
    with open(os.path.join(os.environ["FAKE_LOG"], "calls"), "a") as f:
        f.write(json.dumps(dict({"name": name, "argv": sys.argv[1:], "stdin": data[:200]}, **extra)) + "\n")
record()
env = os.environ
if name == "grim":
    if env.get("FAKE_GRIM") == "fail":
        sys.exit(1)
    open(sys.argv[-1], "wb").write(b"\x89PNG fake " + sys.argv[-2].encode())
elif name == "slurp":
    answer = env.get("FAKE_SLURP", "")
    if answer == "":
        sys.exit(1)  # Esc
    click = re.fullmatch(r"click:(-?\d+),(-?\d+)", answer)
    if click:
        # As slurp: the smallest fed box under the point, else a 1x1 area there.
        px, py = int(click[1]), int(click[2])
        boxes = []
        for line in data.splitlines():
            b = re.fullmatch(r"(-?\d+),(-?\d+) (\d+)x(\d+)", line)
            if b:
                x, y, w, h = map(int, b.groups())
                if x <= px < x + w and y <= py < y + h:
                    boxes.append((w * h, line))
        answer = min(boxes)[1] if boxes else "%d,%d 1x1" % (px, py)
    print(answer)
elif name == "hyprctl":
    print(env.get("FAKE_MONITORS" if sys.argv[2] == "monitors" else "FAKE_CLIENTS", "[]"))
elif name == "xdg-user-dir":
    if "FAKE_DESKTOP" in env:
        print(env["FAKE_DESKTOP"])
    else:
        sys.exit(1)
elif name == "pkill":
    sys.exit(0 if env.get("FAKE_SELECTING") == "1" else 1)
elif name == "notify-send":
    def closed(sig, frame):
        record(signal="INT")
        sys.exit(0)
    signal.signal(signal.SIGINT, closed)
    print(17, flush=True)
    answer = env.get("FAKE_ANSWER", "")
    if answer == "hang":
        time.sleep(60)
    elif answer:
        print(answer, flush=True)
    # As notify-send, whose output ends before it has ended (it still closes its connection to the bus): the helper must wait
    # for the process, not take the end of the output for its wait running out (review of step 8, MAJOR 1).
    os.close(1)
    time.sleep(0.2)
''')
for name in os.listdir(fake):
    if name != "notify-send":
        os.symlink(os.path.join(fake, name), os.path.join(quiet, name))

MONITORS = json.dumps([
    {"name": "DP-1", "x": 0, "y": 0, "width": 3840, "height": 2160, "scale": 2.0, "transform": 0, "focused": False,
     "activeWorkspace": {"id": 1}, "specialWorkspace": {"id": 0}},
    {"name": "HDMI-A-1", "x": 1920, "y": 0, "width": 1080, "height": 1920, "scale": 1.0, "transform": 1, "focused": True,
     "activeWorkspace": {"id": 2}, "specialWorkspace": {"id": 0}},
    {"name": "DP-2", "x": 0, "y": 0, "width": 1920, "height": 1080, "scale": 1.0, "transform": 0, "disabled": True,
     "activeWorkspace": {"id": 3}, "specialWorkspace": {"id": 0}}])
CLIENTS = json.dumps([
    {"mapped": True, "hidden": False, "workspace": {"id": 1}, "at": [100, 50], "size": [800, 600], "fullscreen": 0},
    {"mapped": True, "hidden": True, "workspace": {"id": 1}, "at": [0, 0], "size": [500, 500], "fullscreen": 0},
    {"mapped": True, "hidden": False, "workspace": {"id": 9}, "at": [0, 0], "size": [400, 400], "fullscreen": 0},
    {"mapped": True, "hidden": False, "workspace": {"id": 2}, "at": [2000, 100], "size": [600, 400], "fullscreen": 0}])
# Workspace 2 with a fullscreen window over the tiled one (and a maximized one elsewhere, which hides nothing).
FULL = json.dumps([
    {"mapped": True, "hidden": False, "workspace": {"id": 1}, "at": [100, 50], "size": [800, 600], "fullscreen": 1},
    {"mapped": True, "hidden": False, "workspace": {"id": 2}, "at": [2000, 100], "size": [600, 400], "fullscreen": 0},
    {"mapped": True, "hidden": False, "workspace": {"id": 2}, "at": [1920, 0], "size": [1920, 1080], "fullscreen": 2}])


def calls(name=None):
    try:
        lines = [json.loads(l) for l in open(os.path.join(log, "calls"))]
    except FileNotFoundError:
        return []
    return [c for c in lines if name is None or c["name"] == name]


def capture(mode, program=None, path=None, **extra):
    if os.path.exists(os.path.join(log, "calls")):
        os.unlink(os.path.join(log, "calls"))
    env = {"PATH": (path or fake) + ":/usr/bin:/bin", "HOME": home, "FAKE_LOG": log, "FAKE_MONITORS": MONITORS,
           "FAKE_CLIENTS": CLIENTS, "FAKE_ANSWER": "default"}
    env.update(extra)
    began = time.monotonic()
    r = subprocess.run([program or helper] + ([mode] if mode is not None else []), env=env, capture_output=True, timeout=60)
    return r, time.monotonic() - began


def files(folder):
    return sorted(os.listdir(folder)) if os.path.isdir(folder) else []


desktop = os.path.join(home, "Desktop")
name = re.compile(r"Screenshot [0-9]{4}-[0-9]{2}-[0-9]{2} at [0-9]{2}\.[0-9]{2}\.[0-9]{2}( \([0-9]+\))?\.png")

# The screen: every enabled display, the focused one first, one picture each, saved to ~/Desktop (no xdg-user-dir answer).
r, _ = capture("screen")
grim = calls("grim")
saved = files(desktop)
base = [f for f in saved if " (" not in f]
check(r.returncode == 0 and [g["argv"][:2] for g in grim] == [["-o", "HDMI-A-1"], ["-o", "DP-1"]] and len(saved) == 2
      and all(name.fullmatch(f) for f in saved) and len(base) == 1 and base[0][:-4] + " (2).png" in saved,
      "Shift-Cmd-3: every display, the focused one first, as macOS names them (the next one \" (2)\") [%r %r]"
      % ([g["argv"] for g in grim], saved))
first = os.path.join(desktop, base[0]) if base else ""
second = first[:-4] + " (2).png" if first else ""
check(all(os.path.dirname(g["argv"][-1]) == desktop and os.path.basename(g["argv"][-1]).startswith(".grassfield-capture-")
          for g in grim) and first and open(first, "rb").read().endswith(b"-o HDMI-A-1"[-8:]),
      "grim writes a hidden file of the helper's on the Desktop, which then takes the picture's name [%r]"
      % [g["argv"][-1] for g in grim])
check(not any(f.startswith(".") for f in os.listdir(desktop)), "no hidden file is left on the Desktop")
check(calls("slurp") == [], "the screen needs no crosshair")
copied = calls("wl-copy")
check(copied and copied[0]["argv"] == ["--type", "image/png"] and copied[0]["stdin"].startswith("�PNG")
      and copied[0]["stdin"].endswith("HDMI-A-1"), "the focused display's picture is copied to the clipboard as PNG")
note = calls("notify-send")
check(note and "string:image-path:" + first in note[0]["argv"] and "default=Open in Preview" in note[0]["argv"]
      and "open=Open in Preview" in note[0]["argv"] and note[0]["argv"][-2:] == ["Screenshot", "Saved to the Desktop and copied."]
      and "-t" not in note[0]["argv"] and note[0]["argv"][note[0]["argv"].index("-i") + 1] == "org.grassfield.Preview",
      "the notice shows the picture (Preview's icon when it cannot), an ordinary banner (no -t 0), a click or its button "
      "opens Preview [%r]" % (note[0]["argv"] if note else None))
run = calls("systemd-run")
check(run and run[0]["argv"][-5:] == [os.path.join(fake, "uwsm-app"), "--", "org.grassfield.Preview.desktop", first, second],
      "a click opens Preview with the capture's pictures, as the Dock starts an app [%r]" % (run[0]["argv"] if run else None))

# A second capture the same second: other names, never a file overwritten.
before = files(desktop)
r, _ = capture("screen")
check(len(files(desktop)) == len(before) + 2 and all(name.fullmatch(f) for f in files(desktop)),
      "another capture never overwrites a picture: %r" % files(desktop))

# The click on the notice is never lost (review of step 8, MAJOR 1: notify-send's output ended before it could be reaped,
# and the helper took that for its wait running out): 40 notices clicked as soon as they show.
opened = 0
for _ in range(40):
    r, _ = capture("selection", FAKE_SLURP="10,20 300x200")
    opened += len(calls("systemd-run")) == 1 and not any(c.get("signal") for c in calls("notify-send"))
check(opened == 40, "a click on the notice opens Preview every time (%d of 40)" % opened)
r, _ = capture("selection", FAKE_SLURP="10,20 300x200", FAKE_ANSWER="open")
check(len(calls("systemd-run")) == 1, "its Open in Preview button opens Preview")

# The selection: slurp in the tokens' colours, the shown workspaces' visible windows as boxes (the displays are the veil's).
r, _ = capture("selection", FAKE_SLURP="10,20 300x200")
slurp = calls("slurp")
check(slurp and slurp[0]["argv"] == slurp_argv, "the crosshair in Grassfield's colours [%r]" % (slurp[0]["argv"] if slurp else None))
check(slurp and slurp[0]["stdin"] == "100,50 800x600\n2000,100 600x400\n",
      "boxes: the shown workspaces' visible windows only, so the veil shows everywhere else [%r]"
      % (slurp[0]["stdin"] if slurp else None))
grim = calls("grim")
check(grim and grim[0]["argv"][:2] == ["-g", "10,20 300x200"], "a drag: that area [%r]" % (grim[0]["argv"] if grim else None))
r, _ = capture("selection", FAKE_SLURP="click:150,70")
grim = calls("grim")
check(grim and grim[0]["argv"][:2] == ["-g", "100,50 800x600"], "a click on a window: that window [%r]" % (grim[0]["argv"] if grim else None))
r, _ = capture("selection", FAKE_SLURP="click:1950,600")
grim = calls("grim")
check(grim and grim[0]["argv"][:2] == ["-g", "1920,0 1920x1080"], "a click outside every window: the display under it, "
      "rotated [%r]" % (grim[0]["argv"] if grim else None))
r, _ = capture("selection", FAKE_SLURP="click:5000,5000")
check(calls("grim") == [], "a click outside every display: nothing")
r, _ = capture("selection", FAKE_SLURP="click:2100,200", FAKE_CLIENTS=FULL)
slurp, grim = calls("slurp"), calls("grim")
check(slurp and slurp[0]["stdin"] == "100,50 800x600\n1920,0 1920x1080\n" and grim and grim[0]["argv"][:2] == ["-g", "1920,0 1920x1080"],
      "a fullscreen window: the only box of its workspace, so a click on it never picks the window behind [%r %r]"
      % (slurp[0]["stdin"] if slurp else None, grim[0]["argv"] if grim else None))
count = len(files(desktop))
r, _ = capture("selection", FAKE_SLURP="")
check(r.returncode == 0 and calls("grim") == [] and calls("notify-send") == [] and len(files(desktop)) == count,
      "Esc: nothing captured, saved or shown")
r, _ = capture("selection", FAKE_SELECTING="1", FAKE_SLURP="10,20 300x200")
pk = calls("pkill")
check(r.returncode == 0 and calls("slurp") == [] and calls("grim") == [] and pk
      and pk[0]["argv"] == ["-u", str(os.getuid()), "-f", "-x", " ".join(["slurp"] + slurp_argv)],
      "a second press while the crosshair shows cancels it, and only this helper's slurp (its exact command line) [%r]"
      % (pk[0]["argv"] if pk else None))
r, _ = capture("selection", FAKE_SLURP="garbage")
check(calls("grim") == [] and len(files(desktop)) == count, "an answer of slurp that does not read: nothing")

# The notice's wait is bounded: unanswered, notify-send is asked (SIGINT) to close its notice; nothing opens.
r, took = capture("selection", program=short, FAKE_SLURP="10,20 300x200", FAKE_ANSWER="hang")
note = calls("notify-send")
check(r.returncode == 0 and any(c.get("signal") == "INT" for c in note) and calls("systemd-run") == [] and calls("gdbus") == []
      and took < 10, "no click within the wait: notify-send closes its notice, Preview does not open (%.1f s)" % took)
# No click: no Preview.
r, _ = capture("screen", FAKE_ANSWER="")
check(calls("systemd-run") == [], "the notice closed without a click: Preview does not open")
# Without notify-send (libnotify is optional): the notice through gdbus, no button.
r, _ = capture("screen", path=quiet)
bus = calls("gdbus")
check(r.returncode == 0 and bus and "org.freedesktop.Notifications.Notify" in bus[0]["argv"]
      and bus[0]["argv"][bus[0]["argv"].index("org.freedesktop.Notifications.Notify") + 3] == "org.grassfield.Preview"
      and any(a.startswith("{'image-path': <\"" + desktop) for a in bus[0]["argv"]),
      "without notify-send: the notice through gdbus, with the picture [%r]" % (bus[0]["argv"] if bus else None))

# Failures leave nothing behind, and never end in a traceback.
count = len(files(desktop))
r, _ = capture("screen", FAKE_GRIM="fail")
check(r.returncode != 0 and len(files(desktop)) == count and calls("notify-send") == []
      and not any(f.startswith(".") for f in os.listdir(desktop)), "grim failing: no file left, no notice")
r, _ = capture("screen", FAKE_MONITORS="[]")
check(r.returncode != 0 and calls("grim") == [], "no display: nothing")
os.chmod(desktop, 0o555)
r, _ = capture("screen")
os.chmod(desktop, 0o755)
check(r.returncode == 1 and b"Traceback" not in r.stderr and len(files(desktop)) == count and calls("notify-send") == [],
      "a Desktop that cannot be written: nothing, and no traceback [%r]" % r.stderr[-200:])
r, _ = capture(None)
check(r.returncode == 2 and calls() == [], "no mode: usage, nothing run")
r, _ = capture("fullscreen")
check(r.returncode == 2 and calls() == [], "Omarchy's mode names are not taken")

# The Desktop: xdg-user-dir's, never the home folder or the root.
other = os.path.join(home, "Bureau")
r, _ = capture("screen", FAKE_DESKTOP=other)
check(len(files(other)) == 2, "xdg-user-dir's Desktop (a French one) [%r]" % files(other))
for bad in (home, "/", "", "relative/dir"):
    count = len(files(desktop))
    r, _ = capture("screen", FAKE_DESKTOP=bad)
    check(len(files(desktop)) == count + 2 and not any(f.endswith(".png") for f in os.listdir(home)),
          "xdg-user-dir answering %r: ~/Desktop" % bad)

# French: the names and the notice.
r, _ = capture("screen", LANG="fr_FR.UTF-8")
fr = [f for f in files(desktop) if f.startswith("Capture")]
note = calls("notify-send")
check(len(fr) == 2 and all(re.fullmatch(r"Capture d’écran [0-9]{4}-[0-9]{2}-[0-9]{2} à [0-9]{2}\.[0-9]{2}\.[0-9]{2}( \(2\))?\.png", f)
                           for f in fr)
      and note and "default=Ouvrir dans la Visionneuse" in note[0]["argv"]
      and note[0]["argv"][-2:] == ["Capture d’écran", "Enregistrée sur le Bureau et copiée."],
      "in French: « Capture d’écran … à … », the notice in French [%r]" % fr)

sys.exit(1 if failed else 0)
