# packaging/bin/grassfield-capture against fakes (run by tests/shell/capture.sh as `python3 -I check.py <root> <tmp>`).
import datetime
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


fake, home, log = (os.path.join(tmp, d) for d in ("fake", "home", "log"))
for d in (fake, home, log):
    os.makedirs(d)
helper = os.path.join(root, "packaging/bin/grassfield-capture")

# The colours are the tokens' (capture.*), as slurp takes them.
tokens = json.load(open(os.path.join(root, "ui/tokens/tokens.json")))["capture"]
source = open(helper).read()
m = re.search(r"^COLOURS = (\{.*\})$", source, re.M)
colours = json.loads(m.group(1)) if m else {}
check(colours == {k: tokens[k]["value"] for k in ("veil", "selection", "border", "box")}
      and re.search(r"^BORDER_WIDTH = %d$" % tokens["borderWidth"]["value"], source, re.M) is not None,
      "the crosshair's colours and width are ui/tokens/tokens.json's capture.* [%r]" % colours)

# Fakes: each records its argv (and stdin) as one JSON line; behaviour from FAKE_* variables.
for name in ("grim", "slurp", "wl-copy", "notify-send", "hyprctl", "xdg-user-dir", "pkill", "systemd-run", "uwsm-app", "gdbus"):
    write(os.path.join(fake, name), r'''#!/usr/bin/python3 -I
import json, os, sys, time
name = os.path.basename(sys.argv[0])
data = sys.stdin.buffer.read().decode("utf-8", "replace") if name in ("slurp", "wl-copy") else ""
with open(os.path.join(os.environ["FAKE_LOG"], "calls"), "a") as f:
    f.write(json.dumps({"name": name, "argv": sys.argv[1:], "stdin": data[:200]}) + "\n")
env = os.environ
if name == "grim":
    if env.get("FAKE_GRIM") == "fail":
        sys.exit(1)
    open(sys.argv[-1], "wb").write(b"\x89PNG fake")
elif name == "slurp":
    if env.get("FAKE_SLURP", "") == "":
        sys.exit(1)
    print(env["FAKE_SLURP"])
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
    print(17, flush=True)
    answer = env.get("FAKE_ANSWER", "")
    if answer == "hang":
        time.sleep(30)
    elif answer:
        print(answer)
''')

MONITORS = json.dumps([
    {"name": "DP-1", "x": 0, "y": 0, "width": 3840, "height": 2160, "scale": 2.0, "transform": 0, "focused": False,
     "activeWorkspace": {"id": 1}, "specialWorkspace": {"id": 0}},
    {"name": "HDMI-A-1", "x": 1920, "y": 0, "width": 1080, "height": 1920, "scale": 1.0, "transform": 1, "focused": True,
     "activeWorkspace": {"id": 2}, "specialWorkspace": {"id": 0}}])
CLIENTS = json.dumps([
    {"mapped": True, "hidden": False, "workspace": {"id": 1}, "at": [100, 50], "size": [800, 600]},
    {"mapped": True, "hidden": True, "workspace": {"id": 1}, "at": [0, 0], "size": [500, 500]},
    {"mapped": True, "hidden": False, "workspace": {"id": 9}, "at": [0, 0], "size": [400, 400]},
    {"mapped": True, "hidden": False, "workspace": {"id": 2}, "at": [2000, 100], "size": [600, 400]}])


def calls(name=None):
    try:
        lines = [json.loads(l) for l in open(os.path.join(log, "calls"))]
    except FileNotFoundError:
        return []
    return [c for c in lines if name is None or c["name"] == name]


def capture(mode, **extra):
    if os.path.exists(os.path.join(log, "calls")):
        os.unlink(os.path.join(log, "calls"))
    env = {"PATH": fake + ":/usr/bin:/bin", "HOME": home, "FAKE_LOG": log, "FAKE_MONITORS": MONITORS, "FAKE_CLIENTS": CLIENTS,
           "FAKE_ANSWER": "default"}
    env.update(extra)
    began = time.monotonic()
    r = subprocess.run([helper] + ([mode] if mode is not None else []), env=env, capture_output=True, timeout=60)
    return r, time.monotonic() - began


def files(folder):
    return sorted(os.listdir(folder)) if os.path.isdir(folder) else []


desktop = os.path.join(home, "Desktop")
name = re.compile(r"Screenshot [0-9]{4}-[0-9]{2}-[0-9]{2} at [0-9]{2}\.[0-9]{2}\.[0-9]{2}( \([0-9]+\))?\.png")

# The screen: the focused display, by name, saved to ~/Desktop (no xdg-user-dir answer).
r, _ = capture("screen")
grim = calls("grim")
saved = files(desktop)
check(r.returncode == 0 and grim and grim[0]["argv"][:2] == ["-o", "HDMI-A-1"] and len(saved) == 1 and name.fullmatch(saved[0]),
      "Shift-Cmd-3: the focused display, saved to the Desktop as macOS names it [%r %r]" % (grim[0]["argv"] if grim else None, saved))
check(calls("slurp") == [], "the screen needs no crosshair")
copied = calls("wl-copy")
check(copied and copied[0]["argv"] == ["--type", "image/png"] and copied[0]["stdin"].startswith("�PNG"),
      "the picture is copied to the clipboard as PNG")
