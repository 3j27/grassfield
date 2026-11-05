#!/usr/bin/env bash
# Upstream drift check for the security forks (GF-AUDIT-001 GF-031): the Omarchy files the lock, idle and polkit modules
# derive from are pinned by sha256 in docs/upstream/omarchy.lock. Fails (exit 1) when the installed Omarchy changed or
# removed one of them, so an upstream fix (or regression) in code Grassfield forked is reviewed instead of missed. Part of
# `just check`. Read-only unless --update; no Omarchy command is executed.
#
#   scripts/dev/upstream-drift.sh             check (SKIP and exit 0 when Omarchy is not installed)
#   scripts/dev/upstream-drift.sh --require   check; fail when Omarchy is not installed (release check)
#   scripts/dev/upstream-drift.sh --update    after the review: re-pin every reviewed hash (and the package line) to the installed
#                                             files; a pending line (below) stays pending
#
# Which Omarchy versions are accepted (Grassfield supports 4.0.6, the minimum, and 4.5.0): ONE LOCK FILE PER ACCEPTED VERSION,
# docs/upstream/omarchy.lock (4.0.6) and docs/upstream/omarchy-<version>.lock. The lock for a tree is the one whose
# "# omarchy-newest-migration N" line names the newest migration of the tree under check (<tree>/migrations/N.sh): this reads
# the tree itself, so it needs no pacman and works for an installed Omarchy and for a checkout alike. A tree no lock names
# (a new release, a patch that brings a migration) FAILS, closed: review its diff against the Grassfield files the last lock
# names, copy that lock to docs/upstream/omarchy-<version>.lock, set its two header lines, then --update --lock <that file>.
# Why not several hashes per line: a file that is right for one version and not yet reviewed for the other could pass
# on a hash it was never reviewed against; with a lock per version each line is a statement about one version, the
# review record of a version is one diff, and a line can be pending for it alone.
# A line whose first field is `pending:<who>` instead of a sha256 is a file of that version not yet reviewed (the owner of
# the derived code is named): the check FAILS on it ("pending review by <who>") until the reviewer replaces the field by the
# file's sha256 (sha256sum <tree>/<path>), so a file cannot be forgotten.
#
# Also checked, without Omarchy: every pinned line of EVERY lock names derived files that exist and still name their
# upstream file (attribution kept), and every file of the tree whose header says "adapted from Omarchy" is pinned.
# Exit: 0 ok or skipped, 1 drift, a pending line, an unknown tree, attribution mismatch or a read error, 2 malformed lock file
# or usage.
# Options for tests only (`just check` passes none; no environment variable changes what is checked, review of 395715e):
#   --omarchy DIR   the tree to check (default /usr/share/omarchy; a 4.5.0 checkout is checked against omarchy-4.5.0.lock)
#   --lock FILE     this lock only, whatever the tree (default: every docs/upstream/omarchy*.lock, the tree's chosen as above)
#   --root DIR      the tree whose files are derived (default the repository)
#   --package V     the package version --update writes (default `pacman -Q omarchy`)
set -u
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
omarchy=/usr/share/omarchy
lock=""
lock_arg=""
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
        --lock) lock_arg=$2 ;;
        --root) repo=$2 ;;
        --package) pkg_override=$2 ;;
      esac
      shift
      ;;
    *) echo "usage: upstream-drift.sh [--require|--update] [--omarchy DIR] [--lock FILE] [--root DIR] [--package V]" >&2; exit 2 ;;
  esac
  shift
done
# The lock files: the one named by --lock, else every docs/upstream/omarchy*.lock (the attribution of all of them is always
# checked; the hashes against the one that names the tree).
if [[ -n $lock_arg ]]; then
  locks=("$lock_arg")
else
  shopt -s nullglob
  locks=("$repo"/docs/upstream/omarchy*.lock)
  shopt -u nullglob
