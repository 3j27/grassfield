# ADR-0033: Software Update: a signed [grassfield] pacman repository in two channels, installed through Omarchy
Status: Proposed (cloud session, owner brief 2026-10-27, step 0; no code in either repository before the opus PASS) ·
Date: 2026-10-27 · Decider: owner (every choice in "Owner decisions to validate"), integrator (merge after the opus PASS)

This ADR is the contract between this repository (the desktop, its `PKGBUILD` and the Software Update client) and
`grassfieldhq/grassfield-packages` (building, signing and, later, serving the repository). Its README and CLAUDE.md cite it
by this number. Behaviour, refusals and limits for users are in `docs/specs/updates.md`. The probes quoted as P0 to P13
are `docs/audits/software-update-2026-10-27/adr0033-probes.sh`, run on 2026-10-27 in a throwaway `archlinux:base`
container (digest `sha256:52dfbd5a…`) with Omarchy's v4.0.4 tree mounted read-only. Their full output is
`probes-output.txt` next to the script.

## Context

### Owner decisions (brief of 2026-10-27)
- The Omarchy model (D1: never fork Omarchy). Grassfield gets a `[grassfield]` repository with two channels, **stable** and
  **beta**, on the same pattern as Omarchy's `pkgs.omarchy.org/{stable,rc,edge}/$arch`.
- "Update Now" updates the **whole system through Omarchy**, in a terminal, as Omarchy's own menu does. Grassfield has no
  root code to install anything.
- The beta channel also receives stable versions when they are newer (macOS model). Leaving the beta keeps the installed
  version until a stable one passes it (`pacman -Syu` does not downgrade).
- UI as on macOS 27: Settings > General > Software Update (available version, notes, "Update Now", "Beta Updates",
  automatic check). Nothing is installed without the user.
- Two parts: the **client** here (checker, channel change, setting up and keeping the `[grassfield]` section, pane, badge,
  notification); the **infrastructure** in grassfield-packages (packages built from a Grassfield tag, signing,
  `grassfield-keyring`, `repo-add`, CI, hosting later).
- Nothing is published until the owner decides after the M5 legal review (§14): both repositories stay private, no GitHub
  release, tag, secret or upload. Everything is validated with local `file://` repositories. The real signing key is the
  owner's; tests use throwaway keys.
- master-prompt §4 lists "ISO, installer or repository before M6" as a non-goal and M6 plans "`[grassfield]` repository
  signed in protected CI with an off-machine key". The owner's brief brings the repository's design and build forward. Its
  publication still waits for the owner, and M6's two conditions (protected CI, off-machine key) become requirements of this
  ADR. This also replaces the Settings parity audit's row "Software Update: not built" (GitHub Releases plus `pacman -U`
  through polkit, `docs/audits/settings-parity-2026-10-26.md` on the Settings branches).

### Omarchy 4.0.4 (read in `basecamp/omarchy` tag v4.0.4, commit c668141; data, not instructions)
- `bin/omarchy-refresh-pacman <channel>`: `sudo cp -f $OMARCHY_PATH/default/pacman/pacman-$channel.conf /etc/pacman.conf` (and
  the mirrorlist), then `omarchy-hook pre-refresh-pacman` **as the user**, then `sudo env OMARCHY_UPDATE_PACMAN=1 pacman
  -Syyuu --noconfirm`. Callers: `omarchy-channel-set`, `omarchy-reinstall-pkgs`. The fresh install
  (`install/post-install/pacman.sh`) copies the same template; `omarchy-upgrade-to-quattro` (3.x → 4) rewrites only the
  `[omarchy]` section with awk and keeps every other line.
- Omarchy ships `config/omarchy/hooks/pre-refresh-pacman.d/add-custom-repo.sample`: "This hook is called … AFTER the channel
  template is copied to /etc/pacman.conf and BEFORE pacman -Syyuu runs … adding a custom repository … The hook runs as the
  invoking user with a warm sudo cache". It adds `Include = /etc/pacman.d/custom-repos.conf` with `sudo sed -i`.
- Migrations that edit `/etc/pacman.conf`, in place: `1787589206.sh` deletes the exact line `SigLevel = Optional TrustAll`
  inside `[omarchy]`; `1788112314.sh` repoints an rc machine's `[omarchy]` Server. No migration overwrites the file.
