#!/usr/bin/env bash
# Capture defect 1 (words): in the French nested session the widget gallery showed "Clock", "Small/Medium/Large" and the Clock widget
# "octobre 17" in English for the first moments of the Registry singleton and of a placed Clock, while the catalog held them and
# qsTranslate("Registry", ...) in the same call returned the French text (live probe, 2026-10-30). Those two files therefore use
# qsTranslate with their own context instead of qsTr. This check holds them to it (the bug does not show in a headless shell, so no
# behaviour test can see it: the nested pass, tests/visual/flow-capture-defects.sh gallery capture, is the evidence) and checks that
# the catalog has every string under that context.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root" || exit 2
fail=0
check() { if [[ $2 -eq 0 ]]; then echo "PASS widgets_translate_guard: $1"; else echo "FAIL widgets_translate_guard: $1"; fail=1; fi; }
reg=shell/widgets/Registry.qml
clock=shell/widgets/builtin/clock/Clock.qml
! grep -nE '(^|[^A-Za-z.])qsTr\(' "$reg" | grep -v '^\s*[0-9]*:\s*//' | grep -q .; check "Registry.qml has no qsTr (qsTranslate with the context Registry)" $?
! grep -nE '(^|[^A-Za-z.])qsTr\(' "$clock" | grep -v '^\s*[0-9]*:\s*//' | grep -q .; check "Clock.qml has no qsTr (qsTranslate with the context Clock)" $?
ts=translations/grassfield_fr.ts
python3 -I - "$ts" "$reg" "$clock" <<'EOF'
import re, sys, xml.etree.ElementTree as ET
ts, reg, clock = sys.argv[1:4]
root = ET.parse(ts).getroot()
have = {(c.findtext("name"), m.findtext("source")): (m.find("translation").text or "", m.find("translation").get("type"))
        for c in root.findall("context") for m in c.findall("message")}
bad = []
for path, ctx in ((reg, "Registry"), (clock, "Clock")):
    for text in re.findall(r'qsTranslate\("%s",\s*"((?:[^"\\]|\\.)*)"' % ctx, open(path, encoding="utf-8").read()):
        got = have.get((ctx, text))
        if got is None or got[0] == "" or got[1] == "unfinished":
            bad.append((ctx, text))
        if got is not None and got[0] == text and text not in ("MMMM d",):
            pass
if bad:
    print("missing or unfinished:", bad)
    sys.exit(1)
EOF
check "every qsTranslate string of the two files is finished in the French catalog" $?
exit $fail
