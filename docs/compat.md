# Compatibility matrix

Compare these with the installed versions at the start of every session (master-prompt §13).
If Hyprland or Quickshell changed: rebuild the plugin and run the C2 degradation test first.

| Component | Version | Verified | How |
|---|---|---|---|
| Omarchy | 4.0.4 (package; `/usr/share/omarchy/version` says `4.0.0.alpha`) | 2026-10-17 | `pacman -Q omarchy`, `/etc/os-release` |
| Hyprland | 0.56.2 (commit efb50993, tag v0.56.2) | 2026-10-17 | `hyprctl version` |
| Hyprland plugin ABI string | `efb50993780079460b0cbed1363e2166a2de1d9f_aq_0.15_hu_0.14_hg_0.5_hc_0.1_hlg_0.6` | 2026-10-17 | `hyprctl version` |
| Hyprland headers | 0.56.2 | 2026-10-17 | `pkg-config --modversion hyprland` |
| aquamarine / hyprutils | 0.15.0 / 0.14.2 | 2026-10-17 | `pacman -Q` |
| Quickshell | 0.3.1 | 2026-10-17 | `pacman -Q quickshell`, `qs --version` |
| Qt | 6.11.2 | 2026-10-17 | `pacman -Q qt6-base` |
| KIO (KF6) | 6.29.0 | 2026-10-17 | `pacman -Q kio` |
| Compilers | gcc 16.2.1, clang 22.1.8 | 2026-10-17 | `pacman -Q` |
| Mesa | 26.2.2 | 2026-10-17 | `pacman -Q mesa` |
| Kernel | 7.2.5-3-omarchy | 2026-10-17 | `uname -r` |
| grassfield-compositor built for | Hyprland 0.56.2 (ABI efb50993…_aq_0.15_hu_0.14_hg_0.5_hc_0.1_hlg_0.6), via `compositor/build-direct.sh` | 2026-10-17 | plugin log "ABI hash match" in nested |

## Known upstream issues (observed, not caused by Grassfield)
| Component | Issue | Evidence | Impact / mitigation |
|---|---|---|---|
| Hyprland 0.56.2 | SIGSEGV during process exit in `Screenshare::CScreenshareManager` destructor (`CScreenshareSession::~CScreenshareSession` → `screenshareEvents`) when a toplevel capture session is still active | `coredumpctl info 89926` (nested instance, 2026-10-17 02:56, Overview live thumbnails active at compositor exit); no grassfield-compositor frames in the stack | Only at compositor exit (logout). Overview stops captures when it closes; leaves a core dump if the session ends while Overview is open. Report upstream (owner decision). |
| Quickshell 0.3.1 (Arch build, Qt 6.11.2) | SIGSEGV in libc under `Qt::endPropertyUpdateGroup()` ← two unsymbolized quickshell frames ← `QAbstractSocketPrivate::canReadNotification()`, i.e. while a socket read handler applies a batched property update; seen about 1 s after a shell restart in a nested session, right after `quickshell.service.polkit.listener: failed to register listener ... An authentication agent already exists` | Two identical crash stacks (Quickshell crash reporter, 2026-10-21 23:4x, nested dev sessions); 1/10 restarts on main 72176a1, 1/10 and 2/12 on a Dock branch; no Grassfield code in the stack | Nested dev only so far (the polkit agent registers normally in the real session). Owner: watch for "Quickshell crashed" in the real session. Upstream report needs symbols (debuginfod) to name the socket owner, likely the Hyprland IPC event socket. |

## Omarchy dependencies (GF-AUDIT-001, 02 §5.5; remediation of F2, F5, F6, F7)

Grassfield is a separate session over Omarchy (ADR-0001). It reads Omarchy's files and runs a few of its commands; it modifies
none of them and none of the owner's dotfiles. **`scripts/dev/omarchy-compat.sh`** (`just check-omarchy`, also run by
`tests/shell/omarchy_compat.sh`) checks every row below against the installed Omarchy and exits 1 when one is gone or changed
in the way Grassfield relies on. Run it after every Omarchy update (done from the Omarchy session, see below) and before a release.
`/usr/share/omarchy/version` is a stale upstream file (`4.0.0.alpha` at every tag): the include no longer reads it; the gate is the
presence of the modules in the first rows.