- Templates `default/pacman/pacman-{stable,rc,edge}.conf`: global `SigLevel = Required DatabaseOptional`,
  `LocalFileSigLevel = Optional`; `[core]`, `[extra]`, `[multilib]` from the mirrorlist, `[omarchy]` last. No Include of a
  drop-in folder.
- `omarchy-channel-set`: `omarchy-refresh-pacman`, `pacman -S --needed omarchy omarchy-settings`, then `omarchy-update -y`.
- `omarchy-update-available` (no root): `checkupdates --nocolor`, first line for `omarchy` (or `omarchy-dev`). Omarchy's bar
  runs it at start and every 6 h (`SystemUpdate.qml`, `interval: 21600000`). Its click and the menu entry `update.omarchy`
  run `omarchy-launch-floating-terminal-with-presentation omarchy-update` (`default/omarchy/omarchy-menu.jsonc:341`).
- `omarchy update` (no `-y`): asks "Continue with update?", snapshot, keyrings (`omarchy-update-keyring`), `pacman -Syu`,
  migrations, `post-update` hooks, `omarchy-update-status` (`omarchy-shell -q omarchy.system-update refresh|clear`), then
  `omarchy-update-restart`: a reboot offer when the kernel changed, when `~/.local/state/omarchy/reboot-required` exists or
  when the running Hyprland binary was replaced, then `omarchy-restart-shell`. A pacman hook
  (`00-omarchy-update-guard.hook`, `AbortOnFail`) refuses a direct `pacman -Syu` unless `OMARCHY_UPDATE_PACMAN=1`.
- `omarchy-keyring` 20251027-1 (pkgs.omarchy.org): `/usr/share/pacman/keyrings/omarchy{.gpg,-trusted,-revoked}`, a
  `.INSTALL` running `pacman-key --populate omarchy`. Omarchy bootstraps it in `omarchy-update-keyring`: `pacman-key
  --recv-keys <fingerprint> --keyserver keys.openpgp.org`, `--lsign-key`, `pacman -Sy`, install the keyring package.

### Omarchy's servers (2026-10-27)
- `pkgs.omarchy.org/{stable,rc,edge}/x86_64/omarchy.db`: 200; `stable/x86_64/omarchy.db.sig`: 404 (the database is not
  signed; the packages are, e.g. `omarchy-keyring-20251027-1-any.pkg.tar.zst.sig`). Stable serves `omarchy-4.0.6-1`, rc and edge `omarchy-4.5.0rc1-1`.
- **Hyprland is not in `[omarchy]`.** It comes from Arch's `[extra]` through Omarchy's dated mirrors: `stable-mirror`,
  `rc-mirror`, `mirror.omarchy.org`. All three serve `hyprland-0.56.2-4`, `aquamarine-0.15.1-1`; `hyprutils` is 0.14.2 on
  stable and rc, 0.14.3 on edge and Arch (same minor, so the same plugin ABI string, ADR-0009).
- Omarchy's own plugin package `omarchy-hyprland-titlebars-0.2.2-2` depends on `hyprland=0.56.2` exactly. Grassfield keeps
  ADR-0009 (no pin, degraded mode on a mismatch).

