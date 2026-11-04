#!/usr/bin/env bash
# grassfield-store-helper's `remove`, the WHOLE script in its own order, against stub pacman, pacman-conf and logger programs and
# a fake root (ADR-0046 D3). Without root and without a real pacman: the helper file is copied with only its fixed places
# replaced (/run/grassfield-store, the lists under /usr/share/omarchy, /usr/lib/grassfield, PATH, the root checks), nothing else, so
# a function used before its definition, a refusal that always fires or a wrong exit code is found here (a copy that only cuts
# denied() out cannot see it: tests/shell/store_helper_denied.sh). Nothing is installed or removed: the stub's -Rns writes a line.
#   tests/shell/store_helper_e2e.sh [HELPER]   HELPER: the helper to test (default: packaging/store/grassfield-store-helper)
# The real root, polkit and pacman path: tests/integration/store_helper.sh, in a container.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
helper=${1:-$root/packaging/store/grassfield-store-helper}
fails=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }

work=$(mktemp -d "${TMPDIR:-/tmp}/store-e2e.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT
stub=$work/stub run=$work/run lists=$work/omarchy calls=$work/calls.log
mkdir -p "$stub" "$run" "$lists"
: >"$calls"
printf 'btop\nchromium\n' >"$lists/omarchy-base.packages"
: >"$lists/omarchy-other.packages"

cat >"$stub/pacman" <<EOF
#!/bin/bash
echo "pacman \$*" >>"$calls"
case "\$1" in
  -Qu) exit 1 ;;
  -Slq) printf '%s\n' gs-app gs-kio hyprland btop ;;
  -Qqe) printf '%s\n' gs-app gs-kio hyprland btop ;;
  -Qq) printf '%s\n' grassfield-desktop gs-app gs-kio hyprland ;;
  -Qi) printf '%s\n' 'Name            : grassfield-desktop' 'Depends On      : hyprland' \\
         'Optional Deps   : gs-kio: network places [installed]' '                  perl' 'Required By     : None' ;;
  -Qlq) printf '%s\n' "/usr/share/applications/\${3}.desktop" ;;
  -Rs) printf '%s\n' "\${6}" ;;
  -Rns) exit 0 ;;
  *) exit 1 ;;
esac
EOF
printf '#!/bin/bash\ncase "$1" in DBPath) echo %s/db ;; HoldPkg) echo pacman glibc ;; esac\n' "$work" >"$stub/pacman-conf"
printf '#!/bin/bash\nexit 0\n' >"$stub/logger"
mkdir -p "$work/db"
chmod +x "$stub/pacman" "$stub/pacman-conf" "$stub/logger"

copy=$work/helper
sed -e "s#/run/grassfield-store#$run#g" \
    -e "s#/usr/share/omarchy/install/#$lists/#g" \
    -e "s#/usr/lib/grassfield/grassfield-store-helper#$copy#g" \
    -e "s#^export PATH=/usr/bin LC_ALL=C#export PATH=$stub:/usr/bin LC_ALL=C#" \
    -e 's#^((EUID == 0)) || {.*#true#' \
    -e 's#== 0:755#== $(id -u):755#; s#== 0:600#== $(id -u):600#' \
    "$helper" >"$copy"
for want in "$run" "$lists/omarchy-base.packages" "$copy" "$stub:/usr/bin" '$(id -u):755' '$(id -u):600'; do
  grep -qF -- "$want" "$copy" || { bad "the copy lacks its replacement: $want"; }
done
grep -q 'EUID == 0' "$copy" && bad "the root check is still there"
chmod +x "$copy"
((fails == 0)) || { echo "stopped: the copy is not what the test expects"; exit 1; }
# The re-exec under env -i keeps PATH out of reach; the copy's own export brings the stubs back. The helper's variables are theirs.

n=0
run_remove() { # package... -> exit code in $rc, the helper's log in $log
  local id
  n=$((n + 1)); printf -v id "%032x" "$n"
  : >"$calls"
  /usr/bin/env -i /usr/bin/bash -p "$copy" remove "$id" "$@" >"$work/out.txt" 2>&1
  rc=$?
  log=$run/$id.log
}

run_remove gs-app
[[ $rc == 0 ]] && ok "an allowed package: exit 0" || { bad "an allowed package: exit $rc"; cat "$log" 2>/dev/null | tail -5; }
grep -q '^pacman -Rns --noconfirm --noprogressbar -- gs-app$' "$calls" && ok "  it reached the final pacman -Rns call, on that package only" || { bad "  no pacman -Rns call"; cat "$calls"; }
grep -q "cannot read what Grassfield" "$log" 2>/dev/null && bad "  the optional-dependency read failed (a function used before its definition?)"
[[ $(cat "$run"/*.exit 2>/dev/null | tail -1) == 0 ]] && ok "  the exit file says 0" || bad "  the exit file does not say 0"

run_remove hyprland
[[ $rc == 6 ]] && ok "a protected package (hyprland): refused, exit 6" || bad "a protected package: exit $rc"
grep -q 'pacman -Rns' "$calls" && bad "  pacman -Rns ran for a protected package" || ok "  pacman -Rns never ran"

run_remove btop
[[ $rc == 6 ]] && ok "a package of Omarchy's lists (btop): refused, exit 6" || bad "btop: exit $rc"
grep -q 'pacman -Rns' "$calls" && bad "  pacman -Rns ran for btop"

run_remove gs-kio
[[ $rc == 6 ]] && ok "an optional dependency of grassfield-desktop: refused, exit 6" || bad "gs-kio: exit $rc"
grep -q 'pacman -Rns' "$calls" && bad "  pacman -Rns ran for it" || ok "  pacman -Rns never ran"

run_remove 'gs app'
[[ $rc == 2 ]] && ok "a name outside the charset: usage, exit 2" || bad "a bad name: exit $rc"

((fails == 0)) && exit 0
exit 1
