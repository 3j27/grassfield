#!/usr/bin/env bash
# Upstream drift check for the security forks (GF-AUDIT-001 GF-031): the Omarchy files the lock, idle and polkit modules
# derive from are pinned by sha256 in docs/upstream/omarchy.lock. Fails (exit 1) when the installed Omarchy changed or
# removed one of them, so an upstream fix (or regression) in code Grassfield forked is reviewed instead of missed. Part of
# `just check`. Read-only unless --update; no Omarchy command is executed.
#
#   scripts/dev/upstream-drift.sh             check (SKIP and exit 0 when Omarchy is not installed)
#   scripts/dev/upstream-drift.sh --require   check; fail when Omarchy is not installed (release check)
#   scripts/dev/upstream-drift.sh --update    after the review: re-pin every hash (and the package line) to the installed files
#
# Also checked, without Omarchy: every pinned line names derived files that exist and still name their upstream file
# (attribution kept), and every file of the tree whose header says "adapted from Omarchy" is pinned here.
# Exit: 0 ok or skipped, 1 drift, attribution mismatch or a read error, 2 malformed lock file or usage.
# Options for tests only (`just check` passes none; no environment variable changes what is checked, review of 395715e):
#   --omarchy DIR   the installed tree (default /usr/share/omarchy)
#   --lock FILE     the lock file (default <repository>/docs/upstream/omarchy.lock)
#   --root DIR      the tree whose files are derived (default the repository)
#   --package V     the package version --update writes (default `pacman -Q omarchy`)
set -u
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
omarchy=/usr/share/omarchy
lock=""
pkg_override=""
mode=check
while (($#)); do
  case $1 in
    --require) mode=require ;;
    --update) mode=update ;;
    --omarchy | --lock | --root | --package)
      [[ $# -ge 2 && -n $2 ]] || { echo "upstream-drift: $1 needs a value" >&2; exit 2; }
      case $1 in
        --omarchy) omarchy=$2 ;;
        --lock) lock=$2 ;;
        --root) repo=$2 ;;
        --package) pkg_override=$2 ;;
      esac
      shift
      ;;
    *) echo "usage: upstream-drift.sh [--require|--update] [--omarchy DIR] [--lock FILE] [--root DIR] [--package V]" >&2; exit 2 ;;
  esac
  shift
done
lock=${lock:-$repo/docs/upstream/omarchy.lock}

[[ -r $lock ]] || { echo "upstream-drift: FAIL: no lock file $lock" >&2; exit 2; }

