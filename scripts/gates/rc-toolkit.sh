#!/usr/bin/env bash
# The rc-channel gate (ADR-0041 step 2c; audit T-5 and T-10; master-prompt section 10 C3): this tree built and run on the
# toolkit of Omarchy's rc channel in a throwaway Arch container, so an incompatibility (Qt, Quickshell, KDE Frameworks,
# Hyprland) is known one Omarchy cycle before it reaches stable. Never on a real machine: inside, it refuses to run unless it
# is root in a container with the repository mounted at /src and the report directory at /out.
#
#   scripts/gates/rc-toolkit.sh [--only lint,test,plugin] [--mirror URL] [--logs DIR]
#   scripts/gates/rc-toolkit.sh --selftest
#     --only STEPS   run only these steps (debugging; the verdict then says "partial")
#     --mirror URL   the channel's Arch mirror (default https://rc-mirror.omarchy.org, Omarchy's mirrorlist-rc at v4.0.4; the
#                    stable mirror, https://stable-mirror.omarchy.org, gives a stable-channel run)
#     --logs DIR     where the report goes (default .dev/rc-toolkit/<timestamp>/)
#     --selftest     the pure parts (the dependency reader, the moved-package table, the verdict, the record) on fixed
#                    samples; no container
#
# Runs `docker run --rm --network host` on archlinux:base (digest pinned below, the one of tests/integration) with the
# repository mounted read-only; HTTPS_PROXY/HTTP_PROXY/NO_PROXY are passed through and GRASSFIELD_TEST_CA, when set, is
# mounted as the container's CA bundle. Inside: pacman's mirrorlist names the channel's mirror only and `pacman -Syuu`
# brings the whole base to that snapshot (downgrades allowed: the image may be newer than the snapshot), then the PKGBUILD's
# makedepends and the desktop package's depends (what an rc machine runs) are installed from it. A `git archive HEAD` of the
# repository (uncommitted changes are not in it, and are reported) runs as an unprivileged user:
#   lint    scripts/dev/qmllint.sh: the tree's QML against the installed Quickshell's qmltypes (T-10; gate Q1 on rc)
#   test    scripts/dev/test.sh --layer data,logic,headless: the offscreen suites on the rc Quickshell, Qt and KDE Frameworks
#           (T-5); among them tests/shell/hypr_socket_errors.sh, incident I-1's error paths on that Quickshell
#   plugin  the compositor plugin and its unit tests built with CMake/Ninja against the rc Hyprland headers (C3)
# Report (the logs directory): setup.log, <step>.log, result.tsv, toolkit.txt (pacman -Q of the toolkit in the container),
# snapshot.txt (the mirror and its database's date), stable.txt (the same packages on this machine, when pacman knows them)
# and summary.json, the record a watch job reads (ADR-0033 f: the rc toolkit, what moved against this machine, each step's
# result, the verdict). Exit: 0 PASS (every step passed), 1 FAIL (a step failed), 2 INCONCLUSIVE (no docker, the setup
# failed, a step did not run; never a pass) or usage error. Bare command: needs the docker daemon.
set -uo pipefail

IMAGE=archlinux:base@sha256:52dfbd5afb23a220d5ee92dafcb4c788d96c026ed04179890c23adef4c897fa0
MIRROR_DEFAULT=https://rc-mirror.omarchy.org
# The packages the record names: BUILD-DEPS's five (ADR-0033 s3.4: what the compatibility check tracks) and the ones the
# shell's QML and the plugin's ABI depend on besides.
TOOLKIT=(qt6-base qt6-declarative quickshell hyprland aquamarine hyprutils hyprlang kcoreaddons kio)
STEPS=(lint test plugin)

# --- the pure parts (tested by --selftest, run by tests/shell/gates.sh) ---------------------------------------------------

