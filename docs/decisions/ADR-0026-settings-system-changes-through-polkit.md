# ADR-0026: Settings changes the system only through the system services' own polkit actions
Status: Proposed (cloud session, owner brief 2026-10-26: "toute action privilégiée passe par polkit et demande un ADR, plus une
relecture opus") · Date: 2026-10-26 · Decider: owner (brief), integrator (merge after the opus review)

## Context
The General group of the Settings parity work (`docs/specs/settings.md` § macOS 27 parity inventory) needs the first changes
that are not the user's to make alone:
- About > Name: the computer's name (hostname1 `SetPrettyHostname`, `SetStaticHostname`);
- Date & Time: automatic time, the time zone and the time itself (timedate1 `SetNTP`, `SetTimezone`, `SetTime`).

Later groups add printers (CUPS through `cups-pk-helper`) and power profiles. They get their own entry in this ADR, or their own ADR,
before they land.

Grassfield already runs the session's polkit agent (`shell/security/`, Quickshell Polkit, SEC6). Omarchy changes the time zone
with `sudo timedatectl set-timezone` from a terminal menu, and generates locales through its own sudoers rule or `pkexec`
(`omarchy-language`). The Settings app has no terminal, no setuid helper, and must not get one.

Each systemd service declares its own polkit actions:
- hostname1: `org.freedesktop.hostname1.set-static-hostname` and `.set-machine-info`;
- timedate1: `org.freedesktop.timedate1.set-time`, `.set-timezone` and `.set-ntp`.

These actions default to `auth_admin_keep` for the active local session. Each method takes an `interactive` flag that lets the
service ask the session's agent itself.

## Decision
- The Settings app calls the system service's own D-Bus method, with `interactive = true`, on the system bus, from a worker
  thread (`apps/settings/src/systembus.cpp`, `busjobs.h`). The service asks polkit. Polkit asks the session's agent, Grassfield's
  sheet, which shows the message, the action id and the requesting program. The service changes the system only when polkit
  says yes.
- No Grassfield code runs as root: no helper, no `pkexec`, no sudo, no setuid binary, no new polkit policy, no rule file. The
  defaults of each service's own policy apply: the administrator's password, kept for a few minutes (`auth_admin_keep`).
- The call waits for the user's answer for up to 120 s (`kPrivilegedMs`). The job's deadline covers two such calls, 250 s
  (`kPrivilegedJobMs`). The window never blocks. A refusal, a cancelled dialog or no agent at all comes back as the service's
  error and is shown on one line under the group: "The name could not be changed: not allowed: the system refused the request".
  The page then reads the state again. Nothing is retried on its own.
- Every op is validated twice:
  - in QML (`General.js` builds the map or returns null);
  - again in C++ (`validAction`):
    - a computer name: 1 to 64 characters, no control character;
    - a zone: one to four segments of `[A-Za-z0-9_+-]` separated by `/` ("Europe/Paris", "America/Argentina/Buenos_Aires",
      "UTC"), at most 64 characters;
    - a time: microseconds between 2000 and 2200, as a decimal string;
    - NTP: a boolean.
  - The static host name is derived in C++ from the validated name (`hostNameFor`: lower case ASCII letters, digits and `-`,
    63 at most). QML never sends it.
- Dev guard (ADR-0019): in a dev session `Backend.busAct` sends nothing. One `dev guard: … suppressed` line is logged and the
  page shows "dev: not applied". Below that, `GuardedCaller` lets only reads through to these services in a dev session:
  `Properties.Get/GetAll`, timedate1 `ListTimezones`, systemd `ListUnitFilesByPatterns`. A nested session can therefore never
  change the owner's clock or name, whatever the QML asks.
- The language goes through Omarchy's own per-user command (`omarchy-language <code>`, owner decision 2026-10-26). Grassfield
  runs that command as an action: one validated code, one argument vector, no shell, no action in a dev session. What the
  command does is Omarchy's, not Grassfield's (read in Omarchy's upstream sources at commit 58858ae; the installed 4.0.4
  may differ, owner check below):
  - it generates the locale when it is missing: `sudo -n` through Omarchy's passwordless sudoers rule for its own helper
    `omarchy-locale-generate`, else `pkexec omarchy-locale-generate <code>`, whose password dialog is Grassfield's polkit
    agent (the same sheet as the services above);
  - only once the locale exists, it writes the language file and `~/.config/uwsm/env.d/50-omarchy-language` (LANG for the
    next login), seeds an input method for Chinese, Japanese and Korean, runs `hyprctl eval 'hl.env("LANG", …)'` on the live
    compositor (apps started by Hyprland from then on get the new LANG) and `omarchy-restart-shell`, which is the no-op
    shim in a Grassfield session (packaging/shims), and sends a notification;
  - Settings waits up to 130 s (`actionTimeoutMs`), as long as a polkit call above. When that time is up Settings stops the
    command and says "timed out"; a pkexec dialog that is still open stays open (pkexec is a separate process) and can be
    cancelled; answering it then only generates the locale, the language does not change (the command that would have
    written it is gone). The page asks to log out and back in: grassfield-shell keeps its language until then.
- Unprivileged changes stay what they were: the user's own systemd services (`EnableUnitFiles`/`DisableUnitFiles` on the
  session bus, only units under the user's own unit folders) and the user's autostart folder. They are not polkit actions.
  An autostart write or removal touches only a plain `<name>.desktop` of that folder that is not a symbolic link (a write
  would go through the link, to a dotfile manager's file or out of `.dev`), and in a dev session only a folder whose real
  location lies under the worktree's `.dev` (`isAutostartWrite`, systemguard.h; review finding of 2026-10-26).

- Hardware group (PR after #6), NetworkManager. NetworkManager checks its own polkit actions for every client call and lets
  polkit ask the session's agent; the method has no `interactive` argument. Grassfield sends these calls only:
  - Wi-Fi > Forget This Network: `Settings.Connection.Delete` on the saved Wi-Fi profile with that uuid (`wifi.forget`).
    A profile of the whole system needs `org.freedesktop.NetworkManager.settings.modify.system`, `auth_admin_keep` or `yes`
    depending on how the distribution built NetworkManager, so the call may wait for the dialog: 120 s, as above. A profile
    of any other type is refused (a VPN uuid is not a network to forget).
  - Joining a new network (`wifi.connectOpen`, and `wifi.connectSecure` with a WPA/WPA3 personal password):
    `AddAndActivateConnection` adds a profile of the whole system (the same action, `settings.modify.system`), so it waits 120 s
    too. The password goes from the sheet's field to that one call: it is validated (8 to 63 printable ASCII characters or 64
    hex digits) in QML and in C++, never logged (a dev session logs only "wifi join"), and the field is emptied on Join and on
    Cancel; NetworkManager stores it in the profile, as nmcli does. A join that does not come up within 30 s deletes the
    profile it added, so a wrong password leaves no saved network behind.
  - VPN switches: `ActivateConnection` of a `vpn` or `wireguard` profile on no device, `DeactivateConnection` of its active
    connection (`vpn.connect`; `network-control`, `yes` for the active session by default). A VPN that needs a secret it does
    not store needs NetworkManager's secret agent, which Grassfield does not provide: the activation fails with
    NetworkManager's own reason, shown under the list.
  All are validated twice (a uuid, an SSID, a password, a boolean) and are refused by `GuardedCaller` in a dev session
  (`tests/unit/settings/tst_systembus.cpp`, `tests/integration/settings_dbus.sh` section 11).

- Hardware group, Battery:
  - Low Power Mode sets Omarchy's two remembered power profiles with Omarchy's own command, `omarchy-powerprofiles-set
    ac|battery <profile>` (an action: one source and one of the three profiles, nothing else; the source in use last, as the
    command applies what it remembers at once). The command switches the profile with `powerprofilesctl`, through
    power-profiles-daemon and its own polkit action for switching profiles (not read here: owner check); it writes
    the choice under `$XDG_STATE_HOME/omarchy/powerprofiles/`. The shell runs `omarchy-powerprofiles-set autodetect` when the
    power source changes. Neither runs in a dev session.
  - Charging > Limit charging calls UPower's `EnableChargeThreshold(b)` on the battery (`power.chargeLimit`), whose polkit
    action `org.freedesktop.UPower.enable-charging-limit` defaults to `yes` for the active session (read in UPower's sources,
    commit 68438ca); it may wait for the agent like the calls above (120 s). Shown only when UPower says the battery has a
    limit (`ChargeThresholdSupported`).
  - Reads only: `power.state` (UPower's properties, `EnumerateDevices`, `GetHistory`), allowed in a dev session.

## macOS reference
System Settings > General > About > Name and Date & Time change machine-wide settings. They ask for an administrator's password
(the lock, or a sheet) and remember it for a while. Nothing else in the window changes while the system asks.

## Alternatives rejected
- A Grassfield polkit helper (a small root binary with its own policy): a new privileged component, its own attack surface
  and review. The systemd services already are that helper.
- `pkexec timedatectl …` / `pkexec hostnamectl …`: runs a whole program as root for what one D-Bus method does, and puts the
  arguments on a command line.
- `sudo` from a terminal (Omarchy's menu): there is no terminal in Settings, and the brief rules sudo out.
- `interactive = false` with a separate `pkcheck` first: a race between the check and the call, and two prompts.

## Consequences
- Tests:
  - `tests/unit/settings/tst_systembus.cpp`: the exact calls, the `interactive` flag and the derived host name against a canned
    bus.
  - `tests/integration/settings_dbus.sh`: fake hostname1, timedate1 and systemd services on a private bus. Each method, a polkit
    refusal and the dev guard.
  - `tests/unit/tst_settingsgeneral.qml`: the QML-side builders.
- The real polkit dialog cannot be shown in a nested session (the agent cannot register there, `docs/specs/security.md` L5). The
  owner checks it in the real session (L2): change the name and the time zone, cancel once, enter a wrong password once, and
  leave the dialog open for 60 s before answering (the service's own polkit query must still apply the change); switch the
  language to one whose locale is not generated yet (Omarchy's prompt or grant, then log out and in) and back.
- A review by the security reviewer (opus) is required before merge. 2026-10-26: FAIL (an autostart write through a symlinked
  entry; no test of those writes; this ADR silent on what omarchy-language does; a region changing the words; the zone
  wording) → 55d87be → counter-review FAIL (a textual `link/..` path normalised past the folder check) → e0db168 →
  counter-review #2 PASS on the whole scope. Not verified by it: the real polkit dialog, real hostname1/timedate1/systemd,
  the installed omarchy-language, a nested session (owner checks above).
