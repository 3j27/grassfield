# menubar spec · shell-engineer · M1

## macOS reference behavior (from design/reference/, described in words — no Apple images committed)
Not yet measured (F1 pending). Assumed: 24 px translucent bar across the top; Grassfield mark (system menu) and bold active-application name (application menu) on the left; status items, Control Center icon and clock on the right. Menus open under their title, highlight rows in the accent color, and clicking another title switches menus.

## Purpose and non-goals
Per-screen top bar with the system menu, a T0 application menus (app, File, Window), status menus and the Control Center entry. Non-goals now: T1/T2 app menus (menu bridge ADR-0008), Services and Settings… items, Bluetooth/brightness/media items, notification center.

## Functional requirements
1. One layer-shell window per screen, namespace `grassfield-menubar`, layer Top, exclusive zone 24 px, keyboard focus OnDemand (click the bar, then Tab/Return/Space/Down).
2. Popups are drawn by `qs.overlay` (one full-screen layer-shell window per screen, mapped only while a popup is open, exclusive keyboard focus, click outside closes, the menu bar strip stays clickable). State: `qs.services` `Popups` (kind, anchor, payload).
3. Grassfield menu: About This Computer (real panel: Omarchy NAME/VERSION_ID from `/etc/os-release`, Grassfield version, kernel, hostname, CPU and threads from `/proc/cpuinfo`, memory from `/proc/meminfo`, graphics from `lspci`; read-only), System Settings… (launches `grassfield-settings`; `GRASSFIELD_SETTINGS_CMD` overrides the command in dev), Force Quit… (lists toplevels; the selected app's PID comes from Hyprland window data; `kill -9` only after a second confirmation), Sleep (`systemctl suspend`), Restart…, Shut Down… (confirmation, then `systemctl reboot`/`poweroff`), Lock Screen (PLACEHOLDER, disabled "(coming in M2)"), Log Out <user>… (confirmation, then `hl.dsp.exit()` through the platform layer; Quickshell wraps the request as `hl.dispatch(<request>)` when `Hyprland.usingLua`).
4. Dev guard: with `GRASSFIELD_DEV=1` Sleep, Restart and Shut Down never run `systemctl`; they log a warning and show a notice dialog. Log Out ends only the compositor of the session (the nested one).
5. Application menu (T0, real items only). The bar shows the focused app name (bold) followed by `File` (only when it has real items) and `Window`. The app is identified by foreign-toplevel app id mapped to a desktop entry, never by title. Models are pure (`shell/menubar/model/AppMenuModel.qml`, tested by `tests/unit/tst_appmenumodel.qml`); `AppMenus` (singleton) builds the live context and runs every item through the platform layer. Popup kinds: `app`, `appfile`, `appwindow`.
   - App menu: About <App> (desktop entry name, comment, generic name, id, command; the desktop-entry Version key is not exposed by Quickshell), Hide <App> (moves its windows to `special:hidden`; Dock click or Show All brings them back), Hide Others, Show All (enabled only when something is hidden), Quit <App> (xdg close request for every window of the app; not a kill).
   - File: New Window is shown only when the entry declares a `new-window` desktop action (that action runs), then every other `.desktop` Action as an item. Known limitation: without that action nothing is shown, because launching the entry again is not known to open a new window (`SingleMainWindow=true`, single-instance apps re-activate the existing one) and Quickshell does not expose `SingleMainWindow`. No real item: no File menu.
   - Window: Minimize, Zoom (toggles the maximized state), Enter/Exit Full Screen (toggle through the foreign-toplevel `maximized`/`fullscreen` requests), Move to Desktop > (existing Spaces, the current one checked and disabled, then New Desktop; moves without following), Bring All to Front, then the app's windows (title as plain text, elided to 40 characters, check on the focused one; a minimized window is marked and restored when chosen).
   - Shortcut text comes from one table in `AppMenuModel.qml` that mirrors `config/hypr/grassfield/bindings.lua` (SUPER+H Hide, SUPER+M Minimize, SUPER+ALT+F Zoom, SUPER+CTRL+F Full Screen). Update both together.
   - With a popup open the keyboard focus leaves the app, so the "focused window" of an app is its most recently focused window.
6. Status area, real backends only: Network (Quickshell.Networking: wifi strength icon, wired icon, off icon; menu: Wi-Fi on/off, current network), Volume (Pipewire default sink: icon follows level/mute, scroll ±5 %, menu: volume slider, mute, output device list that selects the default sink), Battery (UPower, hidden when no laptop battery; menu: percentage, time remaining/until full), Control Center icon (see controlcenter.md), clock.
7. Keyboard in menus: Up/Down/Home/End, Return/Space activate, Right opens a submenu, Left closes it, Esc closes. Disabled rows are skipped.
8. Every string uses `qsTr()`; every control has `Accessible.name`/role and a visible focus ring.

## Acceptance criteria
- Screenshots of the system menu, app menu, volume menu and About panel (L2). `qmllint.sh` 0 warnings (L0). `tests/unit/tst_menunav.qml`, `tst_popupmenu.qml` (L0).
- Dev guard: Shut Down confirmation in the nested session logs `suppressed systemctl poweroff` and shows the notice (L2).

## Interfaces / contracts (versions)
Reads `Compositor` (toplevels, focused app, pid, hide, close, exitSession), `Settings`, `Appearance`, `Audio`, `Connectivity`, `Power`, `Popups`. Test hooks (IpcHandler): `menubar open <system|app|appfile|appwindow|...> <output>`, `menubar panel <about|forcequit> <output>`, `menubar close`, `controlcenter <transparency|appearance|reduceTransparency|reduceMotion>`.

`windows` IPC (platform, for key bindings): `windows minimize` (focused window), `windows hide` (focused app).

## Dependencies (verified versions)
Quickshell 0.3.1: PanelWindow, WlrLayershell, BackgroundEffect, SystemClock, DesktopEntries, UPower, Pipewire, Networking, Io (Process, FileView), IpcHandler. Hyprland IPC only inside `shell/platform`.

## Degraded behavior
No battery: item hidden. NetworkManager absent: network menu says so. No PipeWire sink: slider shows 0 and does nothing. No `lspci`: graphics line omitted. Unknown PID: Force Quit disabled.

## Automated tests · Manual verification steps
`scripts/dev/test.sh`. Manual: nested-up, open foot, `qs ipc call menubar open system GF-REF`, `shot.sh`; keyboard flows with `wtype -k Down -k Return` on the nested socket.

## Performance · Accessibility · i18n
Event-driven (no polling). Menus have `Accessible.role: PopupMenu`/`MenuItem`. Strings via `qsTr()`. Clock date pattern is translatable.

## Known limitations
- Zoom and Full Screen use the foreign-toplevel requests; whether a client or Hyprland honors them was checked only for the menu wiring, not per app. Window menu list with several windows is covered by the unit test, the nested screenshot has one window.
- Move to Desktop lists the Spaces of the focused output only; SingleMainWindow is read per entry once (cached for the session).
- The Sleep/Restart/Shut Down paths were exercised only in the dev guard; the real `systemctl` calls are untested by design.
- Submenus are not blurred (only the top-level panel declares a blur region) and no menu uses one yet.
- About "Version" of an app is unavailable. Menu bar items are not reachable with a global shortcut yet (needs a Hyprland binding calling IPC; config/ is not mine).
- Per-screen focus is global: every bar shows the globally focused app. While a popup holds keyboard focus the bar keeps showing the last app.
- Wi-Fi network list/connect and Bluetooth are M2 (Control Center spec).
