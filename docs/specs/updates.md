# Software Update spec · platform-engineer (client, channel), shell-engineer (pane, badge, menu, banner) · owner brief 2026-10-27
Status: step 0 (this spec and ADR-0033), awaiting the opus review; owner answers O1-O4 of 2026-10-27 included (channel
change through polkit, switch only, badge for Grassfield and Omarchy, the hook link). Nothing is built yet. Step 1 builds the checker, the channel
command, the persistence and the container test. Step 2 builds the pane, the badge, the menu count and the notification,
after the Settings PRs (#6, #8, #9, #10) merge.
Decisions and evidence: `docs/decisions/ADR-0033-software-update.md` (the contract with grassfieldhq/grassfield-packages,
probes P0–P13). UI names: "Software Update" (fr « Mise à jour de logiciels »), "Beta Updates" (fr « Mises à jour bêta »),
"Update Now" (fr « Mettre à jour maintenant »).

## macOS reference behavior (described in words; no Apple image committed)
- System Settings > General > Software Update. A first group has two rows, each with its value text and an info button:
  "Automatic updates" (its sheet has switches: check for updates, download, install the system, install apps, install
  security responses) and "Beta updates" (its sheet has a menu: Off, Public Beta, Developer Beta).
- Below it a status area: "Checking for updates…" with a spinner. Then either the system is up to date (the installed version
  shown) or the updates are listed: the system update with its name, a "More Info…" link to its notes, and "Update Now".
  After an update that needs it: "Restart to finish installing" with "Restart Now".
- Pending updates show a red badge on System Settings in the Dock, on the General row and the Software Update row inside
  System Settings, and a count after "System Settings…" in the Apple menu ("1 update"). A notification announces an update
  found in the background.
- With automatic checks off, opening the pane still checks.
- Measures and parity are taken in step 2 on the reference capture `General-Software-Update.png` (macOS 15; no macOS 26 or
  27 capture exists, `docs/audits/settings-parity-2026-10-26.md`), with that audit's method and the macOS 27 panes' rows,
  groups and type. Visual NOT verified until then.

## Purpose and non-goals
Purpose: show the user, in Grassfield, that a Grassfield release (and Omarchy's) is available, with its notes; let them
start Omarchy's own update; let them choose the stable or beta channel; keep the `[grassfield]` repository working across
Omarchy's own changes.

Non-goals:
- no installation code, no root code in Grassfield (the install is `omarchy update`);
- no automatic download or install;
- no per-package choice, no rollback button (Omarchy's snapshots are the rollback);
- no App Center (master-prompt §4);
- no publication of anything before the owner's decision (ADR-0033 h).

## Functional requirements
Checker (`grassfield-update-check`, a one-shot child of the shell, ADR-0033 d)
- U1. Runs as the user, never as root. It writes only its database folder (`$XDG_CACHE_HOME/grassfield/checkup-db`) and
  returns one JSON object on stdout (at most 256 KiB, `version: 1`). The shell writes it to
  `$XDG_STATE_HOME/grassfield/software-update.json` (0600, atomic, ADR-0020).
- U2. States: `not-set-up` (no `[grassfield]`, no `/etc/pacman.d/grassfield.conf`), `repair` (the file is there, the Include
  line is not), `up-to-date`, `available`, `failed` (with `offline` or `unavailable` and the time of the last success).
  `checking` is the shell's state while the child runs. Every result carries the channel: `stable`, `beta`, or `custom` when
  the Server is not `<base>/<channel>/$arch`.
- U3. `available` lists, from one `checkupdates` run:
  - the Grassfield release (`grassfield-desktop` installed → candidate, pkgver-pkgrel) with its notes;
  - Omarchy's release (`omarchy` or `omarchy-dev`) as `omarchy-update-available` reports it;
  - the number of other package updates.
  Other `grassfield-*` packages are not listed on their own.
- U4. One check at a time, stopped after 180 s. A request while one runs joins it. None runs while `omarchy update` holds
  `$XDG_RUNTIME_DIR/omarchy-update.lock`; the state then says an update is in progress.
- U5. When the Server differs from the one it last synced, the checker deletes its own `[grassfield]` database files first
  (ADR-0033 c, P7).
- U6. Notes: fetched only for an available Grassfield release; https only (`file` in the container test); at most 64 KiB,
  15 s; signature checked with `gpgv` against `/usr/share/pacman/keyrings/grassfield.gpg`; a signer listed in
  `grassfield-revoked` is refused; JSON validated (`version` 1, at most 20 releases, `en` required, at most 8000 characters a
  text, UTF-8). The notes of every release newer than the installed one are shown, newest first, `fr` when the session is
  French and present, else `en`. Anything invalid: no notes, "Release notes are not available" (fr « Les notes de version ne
  sont pas disponibles »).

When it runs (shell)
- U7. `updates.automaticCheck` (bool, default true; schema-generated, ADR-0020): 10 min after the session starts, then every
  6 h, skipped while the shell's connectivity says offline or metered.
- U8. The pane checks when it opens (unless a check finished less than 60 s ago or one is running) and on "Check Now"
  (fr « Vérifier maintenant »), whatever U7 says.
- U9. `omarchy-shell -q omarchy.system-update refresh|clear` (called by `omarchy update`) reaches Grassfield's shim, which
  asks the shell for a check (no other new IPC verb of the shim; everything else keeps failing quietly).
- U10. Settings reads `software-update.json` (bounded read) and asks the shell to check over IPC. Without a shell it runs the
  checker itself and keeps the result in memory.

Actions (never in a dev session)
- U11. "Update Now" runs exactly `omarchy-launch-floating-terminal-with-presentation omarchy-update`, in Omarchy's floating
  terminal. Omarchy asks "Continue with update?" there; the user can cancel. While the update lock is held the button is
  disabled and the pane says the update runs in the terminal. The pane checks again when the lock is released.
- U12. "Beta Updates" (Off / Grassfield Beta) runs `grassfield-channel-set beta` or `grassfield-channel-set stable` as a child
  process of Settings, with no terminal. The polkit dialog asks for the administrator's password; the row says "Waiting for
  permission…" meanwhile, up to 120 s. A refusal or a cancel shows one line ("Beta updates were not changed: not allowed"),
  and nothing is retried. The shown value is read from `/etc/pacman.d/grassfield.conf` (watched), never stored per user; the
  switch shows the old value until the file changes. Switching installs nothing (O2); the pane then checks.
- U13. "Set Up…" (`not-set-up`) runs `grassfield-channel-set stable`; "Repair…" (`repair`) runs `grassfield-channel-set
  repair`. Both work as U12 does.
- U14. After a Grassfield update in this session (GF-083's `updatePending`), the pane shows "Log out to finish updating
  Grassfield" with "Log Out…". When Omarchy's `~/.local/state/omarchy/reboot-required` exists or the running kernel's modules
  are gone, it shows "Restart to finish updating" with "Restart…" instead. Both use the existing session-end path.

`grassfield-channel-set` and `grassfield-channel-helper` (ADR-0033 a–c; owner decision O1: polkit)
- U15. `grassfield-channel-set` (the user's command; it refuses to run as root):
  - with no argument it prints the channel (`stable`, `beta`, `off`, `repair`, `custom`);
  - `stable` and `beta` set up or switch: `pkexec grassfield-channel-helper set <channel>`, then the hook link;
  - `repair` runs the helper's `restore`, then the hook link;
  - `off` runs the helper's `off`, then removes the hook link.
  Exit 0 on success; 1 on a refusal, a cancelled or refused authentication, or a failed step (the message names it).
- U16. `grassfield-channel-helper` (root, through pkexec only; opus security review) accepts exactly `set stable`, `set beta`,
  `restore`, `off`.
  - Order of `set`: validate; bootstrap the trust if needed (pinned fingerprint, the shipped key file checked against it,
    `pacman-key --add`, `--lsign-key`); write the section from the packaged template (to `.new`, then a rename); append the
    Include line if missing (temporary file in `/etc`, rename, mode kept); drop pacman's synced `[grassfield]` files.
  - A step that fails stops the helper and leaves `pacman.conf` valid: the Include line is never present without its file.
  - It installs no package (`grassfield-keyring` comes as a dependency of `grassfield-desktop`), uses no network, reads no
    environment variable and writes nothing in a user's home.
- U17. The hook `pre-refresh-pacman` (linked by `grassfield-channel-set`, owner decision O4) adds the Include line with `sudo
  sed` (Omarchy's warm sudo cache) when the file exists and the line is missing; otherwise it does nothing. It never writes
  the section itself.

Badge, menu, notification (step 2)
- U18. The Dock's Settings tile shows the number of available releases (0, 1 or 2: Grassfield, Omarchy), set by the shell as
  that application's own count (ADR-0018: the count of an app that sets one wins over the notification-derived one).
- U19. The Grassfield menu's "Settings…" item shows "1 update" / "2 updates" (fr « 1 mise à jour » / « 2 mises à jour »)
  after its label. In Settings, the General row in the sidebar and the Software Update row show the same badge.
- U20. One notification per newly found version (Grassfield or Omarchy), never repeated for a version already announced
  (`software-update.json` keeps the announced versions): title "Grassfield 1.0.1 is available" (fr « Grassfield 1.0.1 est
  disponible »), a click opens Settings > General > Software Update. No banner for a check the user started.

Pane (step 2)
- U21. Layout per the macOS 27 panes (tokens only, light and dark, keyboard, `qsTr` en and fr). First group:
  - "Automatic Updates": value "Check for updates" or "Off"; an info sheet with the one switch Grassfield can honour, and a
    sentence saying that downloading and installing stay manual;
  - "Beta Updates": value "Off" or "Grassfield Beta"; an info sheet with the menu and a sentence on leaving the beta
    (U12, Known limitations).
  Status area: the U2 states; "Grassfield X.Y.Z" with "More Info…" (the notes, U6), "Omarchy X.Y.Z" (the text "Omarchy's
  release notes are on its project page", no link opened by Grassfield), "N other updates", "Update Now"; the installed
  version and the time of the last check when up to date.

## Refusals (what is refused, and what the user sees)
| Case | Behaviour |
|---|---|
| `grassfield-channel-set` run as root (`sudo grassfield-channel-set …`) | refused: "run it as your user; it asks for permission itself" |
| The helper started without root, with another verb or more arguments, or while pacman's `db.lck` exists | refused, nothing changed |
| The polkit dialog cancelled, the password wrong, or no agent | the helper does not run; one line under the row; nothing changed |
| Unknown channel argument | refused, usage printed, nothing changed |
| A build without the pinned signing key, or whose `GRASSFIELD_REPO_BASE` is the `.invalid` placeholder (both the case until the owner provides a key and hosting) | refused: "no signing key in this build" / "no package repository in this build"; the pane hides "Set Up…" and says Software Update is not available in this build (the container tests build their own `repository.conf` with a `file://` base and a throwaway key) |
| The shipped key file is not the pinned fingerprint | refused before `pacman-key` runs |
| `omarchy update` running (its lock held) | `grassfield-channel-set` refuses (and the helper while pacman runs); "Update Now" disabled; no check starts |
| A package unsigned, signed by an unknown or disabled key, or changed after signing | pacman refuses it in Omarchy's terminal, nothing is upgraded (P8, P13); the next check still lists the update |
| A `[grassfield]` database unsigned, badly signed or signed by a revoked key | pacman refuses the database (P5, P7, P8, P13); the checker reports `failed`/`unavailable` |
| Notes unsigned, badly signed, revoked signer, over 64 KiB, not UTF-8, invalid JSON, not https | not shown (U6); the update is still offered |
| A dev session | "Update Now", "Set Up…", "Repair…" and the beta switch log `dev guard: … suppressed` and do nothing; `GRASSFIELD_UPDATE_LAUNCHER` and `GRASSFIELD_UPDATE_PKEXEC` may record the commands |
| A second check while one runs | joins the running one |

## Acceptance criteria (each mapped to a test; level)
| Id | Criterion | Test | Level |
|---|---|---|---|
| A1 | 1.0.0 installed; 1.0.1 published → detected, then installed by `pacman -Syu` | container test (step 1) | L0 (container) |
| A2 | beta: 1.1.0beta1 detected and installed; back to stable: no downgrade, nothing listed; 1.1.0 stable → upgraded | container test | L0 |
| A3 | unsigned, foreign-key and changed packages refused, installed version unchanged | container test | L0 |
| A4 | corrupt database, offline channel: checker exits cleanly with `failed`, no crash, pacman's databases untouched | container test | L0 |
| A5 | Omarchy's `omarchy-refresh-pacman` (v4.0.4 script) overwrites `pacman.conf`: with the hook `[grassfield]` survives; without, the checker says `repair` and `grassfield-channel-set` repairs | container test | L0 |
| A6 | `grassfield-channel-set off` leaves a working pacman (no Include without its file) | container test | L0 |
| A6b | the helper, run as root in the container: every verb, the refusals (verb, `db.lck`, missing or mismatching key file), atomic writes; `grassfield-channel-set` on a recording pkexec stand-in | container test | L0 |
| A7 | channel switch drops the synced database (P7 case passes) | container test | L0 |
| A8 | notes: good, rogue, changed, revoked signer, oversize, bad JSON | checker unit tests (Python, fixtures) | L0 |
| A9 | checker output parsing, states, announced versions, schedule (fake clock), dev guard of the actions | `tests/unit/tst_softwareupdate.qml` with `GRASSFIELD_UPDATE_FIXTURE` | L0 |
| A10 | grassfield-packages' real packages: stable install, update, beta and back, bad signature, the client sees each update | grassfield-packages end-to-end (step 1b) | L0 |
| A11 | pane, badge, menu count, notification, light and dark, en and fr, keyboard | offscreen tests and captures with the fake backend (step 2) | L0/L1 |
| A12 | real flows: the polkit dialog of Set Up… and Beta Updates (cancel once, a wrong password once, then accept), Update Now in Omarchy's floating terminal | owner, real session | L2 |

## Interfaces / contracts (versions)
- ADR-0033 § g (the repository contract; `grassfield-notes.json` version 1).
- `grassfield-update-check` output, version 1: `{"version":1,"state":…,"channel":…,"checkedAt":…,"lastSuccessAt":…,
  "error":…,"grassfield":{"installed":…,"available":…,"notes":[…]},"omarchy":{"installed":…,"available":…},"others":N}`.
- `software-update.json`, version 1: the last output plus `announced` (versions already notified). State class, ADR-0020.
- `grassfield.json`: `updates.automaticCheck` (boolean, default true), schema-generated (ADR-0020).
- Shell IPC: `update check` (Settings → shell). The `omarchy-shell` shim forwards `omarchy.system-update refresh|clear` to it.

## Dependencies (verified versions)
On Omarchy 4.0.4 (its `install/omarchy-base.packages`): `pacman-contrib` (`checkupdates`; P0: 1.13.1-1), `fakeroot`, `jq`,
`gum`, `uwsm`, `xdg-terminal-exec`; pacman 7.1 (P0); gnupg 2.4 (`gpgv`); curl; python; polkit (`pkexec`). `omarchy` 4.0.6
itself depends on `omarchy-keyring`, `pacman-contrib` and `fakeroot`. `pacman-contrib` and `grassfield-keyring` are added to
`grassfield-desktop`'s `depends` in step 1 (declared, not assumed). Omarchy's commands used:
`omarchy-launch-floating-terminal-with-presentation`, `omarchy-update`, `omarchy-hook` (through Omarchy itself).

## Degraded behavior
- `checkupdates` missing: state `failed`/`unavailable` with "pacman-contrib is not installed"; no other effect.
- Omarchy's launcher missing (not an Omarchy system): the actions are disabled, with a sentence; the check still works.
- No shell (Settings alone): Settings runs the checker (U10); no badge, no banner.
- Offline: automatic checks skipped; a manual check fails cleanly (U2, A4).

## Automated tests · Manual verification steps
- Step 1 container test (`tests/integration/software_update.sh`, run only inside a throwaway Arch container, as the ADR's
  probes): the A1–A7 cases with fake packages signed by a throwaway key made in the container, Omarchy's v4.0.4
  `omarchy-refresh-pacman` and migrations, the real `grassfield-channel-set`, hook and checker. Never on the owner's machine.
- Checker unit tests (A8), QML tests (A9), grassfield-packages end-to-end (A10).
- Owner, real session (L2): Set Up… (Grassfield's polkit sheet), Update Now with a published test channel, Beta
  Updates on and off, an Omarchy channel change with the hook, Log Out… after an update.

## Performance (gates affected) · Accessibility · i18n
- No resident process; a check every 6 h at most in the background. `checkupdates` downloads a database only when it changed
  (Omarchy's `extra.db` is about 8.8 MB). P1 (idle CPU) is unaffected. The UI never waits on the child (U1, U4).
- Every control has a name and is reachable by keyboard (A1 gate). Notes are plain text, readable by assistive technology.
- Every string is in `qsTr` (en, fr). The release notes come in en and fr from the channel.

## Known limitations
- Omarchy's own channel change (`omarchy-channel-set`, through `omarchy-refresh-pacman`'s `pacman -Syyuu`) and
  `omarchy-reinstall-pkgs` (`pacman -Suu`) allow downgrades. After leaving the Grassfield beta, they replace the beta with
  the stable version at once (P11), instead of waiting for a newer stable. Omarchy's own packages behave the same way.
- Leaving the beta keeps the beta build until a stable version passes it, so stable-only fixes released meanwhile are not
  received (macOS behaves the same way).
- No automatic download or install, no install at logout: pacman's cache and the install need root, and the owner wants no
  install without the user.
- "Update Now" updates the whole system (Omarchy's update), not Grassfield alone.
- The update runs in Omarchy's terminal; the pane shows no progress.
- A host can replay an old, validly signed database and hold back updates; pacman has no database expiry.
- Omarchy can ship a new Hyprland before the matching plugin is published: the session runs degraded (ADR-0009) until then.
- The channel is per machine. Another user's Omarchy channel change, without their own hook, puts this machine in `repair`
  until someone runs "Repair…".
- `checkupdates` gives one message for every failure ("Cannot fetch updates"): the pane tells offline apart only through the
  shell's connectivity, not an untrusted key from a corrupt database.
- In a nested dev session the polkit agent cannot register (`docs/specs/security.md` L5); the actions are suppressed there
  anyway. In an Omarchy session the dialog is Omarchy's agent, not Grassfield's sheet.
- Nothing is published: until the owner enables hosting, the base is the `.invalid` placeholder and "Set Up…" is hidden
  (Refusals).
- "Software Update" is a descriptive name, as on macOS; it goes on the legal review list with the pane (step 2).
