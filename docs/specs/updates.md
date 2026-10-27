# Software Update spec · platform-engineer (client, channel), shell-engineer (pane, badge, menu, banner) · owner brief 2026-10-27
Status: step 0 (this spec and ADR-0033), revised after the first opus review (FAIL, 5 MAJOR); every owner decision of
2026-10-27 (ADR-0033 O1-O20) is included; revised again after the second review. Nothing is built yet. Step 1 builds the checker, the channel command, the
persistence and the container test. Step 2 builds the pane, the badge, the menu count and the notification,
after the Settings PRs (#6, #8, #9, #10) merge.
Decisions and evidence: `docs/decisions/ADR-0033-software-update.md` (the contract with grassfieldhq/grassfield-packages,
probes P0–P13, Q0–Q8 and R0–R5). UI names: "Software Update" (fr « Mise à jour de logiciels »), "Beta Updates" (fr « Mises à jour bêta »),
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
- no installation code (the install is `omarchy update`). The only Grassfield code that runs as root writes pacman's
  configuration for `[grassfield]` and its trust: `grassfield-channel-helper` (pkexec, owner decision O1) and
  `grassfield-channel-scriptlet` (pacman's scriptlets), ADR-0033 c;
- no automatic download or install;
- no per-package choice, no rollback button (Omarchy's snapshots are the rollback);
- no App Center (master-prompt §4);
- no publication of anything before the owner's decision (ADR-0033 h).

## Functional requirements
Checker (`grassfield-update-check`, a one-shot child of the shell, ADR-0033 d)
- U1. Runs as the user, never as root.
  - It writes only under `$XDG_CACHE_HOME/grassfield/`: `checkup-db/`, `health-db/` and `checkup.lock`.
  - It returns one JSON object on stdout (at most 256 KiB, `version: 1`). The shell writes it to
    `$XDG_STATE_HOME/grassfield/software-update.json` (0600, atomic, ADR-0020).
  - It holds `flock -n` on `checkup.lock`, and a second run answers `busy`. Under that lock, a `db.lck` left in its own
    database folders is stale and is removed first (Q8).
  - It is stopped after 180 s: SIGTERM, then SIGKILL 5 s later.
  - Every child runs with stdin from `/dev/null`.
- U2. States:
  - `not-set-up`: no `[grassfield]` and no `/etc/pacman.d/grassfield.conf`;
  - `repair`: the file is there, the `[grassfield]` lines are not;
  - `blocking`: two `[grassfield]`-only syncs in a row (15 minutes apart) failed while the network works, so every
    `omarchy update` fails (U22);
  - `up-to-date`, `available`;
  - `failed`, with `offline` or `unavailable` and the time of the last success;
  - `update-running`: Omarchy's update lock is held (U4).
  `checking` is the shell's state while the child runs. Every result carries the channel: `stable`, `beta`, or `custom` when
  the primary Server is not `<base>/<channel>/$arch` for the current base.
- U3. Before `checkupdates`, the checker syncs `[grassfield]` alone:
  - its own minimal configuration (`[options]` plus the `Include`, no `DisableSandbox`) and its own `health-db/`;
  - under `fakeroot`, with checkupdates' flag `--disable-sandbox-filesystem` (ADR-0033 a2, Q3, R5).
  A first failure with the network up schedules a second sync 15 minutes later; a second failure in a row is `blocking`. A
  success clears the count.
  `available` lists, from one `checkupdates` run:
  - the Grassfield release (`grassfield-desktop` installed → candidate, pkgver-pkgrel) with its notes;
  - Omarchy's release (`omarchy` or `omarchy-dev`) as `omarchy-update-available` reports it;
  - the number of other package updates.
  Other `grassfield-*` packages are not listed on their own.
- U4. One check at a time. A request while one runs joins it.
  - A request while `omarchy update` holds `$XDG_RUNTIME_DIR/omarchy-update.lock` (tested with `flock -n`, released at
    once) is handed to one waiter. The waiter blocks on `flock -x -w 7200` on that file, releases it at once, then checks.
  - This covers the shim's request, which comes from inside `omarchy update` (ADR-0033 d.5, Q8).
  - The state is `update-running` meanwhile.
- U5. When the Server differs from the one it last synced, the checker deletes its own `[grassfield]` database files first
  (ADR-0033 c, P7).
- U6. Notes: fetched only for an available Grassfield release; https only (`file` in the container test); at most 64 KiB,
  15 s; signature checked with `gpgv` against `/usr/share/grassfield/pacman-keyring/grassfield.gpg`. The signer is VALIDSIG's argument
  10, the primary key (argument 1 is a signing subkey, Q7). It must be in `grassfield-trusted` and not in
  `grassfield-revoked`; JSON validated (`version` 1, at most 20 releases, `en` required, at most 8000 characters a
  text, UTF-8). The notes of every release newer than the installed one are shown, newest first, `fr` when the session is
  French and present, else `en`. Anything invalid: no notes, "Release notes are not available" (fr « Les notes de version ne
  sont pas disponibles »).

When it runs (shell)
- U7. `updates.automaticCheck` (bool, default true; schema-generated, ADR-0020): 10 min after the session starts, then every
  6 h, skipped while the shell's connectivity says offline or metered.
- U8. The pane checks when it opens (unless a check finished less than 60 s ago or one is running) and on "Check Now"
  (fr « Vérifier maintenant »), whatever U7 says.
- U9. `omarchy-shell -q omarchy.system-update refresh|clear` (called by `omarchy update`, under its lock) reaches
  Grassfield's shim. The shim only sends the shell a check request, which U4 hands to the waiter. It starts no process
  itself, since a child inheriting Omarchy's lock descriptor would keep the lock. No other IPC verb of the shim is new;
  everything else keeps failing quietly.
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
- U13. "Set Up…" (`not-set-up`) runs `grassfield-channel-set stable`; "Repair…" (`repair`, `custom`) runs
  `grassfield-channel-set repair` (in `custom` it rewrites the file, U15); "Turn Off Grassfield Updates…" (`blocking`, and in the Beta Updates info sheet) runs
  `grassfield-channel-set off`. All work as U12 does.
- U14. After a Grassfield update in this session (GF-083's `updatePending`), the pane shows "Log out to finish updating
  Grassfield" with "Log Out…". When Omarchy's `~/.local/state/omarchy/reboot-required` exists or the running kernel's modules
  are gone, it shows "Restart to finish updating" with "Restart…" instead. Both use the existing session-end path.

`grassfield-channel-set`, `grassfield-channel-helper`, `grassfield-channel-scriptlet` (ADR-0033 a–c; owner decision O1: polkit)
- U15. `grassfield-channel-set` (the user's command; it refuses to run as root):
  - with no argument it prints the channel (`stable`, `beta`, `off`, `repair`, `custom`);
  - `stable` and `beta` set up or switch: `pkexec grassfield-channel-helper set <channel>`, then the hook link;
  - `repair` runs the helper's `restore` in the `repair` state. In the `custom` state it runs `set <channel>` instead, the
    channel named by the Server's path (`/stable/$arch` or `/beta/$arch`), else `stable`. Then it makes the hook link;
  - `off` runs the helper's `off`, then removes the hook link.
  Exit 0 on success; 1 on a refusal, a cancelled or refused authentication, or a failed step (the message names it).
- U16. Two root programs over one library, `grassfield-channel.sh` (opus security review).
  - `grassfield-channel-helper`, the polkit action's program, accepts exactly `set stable`, `set beta`, `restore` and `off`.
    All are refused while pacman's `db.lck` exists.
  - `grassfield-channel-scriptlet`, run only by `grassfield-desktop`'s install script, accepts exactly `remove` (`pre_remove`)
    and `upgrade` (`post_upgrade`), and does not check `db.lck` (pacman holds it).
  - Neither reads an environment variable. Under `pkexec pacman -R`, whose scriptlets inherit `PKEXEC_UID`, the removal still
    takes the section and the keys away.
  - Layout written: two lines at the end of `pacman.conf`, `[grassfield]` and `Include = /etc/pacman.d/grassfield.conf`. The
    file holds `SigLevel = Required` and the `Server` lines, the primary then the mirrors (ADR-0033 a.1, Q4, Q5).
  - Order of `set`:
    1. validate;
    2. the trust bootstrap when the pinned key's validity in pacman's keyring is not full or ultimate (trust, not presence):
       the shipped key file is checked against the pinned fingerprint, then `pacman-key --add` and `--lsign-key`;
    3. `pacman-key --populate-from /usr/share/grassfield/pacman-keyring --populate grassfield`, so a key newer than the
       pinned one is trusted too (R3);
    4. the file from the packaged template (to `.new`, then a rename);
    5. the two lines if missing (temporary file in `/etc`, rename, mode kept);
    6. drop pacman's synced `[grassfield]` files.
  - `off` and the scriptlet's `remove`: the two lines, then the file, then the synced files, then `pacman-key --delete` of every key
    in `grassfield-trusted` and of the pinned key (ADR-0033 b.8, Q6).
  - The scriptlet's `upgrade`: when the primary Server is `<previous base>/<channel>/$arch`, it rewrites the file for that channel
    and drops the synced files; otherwise it does nothing (ADR-0033 h.3).
  - A step that fails stops the helper and leaves `pacman.conf` valid: the `[grassfield]` lines are never present without
    their file.
  - It installs no package (`grassfield-keyring` comes as a dependency of `grassfield-desktop`), uses no network, reads no
    environment variable and writes nothing in a user's home.
- U17. The hook `pre-refresh-pacman` (linked by `grassfield-channel-set`, owner decision O4) adds the two lines with `sudo tee
  -a` (Omarchy's warm sudo cache) when the file exists and `pacman.conf` has no `[grassfield]` line; otherwise it does
  nothing. It never writes the file.
- U22. `blocking` (owner decision O18), only after two failures in a row (U3):
  - the pane says that Grassfield's repository cannot be used and that this stops every system update, and offers "Turn Off
    Grassfield Updates…" (U13);
  - one notification per episode says the same, and its action opens the pane;
  - nothing is turned off without the user;
  - after "Turn Off…", `omarchy update` works again (ADR-0033 a2, Q1).
- U23. `grassfield-keyring` (ADR-0033 b.2, b.8):
  - its files sit in `/usr/share/grassfield/pacman-keyring/`;
  - its install script populates from there only when `grassfield.gpg` is not empty and `/etc/pacman.d/grassfield.conf`
    exists;
  - its `pre_remove` deletes the keys of its trusted list from pacman's keyring.
  After "Turn Off…", a plain `pacman-key --populate` does not trust a Grassfield key again (R2). After `pacman -Rns
  grassfield-desktop grassfield-keyring …` no `[grassfield]` line and no Grassfield key remain, and pacman works (Q6).
  **Until the owner's key exists (O11, O20) it holds no key** and trusts nothing (R1). Test keys are made per run inside
  test containers, never committed or installed elsewhere.

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
| The helper started without root, with another verb or more arguments, or (pkexec verbs) while pacman's `db.lck` exists | refused, nothing changed |
| `grassfield-channel-helper` given a scriptlet verb, or `grassfield-channel-scriptlet` given a helper verb | refused, nothing changed (each program knows only its own verbs) |
| The polkit dialog cancelled, the password wrong, or no agent | the helper does not run; one line under the row; nothing changed |
| Unknown channel argument | refused, usage printed, nothing changed |
| A build without the pinned signing key, or whose `GRASSFIELD_REPO_BASE` is the `.invalid` placeholder (both the case until the owner provides a key and hosting) | refused: "no signing key in this build" / "no package repository in this build"; the pane hides "Set Up…" and says Software Update is not available in this build (the container tests build their own `repository.conf` with a `file://` base and a throwaway key) |
| The shipped key file is not the pinned fingerprint | refused before `pacman-key` runs |
| `omarchy update` running (its lock held) | `grassfield-channel-set` refuses (and the helper while pacman runs); "Update Now" disabled; checks wait for the release (U4) |
| A package unsigned, signed by an unknown or disabled key, or changed after signing | pacman refuses it in Omarchy's terminal, nothing is upgraded (P8, P13); the next check still lists the update |
| A `[grassfield]` database unsigned, badly signed or signed by a revoked key, or a server offline with no mirror answering | pacman refuses the database (P5, P7, P8, P13, Q1) and every `omarchy update` fails; the checker reports `blocking` and offers "Turn Off…" (U22) |
| Notes unsigned, badly signed, revoked signer, over 64 KiB, not UTF-8, invalid JSON, not https | not shown (U6); the update is still offered |
| A first installation from downloaded files (`pacman -U ./…`) | not verified by pacman (`LocalFileSigLevel = Optional`, Q0); not a documented procedure. The verified one is ADR-0033 b.3a (out-of-band fingerprint, `--lsign-key`, install from the repository). The owner accepted the residual risk of the helper's bootstrap (O17). |
| A dev session | "Update Now", "Set Up…", "Repair…", "Turn Off…" and the beta switch log `dev guard: … suppressed` and do nothing; `GRASSFIELD_UPDATE_LAUNCHER` and `GRASSFIELD_UPDATE_PKEXEC` may record the commands |
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
| A7b | layout against Omarchy's rewrites: the 3.x→4 awk, migrations 1787589206, 1788112314 (4.0.4) and 1791403252 (4.0.6) keep `[grassfield]` last (Q4, Q5) | container test | L0 |
| A7c | `blocking`: an offline or badly signed `[grassfield]` is detected by the `[grassfield]`-only sync; "Turn Off" (`off`) makes `pacman -Syu` work again; a mirror covers an offline primary (Q1, Q3) | container test | L0 |
| A7d | `off` and `pacman -Rns`: no `[grassfield]` line, no Grassfield key left, pacman works (Q6) | container test | L0 |
| A7e | host change: the scriptlet's `upgrade` rewrites a config on a previous base, leaves a custom one alone; "Repair…" in `custom` rewrites it | container test | L0 |
| A7g | the keyring: an empty one trusts nothing; after `off` a plain `pacman-key --populate` trusts nothing; `set` populates a newer key (R1–R3) | container test | L0 |
| A7h | `blocking` only after two failures in a row (fake clock) | checker tests | L0 |
| A7i | rollback by a new snapshot; a pointer moved back fails for clients already updated (R4) | grassfield-packages end-to-end | L0 |
| A7f | update lock: a request under the lock waits and checks after the release; a stale `db.lck` is removed (Q8) | checker tests | L0 |
| A8 | notes: good, rogue, changed, revoked signer, oversize, bad JSON | checker unit tests (Python, fixtures) | L0 |
| A9 | checker output parsing, states, announced versions, schedule (fake clock), dev guard of the actions | `tests/unit/tst_softwareupdate.qml` with `GRASSFIELD_UPDATE_FIXTURE` | L0 |
| A10 | grassfield-packages' real packages: stable install, update, beta and back, bad signature, the client sees each update | grassfield-packages end-to-end (step 1b) | L0 |
| A11 | pane, badge, menu count, notification, light and dark, en and fr, keyboard | offscreen tests and captures with the fake backend (step 2) | L0/L1 |
| A12 | real flows: the polkit dialog of Set Up…, Beta Updates and Turn Off… (cancel once, a wrong password once, then accept), Update Now in Omarchy's floating terminal | owner, real session | L2 |

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
`grassfield-desktop`'s `depends` in step 1, with `fakeroot` (declared, not assumed). Omarchy's commands used:
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
- A `[grassfield]` that cannot sync (server down with no mirror answering, a wrong signature, a revoked key) makes every
  `omarchy update` fail, security fixes included, until it is fixed or turned off (U22). Mirrors cover outages, not a bad
  publication (Q1).
- How Landlock treats the user-side check under `fakeroot` on a real Omarchy machine is NOT VERIFIED: Docker refuses
  Landlock (R5). The check uses checkupdates' own `--disable-sandbox-filesystem`.
- A client whose two requests straddle a publication's pointer write gets a mismatched pair once; that `omarchy update` fails,
  the next one works (ADR-0033 h.2).
- The update-lock waiter and the quick test hold Omarchy's lock for microseconds. An `omarchy update` started at that very
  instant reports "already running".
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
- One signing key (owner decision O6): if it is ever compromised, revoking it stops every client's `[grassfield]` (`blocking`)
  until the user turns it off or trusts a new key through the verified first-installation steps (ADR-0033 b.3a, b.5).
- The first `grassfield-desktop` installed is the trust anchor of the helper's bootstrap (owner decision O17). A package
  installed from a file with `pacman -U` is not verified.
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
