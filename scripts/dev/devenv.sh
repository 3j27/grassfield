#!/usr/bin/env bash
# Dev-only environment (sourced by nested-up.sh, shell-run.sh and isolated.sh; never by anything that touches the
# owner's session). Puts <repo>/.dev/share first in XDG_DATA_DIRS so that dev processes find the icon and cursor
# themes provisioned there (branding/cursors/build.sh, the Grassfield icon theme: scripts/dev/icons.sh or the wrapper), and
# selects the Grassfield icon theme for every Qt process (see below).
# The Grassfield cursor theme (branding/cursors/build.sh, ADR-0014), when built under .dev/share/icons, is selected the
# way config/hypr/grassfield/cursor.lua selects it for Hyprland and its children (exec_cmd, Xwayland): the shell, the
# private bus and the apps are started outside Hyprland and would not see those variables otherwise.
# Only the environment of the calling process and its children is changed.

# A dev process never inherits the live session it was started from (the owner may run a real Grassfield session, and a
# terminal started from it carries that session's and grassfield-shell.service's variables): GRASSFIELD_SESSION=1 marks a
# packaged session (it turns the test hooks off and the real-session launch path on), QS_DISABLE_FILE_WATCHER and
# QS_NO_RELOAD_POPUP belong to the shell unit (shell-run.sh --unit-env sets them on purpose), the rest is systemd and
# uwsm bookkeeping of the live session's units.
unset GRASSFIELD_SESSION QS_DISABLE_FILE_WATCHER QS_NO_RELOAD_POPUP INVOCATION_ID JOURNAL_STREAM SYSTEMD_EXEC_PID \
  MANAGERPID MANAGERPIDFDID UWSM_FINALIZE_VARNAMES UWSM_WAIT_VARNAMES

_gf_dev_root=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
# The Grassfield app icon theme (ADR-0017), selected for every Qt process (Quickshell and the Grassfield apps) through
# QT_QPA_SYSTEM_ICON_THEME, as /usr/share/uwsm/env-grassfield does in the real session. Two forms of the same name:
#  * composed (scripts/dev/icons.sh, `just icons`): .dev/share/icons/grassfield-icons holds the full theme and the stamp
#    .grassfield-icons-stamp, written last; it is used as is;
#  * otherwise (offline, never provisioned) the wrapper theme (branding/icons/theme/index.theme: Grassfield's own icons,
#    then Breeze, Adwaita and hicolor) is copied there, with the real directories GTK needs and its own device glyphs.
_gf_icon_src=$_gf_dev_root/branding/icons/theme/index.theme
_gf_icon_dst=$_gf_dev_root/.dev/share/icons/grassfield-icons
if [[ -f $_gf_dev_root/.dev/share/icons/.grassfield-icons-stamp && -f $_gf_icon_dst/index.theme ]]; then
  :