# The packages the container installs: the PKGBUILD's global makedepends and the depends of package_grassfield-desktop(),
# version constraints stripped, Grassfield's own packages left out (they are built from this tree), sorted and unique.
rc_deps() { # <PKGBUILD>
  python3 -I - "$1" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()

def array(body):
    names = []
    for line in body.splitlines():
        line = line.split("#", 1)[0]
        for word in line.split():
            word = word.strip("'\"")
            name = re.split(r"[<>=]", word, maxsplit=1)[0].strip("'\"")
            if name and not name.startswith("grassfield-") and "$" not in name:
                names.append(name)
    return names

def arrays(scope, key):
    return [array(m.group(1)) for m in re.finditer(r"^\s*%s=\((.*?)\)" % key, scope, re.S | re.M)]

# The global scope is everything before the first function; the desktop package is its function's body.
first_function = re.search(r"^[A-Za-z_][A-Za-z0-9_-]*\(\)\s*\{", text, re.M)
global_scope = text[:first_function.start()] if first_function else text
desktop = re.search(r"^package_grassfield-desktop\(\)\s*\{(.*?)^\}", text, re.S | re.M)
names = set()
for found in arrays(global_scope, "makedepends"):
    names.update(found)
if desktop:
    for found in arrays(desktop.group(1), "depends"):
        names.update(found)
print("\n".join(sorted(names)))
PY
}

# The toolkit packages whose version in the container differs from this machine's: "<name> <stable> -> <rc>" per line,
# nothing when this machine's list is empty (no pacman, or the packages are not installed here).
rc_moved() { # <toolkit.txt (name version per line)> <stable.txt (the same)>
  awk 'NR == FNR { stable[$1] = $2; next } ($1 in stable) && stable[$1] != $2 { print $1, stable[$1], "->", $2 }' "$2" "$1"
}

# The verdict from result.tsv (step, result, seconds, note; tab-separated) for the steps that were wanted: PASS when every
# one passed, FAIL when one failed, INCONCLUSIVE when one is missing. Prints the word; exit 0, 1 or 2.
rc_verdict() { # <result.tsv> <wanted steps, comma-separated>
  local tsv=$1 wanted=$2 step result verdict=PASS
  IFS=, read -r -a steps <<<"$wanted"
  for step in "${steps[@]}"; do
    result=$(awk -F'\t' -v s="$step" '$1 == s { print $2 }' "$tsv" 2>/dev/null | tail -n 1)
    if [[ -z $result ]]; then verdict=INCONCLUSIVE; elif [[ $result != PASS && $verdict != INCONCLUSIVE ]]; then verdict=FAIL; fi
  done
  echo "$verdict"
  case $verdict in PASS) return 0 ;; FAIL) return 1 ;; *) return 2 ;; esac
}

# summary.json: the record of a run (ADR-0033 f's watch job reads it: the rc toolkit, what moved, the steps, the verdict).
rc_summary() { # <logs dir> <commit> <mirror> <wanted steps> <verdict> [uncommitted paths]
  python3 -I - "$@" <<'PY'
import json, os, sys
logs, commit, mirror, wanted, verdict = sys.argv[1:6]
dirty = int(sys.argv[6]) if len(sys.argv) > 6 else 0

def pairs(name):
    path = os.path.join(logs, name)
    if not os.path.exists(path):
        return {}
    out = {}
    for line in open(path, encoding="utf-8", errors="replace"):
        parts = line.split()
        if len(parts) >= 2:
            out[parts[0]] = parts[1]
    return out

toolkit, stable = pairs("toolkit.txt"), pairs("stable.txt")
steps = {}
path = os.path.join(logs, "result.tsv")
if os.path.exists(path):
    for line in open(path, encoding="utf-8", errors="replace"):
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 3:
            steps[parts[0]] = {"result": parts[1], "seconds": int(parts[2]) if parts[2].isdigit() else None, "note": parts[3] if len(parts) > 3 else ""}
snapshot = ""
path = os.path.join(logs, "snapshot.txt")
if os.path.exists(path):
    snapshot = open(path, encoding="utf-8", errors="replace").read().strip()
record = {
    "v": 1,
    "commit": commit,
    "uncommitted_paths": dirty,
    "mirror": mirror,
    "snapshot": snapshot,
    "toolkit": toolkit,
    "stable": stable,
    "moved": {name: {"stable": stable[name], "rc": toolkit[name]} for name in sorted(toolkit) if name in stable and stable[name] != toolkit[name]},
    "steps_wanted": wanted.split(","),
    "steps": steps,
    "verdict": verdict,
}
with open(os.path.join(logs, "summary.json"), "w", encoding="utf-8") as f:
    json.dump(record, f, indent=1, sort_keys=True)
    f.write("\n")
PY
}