fi
((${#locks[@]} > 0)) || { echo "upstream-drift: FAIL: no lock file in $repo/docs/upstream" >&2; exit 2; }
for lock in "${locks[@]}"; do
  [[ -r $lock ]] || { echo "upstream-drift: FAIL: no lock file $lock" >&2; exit 2; }
done

# parse_lock FILE: "<sha256|pending:who> <path> <derived[,derived...]>" into shas, paths and derived; comments and blank lines
# are skipped.
parse_lock() {
  local file=$1 n=0 line sha path from extra
  shas=() paths=() derived=()
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    read -r sha path from extra <<<"$line"
    if [[ ! $sha =~ ^([0-9a-f]{64}|pending:[A-Za-z0-9._-]+)$ || -z ${path:-} || -z ${from:-} || -n ${extra:-} || $path == /* || $path == *..* ]]; then
      echo "upstream-drift: FAIL: $file:$n is not '<sha256|pending:who> <relative path> <derived,...>': $line" >&2
      exit 2
    fi
    shas+=("$sha") paths+=("$path") derived+=("$from")
  done <"$1"
  ((${#paths[@]} > 0)) || { echo "upstream-drift: FAIL: $file pins nothing" >&2; exit 2; }
}
# header_value FILE NAME: the value of the first "# NAME value" line.
header_value() { sed -n "s/^# $2[[:space:]]\{1,\}\([^[:space:]]\{1,\}\).*/\1/p" "$1" | head -n 1; }

fails=0
declare -A reported=()
bad() { [[ -n ${reported[$*]:-} ]] && return; reported[$*]=1; echo "FAIL: $*"; fails=$((fails + 1)); }

# Attribution (no Omarchy needed), in every lock: each derived file exists and names its upstream file (bin/<x> is named by
# <x>). A pending line only has to name existing files: the review that completes it adds the attribution of that version.
declare -A pinned=()
for lock in "${locks[@]}"; do
  parse_lock "$lock"
  for i in "${!paths[@]}"; do
    needle=${paths[$i]#bin/}
    IFS=, read -r -a files <<<"${derived[$i]}"
    for f in "${files[@]}"; do
      pinned[$f]=1
      if [[ ! -f $repo/$f ]]; then
        bad "$f (derived from ${paths[$i]}) does not exist"
        continue
      fi
      [[ ${shas[$i]} == pending:* ]] && continue
      grep -qF -- "$needle" "$repo/$f"
      case $? in
        0) ;;
        1) bad "$f no longer names its upstream file $needle (attribution header)" ;;
        *) bad "$f cannot be read (grep failed)" ;;
      esac
    done
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
  # Only when the scanned root is itself a checkout's top level: a --root fixture inside another checkout (the test's
  # temporary tree under .dev) is plain files.
  top=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null || true)
  if [[ -n $top && $(realpath "$top") == "$(realpath "$repo")" ]]; then
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
    [[ -n ${pinned[$f]:-} ]] || bad "$f says it is adapted from Omarchy but is not pinned in docs/upstream/omarchy*.lock"
  done < <(LC_ALL=C sort <<<"$forks")
fi

if [[ ! -d $omarchy ]]; then
  if [[ $mode == require || $mode == update ]]; then
    echo "FAIL: Omarchy is not installed at $omarchy"
    exit 1
  fi
  ((fails == 0)) || { echo "upstream-drift: $fails attribution problem(s)"; exit 1; }
  echo "SKIP: Omarchy is not installed at $omarchy (drift not checked; use --require to fail); attribution ok (${#locks[@]} lock file(s), ${#pinned[@]} derived files)"
  exit 0
fi

# The lock of this tree: the one whose "# omarchy-newest-migration" line names the newest migration of the tree (--lock FILE
# overrides). No lock names it: fail closed.
tree_id=""
for f in "$omarchy"/migrations/[0-9]*.sh; do
  [[ -f $f ]] || continue
  n=${f##*/}
  n=${n%.sh}
  [[ $n =~ ^[0-9]{1,18}$ ]] || continue
  ((10#$n > ${tree_id:-0})) && tree_id=$((10#$n))
done
if [[ -n $lock_arg ]]; then
  lock=$lock_arg
else
  lock=""
  known=""
  for f in "${locks[@]}"; do
    marker=$(header_value "$f" omarchy-newest-migration)
    known+="${known:+, }${f#"$repo"/} -> ${marker:-no marker}"
    [[ -n $tree_id && $marker == "$tree_id" ]] || continue
    [[ -z $lock ]] || { echo "upstream-drift: FAIL: ${lock#"$repo"/} and ${f#"$repo"/} both name the migration $tree_id" >&2; exit 2; }
    lock=$f
  done
  if [[ -z $lock ]]; then
    ((fails == 0)) || echo "upstream-drift: $fails attribution problem(s)"
    echo "FAIL: no lock names this Omarchy tree ($omarchy: newest migration ${tree_id:-none}); known: $known."
    echo "      Omarchy changed to a version Grassfield has not reviewed: read its diff against the Grassfield files the closest lock names,"
    echo "      copy that lock to docs/upstream/omarchy-<version>.lock, set its omarchy-package and omarchy-newest-migration lines,"
    echo "      then run scripts/dev/upstream-drift.sh --update --lock <that file> (docs/upstream/omarchy.lock header)"
    exit 1
  fi
fi
parse_lock "$lock"

if [[ $mode == update ]]; then
  ((fails == 0)) || { echo "upstream-drift: $fails attribution problem(s); fix them before re-pinning"; exit 1; }
  for i in "${!paths[@]}"; do
    [[ ${shas[$i]} == pending:* ]] && continue
    [[ -r $omarchy/${paths[$i]} ]] || { echo "FAIL: $omarchy/${paths[$i]} is gone: remove or replace its line by hand"; exit 1; }
  done
  pkg=${pkg_override:-$(pacman -Q omarchy 2>/dev/null | awk '{print $2}')}
  tmp=$(mktemp "$lock.XXXXXX") || exit 2
  kept=0
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line =~ ^#\ omarchy-package\  && -n $pkg ]]; then
      echo "# omarchy-package $pkg"
    elif [[ $line =~ ^#\ omarchy-newest-migration[[:space:]] && -n $tree_id ]]; then
      echo "# omarchy-newest-migration $tree_id"
    elif [[ $line =~ ^[[:space:]]*(#|$) ]]; then
      printf '%s\n' "$line"
    else
      read -r sha path from <<<"$line"
      if [[ $sha == pending:* ]]; then # not reviewed: stays pending
        kept=$((kept + 1))
        printf '%s\n' "$line"
        continue
      fi
      sum=$(sha256sum -- "$omarchy/$path" | awk '{print $1}')
      [[ $sum =~ ^[0-9a-f]{64}$ ]] || { rm -f -- "$tmp"; echo "FAIL: cannot hash $omarchy/$path"; exit 1; }
      echo "$sum $path $from"
    fi
  done <"$lock" >"$tmp"
  mv -- "$tmp" "$lock"
  echo "upstream-drift: re-pinned $((${#paths[@]} - kept)) files in ${lock#"$repo"/} to $omarchy${pkg:+ (omarchy $pkg)}${tree_id:+, newest migration $tree_id}; record the review in docs/specs/security.md \"Upstream base\""
  ((kept == 0)) || echo "upstream-drift: $kept line(s) stay pending: replace pending:<who> by the sha256 of the file once it is reviewed"
  exit 0
fi

for i in "${!paths[@]}"; do
  file=$omarchy/${paths[$i]}
  if [[ ${shas[$i]} == pending:* ]]; then
    bad "${paths[$i]} pending review by ${shas[$i]#pending:}: ${derived[$i]//,/, } derive from it and have not been checked against this version of Omarchy (replace the pending field of ${lock#"$repo"/} by its sha256 after the review)"
    continue
  fi
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
  echo "upstream-drift: $fails problem(s): the Omarchy at $omarchy differs from ${lock#"$repo"/} (GF-031)"
  exit 1
fi
echo "upstream-drift: ${#paths[@]} upstream files unchanged (${lock#"$repo"/})"
