#!/usr/bin/env bash
# Mutation check of tests/unit/tst_dockfeel.qml (headless Dock feel). Copies Magnify.js, AutoHide.js and the test into a
# temporary tree, breaks the scripts on purpose (one mutant at a time) and requires the test to FAIL for each one; the
# unmodified copy must pass. Offscreen, no compositor. Plain shell test: prints a mutant table, PASS/FAIL, exits non-zero on failure.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
unset QT_QPA_PLATFORMTHEME DISPLAY WAYLAND_DISPLAY
mkdir -p "$root/.dev"
tmp=$(mktemp -d "$root/.dev/dockfeel-mutants.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
export QML_XHR_ALLOW_FILE_READ=1 QT_QPA_PLATFORM=offscreen

python3 -I - "$root" "$tmp" /usr/lib/qt6/bin/qmltestrunner <<'PY'
import os, shutil, subprocess, sys

root, tmp, runner = sys.argv[1:4]
MAG = "shell/dock/Magnify.js"
AUTO = "shell/dock/AutoHide.js"
SLOT_OLD = "out.push(meanScale(centers[i] - half - pointerX, centers[i] + half - pointerX, pitch, max, radiusIcons));"
SLOT_MEAN = "meanScale(centers[i] - half - pointerX, centers[i] + half - pointerX, pitch, max, radiusIcons)"
# (name, file, old text, new text)
MUTANTS = [
    ("cosine-falloff", MAG, "return 1 - x * x * x * (x * (x * 6 - 15) + 10);", "return (Math.cos(Math.PI * x) + 1) / 2;"),
    ("unclamped-dt", MAG, "Math.min(Math.max(dt, 0), maxDt)", "Math.max(dt, 0)"),
    ("slow-tau", MAG, "/ tau);", "/ (tau * 8));"),
    ("frame-based-alpha", MAG, "1 - Math.exp(-Math.min(Math.max(dt, 0), maxDt) / tau)", "0.4"),
    ("scale-stairs", MAG, SLOT_OLD, "out.push(Math.round(" + SLOT_MEAN + " * 10) / 10);"),
    ("overlap", MAG, "(scalesList[i] !== undefined ? scalesList[i] : 1) + spacing;", "(scalesList[i] !== undefined ? scalesList[i] : 1);"),
    ("overshoot-gain", MAG, "out.push(c + (target[i] - c) * k);", "out.push(c + (target[i] - c) * k * 2.5);"),
    ("dead-band", MAG, "out.push(c + (target[i] - c) * k);", "out.push(Math.abs(target[i] - c) < 0.03 ? c : c + (target[i] - c) * k);"),
    ("sampled-not-integrated", MAG, SLOT_OLD, "out.push(scale(centers[i] - pointerX, pitch, max, radiusIcons));"),
    ("ignore-drag", AUTO, "inh.pointer || inh.drag ||", "inh.pointer ||"),
    ("ignore-hold", AUTO, "inh.popup || inh.hold ||", "inh.popup ||"),
    ("ignore-popup", AUTO, "inh.drag || inh.popup ||", "inh.drag ||"),
    ("hiding-ignores-inhibitor", AUTO, 'case "hiding":\n        if (busy) {', 'case "hiding":\n        if (false) {'),
    ("no-grace", AUTO, "if (out.timer >= timing.hideGrace) {", "if (true) {"),
    ("grace-not-reset", AUTO, "if (busy) {\n            out.timer = 0;\n        } else {\n            out.timer = m.timer + dt;", "if (busy) {\n            out.timer = m.timer;\n        } else {\n            out.timer = m.timer + dt;"),
    ("edge-never-reveals", AUTO, "} else if (inh.pointer) {", "} else if (false) {"),
    ("no-dwell", AUTO, "if (out.timer >= timing.revealDwell) {", "if (true) {"),
    ("popup-no-reveal", AUTO, "if (forcing(inh)) {", "if (false) {"),
    ("reversal-jump", AUTO, 'case "hiding":\n        if (busy) {\n            out.state = "revealing";', 'case "hiding":\n        if (busy) {\n            out.visible = 0;\n            out.state = "revealing";'),
    ("disabled-stays-hidden", AUTO, "if (!enabled) {", "if (false) {"),
    ("clock-stops-hidden", AUTO, 'if (m.state === "hidden")\n        return inhibited(inh);', 'if (m.state === "hidden")\n        return false;'),
]

def run(dirname):
    p = subprocess.run([runner, "-import", os.path.join(root, "ui"), "-input", os.path.join(dirname, "tests/unit/tst_dockfeel.qml")],
                       capture_output=True, text=True, cwd=dirname, timeout=120)
    out = p.stdout + p.stderr
    failed = sorted({line.split("(")[0].split("::")[-1].strip() for line in out.splitlines() if line.startswith("FAIL!")})
    return p.returncode, out, failed

def tree(name):
    d = os.path.join(tmp, name)
    os.makedirs(os.path.join(d, "shell/dock"))
    os.makedirs(os.path.join(d, "tests/unit"))
    for f in (MAG, AUTO):
        shutil.copy(os.path.join(root, f), os.path.join(d, f))
    shutil.copy(os.path.join(root, "tests/unit/tst_dockfeel.qml"), os.path.join(d, "tests/unit/tst_dockfeel.qml"))
    return d

rc, out, failed = run(tree("baseline"))
if rc != 0:
    print(out)
    print("FAIL: tests/shell/dockfeel_mutants.sh (the unmodified copy does not pass)")
    sys.exit(1)
print("baseline: pass")
print("%-26s %-9s %s" % ("mutant", "result", "failing assertions (first 3)"))
survived = []
for name, f, old, new in MUTANTS:
    d = tree(name)
    path = os.path.join(d, f)
    text = open(path).read()
    if old not in text:
        print("FAIL: mutant %s does not apply: %s" % (name, old))
        sys.exit(1)
    open(path, "w").write(text.replace(old, new, 1))
    rc, out, failed = run(d)
    killed = rc != 0
    if not killed:
        survived.append(name)
    print("%-26s %-9s %s" % (name, "killed" if killed else "SURVIVED", ", ".join(x.replace("DockFeel::", "") for x in failed[:3])))
if survived:
    print("FAIL: tests/shell/dockfeel_mutants.sh (survived: %s)" % ", ".join(survived))
    sys.exit(1)
print("dockfeel-mutants: PASS (%d mutants killed)" % len(MUTANTS))
PY