selftest() {
  local work fails=0
  work=$(mktemp -d)
  trap 'rm -rf "$work"' RETURN
  expect() { # <name> <got> <want>
    if [[ $2 == "$3" ]]; then echo "  ok   $1"; else echo "  FAIL $1: got '$2', want '$3'"; fails=$((fails + 1)); fi
  }
  cat >"$work/PKGBUILD" <<'EOF'
pkgname=(grassfield-desktop grassfield-store)
makedepends=(cmake ninja  # a tool the plugin needs
             'quickshell>=0.3' hyprland "qt6-declarative")
options=(!debug)
package_grassfield-desktop() {
  depends=(hyprland quickshell qt6-svg grassfield-icons "grassfield-keyring>=1" python
           inter-font)
  conflicts=('quickshell=0.3.2')
  optdepends=('brightnessctl: the OSD')
}
package_grassfield-store() {
  depends=(flatpak "grassfield-desktop=$pkgver-$pkgrel")
}
EOF
  expect "the dependency reader: makedepends and the desktop's depends, constraints off, grassfield-* and other packages out" \
    "$(rc_deps "$work/PKGBUILD" | paste -sd' ' -)" "cmake hyprland inter-font ninja python qt6-declarative qt6-svg quickshell"
  printf 'qt6-base 6.12.0-1\nquickshell 0.3.2-1\nhyprland 0.56.2-4\nkio 6.31.0-1\n' >"$work/toolkit.txt"
  printf 'qt6-base 6.11.2-1\nquickshell 0.3.2-1\nhyprland 0.56.2-2\n' >"$work/stable.txt"
  expect "moved: the packages both lists have at different versions" "$(rc_moved "$work/toolkit.txt" "$work/stable.txt" | paste -sd';' -)" \
    "qt6-base 6.11.2-1 -> 6.12.0-1;hyprland 0.56.2-2 -> 0.56.2-4"
  : >"$work/empty.txt"
  expect "moved: nothing against an empty list" "$(rc_moved "$work/toolkit.txt" "$work/empty.txt")" ""
  printf 'lint\tPASS\t30\t200 files, 0 warnings\ntest\tPASS\t600\tno check skipped\nplugin\tPASS\t90\tabi x\n' >"$work/all.tsv"
  verdict_of() { local v; v=$(rc_verdict "$@"); printf '%s %s' "$v" "$?"; }
  expect "verdict: every wanted step passed" "$(verdict_of "$work/all.tsv" lint,test,plugin)" "PASS 0"
  printf 'lint\tPASS\t30\t\ntest\tFAIL(1)\t600\t\nplugin\tPASS\t90\t\n' >"$work/one.tsv"
  expect "verdict: one step failed" "$(verdict_of "$work/one.tsv" lint,test,plugin)" "FAIL 1"
  printf 'lint\tPASS\t30\t\n' >"$work/partial.tsv"
  expect "verdict: a wanted step that did not run is inconclusive" "$(verdict_of "$work/partial.tsv" lint,test,plugin)" "INCONCLUSIVE 2"
  expect "verdict: --only lint with lint passed" "$(verdict_of "$work/partial.tsv" lint)" "PASS 0"
  expect "verdict: a failed step beside a missing one stays inconclusive (nothing was proven)" \
    "$(printf 'lint\tFAIL(1)\t3\t\n' >"$work/fm.tsv"; verdict_of "$work/fm.tsv" lint,test)" "INCONCLUSIVE 2"
  cp "$work/all.tsv" "$work/result.tsv"
  echo "https://rc-mirror.omarchy.org extra.db of Sat, 01 Nov 2026 00:00:00 GMT" >"$work/snapshot.txt"
  rc_summary "$work" abc123 https://rc-mirror.omarchy.org lint,test,plugin PASS 2
  expect "the record: valid JSON with the moved packages and the verdict" \
    "$(python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r["verdict"], sorted(r["moved"]), r["steps"]["test"]["seconds"], r["uncommitted_paths"], r["toolkit"]["kio"])' "$work/summary.json")" \
    "PASS ['hyprland', 'qt6-base'] 600 2 6.31.0-1"
  if ((fails == 0)); then echo "rc-toolkit selftest: PASS (10 cases)"; else echo "rc-toolkit selftest: FAIL ($fails)"; fi
  return $((fails > 0))
}

# --- inside the container ---------------------------------------------------------------------------------------------------

