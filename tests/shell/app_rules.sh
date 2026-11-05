#!/usr/bin/env bash
# ADR-0045 OC-12: config/hypr/grassfield/apps.lua, Omarchy's per-application window rules that hold in the Grassfield session.
#   wiring    core.lua (loaded by session.lua and dev.lua) loads grassfield.apps, after grassfield.privacy, as an optional module
#   ported    evaluated with plain `lua` and a recording `hl`: every rule applied (none refused), named gf-app-*, once each,
#             citing an Omarchy file; and against that file's TEXT (Omarchy's files are read, never run): an o.window call of
#             the cited file has the same match (a string first argument is a class) and gives every effect of the rule, with
#             the same value (an effect may come from the rule of a tag that call adds, as pip.lua does); so nothing is invented
#             or changed. SKIP without lua; the comparison SKIPs without Omarchy's files ($OMARCHY_PATH, else
#             /usr/share/omarchy)
#   narrowed  a rule may narrow Omarchy's match only when it is listed here (NARROWED) and keeps Omarchy's match in
#             `omarchy_match` (the one compared above) with a reason in `narrowed`; the narrowed match constrains every key
#             Omarchy's did. Picture-in-Picture (security review LOW 1): its title and class regexes pin a browser's PiP
#             window ("Picture-in-Picture", "Picture in picture") and never a window that only mentions it ("Picture-in-
#             Picture.png" in Preview, a Files folder), whether Hyprland matches the whole string or searches it
#   kept out  no rule sets an effect ADR-0045 OC-12 leaves out (tiling, workspaces, Omarchy's look, full screen at map,
#             float/center that every window already gets); size and move only for the camera overlay (its corner)
# Hyprland's own acceptance (`Hyprland --verify-config`) is `just check-config`, on the owner's machine.
# Plain shell test: prints PASS/FAIL, exits non-zero on failure.
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
rules=$root/config/hypr/grassfield/apps.lua
fail=0
pass() { echo "PASS: app rules $*"; }
bad() { echo "FAIL: app rules $*"; fail=1; }
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/app-rules.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# --- wiring ---
core=$root/config/hypr/grassfield/core.lua
code=$(grep -v '^ *--' "$core")
if grep -q 'pcall(require, "grassfield.apps")' <<<"$code"; then pass "wiring: core.lua loads grassfield.apps as an optional module"; else bad "wiring: core.lua does not load grassfield.apps"; fi
privacy_line=$(grep -n 'require("grassfield.privacy")' "$core" | cut -d: -f1)
apps_line=$(grep -n '"grassfield.apps"' "$core" | cut -d: -f1)
((privacy_line > 0 && apps_line > privacy_line)) && pass "wiring: after grassfield.privacy" || bad "wiring: order privacy $privacy_line, apps $apps_line"
for s in session dev; do
  grep -q 'require("grassfield.core")' "$root/config/hypr/$s.lua" && pass "wiring: $s.lua loads grassfield.core" || bad "wiring: $s.lua does not load grassfield.core"
done