| Dependency | Used by | If it disappears |
|---|---|---|
| `$OMARCHY_PATH/default/hypr/{helpers,envs,paths,require_optional,nvidia}.lua`, global `o` | `config/hypr/grassfield/omarchy.lua` (environment, Wayland toolkit variables, GPU variables, PATH) | include skipped, one critical notification at start, journal line `grassfield: Omarchy include`; Grassfield defaults apply |
| `default/hypr/input.lua` (layout from `/etc/vconsole.conf`, `compose:caps`, repeat 40/250, numlock; GF-023) | same | the same defaults are reproduced by the fallback in `omarchy.lua` and one notification says so |
| `~/.config/hypr/{monitors,input}.lua` (owner's files, read only) | same | a failing file is reported, the others still load |
| `bin/omarchy-restart-shell`, `bin/omarchy-launch-shell` and the call chain `omarchy-update-restart` → `omarchy-restart-shell` (GF-032) | shadowed by `/usr/lib/grassfield/omarchy-shims/` (first in PATH: `omarchy.lua` guard_path, `packaging/uwsm/env-grassfield`) | if Omarchy renames them the check fails: the stand-ins no longer cover the update |
| `bin/omarchy-hook`, `omarchy-powerprofiles-init`, `omarchy-powerprofiles-set` | `autostart.lua` (post-boot hooks, power profile at start) | skipped (guarded by `command -v`) |
| `bin/omarchy-migrate` (`--pending`), `omarchy-launch-floating-terminal-with-presentation` | `grassfield-migrate-notify` | no migrations notice |
| user unit `omarchy-sleep-lock` (delay inhibitor, `PrepareForSleep` monitor; `omarchy-system-sleep-lock` calls `omarchy-shell lock lock` and polls `omarchy-shell lock status`) | D-12 fail-safe: drop-in `ExecCondition=/usr/lib/grassfield/sleep-lock-gate` (skipped while grassfield-shell runs), started by `OnFailure=` of grassfield-shell; its `omarchy-shell` calls reach the stand-in in `omarchy-shims`, which starts grassfield-shell again and asks it to lock (docs/specs/security.md "Lock coverage") | renamed unit: no fail-safe after a shell failure; a changed `lock status` JSON contract: Omarchy keeps asking, then reports that the screen did not lock |
| user units `omarchy-crash-watch`, `omarchy-migrate-notify`, `omarchy-update-user-notify` | drop-ins `/usr/lib/systemd/user/<unit>.service.d/10-grassfield.conf` (`ConditionEnvironment=!GRASSFIELD_SESSION=1`) | a renamed unit runs in both sessions and needs the Omarchy shell (check fails; the other `omarchy-*.service` units are listed as info) |
| PAM services `omarchy-lock-password` (+ optional `omarchy-lock-fingerprint`), generated by `omarchy-apply-lock` | `shell/security/lock/Lock.qml` | the lock refuses and stays locked (fails closed) |
| `/usr/local/share/wayland-sessions/omarchy.desktop` (fallback `hyprland-uwsm.desktop`) | `grassfield-login set omarchy` starts its `Exec` line | login falls back to Grassfield |
| SDDM theme `omarchy`: `Main.qml` picks the first session whose name contains `uwsm`; no session list (GF-015) | `/etc/sddm.conf.d/grassfield.conf` (SessionDir, autologin session), entry `Grassfield (uwsm)` | the check fails; `grassfield-login-check` explains |
| `/usr/share/uwsm/env.d/10-omarchy` (OMARCHY_PATH, TERMINAL, EDITOR, mise) | both sessions through uwsm | information only |
| Hyprland Lua API `hl.{bind,on,dispatch,timer,exec_cmd,send_key_state,get_active_window,get_layers,monitor,env,config,gesture}` (stub `/usr/share/hypr/stubs/hl.meta.lua`) | `config/hypr/grassfield/*.lua` | check fails; `just check-config` also parses the config |

What Grassfield provides itself where Omarchy's version needs the Omarchy shell (audit 02 §5.3): crash notifications
(`grassfield-crash-watch.service`: the macOS model, "<App> quit unexpectedly" with Reopen only when a crashed application of the
user is gone: a trusted systemd-coredump entry for an app scope whose cgroup is gone or empty within 10 s; a tool crashing in a
terminal, a helper of a running app, a service and the shell give no notice, the journal keeps every dump; rules in the header
of `packaging/bin/grassfield-crash-watch`, tests in `tests/shell/crash_watch.sh`), low battery at 20/10/5 % (`grassfield-battery-watch.service`), a clickable migrations notice
(`grassfield-migrate-notify.service`; Omarchy's click command travels in a private hint, `omarchy-exec-argv`, that Grassfield's
server does not run, on purpose: any program could otherwise name a command), removable media (`grassfield-automount.service`,
udiskie), Night Shift (`grassfield-nightshift on|off|toggle|status`, hyprsunset; the Control Center switch is shell work),
screenshots (Super+Shift+3/4/5), lid and clamshell (`grassfield-lid`), graceful Log Out / Restart / Shut Down
(`grassfield-session-end`), the keyboard defaults, post-boot hooks and the power profile at start.
Not provided (Omarchy features without a macOS counterpart): Omarchy menu, clipboard history, emoji picker, tmux/herdr key
menus, screen recording bindings, 1Password lock on lock, first-run provisioning.

### Updating Omarchy with Grassfield installed
Run the Omarchy update from the **Omarchy session** (or a TTY): it restarts the Omarchy shell at its end and Omarchy's
pacman hooks reload every Hyprland instance. In a Grassfield session the restart step is shadowed by a no-op
(`tests/shell/omarchy_guard.sh`), so a forgotten update in a Grassfield terminal does no harm, but the Omarchy shell is not
restarted either and `grassfield-shell` is not touched (log out and in to restart it). A reload from Omarchy's hooks still
reaches the Grassfield instance: `grassfield.core` clears its modules and a new Lua state loads the config again (T-OM4 in
the audit: verify in the nested session). After the update: `just check-omarchy`,
`Hyprland --verify-config --config /usr/share/grassfield/hypr/session.lua`, and after a Hyprland upgrade rebuild the plugin
first (ABI hash above).

### Pending for Omarchy 4.0.6 (Qt 6.12, Quickshell 0.3.2): UNVERIFIED here
Omarchy stable is 4.0.6 (installed: 4.0.4); 4.0.5 moves the system to Qt 6.12 and Quickshell 0.3.2. None of this has run on
Grassfield: take a snapshot, update, then run `just test`, `just check-omarchy --require`, the lock and polkit security tests
and the owner L2 list. The lock fixes of 4.0.5/4.0.6 (stale `locked` binding before suspend, stranded-lock takeover) are in
Omarchy's plugin, of which Grassfield's `shell/security/lock/Lock.qml` is an adapted fork (review item for the security
owner; no upstream commit is pinned in the file header).

### Corrections for the documents (integrator)
- ADR-0001, Decision: "If the include fails ... the shell shows one notification" is now true (a critical notification from
  `session.lua`, text fixed); the include is a capability check, no longer the version file; it loads `default.hypr.input` too.
  "XDG_CURRENT_DESKTOP=Hyprland is kept" stays (`packaging/uwsm/env-grassfield` comment fixed): `Hyprland:Grassfield` exists only
  while uwsm prepares the session, so `OnlyShowIn=Grassfield` cannot match; `XDG_SESSION_DESKTOP=Grassfield` identifies it.
- ADR-0002, Keyboard: Ctrl+arrows and Ctrl+1..9 (Spaces) and Ctrl+Up (Overview) are kept as on macOS; Alt+Left/Right,
  Alt+Shift+Left/Right, Alt+Backspace, Alt+Delete are forwarded to the focused window as Ctrl word keys (not in terminals);
  Super+1..9 and Super+Up reach Ctrl+1..9 and Ctrl+Up in the application (Command+number); Super+[ and Super+] send Alt+Left/Right.
- ADR-0009 (per-ABI plugin variants) is still not implemented (one `.so`).