# Parse: "<sha256> <path> <derived[,derived...]>"; comments and blank lines are skipped.
shas=() paths=() derived=()
n=0
while IFS= read -r line || [[ -n $line ]]; do
  n=$((n + 1))
  [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
  read -r sha path from extra <<<"$line"
  if [[ ! $sha =~ ^[0-9a-f]{64}$ || -z ${path:-} || -z ${from:-} || -n ${extra:-} || $path == /* || $path == *..* ]]; then
    echo "upstream-drift: FAIL: $lock:$n is not '<sha256> <relative path> <derived,...>': $line" >&2
    exit 2
  fi
  shas+=("$sha") paths+=("$path") derived+=("$from")
done <"$lock"
((${#paths[@]} > 0)) || { echo "upstream-drift: FAIL: $lock pins nothing" >&2; exit 2; }

fails=0
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }

# Attribution (no Omarchy needed): each derived file exists and names its upstream file (bin/<x> is named by <x>).
declare -A pinned=()
for i in "${!paths[@]}"; do
  needle=${paths[$i]#bin/}
  IFS=, read -r -a files <<<"${derived[$i]}"
  for f in "${files[@]}"; do
    pinned[$f]=1
    if [[ ! -f $repo/$f ]]; then
      bad "$f (derived from ${paths[$i]}) does not exist"
      continue
    fi
    grep -qF -- "$needle" "$repo/$f"
    case $? in
      0) ;;
      1) bad "$f no longer names its upstream file $needle (attribution header)" ;;
      *) bad "$f cannot be read (grep failed)" ;;
    esac
  done
done

# Every fork the tree declares ("adapted from Omarchy" in a source file) is pinned. A read error fails the check.
scan_dirs=()
for d in shell ui apps bridges compositor config packaging scripts; do
  [[ -d $repo/$d ]] && scan_dirs+=("$d")
done
if ((${#scan_dirs[@]} > 0)); then
  # In a checkout only the files git tracks count: an untracked build tree (makepkg's packaging/arch/pkg holds copies of
  # the shell) is not the source. A `git archive` export (release-check) has no .git and no such tree: plain grep there.
  if git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    forks=$(git -C "$repo" grep -liI -e "adapted from omarchy" -- "${scan_dirs[@]}" ':(exclude,glob)**/.dev/**' \
      ':(exclude,glob)**/docs/**' ':(exclude,glob)**/tests/**' ':(exclude,glob)**/licenses/**' ':(exclude,glob)**/upstream-drift.sh')
  else
    forks=$(cd "$repo" && grep -rliI --exclude-dir=.git --exclude-dir=.dev --exclude-dir=docs --exclude-dir=tests --exclude-dir=licenses \
      --exclude=upstream-drift.sh -e "adapted from omarchy" -- "${scan_dirs[@]}")
  fi
  rc=$?
  ((rc <= 1)) || bad "the scan for files adapted from Omarchy failed (grep exit $rc)"
  while IFS= read -r f; do
    [[ -n $f ]] || continue
    [[ -n ${pinned[$f]:-} ]] || bad "$f says it is adapted from Omarchy but is not pinned in ${lock#"$repo"/}"
  done < <(LC_ALL=C sort <<<"$forks")
fi

if [[ ! -d $omarchy ]]; then
  if [[ $mode == require || $mode == update ]]; then
    echo "FAIL: Omarchy is not installed at $omarchy"
    exit 1
  fi
  ((fails == 0)) || { echo "upstream-drift: $fails attribution problem(s)"; exit 1; }
  echo "SKIP: Omarchy is not installed at $omarchy (drift not checked; use --require to fail); attribution ok (${#paths[@]} pinned files)"
  exit 0
fi

if [[ $mode == update ]]; then
  ((fails == 0)) || { echo "upstream-drift: $fails attribution problem(s); fix them before re-pinning"; exit 1; }
  for i in "${!paths[@]}"; do
    [[ -r $omarchy/${paths[$i]} ]] || { echo "FAIL: $omarchy/${paths[$i]} is gone: remove or replace its line by hand"; exit 1; }
  done
  pkg=${pkg_override:-$(pacman -Q omarchy 2>/dev/null | awk '{print $2}')}
  tmp=$(mktemp "$lock.XXXXXX") || exit 2
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line =~ ^#\ omarchy-package\  && -n $pkg ]]; then
      echo "# omarchy-package $pkg"
    elif [[ $line =~ ^[[:space:]]*(#|$) ]]; then
      printf '%s\n' "$line"
    else
      read -r _ path from <<<"$line"
      sum=$(sha256sum -- "$omarchy/$path" | awk '{print $1}')
      [[ $sum =~ ^[0-9a-f]{64}$ ]] || { rm -f -- "$tmp"; echo "FAIL: cannot hash $omarchy/$path"; exit 1; }
      echo "$sum $path $from"
    fi
  done <"$lock" >"$tmp"
  mv -- "$tmp" "$lock"
  echo "upstream-drift: re-pinned ${#paths[@]} files to $omarchy${pkg:+ (omarchy $pkg)}; record the review in docs/specs/security.md \"Upstream base\""
  exit 0
fi

for i in "${!paths[@]}"; do
  file=$omarchy/${paths[$i]}
  if [[ ! -r $file ]]; then
    bad "${paths[$i]} is gone from the installed Omarchy ($file): ${derived[$i]} derive from it; review what replaced it"
    continue
  fi
  sum=$(sha256sum -- "$file" | awk '{print $1}')
  if [[ ! $sum =~ ^[0-9a-f]{64}$ ]]; then
    bad "${paths[$i]} cannot be hashed ($file)"
  elif [[ $sum != "${shas[$i]}" ]]; then
    bad "${paths[$i]} changed upstream (pinned ${shas[$i]:0:12}, installed ${sum:0:12}): review it against ${derived[$i]//,/, }, then run scripts/dev/upstream-drift.sh --update"
  else
    echo "ok:   ${paths[$i]} (${derived[$i]//,/, })"
  fi
done

if ((fails > 0)); then
  echo "upstream-drift: $fails problem(s): the installed Omarchy differs from docs/upstream/omarchy.lock (GF-031)"
  exit 1
fi
echo "upstream-drift: ${#paths[@]} upstream files unchanged"