note = calls("notify-send")
path = os.path.join(desktop, saved[0]) if saved else ""
check(note and "string:image-path:" + path in note[0]["argv"] and "default=Open in Preview" in note[0]["argv"]
      and "open=Open in Preview" in note[0]["argv"] and note[0]["argv"][-2:] == ["Screenshot", "Saved to the Desktop and copied."],
      "the notice shows the picture, and a click or its button opens it in Preview [%r]" % (note[0]["argv"] if note else None))
run = calls("systemd-run")
check(run and run[0]["argv"][-4:] == [os.path.join(fake, "uwsm-app"), "--", "org.grassfield.Preview.desktop", path],
      "a click opens Preview with the picture, as the Dock starts an app [%r]" % (run[0]["argv"] if run else None))

# A second picture the same second: another name, never the first one overwritten.
before = files(desktop)
r, _ = capture("screen")
check(len(files(desktop)) == len(before) + 1 and all(name.fullmatch(f) for f in files(desktop)),
      "another picture never overwrites one: %r" % files(desktop))

# The selection: slurp in the tokens' colours, with the windows of the shown workspaces and the displays as boxes.
r, _ = capture("selection", FAKE_SLURP="10,20 300x200")
slurp = calls("slurp")
check(slurp and slurp[0]["argv"] == ["-b", colours["veil"], "-s", colours["selection"], "-c", colours["border"], "-B", colours["box"],
                                     "-w", str(tokens["borderWidth"]["value"])],
      "the crosshair in Grassfield's colours [%r]" % (slurp[0]["argv"] if slurp else None))
check(slurp and slurp[0]["stdin"].split("\n")[:4] == ["100,50 800x600", "2000,100 600x400", "0,0 1920x1080", "1920,0 1920x1080"],
      "boxes: the shown workspaces' visible windows, then each display's logical rectangle (scale, rotation) [%r]"
      % (slurp[0]["stdin"] if slurp else None))
grim = calls("grim")
check(grim and grim[0]["argv"][:2] == ["-g", "10,20 300x200"], "a drag: that area [%r]" % (grim[0]["argv"] if grim else None))
r, _ = capture("selection", FAKE_SLURP="150,70 0x0")
grim = calls("grim")
check(grim and grim[0]["argv"][:2] == ["-g", "100,50 800x600"], "a click on a window: that window [%r]" % (grim[0]["argv"] if grim else None))
r, _ = capture("selection", FAKE_SLURP="1950,600 1x1")
grim = calls("grim")
check(grim and grim[0]["argv"][:2] == ["-g", "1920,0 1920x1080"], "a click outside every window: the display under it [%r]"
      % (grim[0]["argv"] if grim else None))
r, _ = capture("selection", FAKE_SLURP="5000,5000 1x1")
check(calls("grim") == [], "a click outside every display: nothing")
count = len(files(desktop))
r, _ = capture("selection", FAKE_SLURP="")
check(r.returncode == 0 and calls("grim") == [] and calls("notify-send") == [] and len(files(desktop)) == count,
      "Esc: nothing captured, saved or shown")
r, _ = capture("selection", FAKE_SELECTING="1", FAKE_SLURP="10,20 300x200")
check(r.returncode == 0 and calls("slurp") == [] and calls("grim") == [], "a second press while the crosshair shows cancels it")
r, _ = capture("selection", FAKE_SLURP="garbage")
check(calls("grim") == [] and len(files(desktop)) == count, "an answer of slurp that does not read: nothing")

# Failures leave nothing behind.
r, _ = capture("screen", FAKE_GRIM="fail")
check(r.returncode != 0 and len(files(desktop)) == count and calls("notify-send") == [], "grim failing: no file left, no notice")
r, _ = capture("screen", FAKE_MONITORS="[]")
check(r.returncode != 0 and calls("grim") == [], "no focused display: nothing")
r, _ = capture(None)
check(r.returncode == 2 and calls() == [], "no mode: usage, nothing run")
r, _ = capture("fullscreen")
check(r.returncode == 2 and calls() == [], "Omarchy's mode names are not taken")

# The Desktop: xdg-user-dir's, never the home folder or the root.
other = os.path.join(home, "Bureau")
r, _ = capture("screen", FAKE_DESKTOP=other)
check(len(files(other)) == 1, "xdg-user-dir's Desktop (a French one) [%r]" % files(other))
for bad in (home, "/", "", "relative/dir"):
    count = len(files(desktop))
    r, _ = capture("screen", FAKE_DESKTOP=bad)
    check(len(files(desktop)) == count + 1 and not any(f.endswith(".png") for f in os.listdir(home)),
          "xdg-user-dir answering %r: ~/Desktop" % bad)

# French: the name and the notice.
r, _ = capture("screen", LANG="fr_FR.UTF-8")
fr = [f for f in files(desktop) if f.startswith("Capture")]
note = calls("notify-send")
check(len(fr) == 1 and re.fullmatch(r"Capture d’écran [0-9]{4}-[0-9]{2}-[0-9]{2} à [0-9]{2}\.[0-9]{2}\.[0-9]{2}\.png", fr[0])
      and note and "default=Ouvrir dans la Visionneuse" in note[0]["argv"]
      and note[0]["argv"][-2:] == ["Capture d’écran", "Enregistrée sur le Bureau et copiée."],
      "in French: « Capture d’écran … à … », the notice in French [%r]" % fr)

# No click: no Preview; the notice's own close.
r, _ = capture("screen", FAKE_ANSWER="")
check(calls("systemd-run") == [], "the notice closed without a click: Preview does not open")

sys.exit(1 if failed else 0)
