#!/usr/bin/env bash
# ADR-0003: the Grassfield session fontconfig (packaging/fontconfig/fonts.conf), resolved with fc-match under
# FONTCONFIG_FILE. Only reads the repo, /etc/fonts and the installed fonts; nothing is written.
# Family names go through fc-match's name parser, where "-" starts a size: it is escaped as \- (apps pass the family
# string directly, so the escape only exists in this test).
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
conf="$root/packaging/fontconfig/fonts.conf"
fail=0
if ! command -v fc-match >/dev/null || [[ -z $(fc-list 'Inter' family 2>/dev/null) ]]; then
  echo "SKIP: fontconfig session (fc-match or the Inter font missing)"
  exit 0
fi
sys() { fc-match "$1" family | head -1; }
ses() { FONTCONFIG_FILE="$conf" fc-match "$1" family | head -1; }
is() { # pattern expected-family
  local got; got=$(ses "$1")
  if [[ $got == "$2" ]]; then echo "PASS: session $1 -> $got"; else echo "FAIL: session $1 -> $got (want $2)"; fail=1; fi
}
same() { # pattern: unchanged against the system configuration
  local a b; a=$(sys "$1"); b=$(ses "$1")
  if [[ $a == "$b" ]]; then echo "PASS: session $1 unchanged -> $b"; else echo "FAIL: session $1 -> $b, system gives $a"; fail=1; fi
}
is sans-serif Inter
is 'system\-ui' Inter
is '\-apple\-system' Inter
is BlinkMacSystemFont Inter
is 'SF Pro' Inter
is 'SF Pro Text' Inter
is '.AppleSystemUIFont' Inter
is 'SF Pro Display' 'Inter Display'
is 'sans-serif:pixelsize=13' Inter
is 'sans-serif:pixelsize=24' 'Inter Display'
same monospace
same Helvetica
same Arial
same serif
same 'Liberation Sans'
same 'DejaVu Sans'
if [[ $(sys sans-serif) != Inter ]]; then echo "PASS: without FONTCONFIG_FILE sans-serif is still $(sys sans-serif)"; else
  echo "NOTE: the system configuration already resolves sans-serif to Inter"; fi
rend=$(FONTCONFIG_FILE="$conf" fc-match -v sans-serif | grep -E '^\s+(antialias|hintstyle|rgba|lcdfilter):' | tr -s ' \n' ' ')
case $rend in
  *"antialias: True"*"hintstyle: 1"*"rgba: 5"*"lcdfilter: 0"*) echo "PASS: rendering antialias, hintslight, rgba none, lcdfilter none" ;;
  *) echo "FAIL: rendering was: $rend"; fail=1 ;;
esac
if grep -q '<include ignore_missing="yes">/etc/fonts/fonts.conf</include>' "$conf"; then echo "PASS: includes the system fonts.conf first"; else echo "FAIL: no system include"; fail=1; fi
if grep -v '^\s*<!--' "$conf" | grep -qiE '<string>(monospace|Helvetica|Arial)</string>'; then echo "FAIL: rules touch monospace, Helvetica or Arial"; fail=1; else echo "PASS: monospace, Helvetica and Arial are not named by any rule"; fi
env_ok=$(grep -c 'FONTCONFIG_FILE=/usr/share/grassfield/fontconfig/fonts.conf' "$root/packaging/uwsm/env-grassfield" || true)
if [[ $env_ok == 1 ]] && grep -q '^if \[ -r /usr/share/grassfield/fontconfig/fonts.conf \]; then' "$root/packaging/uwsm/env-grassfield"; then
  echo "PASS: env-grassfield exports FONTCONFIG_FILE behind a readability test"; else echo "FAIL: env-grassfield FONTCONFIG_FILE guard"; fail=1; fi
exit "$fail"
