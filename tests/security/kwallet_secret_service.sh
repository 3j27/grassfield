#!/usr/bin/env bash
# ADR-0035 D-12, owner decision Q17-b: in a Grassfield session KWallet's ksecretd never takes org.freedesktop.secrets, so the
# Secret Service stays gnome-keyring's. The session's kwalletrc (packaging/xdg-config/kwalletrc: [org.freedesktop.secrets]
# apiEnabled=false) is read through XDG_CONFIG_DIRS, which packaging/uwsm/env-grassfield puts first, below the user's own
# ~/.config (a user kwalletrc that sets the key wins).
#  * text: the file, the guarded env line, the package installs it;
#  * the real env file, on scratch copies of its paths: the directory goes first, /etc/xdg stays, nothing twice, nothing when
#    the file is unreadable;
#  * KConfig (kreadconfig6, skipped without it): the session's value, and the user's file winning;
#  * the real ksecretd on a private session bus (dbus-run-session, scratch HOME, QT_QPA_PLATFORM=offscreen; skipped without
#    them): with the session's XDG_CONFIG_DIRS it owns only org.kde.secretservicecompat; without it (control, today's
#    behaviour, inventory S12) it also owns org.freedesktop.secrets.
# Never the owner's bus, files or secrets: every process runs under env -i with a scratch HOME and XDG directories.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/kwallet-secret-service.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
rc=$root/packaging/xdg-config/kwalletrc
env_file=$root/packaging/uwsm/env-grassfield

desc="the session's kwalletrc turns ksecretd's Secret Service name off, and sets nothing else"
check test "$(grep -v '^#' "$rc" | grep -v '^$' | tr '\n' ' ')" = "[org.freedesktop.secrets] apiEnabled=false "
desc="env-grassfield adds the directory only behind a readability test of the file"
check grep -q '^if \[ -r /usr/share/grassfield/xdg-config/kwalletrc \]; then' "$env_file"
desc="the package installs the file where env-grassfield looks for it"
check grep -q 'install -Dm644 "$root/packaging/xdg-config/kwalletrc" "$pkgdir/usr/share/grassfield/xdg-config/kwalletrc"' \
  "$root/packaging/arch/PKGBUILD"

# The real env file, with its path rewritten to a scratch copy.
mkdir -p "$tmp/gf"
sed "s|/usr/share/grassfield/xdg-config|$tmp/gf|g" "$env_file" >"$tmp/env"
dirs() { # dirs [XDG_CONFIG_DIRS before] -> the value after sourcing the env file once, or twice with "twice"
  env -i PATH="$PATH" ${1:+XDG_CONFIG_DIRS="$1"} sh -c '. "$1"; [ "${2-}" = twice ] && . "$1"; printf %s "${XDG_CONFIG_DIRS-unset}"' \
    _ "$tmp/env" "${2-}"
}
desc="no kwalletrc readable: XDG_CONFIG_DIRS is left alone"
check test "$(dirs)" = unset
cp "$rc" "$tmp/gf/kwalletrc"
desc="unset XDG_CONFIG_DIRS: the session's directory, then the default /etc/xdg"
check test "$(dirs)" = "$tmp/gf:/etc/xdg"
desc="an existing XDG_CONFIG_DIRS is kept after the session's directory"
check test "$(dirs /etc/xdg:/opt/xdg)" = "$tmp/gf:/etc/xdg:/opt/xdg"
desc="sourced twice, the directory appears once"
check test "$(dirs /etc/xdg twice)" = "$tmp/gf:/etc/xdg"

# KConfig's own reading (KWallet reads kwalletrc through KConfig, src/kwalletsettings.kcfg:49-53).
if command -v kreadconfig6 >/dev/null; then
  mkdir -p "$tmp/kc/home/.config"
  kread() {
    env -i PATH="$PATH" HOME="$tmp/kc/home" XDG_CONFIG_HOME="$tmp/kc/home/.config" XDG_CONFIG_DIRS="$root/packaging/xdg-config:/etc/xdg" \
      kreadconfig6 --file kwalletrc --group org.freedesktop.secrets --key apiEnabled --default true 2>/dev/null
  }
  desc="KConfig reads apiEnabled=false from the session's directory"
  check test "$(kread)" = false
  printf '[org.freedesktop.secrets]\napiEnabled=true\n' >"$tmp/kc/home/.config/kwalletrc"
  desc="a user's own kwalletrc that sets the key wins over the session's"
  check test "$(kread)" = true
else
  echo "SKIP: kreadconfig6 missing (KConfig's reading not checked)"
fi

# The real ksecretd on a private bus.
ksecretd=/usr/bin/ksecretd
if [[ -x $ksecretd ]] && command -v dbus-run-session >/dev/null && command -v dbus-send >/dev/null; then
  cat >"$tmp/probe.sh" <<'SH'
# usage: probe.sh <ksecretd> -> "compat=<bool> secrets=<bool>" once ksecretd has registered (or after 10 s)
has() { dbus-send --session --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner \
  "string:$1" 2>/dev/null | awk '/boolean/ {print $2}'; }
"$1" >/dev/null 2>&1 &
pid=$!
for _ in $(seq 1 100); do [ "$(has org.kde.secretservicecompat)" = true ] && break; sleep 0.1; done
printf 'compat=%s secrets=%s\n' "$(has org.kde.secretservicecompat)" "$(has org.freedesktop.secrets)"
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
SH
  run_ksecretd() { # run_ksecretd <name> [XDG_CONFIG_DIRS]
    mkdir -p "$tmp/$1/home/.config" "$tmp/$1/run"; chmod 700 "$tmp/$1/run"
    env -i PATH="$PATH" HOME="$tmp/$1/home" XDG_CONFIG_HOME="$tmp/$1/home/.config" XDG_DATA_HOME="$tmp/$1/home/.local/share" \
      XDG_RUNTIME_DIR="$tmp/$1/run" QT_QPA_PLATFORM=offscreen ${2:+XDG_CONFIG_DIRS="$2"} \
      timeout 30 dbus-run-session -- sh "$tmp/probe.sh" "$ksecretd" 2>/dev/null
  }
  out=$(run_ksecretd control)
  desc="control: without the session's directory ksecretd takes org.freedesktop.secrets (today's takeover, inventory S12)"
  check test "$out" = "compat=true secrets=true"
  out=$(run_ksecretd session "$root/packaging/xdg-config:/etc/xdg")
  desc="with the session's XDG_CONFIG_DIRS ksecretd keeps only org.kde.secretservicecompat; org.freedesktop.secrets stays free"
  check test "$out" = "compat=true secrets=false"
else
  echo "SKIP: ksecretd, dbus-run-session or dbus-send missing (the daemon's behaviour not checked)"
fi

exit "$fail"
