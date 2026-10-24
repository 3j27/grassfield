#!/usr/bin/env bash
# Off-machine copy of the repository (GF-034): one git bundle of every branch and tag, verified.
#
#   scripts/dev/backup.sh DIR        (just backup DIR)
#
# DIR is the folder of the copy (an external disk, a mounted share): it must exist and must not be inside this
# repository. Writes DIR/grassfield-<date>-<time>-<commit>.bundle and a .sha256 next to it, then verifies the bundle
# with `git bundle verify` and lists its refs. The repository is only read. Restore with
#   git clone DIR/<file>.bundle grassfield-restored
# Exit: 0 bundle written and verified; 1 verification failed; 2 usage error.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dir=${1:-}
[[ -n $dir && -d $dir ]] || { echo "usage: scripts/dev/backup.sh DIR   (DIR must be an existing directory)" >&2; exit 2; }
dir=$(cd "$dir" && pwd)
case $dir/ in
  "$root"/*) echo "backup: $dir is inside the repository: a copy next to the original is not a backup" >&2; exit 2 ;;
esac
file=$dir/grassfield-$(date +%Y%m%d-%H%M%S)-$(git -C "$root" rev-parse --short HEAD).bundle
git -C "$root" bundle create "$file" --all
git -C "$root" bundle verify "$file"
(cd "$dir" && sha256sum "$(basename "$file")" >"$file.sha256" && sha256sum --check "$file.sha256")
echo "backup: $(git -C "$root" bundle list-heads "$file" | wc -l) refs, $(du -h "$file" | cut -f1), $file"