inside() { # <mirror> <wanted steps>
  local mirror=$1 wanted=$2
  [[ -f /.dockerenv && $(id -u) == 0 && -f /src/packaging/arch/PKGBUILD && -d /out ]] ||
    { echo "refused: runs only as root inside a throwaway container (/src, /out)"; exit 2; }
  local log=/out/setup.log t0 rc step name
  : >"$log"
  quiet() { "$@" >>"$log" 2>&1; }
  setup_fail() { echo "rc-toolkit: setup failed: $1 (see setup.log)"; tail -n 15 "$log"; exit 2; }
  want() { [[ ",$wanted," == *",$1,"* ]]; }

  echo "rc-toolkit: the channel's snapshot ($mirror)"
  sed -i 's/^#\?DisableSandbox.*//; /^\[options\]/a DisableSandbox' /etc/pacman.conf
  printf 'Server = %s/$repo/os/$arch\n' "$mirror" >/etc/pacman.d/mirrorlist
  quiet pacman-key --init && quiet pacman-key --populate archlinux || setup_fail "pacman-key"
  # The whole base to the snapshot: an rc machine's package set, the image's newer packages brought down to it.
  quiet pacman -Syuu --noconfirm || setup_fail "pacman -Syuu from $mirror"
  { printf '%s extra.db of ' "$mirror"; curl -fsSI "$mirror/extra/os/x86_64/extra.db" 2>/dev/null | awk 'tolower($1) == "last-modified:" { $1 = ""; sub(/^ /, ""); print; found = 1 } END { if (!found) print "unknown date" }' | tr -d '\r'; } >/out/snapshot.txt
  cat /out/snapshot.txt

  echo "rc-toolkit: the toolkit and the build tools"
  mapfile -t deps < <(rc_deps /src/packaging/arch/PKGBUILD)
  ((${#deps[@]} > 0)) || setup_fail "no dependency read from the PKGBUILD"
  # Besides the PKGBUILD's: the suites' private buses and PyGObject fakes, a font for offscreen text, the portal frontend the
  # file chooser test drives, git for the snapshot, jq for the gate tooling, gcc for the direct builds and their sanitizers.
  quiet pacman -S --needed --noconfirm "${deps[@]}" git jq python python-gobject dbus gcc xdg-desktop-portal ttf-dejavu ||
    setup_fail "pacman -S of the toolkit"
  pacman -Q "${TOOLKIT[@]}" 2>/dev/null >/out/toolkit.txt
  # The lint's reference (T-10): how many qmltypes of this Quickshell the lint sees.
  echo "quickshell-qmltypes $(find /usr/lib/qt6/qml/Quickshell -name '*.qmltypes' 2>/dev/null | wc -l)" >>/out/toolkit.txt
  sed 's/^/  /' /out/toolkit.txt

  echo "rc-toolkit: the snapshot of HEAD, as an unprivileged user"
  useradd -m builder || setup_fail "useradd"
  mkdir -p /work/src && git -C /src archive --format=tar HEAD | tar -x -C /work/src || setup_fail "git archive"
  chown -R builder:builder /work
  as_builder() { runuser -u builder -- env HOME=/home/builder PATH=/usr/bin:/usr/local/bin "$@"; }
  (cd /work/src && as_builder git init -q -b main && as_builder git add -A &&
    as_builder git -c user.name=rc-toolkit -c user.email=rc-toolkit@localhost commit -q -m "snapshot") >>"$log" 2>&1 || setup_fail "git init of the snapshot"

  : >/out/result.tsv
  run_step() { # <name> <command...>: as builder, in the snapshot, logged to /out/<name>.log; result.tsv gets one line
    name=$1
    shift
    want "$name" || return 0
    echo "rc-toolkit: [$name] running..."
    t0=$(date +%s)
    (cd /work/src && as_builder "$@") >"/out/$name.log" 2>&1
    rc=$?
    local note
    note=$(note_of "$name")
    printf '%s\t%s\t%s\t%s\n' "$name" "$([[ $rc == 0 ]] && echo PASS || echo "FAIL($rc)")" "$(($(date +%s) - t0))" "$note" >>/out/result.tsv
    echo "rc-toolkit: [$name] $([[ $rc == 0 ]] && echo PASS || echo "FAIL($rc)") ($note)"
  }
  note_of() {
    case $1 in
      lint) grep -a -E '^qmllint: [0-9]+ files' "/out/lint.log" | tail -n 1 ;;
      test) grep -a -E '^summary: ' "/out/test.log" | tail -n 1 ;;
      plugin) { cat /work/src/compositor/build/grassfield-compositor.abi 2>/dev/null | tr -d '\n'; printf ' '; grep -a -E '^\[  (PASSED|FAILED)  \]' "/out/plugin.log" | head -n 1 | sed 's/\[ *//; s/ *\]//'; } ;;
    esac | tr '\t' ' '
  }
  run_step lint scripts/dev/qmllint.sh
  run_step test scripts/dev/test.sh --layer data,logic,headless
  run_step plugin sh -c 'cmake -S compositor -B compositor/build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo && cmake --build compositor/build && compositor/build/grassfield-compositor-tests --gtest_brief=1'
  chmod -R a+rX /out 2>/dev/null
  exit 0
}