elif [[ -f $_gf_icon_src ]]; then
  # A composed tree without its stamp is a half-finished composition: never mix it with the wrapper.
  [[ -d $_gf_icon_dst/base ]] && rm -rf "$_gf_icon_dst" 2>/dev/null
  { mkdir -p "$_gf_icon_dst/scalable/apps" "$_gf_icon_dst/scalable/devices" && { cmp -s "$_gf_icon_src" "$_gf_icon_dst/index.theme" || cp -f "$_gf_icon_src" "$_gf_icon_dst/index.theme"; }; } 2>/dev/null || true
  # Grassfield's own device glyphs that shadow the Apple device pictures of Breeze and Adwaita (E27).
  cp -f "$_gf_dev_root"/branding/icons/theme/scalable/devices/*.svg "$_gf_icon_dst/scalable/devices/" 2>/dev/null || true
fi
unset _gf_icon_src _gf_icon_dst
# Grayscale QtQuick text (ADR-0003), as /usr/share/uwsm/env-grassfield gives a real session: the distance-field renderer
# ignores fontconfig and would draw RGB subpixel text (orange/blue fringes).
export QSG_DISTANCEFIELD_ANTIALIASING=gray
# This tree's QML modules (Grassfield.Ui, the built Grassfield.I18n) always win over the packaged ones that an installed
# grassfield-desktop puts in /usr/lib/qt6/qml/Grassfield (QML_IMPORT_PATH comes before the default import path).
case ":${QML_IMPORT_PATH:-}:" in
  *":$_gf_dev_root/ui:"*) ;;
  *) export QML_IMPORT_PATH="$_gf_dev_root/ui:$_gf_dev_root/.dev/build/qml${QML_IMPORT_PATH:+:$QML_IMPORT_PATH}" ;;
esac
if [[ -d $_gf_dev_root/.dev/share/icons ]]; then
  case ":${XDG_DATA_DIRS:-}:" in
    *":$_gf_dev_root/.dev/share:"*) ;;
    *) export XDG_DATA_DIRS="$_gf_dev_root/.dev/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}" ;;
  esac
  if [[ -f $_gf_dev_root/.dev/share/icons/grassfield-icons/index.theme ]]; then
    export QT_QPA_SYSTEM_ICON_THEME=grassfield-icons
  fi
fi
if [[ -f $_gf_dev_root/.dev/share/icons/grassfield-cursors/manifest.hl ]]; then
  # The size follows Settings > Accessibility > Pointer (.dev/config/grassfield.json, pointer.size, 24..96 as an integer)
  # unless GRASSFIELD_CURSOR_SIZE overrides it; anything else is the default 24.
  _gf_cursor_size=${GRASSFIELD_CURSOR_SIZE:-}
  if [[ -z $_gf_cursor_size && -r $_gf_dev_root/.dev/config/grassfield.json ]] && command -v jq >/dev/null 2>&1; then
    _gf_cursor_size=$(jq -r 'if (.pointer.size | type) == "number" and .pointer.size == (.pointer.size | floor) and .pointer.size >= 24 and .pointer.size <= 96 then .pointer.size else 24 end' "$_gf_dev_root/.dev/config/grassfield.json" 2>/dev/null || true)
  fi
  [[ $_gf_cursor_size =~ ^[0-9]+$ ]] || _gf_cursor_size=24
  # GRASSFIELD_CURSOR_THEME=grassfield-cursors-custom (nested-up.sh/shell-run.sh --cursor-theme) starts the shell as a real
  # session would after a login with the custom theme on disk (the session environment names it); only the two Grassfield
  # themes are accepted, and the custom one only if it exists under .dev/share/icons (never anything of the owner's).
  _gf_cursor_theme=grassfield-cursors
  if [[ ${GRASSFIELD_CURSOR_THEME:-} == grassfield-cursors-custom && -f $_gf_dev_root/.dev/share/icons/grassfield-cursors-custom/manifest.hl ]]; then
    _gf_cursor_theme=grassfield-cursors-custom
  fi
  export HYPRCURSOR_THEME=$_gf_cursor_theme HYPRCURSOR_SIZE=$_gf_cursor_size
  export XCURSOR_THEME=$_gf_cursor_theme XCURSOR_SIZE=$_gf_cursor_size
  unset _gf_cursor_theme
  case ":${XCURSOR_PATH:-}:" in
    *":$_gf_dev_root/.dev/share/icons:"*) ;;
    *) export XCURSOR_PATH="$_gf_dev_root/.dev/share/icons:${XCURSOR_PATH:-~/.local/share/icons:~/.icons:/usr/share/icons}" ;;
  esac
  unset _gf_cursor_size
fi
# The Grassfield session's GTK defaults (packaging/dconf/grassfield.d, ADR-0017: icon theme, fonts, window buttons), as
# /usr/share/uwsm/env-grassfield gives them to a real session through DCONF_PROFILE: compiled into .dev/dconf (again when a
# source is newer) with a dev profile that reads the process's own user database first (XDG_CONFIG_HOME/dconf/user: an
# isolated one for every client isolated.sh starts and for the private bus's activated services, the portal included),
# then these defaults. No system database, never the owner's user database for a client. Without dconf: nothing exported.
_gf_dconf=$_gf_dev_root/.dev/dconf
if command -v dconf >/dev/null 2>&1 && [[ -d $_gf_dev_root/packaging/dconf/grassfield.d ]]; then
  if [[ ! -s $_gf_dconf/grassfield.db || -n $(find "$_gf_dev_root/packaging/dconf/grassfield.d" -newer "$_gf_dconf/grassfield.db" -print -quit 2>/dev/null) ]]; then
    mkdir -p "$_gf_dconf" 2>/dev/null
    _gf_dconf_tmp=$(mktemp "$_gf_dconf/.grassfield.db.XXXXXX" 2>/dev/null) &&
      dconf compile "$_gf_dconf_tmp" "$_gf_dev_root/packaging/dconf/grassfield.d" 2>/dev/null &&
      mv -f "$_gf_dconf_tmp" "$_gf_dconf/grassfield.db" 2>/dev/null
    rm -f "${_gf_dconf_tmp:-}" 2>/dev/null
    unset _gf_dconf_tmp
  fi
  if [[ -s $_gf_dconf/grassfield.db ]]; then
    printf 'user-db:user\nfile-db:%s\n' "$_gf_dconf/grassfield.db" >"$_gf_dconf/profile.new" 2>/dev/null &&
      { cmp -s "$_gf_dconf/profile.new" "$_gf_dconf/profile" 2>/dev/null && rm -f "$_gf_dconf/profile.new" || mv -f "$_gf_dconf/profile.new" "$_gf_dconf/profile"; }
    [[ -r $_gf_dconf/profile ]] && export DCONF_PROFILE=$_gf_dconf/profile
  fi
fi
unset _gf_dconf
unset _gf_dev_root
