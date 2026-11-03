#!/usr/bin/env bash
# Offline test of Grassfield's public installation script (ADR-0043): packaging/install/render.py and the rendered
# grassfield-install.sh, run against STUB commands in a throwaway fake root. It never runs the real pacman, pacman-key,
# sudo, curl or gpg: the script's PATH holds only the stubs and symlinks to harmless coreutils, so a command the script
# calls that has no stub fails the test instead of reaching the machine. Layer: logic (no session, no root, no network).
#
# The same script can run for real inside an Arch container (as tests/integration/update_helper.sh does for the update
# helper): a container with a local file:// repository and the real pacman is the follow-up the grassfield-packages
# repository owns (ADR-0043 g); this test covers the script's logic, order and idempotence.
# shellcheck disable=SC2015  # `test && pass || fail`: pass never fails
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
expect() { if [[ $2 == "$3" ]]; then pass "$1"; else fail "$1: got '$2', want '$3'"; fi; }
has() { if grep -Fq -- "$2" "$3"; then pass "$1"; else fail "$1: '$2' not in $3"; fi; }
hasnt() { if grep -Fq -- "$2" "$3"; then fail "$1: '$2' found in $3"; else pass "$1"; fi; }

FPR=0123456789ABCDEF0123456789ABCDEF01234567
BASE=https://packages.example.test
BIN=$W/bin S=$W/state R=$W/root
mkdir -p "$BIN" "$S" "$W/home" "$W/run" "$W/tmp" "$W/render"

# ---- 1. render.py ---------------------------------------------------------------------------------------------------
printf 'GRASSFIELD_REPO_BASE=%s\nGRASSFIELD_REPO_MIRRORS=\nGRASSFIELD_REPO_BASE_PREVIOUS=\nGRASSFIELD_SIGNING_FINGERPRINT=%s\n' \
  "$BASE" "$FPR" >"$W/good.conf"
python3 -I "$root/packaging/install/render.py" --conf "$root/packaging/pacman/repository.conf" \
  --template "$root/packaging/install/grassfield-install.sh.in" --out "$W/render/placeholder" >"$W/o" 2>&1
expect 'render refuses the placeholder repository.conf' "$?" 1
has 'render names the placeholder' 'placeholder' "$W/o"
[[ ! -e $W/render/placeholder ]] && pass 'nothing written for a placeholder' || fail 'files written for a placeholder'
sed 's/^GRASSFIELD_SIGNING_FINGERPRINT=.*/GRASSFIELD_SIGNING_FINGERPRINT=/' "$W/good.conf" >"$W/nofpr.conf"
python3 -I "$root/packaging/install/render.py" --conf "$W/nofpr.conf" \
  --template "$root/packaging/install/grassfield-install.sh.in" --out "$W/render/nofpr" >"$W/o" 2>&1
expect 'render refuses an empty fingerprint' "$?" 1
sed 's#^GRASSFIELD_REPO_BASE=.*#GRASSFIELD_REPO_BASE=file:///srv/repo#' "$W/good.conf" >"$W/file.conf"
python3 -I "$root/packaging/install/render.py" --conf "$W/file.conf" \
  --template "$root/packaging/install/grassfield-install.sh.in" --out "$W/render/file" >"$W/o" 2>&1
expect 'render refuses a non-https base' "$?" 1
python3 -I "$root/packaging/install/render.py" --conf "$W/good.conf" \
  --template "$root/packaging/install/grassfield-install.sh.in" --out "$W/render/ok" >"$W/o" 2>&1
expect 'render with a real host and key' "$?" 0
SCRIPT=$W/render/ok/grassfield-install.sh
(cd "$W/render/ok" && sha256sum -c grassfield-install.sh.sha256 >/dev/null 2>&1)
expect 'the published checksum matches the script' "$?" 0
bash -n "$SCRIPT"
expect 'rendered script parses' "$?" 0
grep -q '@GRASSFIELD' "$SCRIPT" && fail 'a marker is left in the rendered script' || pass 'no marker left'
has 'the fingerprint is pinned in the script' "readonly GF_FPR='$FPR'" "$SCRIPT"