# --- outside ---------------------------------------------------------------------------------------------------------------

mirror=$MIRROR_DEFAULT only="" logs="" mode=run
while (($#)); do
  case $1 in
    --only) shift; only=$1 ;;
    --mirror) shift; mirror=$1 ;;
    --logs) shift; logs=$1 ;;
    --selftest) mode=selftest ;;
    --inside) mode=inside ;;
    -h | --help) sed -n '2,/^set -uo/p' "$0" | sed '$d;s/^# \{0,1\}//'; exit 0 ;;
    *) echo "rc-toolkit: unknown argument $1 (--help)" >&2; exit 2 ;;
  esac
  shift
done
wanted=${only:-$(IFS=,; echo "${STEPS[*]}")}
for s in ${wanted//,/ }; do
  [[ " ${STEPS[*]} " == *" $s "* ]] || { echo "rc-toolkit: unknown step '$s' (${STEPS[*]})" >&2; exit 2; }
done
case $mode in
  selftest) selftest; exit $? ;;
  inside) inside "$mirror" "$wanted" ;;
esac

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel) || exit 2
command -v docker >/dev/null && docker info >/dev/null 2>&1 ||
  { echo "rc-toolkit: INCONCLUSIVE: no docker daemon (this gate runs only in a throwaway container)"; exit 2; }
commit=$(git -C "$root" rev-parse HEAD)
dirty=$(git -C "$root" status --porcelain | wc -l)
[[ -n $logs ]] || logs=$root/.dev/rc-toolkit/$(date +%Y%m%d-%H%M%S)
mkdir -p "$logs" || exit 2
logs=$(realpath "$logs")
# This machine's toolkit, when pacman knows these packages (an Omarchy machine): what the rc run is compared with.
pacman -Q "${TOOLKIT[@]}" 2>/dev/null >"$logs/stable.txt" || true
echo "rc-toolkit: commit $commit ($dirty uncommitted path(s) are NOT in the snapshot); mirror $mirror; steps $wanted; report in $logs"
args=(--rm --network host -v "$root:/src:ro" -v "$logs:/out")
[[ -n ${GRASSFIELD_TEST_CA:-} ]] && args+=(-v "$(realpath "$GRASSFIELD_TEST_CA"):/etc/ssl/certs/ca-certificates.crt:ro")
for v in HTTPS_PROXY https_proxy HTTP_PROXY http_proxy NO_PROXY no_proxy; do [[ -n ${!v:-} ]] && args+=(-e "$v"); done
docker run "${args[@]}" "$IMAGE" bash /src/scripts/gates/rc-toolkit.sh --inside --mirror "$mirror" --only "$wanted"
container_rc=$?

echo
printf '%-8s %-9s %6s  %s\n' step result sec note
while IFS=$'\t' read -r step result secs note; do
  printf '%-8s %-9s %6s  %s\n' "$step" "$result" "$secs" "$note"
done <"$logs/result.tsv" 2>/dev/null
echo "toolkit ($(cat "$logs/snapshot.txt" 2>/dev/null || echo "snapshot unknown")):"
sed 's/^/  /' "$logs/toolkit.txt" 2>/dev/null
if [[ -s $logs/stable.txt ]]; then
  moved=$(rc_moved "$logs/toolkit.txt" "$logs/stable.txt")
  echo "moved against this machine: ${moved:+$'\n'}${moved:-nothing (the same versions)}"
else
  echo "moved against this machine: not compared (pacman does not know these packages here)"
fi
verdict=$(rc_verdict "$logs/result.tsv" "$wanted")
rc_summary "$logs" "$commit" "$mirror" "$wanted" "$verdict" "$dirty"
echo "report: $logs (summary.json for the watch job)"
case $verdict in
  PASS) echo "rc-toolkit: PASS${only:+ (partial: only $only)}"; exit 0 ;;
  FAIL) echo "rc-toolkit: FAIL (see the step logs in $logs)"; exit 1 ;;
  *) echo "rc-toolkit: INCONCLUSIVE (container exit $container_rc; a wanted step has no result: setup.log in $logs)"; exit 2 ;;
esac
