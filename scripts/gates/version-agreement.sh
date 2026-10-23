#!/usr/bin/env bash
# GF-013 cross-check: the version every part reports is the one in the VERSION file.
#
#   scripts/gates/version-agreement.sh --nested      this tree's dev builds: .dev/build/grassfield-menu-bridge --version,
#                                                    `hyprctl grassfield` of the nested compositor (scripts/nestctl), the
#                                                    VERSION file the shell's About reads
#   scripts/gates/version-agreement.sh --installed [--instance SIG]   the installed packages in the running session (read only;
#                                                    the plugin is asked on the Hyprland instance SIG, default the one in
#                                                    HYPRLAND_INSTANCE_SIGNATURE; an instance that is this tree's nested one is refused):
#                                                    pacman -Q grassfield-desktop / grassfield-compositor, /usr/bin/grassfield-menu-bridge --version,
#                                                    `hyprctl grassfield`, /usr/share/grassfield/VERSION (About), /usr/share/grassfield/BUILD-COMMIT
#   scripts/gates/version-agreement.sh --selftest
#
# The repository's VERSION file is the reference, not a source. Every source of the mode is normalised to its form (a pacman
# version 1.0.0rc1-1 becomes 1.0.0-rc1) and compared: --nested needs the menu bridge and the plugin; --installed needs
# About (/usr/share/grassfield/VERSION), pacman for grassfield-desktop and grassfield-compositor, the menu bridge and the
# plugin. PASS requires EVERY one of them; a source that cannot be read is named as missing and the run is INCONCLUSIVE,
# never a pass. Exit: 0 every source reports VERSION, 1 a source differs, 2 a source is missing or usage error.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)

# Normalise: strip a pacman "-<pkgrel>" suffix, put the hyphen back before an rc/beta/alpha suffix.
norm() { # <version text>
  local v=${1//[[:space:]]/}
  v=$(sed -E 's/-[0-9]+$//; s/^([0-9]+\.[0-9]+\.[0-9]+)(rc|beta|alpha)/\1-\2/' <<<"$v")
  printf '%s' "$v"
}

if [[ ${1:-} == --selftest ]]; then
  fails=0
  chk() { [[ $(norm "$1") == "$2" ]] || { echo "FAIL: norm '$1' = '$(norm "$1")', want '$2'"; fails=1; }; }
  chk "1.0.0rc1-1" "1.0.0-rc1"
  chk "1.0.0-rc1" "1.0.0-rc1"
  chk "1.0.0-2" "1.0.0"
  chk "1.0.0" "1.0.0"
  chk " 1.0.0beta2-1 " "1.0.0-beta2"
  ((fails == 0)) && echo "version-agreement selftest: PASS (5 cases)"
  exit "$fails"
fi

mode=${1:-}
instance=""
if [[ ${2:-} == --instance ]]; then instance=${3:-}; elif [[ -n ${2:-} ]]; then mode=""; fi
[[ $mode == --nested || $mode == --installed ]] || { echo "usage: version-agreement.sh --nested | --installed [--instance SIG] | --selftest" >&2; exit 2; }
want=$(tr -d '[:space:]' <"$root/VERSION")
declare -a names=() vals=()
add() { names+=("$1"); vals+=("$(norm "$2")"); }
missing=()

plugin_version() { jq -r '.version // empty' 2>/dev/null; }
if [[ $mode == --nested ]]; then
  b=$root/.dev/build/grassfield-menu-bridge
  if [[ -x $b ]]; then add "menu bridge (dev build)" "$("$b" --version | awk '{print $2}')"; else missing+=("menu bridge: $b not built"); fi
  v=$("$root/scripts/nestctl" grassfield -j 2>/dev/null | plugin_version)
  if [[ -n $v ]]; then add "plugin (hyprctl grassfield, nested)" "$v"; else missing+=("plugin: the nested compositor has no plugin loaded or no nested session"); fi
else
  f=/usr/share/grassfield/VERSION
  if [[ -r $f ]]; then add "About (/usr/share/grassfield/VERSION)" "$(<"$f")"; else missing+=("About: $f not installed"); fi
  for pkg in grassfield-desktop grassfield-compositor; do
    if v=$(pacman -Q "$pkg" 2>/dev/null | awk '{print $2}') && [[ -n $v ]]; then add "pacman -Q $pkg" "$v"; else missing+=("$pkg not installed"); fi
  done
  if [[ -x /usr/bin/grassfield-menu-bridge ]]; then add "menu bridge (/usr/bin)" "$(/usr/bin/grassfield-menu-bridge --version | awk '{print $2}')"; else missing+=("menu bridge: not installed"); fi
  inst=${instance:-${HYPRLAND_INSTANCE_SIGNATURE:-}}
  nested_inst=$(cat "$root/.dev/nested.instance" 2>/dev/null || true)
  if [[ -z $inst ]]; then
    missing+=("plugin: no Hyprland instance (pass --instance SIG, or run from the session: HYPRLAND_INSTANCE_SIGNATURE is empty)")
  elif [[ -n $nested_inst && $inst == "$nested_inst" ]]; then
    echo "version-agreement: refusing: instance $inst is this tree's nested session, not the installed one (use --nested)" >&2
    exit 2
  elif ! hyprctl instances -j 2>/dev/null | jq -e --arg i "$inst" 'any(.[]; .instance == $i)' >/dev/null 2>&1; then
    missing+=("plugin: Hyprland instance $inst is not listed by hyprctl instances")
  else
    echo "  plugin asked on Hyprland instance $inst ($([[ -n $instance ]] && echo "--instance" || echo "HYPRLAND_INSTANCE_SIGNATURE"))"
    v=$(HYPRLAND_INSTANCE_SIGNATURE=$inst hyprctl -j grassfield 2>/dev/null | plugin_version)
    if [[ -n $v ]]; then add "plugin (hyprctl grassfield, instance ${inst:0:12})" "$v"; else missing+=("plugin: instance $inst has no plugin loaded"); fi
  fi
  [[ -r /usr/share/grassfield/BUILD-COMMIT ]] && echo "build commit of the installed desktop package: $(</usr/share/grassfield/BUILD-COMMIT)"
fi

echo "  reference: VERSION file of the repository = $want"
bad=0
for i in "${!names[@]}"; do
  if [[ ${vals[$i]} == "$(norm "$want")" ]]; then s=ok; else s="DIFFERS"; bad=1; fi
  printf '  %-48s %-14s %s\n' "${names[$i]}" "${vals[$i]}" "$s"
done
for m in "${missing[@]}"; do echo "  not checked: $m"; done
if ((bad)); then echo "version: FAIL: a part does not report $want (above)"; exit 1; fi
if ((${#missing[@]} > 0)); then echo "version: INCONCLUSIVE: ${#missing[@]} source(s) could not be read (listed above as not checked); the ${#names[@]} read agree with $want"; exit 2; fi
echo "version: PASS: all ${#names[@]} sources report $want"