# --- kept out (text: works without lua) ---
banned='tile|workspace|opacity|rounding|border_size|fullscreen|float|center|tag|no_follow_mouse|no_dim|maximize'
if grep -v '^ *--' "$rules" | grep -Eq "(^ *|[{,] *)($banned) = "; then
  bad "kept out: an effect left out by OC-12 is set: $(grep -v '^ *--' "$rules" | grep -En "(^ *|[{,] *)($banned) = " | head -3)"
else
  pass "kept out: no tiling, workspace, look, full-screen, float, center or tag effect"
fi

if ! command -v lua >/dev/null; then
  echo "SKIP: app rules ported (lua not installed)"
  exit $fail
fi

# --- ported: apply apps.lua with a recording hl ---
# Prints "applied <n>", "failed <n>", then per rule, tab-separated, with Lua literals: the Omarchy file, the name, Omarchy's
# match (`omarchy_match` when the rule narrows it, else its match) as k=v;..., the effects, the reason of a narrowing or "-",
# and the match the rule gives Hyprland.
cat >"$tmp/run.lua" <<'LUA'
local function lit(v)
  if type(v) == "string" then return string.format("%q", v) end
  if type(v) == "table" then
    local parts = {}
    for i, x in ipairs(v) do parts[i] = lit(x) end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return tostring(v)
end
local function pairs_of(t, skip)
  local keys = {}
  for k in pairs(t) do if not skip[k] then keys[#keys + 1] = k end end
  table.sort(keys)
  local out = {}
  for _, k in ipairs(keys) do out[#out + 1] = k .. "=" .. lit(t[k]) end
  return table.concat(out, ";")
end
local applied = {}
hl = { window_rule = function(rule) applied[#applied + 1] = rule end }
local M = dofile(arg[1])
print("applied " .. #applied)
print("failed " .. #M.failed)
for i, e in ipairs(M.rules) do
  local given = applied[i] or {}
  local meta = { source = true, name = true, match = true, omarchy_match = true, omarchy_older_match = true, narrowed = true }
  for k in pairs(meta) do
    if k ~= "name" and k ~= "match" and given[k] ~= nil then error(e.name .. ": " .. k .. " reached Hyprland") end
  end
  print(e.source .. "\t" .. e.name .. "\t" .. pairs_of(e.omarchy_match or e.match, {}) .. "\t" .. pairs_of(e, meta)
    .. "\t" .. (e.narrowed or "-") .. "\t" .. pairs_of(given.match or {}, {}) .. "\t" .. (e.omarchy_older_match and pairs_of(e.omarchy_older_match, {}) or "-"))
end
LUA
out=$(cd "$tmp" && lua "$tmp/run.lua" "$rules" 2>&1)
rc=$?
((rc == 0)) && pass "ported: apps.lua runs" || bad "ported: apps.lua failed: $out"
grep $'\t' <<<"$out" >"$tmp/rules.txt"
n=$(wc -l <"$tmp/rules.txt")
[[ $out == *"applied $n"* && $out == *"failed 0"* && $n -gt 0 ]] && pass "ported: all $n rules applied, none refused" || bad "ported: $out"
dups=$(cut -f2 "$tmp/rules.txt" | sort | uniq -d)
[[ -z $dups ]] && pass "ported: every rule name once" || bad "ported: names used twice: $dups"
grep -vqE $'^[a-z0-9-]+\\.lua\tgf-app-[a-z0-9-]+\t' "$tmp/rules.txt" && bad "ported: a rule without an Omarchy file or a gf-app- name" || pass "ported: every rule cites an Omarchy file and is named gf-app-*"
if [[ -n $(awk -F'\t' '$4 ~ /(^|;)(move|size)=/ && $6 !~ /^class="\^WebcamOverlay-/' "$tmp/rules.txt") ]]; then
  bad "kept out: size or move outside the camera overlay"
else
  pass "kept out: size and move only for the camera overlay"
fi

# --- narrowed: only where listed, every key of Omarchy's match still constrained, and the PiP regexes on sample titles ---
NARROWED="gf-app-pip"
python3 -I - "$tmp/rules.txt" "$NARROWED" <<'PY' && pass "narrowed: only $NARROWED, every Omarchy key kept, PiP pins browsers' PiP windows only" || bad "narrowed: see above"
import ast, re, sys

listing, allowed = sys.argv[1], set(sys.argv[2].split())
bad = 0


def fields(text):
    """k=v;... with Lua %q literals -> {k: str}."""
    out = {}
    for kv in filter(None, text.split(";")):
        k, v = kv.split("=", 1)
        out[k] = ast.literal_eval(v) if v.startswith('"') else v
    return out


for line in open(listing, encoding="utf-8"):
    source, name, omarchy, effects, narrowed, given = line.rstrip("\n").split("\t")[:6]
    o, g = fields(omarchy), fields(given)
    if narrowed == "-":
        if o != g:
            print("  %s: its match differs from Omarchy's without a narrowing" % name)
            bad = 1
        continue
    if name not in allowed:
        print("  %s: narrows Omarchy's match but is not listed in NARROWED" % name)
        bad = 1
    for k in o:
        if k not in g:
            print("  %s: Omarchy's %s is no longer constrained" % (name, k))
            bad = 1
    if name == "gf-app-pip":
        title, cls = re.compile(g.get("title", "")), re.compile(g.get("class", ""))
        for t in ("Picture-in-Picture", "Picture in picture", "Picture in Picture"):
            if not title.fullmatch(t) or not title.search(t):
                print("  gf-app-pip: the title %r is not matched" % t)
                bad = 1
        for t in ("Picture-in-Picture.png", "Picture-in-Picture.png - Preview", "Files - Picture in picture", "Picture-in-Pictures"):
            if title.fullmatch(t) or title.search(t):
                print("  gf-app-pip: the title %r is matched" % t)
                bad = 1
        for c in ("chromium", "google-chrome", "Brave-browser", "firefox", "org.mozilla.firefox", "librewolf", "zen"):
            if not cls.fullmatch(c) or not cls.search(c):
                print("  gf-app-pip: the class %r is not matched" % c)
                bad = 1
        for c in ("org.grassfield.Preview", "org.grassfield.Files", "mpv", "org.mozillaXfirefox", "my-chromium-fork"):
            if cls.fullmatch(c) or cls.search(c):
                print("  gf-app-pip: the class %r is matched" % c)
                bad = 1
sys.exit(bad)
PY

apps=${OMARCHY_PATH:-/usr/share/omarchy}/default/hypr/apps
if [[ ! -d $apps ]]; then
  echo "SKIP: app rules against Omarchy's files ($apps not found)"
  exit $fail
fi
# The oracle reads Omarchy's files as text: their o.window calls, whitespace removed, each with the calls of the tags it adds.
python3 -I - "$apps" "$tmp/rules.txt" <<'PY' && pass "ported: every rule is its Omarchy file's match with that file's effects" || bad "ported: a rule differs from its Omarchy file"
import os, re, sys

apps, listing = sys.argv[1], sys.argv[2]


def calls(text):
    """The o.window(...) calls of a Lua file's text, comments dropped and whitespace removed (strings kept whole)."""
    text = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("--"))
    out, i = [], 0
    while True:
        i = text.find("o.window(", i)
        if i < 0:
            return out
        depth, j, s = 0, i + len("o.window"), None
        while j < len(text):
            c = text[j]
            if s:
                if c == "\\":
                    j += 1
                elif c == s:
                    s = None
            elif c in "\"'":
                s = c
            elif c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        out.append(re.sub(r"\s+", "", text[i:j + 1]))
        i = j


bad = 0
for line in open(listing, encoding="utf-8"):
    fields_ = line.rstrip("\n").split("\t")
    source, name, match, effects = fields_[:4]
    older = fields_[6] if len(fields_) > 6 and fields_[6] != "-" else None
    path = os.path.join(apps, source)
    if not os.path.isfile(path):
        print("  %s: %s is not an Omarchy file" % (name, source))
        bad = 1
        continue
    found = calls(open(path, encoding="utf-8").read())
    def same_match(call, match=match):
        m = [kv.split("=", 1) for kv in match.split(";")]
        keys = {k for k, _ in m}
        if keys == {"class"} and call.startswith("o.window(%s," % re.sub(r"\s+", "", m[0][1])):
            return True
        body = call[len("o.window("):]
        if not body.startswith("{"):
            return False
        first = body[:body.index("}") + 1]
        return all(("%s=%s" % (k, re.sub(r"\s+", "", v))) in first for k, v in m) and first.count("=") == len(m)

    # A rule that follows a change between Omarchy versions (`omarchy_older_match`) is the match of either.
    hits = [c for c in found if same_match(c) or (older and same_match(c, older))]
    if not hits:
        print("  %s: no o.window call of %s has the match %s" % (name, source, match))
        bad = 1
        continue
    allowed = "".join(hits)
    for tag in re.findall(r'tag="\+([^"]+)"', allowed):
        allowed += "".join(c for c in found if c.startswith('o.window({tag="%s"},' % tag))
    for kv in effects.split(";"):
        k, v = kv.split("=", 1)
        if "%s=%s" % (k, re.sub(r"\s+", "", v)) not in allowed:
            print("  %s: %s gives no %s=%s for that match" % (name, source, k, v))
            bad = 1
sys.exit(bad)
PY
exit $fail