# ---- stubs ----------------------------------------------------------------------------------------------------------
for c in awk grep sed cat tee cp rm mkdir mktemp date cmp sort head tail tr dirname basename env bash timeout vercmp chmod cut wc \
  touch printf true false; do
  p=$(command -v "$c") && [[ $p == /* ]] && ln -sf "$p" "$BIN/$c"
done
stub() { cat >"$BIN/$1"; chmod +x "$BIN/$1"; }
LOGF=$S/calls

stub sudo <<'EOF'
#!/bin/bash
echo "sudo $*" >>"$GF_STUB/calls"
[[ ${1:-} == -v ]] && exit 0
exec "$@"
EOF
stub id <<'EOF'
#!/bin/bash
cat "$GF_STUB/uid" 2>/dev/null || echo 1000
EOF
stub uname <<'EOF'
#!/bin/bash
echo x86_64
EOF
stub df <<'EOF'
#!/bin/bash
printf 'Avail\n%sM\n' "$(cat "$GF_STUB/free" 2>/dev/null || echo 20000)"
EOF
stub flock <<'EOF'
#!/bin/bash
exit 0
EOF
stub checkupdates <<'EOF'
#!/bin/bash
cat "$GF_STUB/checkupdates" 2>/dev/null
exit 0
EOF
stub pacman-conf <<'EOF'
#!/bin/bash
# pacman-conf --config FILE --repo-list
file=$2
[[ -f $GF_STUB/conf_broken ]] && { awk '/^\[/ { gsub(/[][]/, ""); if ($0 != "options" && $0 != "grassfield") print }' "$file"; exit 0; }
awk '/^\[/ { gsub(/[][]/, ""); if ($0 != "options") print }' "$file"
EOF
stub pacman <<'EOF'
#!/bin/bash
echo "pacman $*" >>"$GF_STUB/calls"
inst=$GF_STUB/installed
case $1 in
  -Q)
    case $2 in
      omarchy) [[ -f $GF_STUB/omarchy ]] && echo "omarchy $(cat "$GF_STUB/omarchy")" || exit 1 ;;
      quickshell) echo "quickshell $(cat "$GF_STUB/quickshell")" ;;
      hyprland) echo "hyprland 0.56.2-4" ;;
      qt6-base) echo "qt6-base 6.12.0-1" ;;
      *) grep -qx "$2" "$inst" 2>/dev/null && echo "$2 1.0.0-1" || exit 1 ;;
    esac ;;
  -Qm) cat "$GF_STUB/foreign" 2>/dev/null; exit 0 ;;
  -Qu) cat "$GF_STUB/qu" 2>/dev/null; exit 0 ;;
  -Si) echo "Repository      : $(cat "$GF_STUB/qs_repo")"; echo "Name            : $2" ;;
  -Sy) [[ -f $GF_STUB/sync_fail ]] && exit 1; exit 0 ;;
  -S)
    shift
    print=0; pk=()
    for a in "$@"; do case $a in --print) print=1 ;; -*) ;; *) pk+=("$a") ;; esac; done
    if ((print)); then [[ -f $GF_STUB/resolve_fail ]] && { echo "error: could not satisfy dependencies" >&2; exit 1; }; exit 0; fi
    printf '%s\n' "${pk[@]}" >>"$inst"
    printf '%s\n' grassfield-icons grassfield-wallpapers grassfield-keyring >>"$inst"
    : >"$GF_STUB/pkgs-installed-$$" ;;
  -Rns)
    shift
    for a in "$@"; do [[ $a == -* ]] || sed -i "/^$a\$/d" "$inst"; done
    # the packages' pre_remove (grassfield-channel-scriptlet remove)
    "$GF_STUB/offlogic" ;;
esac
EOF
cat >"$W/offlogic" <<'EOF'
#!/bin/bash
# What grassfield-channel-set off / the scriptlet's remove does to the fake machine.
f=$GRASSFIELD_INSTALL_ROOT/etc/pacman.conf
if [[ -f $f ]]; then
  awk '{ l = $0; sub(/#.*/, "", l); gsub(/^[ \t]+|[ \t]+$/, "", l) }
       l == "[grassfield]" { skip = 2 }
       skip > 0 { skip--; next } { print }' "$f" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' >"$f.new" && cat "$f.new" >"$f" && rm -f "$f.new"
