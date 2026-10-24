#!/usr/bin/env bash
# The Quick Settings slider IPC hooks (controlcenter volume, brightness, volumeLevel, brightnessLevel) read and test the
# REAL device (Audio.deviceReady / deviceVolume, Brightness.deviceAvailable / deviceLevel), never the visual-fixture values of
# Audio.ready / volume / muted or Brightness.available / level (a fixture session answered a fixed 0.50).
#
# Structural check of the controlcenter IpcHandler: after comments are dropped and `?.`, spaces and line breaks around a
# dot are normalised, EVERY use of the identifiers Audio and Brightness must be `Audio.<allowed member>` or
# `Brightness.<allowed member>`. So `Audio?.muted`, `Audio?.["muted"]`, `Audio .muted`, `Audio\n.muted`, `Audio["volume"]`
# and aliasing (`const a = Audio; a.muted`) all fail, and the real-device members must be used.
#   ipc_real_values.sh [MenuBar.qml]      (the file defaults to shell/menubar/MenuBar.qml)
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
file=${1:-$root/shell/menubar/MenuBar.qml}
exec python3 -I - "$file" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
start = text.find('target: "controlcenter"')
if start < 0:
    print("FAIL: no controlcenter IpcHandler in the file")
    sys.exit(1)
# The handler ends at the closing brace at four spaces of indent.
end = re.search(r"^    }$", text[start:], re.M)
block = text[start:start + end.end()] if end else text[start:]
block = re.sub(r"/\*.*?\*/", "", block, flags=re.S)
block = re.sub(r"//[^\n]*", "", block)
# `?.`, and blanks or line breaks around a dot, become a plain dot.
block = re.sub(r"\s*\?\.\s*", ".", block)
block = re.sub(r"\s*\.\s*", ".", block)

ALLOWED = {
    "Audio": {"deviceReady", "deviceVolume", "setVolume"},
    "Brightness": {"deviceAvailable", "deviceLevel", "setLevel"},
}
fail = False
used = {name: set() for name in ALLOWED}
for m in re.finditer(r"\b(Audio|Brightness)\b(\.[A-Za-z_]\w*)?", block):
    name, member = m.group(1), m.group(2)
    if member is None:
        print("FAIL: %s is used without a member (alias, bracket access or a bare reference): ...%s..." % (name, block[max(0, m.start() - 20):m.end() + 20].replace("\n", " ")))
        fail = True
        continue
    member = member[1:]
    if member not in ALLOWED[name]:
        print("FAIL: %s.%s is not a real-device member (fixture-backed or unknown)" % (name, member))
        fail = True
    else:
        used[name].add(member)
for name, members in ALLOWED.items():
    for member in sorted(members - {"setVolume", "setLevel"}):
        if member not in used[name]:
            print("FAIL: the controlcenter IPC hooks do not use %s.%s" % (name, member))
            fail = True
if fail:
    sys.exit(1)
print("PASS: the slider IPC hooks read the real device values")
PY
