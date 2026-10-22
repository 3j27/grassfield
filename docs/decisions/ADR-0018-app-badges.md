# ADR-0018: Badges, progress and attention set by applications (Unity LauncherEntry) through grassfield-menu-bridge
Status: Accepted (integrator, 2026-10-22, under the owner's standing instruction to decide with the recommended option
and record it; to be implemented in one slice, reviewed like ADR-0008's bridge work) · Date: 2026-10-22 · Decider:
integrator

## Context
- macOS: an application sets its own Dock badge (`NSDockTile.badgeLabel`) and progress (a bar on the tile, e.g. a copy
  or a download); the Dock never derives them. Grassfield's Dock derives a red count from the notification history
  (`DockModel.badgeCount`, docs/specs/dock.md requirement 14) and has no progress at all (2026-10-22 Dock audit,
  parity checklist row "Badges and progress set by the app itself").
- Linux de facto API: `com.canonical.Unity.LauncherEntry`. An application emits the signal
  `Update(s app_uri, a{sv} properties)` on the session bus, `app_uri` = `application://<desktop id>.desktop`, with any of
  `count` (x), `count-visible` (b), `progress` (d, 0..1), `progress-visible` (b), `urgent` (b) (`quicklist` exists and is
  out of scope). Used by Chromium/Electron (`app.setBadgeCount`, so Discord, Slack, Signal...), Firefox downloads
  progress, Telegram, Thunderbird; KDE's task manager and several docks read it.
- Quickshell 0.3.1 has no generic D-Bus API (VERIFIED 2026-10-22: /usr/lib/qt6/qml/Quickshell/ exposes only DBusMenu,
  Mpris, StatusNotifier and Bluetooth modules), so the shell cannot subscribe to this signal itself.
- `grassfield-menu-bridge` (ADR-0008) is already a QtDBus process on the session bus (the private bus in dev), with
  input limits, penalties and a JSON-lines socket to the shell (`menu/1`, bridges/menu-bridge/src/Protocol.h).

## Options
1. Extend grassfield-menu-bridge: subscribe to the LauncherEntry signal, validate, forward a small message to the
   shell. No new process, reuses the bridge's safety code and lifetime (started with the shell, private bus in dev).
2. A new helper process for this signal only: a new service and package content for one signal (CLAUDE.md: no new
   service without need).
3. `busctl --user monitor` / `gdbus monitor` through a Quickshell Process and parse its text: fragile output parsing,
   a monitor connection sees far more than this signal.

## Decision
Option 1. The bridge adds a match rule for `type='signal',interface='com.canonical.Unity.LauncherEntry',member='Update'`
and forwards each accepted update to the shell as a new, optional message of the existing protocol:
`{"type":"launcher","app":"<desktop id>","count":N|null,"progress":P|null,"urgent":true|false|null}` (`null`: the
property was not part of this update; `count-visible:false` / `progress-visible:false` are sent as `count:0` /
`progress:-1`, meaning "hide"). Old shells ignore unknown types; the protocol stays `menu/1` (additive).

Untrusted input (any client may emit the signal):
- `app_uri` must be `application://` + a desktop id of at most 255 bytes made of `[A-Za-z0-9._-]` + `.desktop`;
  anything else is dropped and counts as a penalty for the sender (Penalties.cpp).
- `count` is clamped to 0..99999 (the Dock shows "99+" above 99 as today); `progress` must be finite and is clamped to
  0..1; wrong types are dropped.
- At most 64 apps are tracked; at most 20 updates per second per sender, the excess is dropped (coalescing: the last
  state per app wins); a sender that disconnects keeps nothing (its apps' entries are cleared).
- Spoofing (one client setting another app's badge) is possible on the session bus as in KDE; the effect is cosmetic
  (a number or a bar on a tile). Accepted risk, documented; no PID matching (Electron helpers and portals make it
  unreliable).

Shell (Dock):
- An app that sent a `count` owns its badge: the notification-derived count is not used for that app while its own
  count is known (macOS: the app is authoritative); apps that never send one keep today's derived count.
- Progress: a thin bar near the bottom of the tile (tokens; light/dark; hidden at -1), like macOS' progress on a Dock
  tile.
- `urgent:true` enters the attention state of docs/specs/dock.md requirement 21 (the same bounce); `urgent:false` clears
  it for that app.

## Consequences
- The bridge's name stays (menu bridge); its spec (docs/specs/menu-bridge.md) gains the LauncherEntry section, limits
  and tests (unit tests of the validation and coalescing in tests/unit/menu-bridge, an integration test that emits
  `Update` on the private bus and reads the Dock's state through a fixtures hook).
- In dev the bridge only ever runs on the private bus (shell-run.sh), so no owner application's badge is read.
- Without the bridge (not built, or crashed) the Dock keeps the notification-derived badges: graceful degradation.
