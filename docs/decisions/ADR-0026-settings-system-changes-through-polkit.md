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
    - a zone: `Area/Location`, at most 64 characters, from `[A-Za-z0-9_+-]`;
    - a time: microseconds between 2000 and 2200, as a decimal string;
    - NTP: a boolean.
  - The static host name is derived in C++ from the validated name (`hostNameFor`: lower case ASCII letters, digits and `-`,
    63 at most). QML never sends it.
- Dev guard (ADR-0019): in a dev session `Backend.busAct` sends nothing. One `dev guard: … suppressed` line is logged and the
  page shows "dev: not applied". Below that, `GuardedCaller` lets only reads through to these services in a dev session:
  `Properties.Get/GetAll`, timedate1 `ListTimezones`, systemd `ListUnitFilesByPatterns`. A nested session can therefore never
  change the owner's clock or name, whatever the QML asks.
- The language goes through Omarchy's own per-user command (`omarchy-language <code>`, owner decision 2026-10-26). Grassfield
  runs that command as an action: one validated code, one argument vector, no shell, no action in a dev session. The privilege
  it may need (generating a locale) is Omarchy's own (its sudoers grant, else `pkexec`), not Grassfield's.
- Unprivileged changes stay what they were: the user's own systemd services (`EnableUnitFiles`/`DisableUnitFiles` on the
  session bus, only units under the user's own unit folders) and the user's autostart folder. They are not polkit actions.

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
  owner checks it in the real session (L2): change the name and the time zone, cancel once, and enter a wrong password once.
- A review by the security reviewer (opus) is required before merge.