fi
rm -f "$GRASSFIELD_INSTALL_ROOT/etc/pacman.d/grassfield.conf"
: >"$GF_STUB/keys"
EOF
chmod +x "$W/offlogic"
stub pacman-key <<'EOF'
#!/bin/bash
echo "pacman-key $*" >>"$GF_STUB/calls"
case $1 in
  --list-keys) grep -q "$2" "$GF_STUB/keys" 2>/dev/null ;;
  --recv-keys) [[ -f $GF_STUB/keyserver_down ]] && exit 2; echo "$2" >>"$GF_STUB/keys" ;;
  --add) grep -o '[0-9A-F]\{40\}' "$2" | head -n 1 >>"$GF_STUB/keys" ;;
  --lsign-key) grep -q "$2" "$GF_STUB/keys" 2>/dev/null ;;
  --delete) sed -i "/$2/d" "$GF_STUB/keys" ;;
esac
EOF
stub curl <<'EOF'
#!/bin/bash
echo "curl $*" >>"$GF_STUB/calls"
[[ -f $GF_STUB/netdown ]] && exit 6
out=''
while (($#)); do [[ $1 == -o ]] && out=$2; shift; done
[[ -n $out ]] && cat "$GF_STUB/keyfile" >"$out"
exit 0
EOF
stub gpg <<'EOF'
#!/bin/bash
f=${*: -1}
c=$(cat "$f")
if [[ $c == SECRETKEY ]]; then printf 'sec:u:255:22:AAAA:1::::::::\nfpr:::::::::%s:\n' "$GF_STUB_FPR"; exit 0; fi
printf 'pub:u:255:22:AAAA:1::::::::\nfpr:::::::::%s:\n' "$c"
EOF
stub omarchy-snapshot <<'EOF'
#!/bin/bash
echo "omarchy-snapshot $*" >>"$GF_STUB/calls"
exit "$(cat "$GF_STUB/snap_rc" 2>/dev/null || echo 0)"
EOF
mk_channel_set() {
  stub grassfield-channel-set <<'EOF'
#!/bin/bash
echo "grassfield-channel-set $*" >>"$GF_STUB/calls"
[[ $1 == off ]] && "$GF_STUB/offlogic"
exit 0
EOF
}
mk_channel_set
stub grassfield-login <<'EOF'
#!/bin/bash
echo "grassfield-login $*" >>"$GF_STUB/calls"
mkdir -p "$HOME/.config/grassfield" && echo "$2" >"$HOME/.config/grassfield/login-session"
EOF
stub systemctl <<'EOF'
#!/bin/bash
echo "systemctl $*" >>"$GF_STUB/calls"
EOF

# A stock machine: Omarchy 4.0.6, [omarchy] first, quickshell from [omarchy].
fresh() {
  rm -rf "$S" "$R" "$W/home" "$W/state-bak"
  mkdir -p "$S" "$R/etc/pacman.d" "$R/var/lib/pacman" "$W/home"
  cp "$W/offlogic" "$S/offlogic"
  cat >"$R/etc/pacman.conf" <<'EOF'
[options]
HoldPkg = pacman glibc

[omarchy]
SigLevel = Optional TrustAll
Server = https://pkgs.omarchy.org/stable/$arch

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist
EOF
  printf 'ID=arch\nNAME="Arch Linux"\n' >"$R/etc/os-release"
  echo 4.0.6-1 >"$S/omarchy"
  echo 0.3.2.r7-1 >"$S/quickshell"
  echo omarchy >"$S/qs_repo"
  : >"$S/keys"
  : >"$S/installed"
  echo "$FPR" >"$S/keyfile"
  cp "$R/etc/pacman.conf" "$W/pacman.conf.orig"
}

# run <stdin> args...: the rendered script on stubs only; output in $W/out, status in $rc.
run() {
  local input=$1
  shift
  : >"$S/calls"
  printf '%s' "$input" | {
    env -i PATH="$BIN" HOME="$W/home" TMPDIR="$W/tmp" LANG="${TLANG:-C}" XDG_RUNTIME_DIR="$W/run" \
      GRASSFIELD_INSTALL_ROOT="$R" GF_STUB="$S" GF_STUB_FPR="$FPR" bash "$SCRIPT" "$@"
    echo $? >"$W/rc"
  } 2>&1 | cat >"$W/out"
  rc=$(<"$W/rc")
}
sudo_calls() { grep '^sudo ' "$S/calls"; }
conf_unchanged() { cmp -s "$R/etc/pacman.conf" "$W/pacman.conf.orig"; }

# ---- 2. usage and refusals before anything runs ---------------------------------------------------------------------
fresh
run '' --help
expect '--help exits 0' "$rc" 0
has '--help documents --uninstall' '--uninstall' "$W/out"
run '' --bogus
expect 'an unknown option exits 2' "$rc" 2
run '' --channel nightly
expect 'an unknown channel exits 2' "$rc" 2
run '' --session kde
expect 'an unknown session exits 2' "$rc" 2
cp "$root/packaging/install/grassfield-install.sh.in" "$W/template.sh"
env -i PATH="$BIN" HOME="$W/home" bash "$W/template.sh" --help >"$W/o" 2>&1 </dev/null
expect 'the unrendered template refuses to run' "$?" 2

# ---- 3. preflight failures: exit 1, the exact fix, no root command, pacman.conf untouched ---------------------------------
preflight_case() { # <name> <expected text> (state already arranged)
  run '' --yes
  expect "$1: exit 1" "$rc" 1
  has "$1: says what is wrong" "$2" "$W/out"
  has "$1: prints a fix" 'Fix:' "$W/out"
  [[ -z $(sudo_calls) ]] && pass "$1: no sudo" || fail "$1: sudo ran: $(sudo_calls)"
  conf_unchanged && pass "$1: pacman.conf untouched" || fail "$1: pacman.conf changed"
  hasnt "$1: no plan shown" '== Plan' "$W/out"
}
fresh; echo 0 >"$S/uid"; preflight_case 'root' 'running as root'
fresh; echo 4.0.5-1 >"$S/omarchy"; preflight_case 'old Omarchy' 'older than 4.0.6'
fresh; rm "$S/omarchy"; preflight_case 'no Omarchy' 'Omarchy is not installed'
fresh
cat >"$R/etc/pacman.conf" <<'EOF'
[options]
HoldPkg = pacman glibc

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

[omarchy]
SigLevel = Optional TrustAll
Server = https://pkgs.omarchy.org/stable/$arch
EOF
cp "$R/etc/pacman.conf" "$W/pacman.conf.orig"
preflight_case '[omarchy] after [extra]' '[omarchy] comes after [extra]'
has 'the order fix says it never reorders itself' 'never reorders' "$W/out"
fresh; echo 0.3.2-1 >"$S/quickshell"; echo extra >"$S/qs_repo"; preflight_case 'quickshell from extra' "extra build"
fresh; echo extra >"$S/qs_repo"; preflight_case 'quickshell offered by extra' 'would come from [extra]'
fresh; touch "$S/netdown"; preflight_case 'no network' 'cannot reach'
fresh; echo 100 >"$S/free"; preflight_case 'low disk' 'MiB free'
fresh; echo 'firefox 1-1 -> 2-1' >"$S/checkupdates"; preflight_case 'pending updates' 'pending updates'
fresh; touch "$R/var/lib/pacman/db.lck"; preflight_case 'pacman running' 'db.lck'
fresh; rm -f "$BIN/sudo"; preflight_case 'sudo missing' 'sudo is missing'
stub sudo <<'EOF'
#!/bin/bash
echo "sudo $*" >>"$GF_STUB/calls"
[[ ${1:-} == -v ]] && exit 0
exec "$@"
EOF
# Several problems are all reported at once.
fresh; echo 4.0.5-1 >"$S/omarchy"; touch "$S/netdown"; run '' --yes
has 'two problems: the first is reported' 'older than 4.0.6' "$W/out"
has 'two problems: the second is reported' 'cannot reach' "$W/out"
has 'the count of problems is said' '2 problem(s)' "$W/out"

# ---- 4. dry run -----------------------------------------------------------------------------------------------------
fresh; run '' --dry-run
expect '--dry-run exits 0' "$rc" 0
has 'dry-run shows the plan' '== Plan' "$W/out"
has 'dry-run says nothing changed' 'Dry run: nothing was changed' "$W/out"
[[ -z $(sudo_calls) ]] && pass 'dry-run: no sudo' || fail 'dry-run ran sudo'
conf_unchanged && pass 'dry-run: pacman.conf untouched' || fail 'dry-run changed pacman.conf'
[[ ! -e $R/etc/pacman.d/grassfield.conf ]] && pass 'dry-run: no grassfield.conf' || fail 'dry-run wrote grassfield.conf'
hasnt 'dry-run: no sync' 'pacman -Sy' "$S/calls"
hasnt 'dry-run: no install' 'pacman -S --needed' "$S/calls"
hasnt 'dry-run: no download of the key' ' -o ' "$S/calls"
has 'the plan names the fingerprint' "$FPR" "$W/out"
fresh; TLANG=fr_FR.UTF-8 run '' --dry-run
has 'French locale: French plan' 'Plan : ce qui va changer' "$W/out"
fresh; run '' --uninstall --dry-run
expect 'uninstall --dry-run exits 0' "$rc" 0
has 'uninstall dry-run shows its plan' 'back to stock Omarchy' "$W/out"
hasnt 'uninstall dry-run: no removal' 'pacman -Rns' "$S/calls"

# ---- 5. confirmation ------------------------------------------------------------------------------------------------
fresh; run $'n\n'
expect 'answering no stops' "$rc" 1
has 'no: says nothing changed' 'Nothing was changed' "$W/out"
[[ -z $(sudo_calls) ]] && pass 'no: no sudo' || fail 'no: sudo ran'
conf_unchanged && pass 'no: pacman.conf untouched' || fail 'no: pacman.conf changed'
fresh; run ''
expect 'no answer at all stops' "$rc" 1

# ---- 6. the happy path: the exact commands ---------------------------------------------------------------------------
fresh; run $'y\n'
expect 'happy path (answered yes) exits 0' "$rc" 0
has 'end message: restart' 'Restart the computer once' "$W/out"
has 'end message: how to undo' '--uninstall' "$W/out"
fresh; run '' --yes
expect 'happy path --yes exits 0' "$rc" 0
want="sudo -v
sudo timeout 120 pacman-key --recv-keys $FPR --keyserver keys.openpgp.org
sudo pacman-key --lsign-key $FPR
sudo tee $R/etc/pacman.d/grassfield.conf
sudo cp -p -- $R/etc/pacman.conf $R/etc/pacman.conf.grassfield-install-bak
sudo tee -a $R/etc/pacman.conf
sudo pacman -Sy
sudo pacman -S --needed --noconfirm grassfield-desktop grassfield-compositor grassfield-store"
expect 'the root commands, exactly and in order' "$(sudo_calls)" "$want"
expect 'the user commands, in order' "$(grep -E '^(omarchy-snapshot|grassfield-)' "$S/calls")" \
  "omarchy-snapshot create
grassfield-channel-set stable
grassfield-login set grassfield"
expect 'grassfield.conf is the b.3a file' "$(cat "$R/etc/pacman.d/grassfield.conf")" \
  "SigLevel = Required
Server = $BASE/stable/\$arch"
expect 'pacman.conf: the original, then the two lines' "$(cat "$R/etc/pacman.conf")" \
  "$(cat "$W/pacman.conf.orig")

[grassfield]
Include = /etc/pacman.d/grassfield.conf"
hasnt 'no service is touched' 'systemctl' "$S/calls"
expect 'no repository order edit: [omarchy] stays second, [grassfield] last' \
  "$(grep '^\[' "$R/etc/pacman.conf" | tr -d '[]\n' | tr -s ' ')" 'optionsomarchycoreextragrassfield'
expect 'the log exists (mode 600)' "$(stat -c %a "$W/home/.local/state/grassfield/install.log")" 600
has 'the log holds the root commands' 'sudo pacman -Sy' "$W/home/.local/state/grassfield/install.log"
cp "$R/etc/pacman.conf" "$W/after1.conf"
cp "$R/etc/pacman.d/grassfield.conf" "$W/after1.grassfield"

# ---- 7. idempotent rerun: repairs and updates, never duplicates ------------------------------------------------------
run '' --yes
expect 'rerun exits 0' "$rc" 0
cmp -s "$R/etc/pacman.conf" "$W/after1.conf" && pass 'rerun: pacman.conf identical (no duplicated line)' || fail 'rerun changed pacman.conf'
cmp -s "$R/etc/pacman.d/grassfield.conf" "$W/after1.grassfield" && pass 'rerun: grassfield.conf identical' || fail 'rerun changed grassfield.conf'
expect 'rerun: sections' "$(grep -c '^\[grassfield\]' "$R/etc/pacman.conf")" 1
expect 'rerun: no key download, no file write, still syncs and installs' "$(sudo_calls)" \
  "sudo -v
sudo pacman-key --lsign-key $FPR
sudo pacman -Sy
sudo pacman -S --needed --noconfirm grassfield-desktop grassfield-compositor grassfield-store"
# A rerun after a half-done install: section there, file missing.
rm -f "$R/etc/pacman.d/grassfield.conf"; run '' --yes
expect 'repair: rewrites the missing file' "$(cat "$R/etc/pacman.d/grassfield.conf")" "SigLevel = Required
Server = $BASE/stable/\$arch"
cmp -s "$R/etc/pacman.conf" "$W/after1.conf" && pass 'repair: pacman.conf still identical' || fail 'repair changed pacman.conf'
# A file naming another host is replaced, the old one kept.
printf 'SigLevel = Required\nServer = https://old.example.test/stable/$arch\n' >"$R/etc/pacman.d/grassfield.conf"
run '' --yes
has 'foreign file: copy kept' 'old.example.test' "$R/etc/pacman.d/grassfield.conf.grassfield-install-bak"
has 'foreign file: ours written' "$BASE/stable" "$R/etc/pacman.d/grassfield.conf"

# ---- 8. options -----------------------------------------------------------------------------------------------------
fresh; run '' --yes --channel beta --with-login-themes --session omarchy --no-snapshot
expect 'beta + themes + omarchy session exits 0' "$rc" 0
has 'beta file' "$BASE/beta/\$arch" "$R/etc/pacman.d/grassfield.conf"
has 'themes package installed' 'grassfield-store grassfield-login-themes' "$S/calls"
has 'channel hand-over is beta' 'grassfield-channel-set beta' "$S/calls"
has 'session omarchy' 'grassfield-login set omarchy' "$S/calls"
hasnt 'no snapshot with --no-snapshot' 'omarchy-snapshot' "$S/calls"
has 'end message for the omarchy session' 'still starts Omarchy' "$W/out"

# ---- 9. snapshot ---------------------------------------------------------------------------------------------------
fresh; echo 1 >"$S/snap_rc"; run '' --yes
expect 'a failing snapshot stops' "$rc" 1
has 'snapshot failure says why' 'snapshot failed' "$W/out"
conf_unchanged && pass 'snapshot failure: pacman.conf untouched' || fail 'snapshot failure: pacman.conf changed'
hasnt 'snapshot failure: no key step' 'pacman-key' "$S/calls"
fresh; echo 127 >"$S/snap_rc"; run '' --yes
expect 'no snapper: goes on' "$rc" 0
fresh; echo 1 >"$S/snap_rc"; run '' --yes --no-snapshot
expect '--no-snapshot goes on after a snapshot problem' "$rc" 0

# ---- 10. the key ---------------------------------------------------------------------------------------------------
fresh; touch "$S/keyserver_down"; run '' --yes
expect 'keyserver down: falls back to the host file' "$rc" 0
has 'fallback downloads the key file' "$BASE/grassfield-signing-key.asc" "$S/calls"
has 'fallback adds the verified file' 'pacman-key --add' "$S/calls"
fresh; touch "$S/keyserver_down"; echo 'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF' >"$S/keyfile"; run '' --yes
expect 'a substituted key file is refused' "$rc" 1
has 'the refusal names it' 'not 0123456789ABCDEF' "$W/out"
hasnt 'nothing is signed' 'lsign-key' "$S/calls"
conf_unchanged && pass 'substituted key: pacman.conf untouched' || fail 'substituted key changed pacman.conf'
fresh; touch "$S/keyserver_down"; echo SECRETKEY >"$S/keyfile"; run '' --yes
expect 'a key file with a secret key is refused' "$rc" 1

# ---- 11. after the sync ---------------------------------------------------------------------------------------------
fresh; touch "$S/resolve_fail"; run '' --yes
expect 'unresolvable packages stop' "$rc" 1
has 'resolution failure says nothing installed' 'Nothing was installed' "$W/out"
hasnt 'resolution failure: no install' '--noconfirm' "$S/calls"
fresh; echo 'qt6-base 6.12.0-1 -> 6.12.1-1' >"$S/qu"; run '' --yes
expect 'pending updates after the sync stop (partial upgrade)' "$rc" 1
has 'partial upgrade message' 'partial upgrade' "$W/out"
fresh; touch "$S/conf_broken"; run '' --yes
expect 'a pacman.conf pacman cannot read with the section is put back' "$rc" 1
conf_unchanged && pass 'conf_broken: pacman.conf restored' || fail 'conf_broken: pacman.conf not restored'

# ---- 12. uninstall --------------------------------------------------------------------------------------------------
fresh; run '' --yes
run '' --uninstall --yes
expect 'uninstall exits 0' "$rc" 0
conf_unchanged && pass 'uninstall: pacman.conf is the original' || fail 'uninstall: pacman.conf differs'
[[ ! -e $R/etc/pacman.d/grassfield.conf ]] && pass 'uninstall: no grassfield.conf' || fail 'uninstall: grassfield.conf left'
expect 'uninstall: no key left' "$(wc -c <"$S/keys")" 0
expect 'uninstall: no package left' "$(wc -c <"$S/installed")" 0
[[ ! -e $W/home/.config/grassfield/login-session ]] && pass 'uninstall: no session choice left' || fail 'uninstall: session file left'
expect 'uninstall: the existing Turn Off, then the session, then the removal' \
  "$(grep -E '^(omarchy-snapshot|grassfield-|pacman -Rns|sudo pacman -Rns)' "$S/calls" | grep -v '^pacman ')" \
  "omarchy-snapshot create
grassfield-channel-set off
grassfield-login set omarchy
sudo pacman -Rns --noconfirm grassfield-store grassfield-compositor grassfield-desktop grassfield-icons grassfield-wallpapers grassfield-keyring"
has 'uninstall end message' 'stock Omarchy' "$W/out"
run '' --uninstall --yes
expect 'uninstall twice exits 0' "$rc" 0
# A failed install leaves [grassfield] and the key but no package: the script's own copy puts pacman.conf back.
fresh; touch "$S/resolve_fail"; run '' --yes
rm -f "$BIN/grassfield-channel-set" # the package is not installed: its helper is not there
run '' --uninstall --yes
expect 'uninstall after a failed install exits 0' "$rc" 0
conf_unchanged && pass 'failed install then uninstall: pacman.conf is the original' || fail 'failed install then uninstall: differs'
expect 'failed install then uninstall: no key' "$(wc -c <"$S/keys")" 0
# pacman.conf edited since: the script does not guess.
fresh; touch "$S/resolve_fail"; run '' --yes
printf '\n# my edit\n' >>"$R/etc/pacman.conf"
rm -f "$BIN/grassfield-channel-set"
run '' --uninstall --yes
mk_channel_set
expect 'uninstall with an edited pacman.conf stops' "$rc" 1
has 'it prints the manual fix' 'delete the two lines' "$W/out"
has 'the manual fix leaves the key for after' 'pacman-key --delete' "$W/out"

# ---- 13. shellcheck (when installed) ----------------------------------------------------------------------------------
if command -v shellcheck >/dev/null; then
  shellcheck -s bash "$SCRIPT" "$0"
  expect 'shellcheck: the rendered script and this test' "$?" 0
else
  echo "  note shellcheck is not installed here: run it in CI (the Arch container installs it)"
fi

((fails == 0)) && echo "PASS: public install script" || echo "FAIL: public install script ($fails)"
exit $((fails > 0))