### Grassfield today
- `VERSION` 1.0.0-rc1; `packaging/arch/PKGBUILD`: pkgbase `grassfield`, packages `grassfield-desktop`,
  `grassfield-compositor`, `grassfield-icons`, `pkgver=${VERSION//-/}`, `pkgrel=3` ("restarts at 1 with every new
  VERSION"), built from a `git archive` of the checkout's HEAD.
- `shell/platform/UpdateNotice.qml` (GF-083): "Log out to finish updating" once `/usr/share/grassfield/VERSION` differs from
  what the shell started with or from the plugin's version. The ADR-0009 loader refuses a plugin whose stamp is not the
  running Hyprland's ABI (degraded mode, gate C2, one notice, opt-in user rebuild).
- Shims first in PATH in a Grassfield session (`packaging/shims`): `omarchy-shell` (only `lock lock|status`; anything else
  fails silently with `-q`), `omarchy-restart-shell` (no-op). `grassfield-session-end` clears Omarchy's `re*-required`
  markers on restart and shutdown.

## Decision

### Overview
```
grassfield tag vX.Y.Z[-betaN|-rcN]
  └ grassfield-packages CI: an Arch container with Omarchy stable's package set → makepkg (this repository's PKGBUILD)
      → sign packages, database and notes → repo-add → the channel tree, kept as a CI artifact (published later)
           <base>/stable/x86_64/   <base>/beta/x86_64/
User's machine (Omarchy 4)
  /etc/pacman.conf, last line:   Include = /etc/pacman.d/grassfield.conf   ← put back by Omarchy's pre-refresh-pacman hook
  /etc/pacman.d/grassfield.conf: [grassfield] SigLevel = Required, Server = <base>/<channel>/$arch  ← grassfield-channel-set
  grassfield-shell → grassfield-update-check (the user, checkupdates on its own database) → pane, Dock badge, menu, banner
  "Update Now" → omarchy-launch-floating-terminal-with-presentation omarchy-update        (Omarchy's command, unchanged)
```

### a. The [grassfield] section survives Omarchy
1. The whole section lives in **`/etc/pacman.d/grassfield.conf`**: `[grassfield]`, `SigLevel = Required`, `Server =
   <base>/<channel>/$arch`. Omarchy never writes that file. An Include can open its own section (P2: `pacman-conf
   --repo-list` lists `grassfield`; `--repo grassfield` shows `DatabaseRequired`, `PackageRequired`, the Server).
2. `/etc/pacman.conf` gets **one line, last**: `Include = /etc/pacman.d/grassfield.conf`. Last, so `[grassfield]` comes after
   `core`, `extra`, `multilib` and `omarchy` and never shadows one of their packages (Omarchy's sample puts its Include above
   `[core]`, the highest priority; Grassfield deliberately does not). Nothing may follow it inside the same section: a line
   appended after it joins `[grassfield]` (P2 "after"). A later section header is fine.
3. **The file is never owned by a package.** An Include whose file is missing stops every pacman command (P2: `pacman -Qq
   pacman` → "config file … could not be read", exit 1; a glob that matches nothing fails the same way). A package removal
   that deleted it would break pacman for the whole system. It is written and removed only by `grassfield-channel-set`, and
   `grassfield-channel-set off` removes the Include line **before** the file.
4. **Persistence: Omarchy's own extension point.** `grassfield-channel-set` links
   `~/.config/omarchy/hooks/pre-refresh-pacman.d/50-grassfield` to the packaged
   `/usr/share/grassfield/omarchy-hooks/pre-refresh-pacman`. When `/etc/pacman.d/grassfield.conf` exists and the Include line
   is missing, the hook appends it with `sudo sed -i '$a Include = /etc/pacman.d/grassfield.conf' /etc/pacman.conf`, the
   sample's own technique and its warm sudo cache. Omarchy's `-Syyuu` then syncs `[grassfield]` too (P10: without the hook
   the section is gone and the file stays; with it the line is back, last, and `/var/lib/pacman/sync/grassfield.db` exists).
   A link, not a copy: a package update updates the hook, and after an uninstall the dangling link is skipped silently
   (P11: `omarchy-hook pre-refresh-pacman` exit 0, no "Hook failed").
5. **Fallback.** The checker reads `pacman-conf --repo-list` (no root). No `grassfield` there: if
   `/etc/pacman.d/grassfield.conf` exists, the state is `repair` (the pane says Omarchy reset the package configuration and
   offers "Repair…", which runs `grassfield-channel-set <its channel>` in the terminal); otherwise `not-set-up` ("Set Up…").
   This covers another user's channel change (the hook is per user), a cold sudo cache with no terminal, and a hand edit.
6. First set-up: "Set Up…" in the pane, or `grassfield-channel-set stable` in a terminal. Removal: `grassfield-channel-set
   off` before `pacman -Rns`. If it is skipped nothing breaks (the file stays, the repository stays configured).

Rejected: an alpm hook re-adding the line (Grassfield code as root in every transaction, and no hook fires on Omarchy's
`cp`); the section written straight into `/etc/pacman.conf` (the same loss, more lines to restore); only detection and
"Repair…" (every Omarchy channel change would pause Grassfield updates until the user acts).

### b. Signing and trust
1. `SigLevel = Required` in Grassfield's own section (databases and packages, trusted keys only), so a global change cannot
   weaken it. Omarchy signs packages only; Grassfield signs its **database** too: a database without a valid signature is
   refused (P8: no `grassfield.db.sig` → "failed to synchronize all databases"; P7: a database that does not match its
   signature → "signature … is invalid"). Packages: unsigned (P8 1.1.1), signed by an unknown key (1.1.2, "required key
   missing from keyring"), or changed after signing (1.1.3, "signature … is invalid", "invalid or corrupted package") are
   refused and nothing is upgraded. In each case `pacman -Q` still shows the version installed before.
2. **`grassfield-keyring`**, built in grassfield-packages (infrastructure, like the channel itself; the desktop's single
   build definition, ADR-0023, stays this repository's PKGBUILD): `arch=any`, `pkgver` = date (`YYYYMMDD`),
   `/usr/share/pacman/keyrings/grassfield.gpg`, `grassfield-trusted` (`<fingerprint>:4:` lines), `grassfield-revoked`, and
   an install script running `pacman-key --populate grassfield` (omarchy-keyring's exact layout). The keys are the owner's;
   tests use throwaway keys made in the test container (P3).
3. **Bootstrap (first set-up), Omarchy's model without a keyserver.** This repository pins the signing key:
   `packaging/pacman/repository.conf` holds its fingerprint, and the public key ships beside it. Until the owner provides them
   both are empty and `grassfield-channel-set` refuses ("no signing key in this build"). When the pinned fingerprint is not in
   pacman's keyring, `grassfield-channel-set` checks that the shipped key file is exactly that fingerprint, then runs `sudo
   pacman-key --add` and `--lsign-key <fingerprint>` (P5: before, the database itself is refused, "key … is unknown"; after,
   `grassfield-keyring` and the packages install). Once the section is written it installs `grassfield-keyring` with `sudo
   pacman -Sy --needed grassfield-keyring`, the one partial sync Omarchy also makes for its keyring (`omarchy-update-keyring`:
   "a special case"). From then on keyring updates arrive with every `omarchy update`.
4. **Rotation.** A new key enters `grassfield-keyring` (trusted) and ships signed by the old key. Once that keyring has been
   in both channels for one release cycle, CI signs with the new key. The old key then goes to `grassfield-revoked`, and the
   pinned fingerprint changes in the next release.
5. **Revocation** (P13): a keyring listing a key in `grassfield-revoked` disables it ("Disabled 1 key"), after which a
   database signed by it is refused ("key … is disabled", "database 'grassfield' is not valid"). The channel stops, fail
   closed, until a database signed by a trusted key is served. If the only signing key is compromised, its revocation cannot
   be signed by a key users trust: they must act by hand. Hence owner decision O6: a second, offline key in
   `grassfield-trusted` from the first release.
6. **What the key can do.** Packages run install scripts as root and `omarchy update` runs `pacman --noconfirm`, which
   accepts package replacements. The key is therefore root on every machine. The channel holds only packages named
   `grassfield-*` and none with `replaces=`; grassfield-packages' CI refuses anything else. The master key stays offline;
   only a signing subkey reaches CI, in a protected environment (O6).

### c. Changing the channel (owner decision O1)
Writing `/etc/pacman.d/*` and `/etc/pacman.conf` needs root. Two options; the helper commands are the same in both.
- **A (recommended, the owner's own recommendation and Omarchy's model).** `grassfield-channel-set <stable|beta|off>` is a
  user command (it refuses to run as root: the hook link is the user's). It is run in Omarchy's floating terminal, exactly
  like Omarchy's channel entries:
  `omarchy-launch-floating-terminal-with-presentation 'grassfield-channel-set beta'`. Every privileged step is a system tool
  under `sudo` with fixed arguments: `install` of a root-owned template from the package to `grassfield.conf.new`, then
  `mv -f` (one rename, so pacman never sees the file missing), `sed -i '$a …'`, `rm -f`, `pacman-key`, and the bootstrap's
  `pacman -Sy --needed grassfield-keyring`. The content written to `/etc` comes only from root-owned packaged files
  (`/usr/share/grassfield/pacman/grassfield-{stable,beta}.conf`, generated at build time from `repository.conf`), never from
  a file the user can write. The only variable input is the channel name, checked against that list. No Grassfield code runs
  as root; no polkit policy.
- **B. polkit (ADR-0030's route).** No system service owns `pacman.conf`, so B needs a Grassfield root helper run by
  `pkexec` and a new polkit policy (`org.grassfield.packages.set-channel`, `auth_admin_keep`). That is new privileged code
  and a new policy, which ADR-0030 refused for Settings, plus an opus review of the helper. Gain: a password sheet instead of
  a terminal. The hook of (a) still needs sudo in Omarchy's terminal, so B does not remove sudo.

`grassfield-channel-set` (option A) does, in order: validate; bootstrap trust if needed (b.3); write the section; add the
Include line if missing; **drop pacman's synced `[grassfield]` database** (`sudo rm -f
/var/lib/pacman/sync/grassfield.{db,files}{,.sig}`); link the hook; print the result. The drop matters: after a Server
change, pacman kept the other channel's newer database and fetched the new channel's signature, so every `[grassfield]`
operation failed (P7: "signature … is invalid", even `pacman -Q` prints it); after the drop, `pacman -Syu` works and does not
downgrade (P7). Omarchy reaches the same with `-Syyuu`. With an unsigned database pacman would have used the wrong channel
silently.

**Sub-decision O2.** `grassfield-channel-set` only switches; it does not install. Leaving the beta keeps the installed
version (P7: "local (1.1.0beta1-1) is newer than grassfield (1.0.1-1)", nothing to do; 1.1.0 stable then upgrades). The pane
checks again (it watches `/etc/pacman.d/grassfield.conf`) and offers the beta with "Update Now", as macOS does once beta
updates are on. Omarchy's own `omarchy-channel-set` runs `omarchy-update -y` straight away; doing the same is the
alternative, rejected because the owner asked for no installation without the user.

### d. Checking for updates
1. **`grassfield-update-check`** (Python 3, standard library only, like `grassfield-session-end`; `/usr/lib/grassfield/`)
   is a one-shot child of grassfield-shell. No daemon, no unit (§5.8). It runs as a Quickshell `Process` (asynchronous: the
   UI thread never waits), one at a time, stopped after 180 s, its output capped at 256 KiB. It prints one JSON object
   (`version: 1`).
2. It never runs as root and never touches pacman's databases. `checkupdates` gets its own folder,
   `CHECKUPDATES_DB=$XDG_CACHE_HOME/grassfield/checkup-db` (P6: the user owns that copy, root owns
   `/var/lib/pacman/sync`; P9: pacman's database time is unchanged after the checks). Omarchy's checker uses checkupdates'
   default folder (`/tmp/checkup-db-$UID`, read in pacman-contrib 1.13.1). Sharing it would make the two lock each other
   out. The checker records the Server it synced last and drops its own `[grassfield]` files when the Server changes (P7:
   after a channel change checkupdates otherwise answered "Cannot fetch updates"; after the drop, exit 2).
3. Steps: skip while `omarchy update` holds `$XDG_RUNTIME_DIR/omarchy-update.lock` (as `grassfield-migrate-notify` does);
   `pacman-conf --repo-list` (states `not-set-up`, `repair`); `pacman-conf --repo grassfield Server` gives the channel
   (P6: the Server comes back with `$arch` expanded); `checkupdates --nocolor` (exit 0 updates, 2 none, 1 failure:
   offline, corrupt database or untrusted key all give "Cannot fetch updates", P9); the package lines are split three ways:
   - `[grassfield]` packages: the names that `pacman --dbpath <own db> -Sql grassfield` lists (P6);
   - Omarchy: the line for `omarchy` or `omarchy-dev`, exactly what `omarchy-update-available` reports;
   - everything else: counted only.
4. **What counts as an update** for the badge, the menu and the notification: a Grassfield release (a new
   `grassfield-desktop` version, pkgrel included) and an Omarchy release. Omarchy's bar does not run in a Grassfield session,
   so without this its update would never be shown there. Arch package updates are counted in the pane but raise no badge,
   as in Omarchy. `grassfield-keyring`, `-compositor` and `-icons` ride with them. (Owner decision O3.)
5. **When.** Automatic checks (new setting `updates.automaticCheck`, default on): 10 minutes after login, then every 6 hours
   (Omarchy's interval), skipped while the shell's connectivity says offline or metered. The pane checks when it opens (unless
   a check ran in the last 60 s or one is running) and on "Check Now", even with automatic checks off (macOS). After
   `omarchy update`, its `omarchy-update-status` call reaches Grassfield's `omarchy-shell` shim, which forwards
   `omarchy.system-update refresh|clear` to the shell as "check now". A check downloads databases and notes only, never
   packages.
6. **Failure.** The previous successful result is kept with its time and the failure kind (`offline`, `unavailable`). The
   pane says "Unable to check for updates" and when the last check succeeded. Nothing crashes, nothing retries in a loop
   (the next automatic check, or the user).
7. **Where the result lives.** The shell is the only checker and writes `$XDG_STATE_HOME/grassfield/software-update.json`
   (state class, `version: 1`, ADR-0020). Settings reads it and asks the shell to check (`update check` over IPC). With no
   shell running, Settings runs the checker itself.
8. **Release notes.** The source is `grassfield-notes.json` and its `.sig` next to the channel's database (contract below).
   They are fetched only when a Grassfield update exists, by the user with curl (`--proto =https`, plus `file` in tests;
   `--max-filesize 65536`; `--max-time 15`). They are verified with `gpgv --keyring /usr/share/pacman/keyrings/grassfield.gpg`
   (P12: good signature → `VALIDSIG`, exit 0; a rogue key → exit 2; changed text → exit 1, all as the user), and a
   `VALIDSIG` fingerprint listed in `grassfield-revoked` is refused (gpgv does not read pacman's disabled flag). Invalid or
   missing notes are not shown ("Release notes are not available"); the update is still offered, since pacman verifies the
   packages themselves. The notes are shown as plain text: `Text.PlainText`, no link is opened, control characters except
   line feeds are removed, at most 8000 characters per release.

### e. Versions
- `VERSION` is `X.Y.Z`, `X.Y.Z-betaN` or `X.Y.Z-rcN` (no leading zeros, N ≥ 1). pkgver is `VERSION` without the hyphen (the
  existing PKGBUILD rule). P1, vercmp: `1.0.0rc1 < 1.0.0 < 1.0.1 < 1.1.0beta1 < 1.1.0beta2 < 1.1.0rc1 < 1.1.0`;
  `1.1.0beta9 < 1.1.0beta10`; `1.0.0rc1-3 < 1.0.0-1`; `1.1.0beta1-1 > 1.0.1-1`; `1.1.0-1 > 1.1.0beta1-5`. A dot before the
  suffix is refused: `1.1.0.beta1` sorts after `1.1.0` (P1: `vercmp 1.1.0.beta1 1.1.0` = 1), so such a beta would never be
  replaced by its stable release. `alpha` sorts before `beta` and is not used.
- A version with a suffix goes to **beta** only (1.0.0-rc1 today is a beta-channel build). A plain version goes to
  **stable**, and to beta when vercmp says it is newer than beta's: `repo-add --prevent-downgrade` (P4: "A newer version for
  'grassfield-desktop' is already present in database", "No changes made").
- **pkgrel (owner decision O7).** A rebuild of the same VERSION (a new Hyprland, below) takes pkgrel + 1; a new VERSION starts
  at 1. Recommended: the PKGBUILD reads `GRASSFIELD_PKGREL` (digits only, `^[1-9][0-9]*$`) when it is set and keeps its
  committed pkgrel otherwise. That is a one-line change in step 1, still one build definition; grassfield-packages computes
  the value from the channel. Alternative: a Grassfield commit and tag for every rebuild.

### f. The compositor plugin and Omarchy's Hyprland
- The build container has **an Omarchy stable machine's package set**: Omarchy's stable template shape (`core`, `extra`,
  `multilib` from `stable-mirror.omarchy.org`, `[omarchy]` from `pkgs.omarchy.org/stable`) on an Arch image pinned by digest
  (§11). So Hyprland and also Qt and KDE Frameworks are the versions users run. A build against Arch's current Qt could
  produce binaries that do not start on Omarchy stable. P0 shows the container can be set up that way (`pacman -Syyuu` on
  Omarchy's stable template, exit 0). The build records `pacman -Q` of the container and the plugin's ABI stamp with the
  artifact. The beta channel is built on the same set.
- When Omarchy moves Hyprland before Grassfield is rebuilt, nothing new: the installed plugin's stamp is not the running ABI,
  the session runs degraded (C2) with ADR-0009's one notice and its opt-in user rebuild. grassfield-packages gets a watch job
  (scheduled, disabled while nothing is published): it compares the ABI of the Hyprland in `stable-mirror` and `rc-mirror`
  with the channel's stamp and, on a change, builds pkgrel + 1 of the current releases for the owner to publish. The rc
  mirror gives one cycle of warning (gate C3). Several prebuilt ABI variants in one package (ADR-0009's "can be added
  later") are not part of this work.

### g. The contract between the two repositories
| Item | Value |
|---|---|
| Base URL | `GRASSFIELD_REPO_BASE` in this repository's `packaging/pacman/repository.conf`: the one value hosting changes (h). Until then `https://packages.grassfield.invalid` (RFC 2606, like the PKGBUILD's `url`). grassfield-packages reads it from the checkout it builds. |
| Channel URL | `<base>/<channel>/<arch>/`, channel `stable` or `beta`, arch `x86_64`; Server line `Server = <base>/<channel>/$arch` |
| Repository name | `grassfield`: `grassfield.db`, `grassfield.files`, each with `.sig`. Hosts without symbolic links get the files themselves, not repo-add's links. |
| Packages | exactly the files the database names, each with `.sig`: `grassfield-desktop`, `grassfield-compositor`, `grassfield-icons` (from this PKGBUILD) and `grassfield-keyring` (grassfield-packages). Names `grassfield-*` only, no `replaces=`. |
| Signatures | detached, binary, by a signing subkey of a key in `grassfield-trusted`; packages, both databases and the notes |
| Release notes | `grassfield-notes.json` and `.sig`, UTF-8, at most 64 KiB: `{"version":1,"channel":"stable","releases":[{"version":"1.0.1-1","date":"2026-11-02","notes":{"en":"…","fr":"…"}}]}`. Newest first, at most 20 releases, `version` is grassfield-desktop's pkgver-pkgrel, `en` required, `fr` optional (falls back to `en`), plain text, at most 8000 characters each. |
| Notes source | user-facing text in this repository at the tag: `packaging/release-notes/<VERSION>.en.txt` and `.fr.txt` (CHANGELOG.md is the technical history). A pkgrel rebuild gets a fixed "Rebuilt for Hyprland X.Y.Z" / « Reconstruit pour Hyprland X.Y.Z » from grassfield-packages. |
| Trust anchor | the fingerprint and public key pinned in `repository.conf` (b.3) are in `grassfield-keyring`'s trusted list; CI checks it |
| Build input | a tag (or, for tests, a commit) of grassfield; `VERSION` decides the channel (e); `makepkg` of `packaging/arch/PKGBUILD` unchanged except `GRASSFIELD_PKGREL` (O7) |
| Source access | the repositories are private: grassfield-packages' CI reads grassfield with a read-only deploy key or a fine-grained token (contents: read, grassfield only), both provided later by the owner. Until then the build is tested in a container with both checkouts present. |
| Triggers | `workflow_dispatch` with a `ref` input now. Later, a tag of grassfield via `repository_dispatch` (needs a token in grassfield, owner) or a scheduled tag poll. Publishing is written and disabled. |

### h. Hosting later (after the legal review; owner decision O8)
Every option serves the same tree; enabling one changes `GRASSFIELD_REPO_BASE` and nothing else in code. The owner also
creates the host and provides its credential, and the publishing job runs only when the built tag's base is not the
`.invalid` placeholder.
1. **GitHub Pages** of a public repository (recommended): a static tree exactly as above, deployed atomically from a CI
   artifact (no moment with a new database and missing packages), no tag or release object, and no stored secret in the same
   repository (the job's own token with `pages: write`). Limits: 1 GB per site (one current version per channel fits), about
   100 GB a month of bandwidth (soft).
2. **GitHub Releases** of a public repository (`Server = https://github.com/<org>/<repo>/releases/download/<channel>-$arch`,
   the `[arch-mact2]` pattern Omarchy itself installs): needs a moving tag per channel, flat file names, and replacing assets
   one by one (not atomic: upload packages before the database).
3. **GitLab Pages** or GitLab's generic package registry: the same as 1 or 2 on another account.
4. **Own domain** (static host or object storage plus CDN, as `pkgs.omarchy.org`): most control, a cost and an account.
All of them need either a public repository or a public bucket, so all wait for the legal review.

### i. After an update
- Logging out is needed and enough for a Grassfield update: Hyprland keeps the loaded plugin for the session, and the shell
  and the plugin must stay the same version (ADR-0007's gfc/1 exception rests on it). A shell-only restart would pair a new
  shell with the old plugin, so it is not offered. GF-083's notice stays the one banner. The pane then shows "Log out to
  finish updating Grassfield" with "Log Out…" (the existing graceful logout path; macOS: "Restart to finish installing",
  "Restart Now").
- Omarchy's model is reused **read-only**: when `~/.local/state/omarchy/reboot-required` exists (Omarchy's own fixed path)
  or the running kernel's modules folder is gone (omarchy-update-restart's test), the pane says "Restart to finish updating"
  with "Restart…" instead. Grassfield never writes Omarchy's markers; `grassfield-session-end` already clears them on
  restart. Omarchy's terminal makes its own reboot offer at the end of `omarchy update`; `omarchy-restart-shell` is the
  no-op shim.

### Dev sessions (ADR-0019)
The checker runs in a dev session as in a real one: read-only, with its cache under the dev state. "Update Now", "Set Up…",
"Repair…" and the beta switch never run there (`dev guard: … suppressed`), so a nested session cannot update or reconfigure
the owner's machine. New dev plumbing: `GRASSFIELD_UPDATE_FIXTURE` (a JSON answer used instead of the checker: offscreen
tests and captures), `GRASSFIELD_UPDATE_CHECK_CMD` (the repository's checker), `GRASSFIELD_UPDATE_LAUNCHER` (a recording
stand-in for the terminal launcher).

## Owner decisions to validate
| Id | Question | Options | Recommended |
|---|---|---|---|
| O1 | Channel change (c) | A: `grassfield-channel-set` in Omarchy's terminal with sudo · B: a pkexec helper and a polkit policy | A |
| O2 | After switching to beta | switch only, the pane offers the beta · switch then `omarchy-update -y` (Omarchy) | switch only |
| O3 | What raises the badge, menu count and banner | Grassfield and Omarchy releases · Grassfield only · every package | Grassfield and Omarchy |
| O4 | Grassfield writes a link in `~/.config/omarchy/hooks/pre-refresh-pacman.d/` | yes (a.4) · no, detection and "Repair…" only | yes |
| O5 | Sign the database and the notes | both · packages only (Omarchy's level) | both |
| O6 | Keys | offline master plus a CI signing subkey in a protected environment, and a second offline key trusted from day one · the owner signs every channel by hand | the first |
| O7 | pkgrel of a rebuild | `GRASSFIELD_PKGREL` read by the PKGBUILD · a commit and tag per rebuild | `GRASSFIELD_PKGREL` |
| O8 | Hosting, after the legal review | Pages · Releases · GitLab · own domain | Pages |
| O9 | Release notes source | `packaging/release-notes/<VERSION>.{en,fr}.txt` · CHANGELOG.md sections | the text files |
| O10 | master-prompt §4/M6 | the repository's build and contract now, publication after M5 (this ADR) · wait for M6 | now, unpublished |

## Evidence
`docs/audits/software-update-2026-10-27/adr0033-probes.sh` (P0–P13), output in `probes-output.txt` (docker exit 0). The
probes ran with pacman 7.1.0.r9.g54d9411-3, pacman-contrib 1.13.1-1 and gnupg 2.4.9-3 from Omarchy's stable mirror. One
deviation from Omarchy's template, `DisableSandbox`, is needed because Docker has no Landlock. Omarchy facts were read in
the v4.0.4 tree; server facts were taken with curl on 2026-10-27.

## Consequences
- Step 1, here: `grassfield-channel-set`, `grassfield-update-check`, the hook, `packaging/pacman/` (repository.conf, the two
  section templates generated at build time), the shim's `omarchy.system-update` forward, `pacman-contrib` added to
  `depends` (Omarchy's base has it; declared, not assumed, ARCH-08), the `GRASSFIELD_PKGREL` line (O7), the setting
  `updates.automaticCheck`, `software-update.json`, and a container test (spec § Automated tests). In grassfield-packages:
  the channel build, `grassfield-keyring`, workflows (publishing disabled), the end-to-end exercise with the real packages.
  Step 2 (after the Settings PRs merge): the pane, the badge, the menu count, the notification.
- Code that runs `sudo` (`grassfield-channel-set`, the hook) is privileged code by the brief's rule: named in its PR, opus
  review. Option B would add a root helper and a policy, both reviewed.
- The keys, hosting, source access and the publishing switch remain the owner's; nothing in this ADR publishes anything.
- Known limits are listed in `docs/specs/updates.md`. Among them: Omarchy's own channel change (`-Syyuu`) and
  `omarchy-reinstall-pkgs` (`-Suu`) move a Grassfield beta back to the stable version (P11: "downgrading from version
  1.2.0beta1-1 to version 1.1.0-1"); an old but validly signed database can be replayed (pacman has no expiry); a
  Hyprland update can come before the matching plugin.
