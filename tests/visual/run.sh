#!/usr/bin/env bash
# Visual regression runner (master-prompt §11 item 3; spec: docs/testing/visual.md).
# Reference machine only; the nested session must be startable (run as a BARE command).
#
#   tests/visual/run.sh                     run every scenario in en and fr, compare with tests/visual/baselines/
#   tests/visual/run.sh --update            write CANDIDATE baselines to .dev/visual/candidates/ (never the repo)
#   tests/visual/run.sh --determinism       run everything twice and require byte-identical-within-fuzz-0 shots
#   tests/visual/run.sh --only menubar,dock --lang en --keep
#
# Baselines (tests/visual/baselines/<scenario>.<lang>.png) are approved by the owner (gate F1): the owner
# reviews .dev/visual/candidates/ and copies the accepted files over. This script never writes them.
# Exit status: 0 all within threshold, 1 regression / missing baseline / scenario failure, 2 usage.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out=$root/.dev/visual
update=0 determinism=0 keep=0 langs="en fr" only=""
# Perceptual threshold: a pixel counts as different when a channel differs by more than 2% (-fuzz 2%,
# absorbs antialiasing/hinting noise); a scenario regresses when more than MAX_AE_PPM parts per million of
# the 2073600 pixels differ (default 500 ppm = 1037 px, about one 32x32 patch).
max_ppm=${VISUAL_MAX_PPM:-500}

while [[ $# -gt 0 ]]; do
  case $1 in
    --update) update=1 ;;
    --determinism) determinism=1 ;;
    --keep) keep=1 ;;
    --lang) langs=${2:?--lang needs en|fr|both}; [[ $langs == both ]] && langs="en fr"; shift ;;
    --only) only=${2:?--only needs a comma list}; shift ;;
    -h|--help) sed -n 2,14p "$0"; exit 0 ;;
    *) echo "visual: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

command -v compare >/dev/null && command -v magick >/dev/null || { echo "visual: ImageMagick missing" >&2; exit 2; }
[[ $(fc-list : family) == *Inter* ]] || echo "visual: WARNING Inter font not installed; screenshots will not match the reference machine" >&2

scenarios=()
for f in "$here"/scenarios/*.sh; do
  n=$(basename "$f" .sh)
  [[ $n == lock ]] && continue
  [[ -z $only || ,$only, == *,$n,* ]] && scenarios+=("$n")
done
# lock last: it tears the nested session down (a locked nested session cannot be unlocked without a password).
[[ -z $only || ,$only, == *,lock,* ]] && scenarios+=(lock)

mkdir -p "$out"

# run_all DIR: every scenario x language, shots into DIR as <name>.<lang>.png. Returns the number of failed scenarios.
run_all() {
  local dir=$1 lang n failed=0
  rm -rf "$dir"; mkdir -p "$dir"
  for lang in $langs; do
    for n in "${scenarios[@]}"; do
      if ! VISUAL_LANG=$lang VISUAL_SHOTS=$dir "$here/scenarios/$n.sh" >"$out/log-$n.$lang.txt" 2>&1; then
        echo "FAIL  scenario $n ($lang): see .dev/visual/log-$n.$lang.txt" >&2
        failed=$((failed + 1))
      fi
    done
    # Fresh shell per language (a lock scenario already tore the session down).
    if [[ -f $root/.dev/nested.pid ]] && kill -0 "$(<"$root/.dev/nested.pid")" 2>/dev/null; then
      "$root/scripts/dev/nested-down.sh" >/dev/null 2>&1 || true
      rm -f "$out/session.lang"
    fi
  done
  return "$failed"
}

# compare_pair A B DIFF: prints the differing pixel count (fuzz 2%) to stdout.
ae() {
  local fuzz=$1 a=$2 b=$3 diff=$4 n
  n=$(compare -metric AE -fuzz "$fuzz" "$a" "$b" "$diff" 2>&1 >/dev/null | awk '$1 ~ /^[0-9.e+-]+$/ {printf "%d", $1 + 0.5}')
  [[ $n =~ ^[0-9]+$ ]] && echo "$n" || echo "-1"
}

status=0
shots=$out/shots

if (( determinism )); then
  run_all "$out/run1" || status=1
  run_all "$out/run2" || status=1
  mkdir -p "$out/diffs"
  printf '%-34s %12s %12s\n' "shot" "AE fuzz 0" "AE fuzz 2%"
  for f in "$out"/run1/*.png; do
    b=$(basename "$f")
    [[ -f $out/run2/$b ]] || { echo "MISSING $b in run2"; status=1; continue; }
    n0=$(ae 0% "$f" "$out/run2/$b" "$out/diffs/determinism-$b")
    n=$(ae 2% "$f" "$out/run2/$b" "$out/diffs/determinism-$b")
    printf '%-34s %12s %12s\n' "$b" "$n0" "$n"
    (( n <= ${VISUAL_DET_MAX_PX:-50} )) || status=1
  done
  (( status == 0 )) && echo "DETERMINISM PASS" || echo "DETERMINISM FAIL"
  (( keep )) || "$root/scripts/dev/nested-down.sh" >/dev/null 2>&1 || true
  exit "$status"
fi

run_all "$shots" || status=1
(( keep )) || "$root/scripts/dev/nested-down.sh" >/dev/null 2>&1 || true

if (( update )); then
  rm -rf "$out/candidates"; mkdir -p "$out/candidates"
  cp "$shots"/*.png "$out/candidates/"
  echo "Candidates written to .dev/visual/candidates/ ($(ls "$out/candidates" | wc -l) files)."
  echo "Owner approval (F1): review them, then copy the accepted ones into tests/visual/baselines/ and commit."
  exit "$status"
fi

mkdir -p "$out/diffs"
total=2073600
printf '%-30s %10s %8s  %s\n' "shot" "diff px" "ppm" "result"
for f in "$shots"/*.png; do
  b=$(basename "$f")
  base=$here/baselines/$b
  if [[ ! -f $base ]]; then
    printf '%-30s %10s %8s  %s\n' "$b" "-" "-" "FAIL (no approved baseline)"
    status=1
    continue
  fi
  n=$(ae 2% "$base" "$f" "$out/diffs/$b")
  if [[ $n == -1 ]]; then
    printf '%-30s %10s %8s  %s\n' "$b" "?" "?" "FAIL (size mismatch or compare error)"
    status=1
    continue
  fi
  ppm=$(( n * 1000000 / total ))
  if (( ppm > max_ppm )); then
    printf '%-30s %10s %8s  %s\n' "$b" "$n" "$ppm" "FAIL (diff: .dev/visual/diffs/$b)"
    status=1
  else
    printf '%-30s %10s %8s  %s\n' "$b" "$n" "$ppm" "ok"
    rm -f "$out/diffs/$b"
  fi
done
exit "$status"
