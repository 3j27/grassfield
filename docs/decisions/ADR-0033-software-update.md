# ADR-0033: Software Update: a signed [grassfield] pacman repository in two channels, installed through Omarchy
Status: Proposed, applied provisionally until the owner accepts it (cloud session, owner brief 2026-10-27). Step 0 (this
ADR and the spec) passed the opus review on its third round and was merged in 609017f (PR #11); step 1 is grassfield PR
#16 (the client) and the step 1b PR of grassfield-packages. The owner's answers O1-O21 are recorded below; the opus
reviews are in "Review history". ·
Date: 2026-10-27 · Decider: owner (every choice in "Owner decisions"), integrator (merge after the opus PASS)

This ADR is the contract between this repository (the desktop, its `PKGBUILD` and the Software Update client) and
`grassfieldhq/grassfield-packages` (building, signing and, later, serving the repository). Its README and CLAUDE.md cite it
by this number. Behaviour, refusals and limits for users are in `docs/specs/updates.md`. Evidence:
- the probes quoted as P0 to P13 are `docs/audits/software-update-2026-10-27/adr0033-probes.sh`;
- those quoted as Q0 to Q8 (the first review's round) are `adr0033-probes-2.sh` in the same folder;
- those quoted as R0 to R5 (the second review's round) are `adr0033-probes-3.sh` in the same folder.
Both ran in a throwaway `archlinux:base` container ("Evidence" says where and how). Their full outputs sit next to them.

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
- Two parts:
  - the **client**, here: checker, channel change, setting up and keeping the `[grassfield]` section, pane, badge,
    notification;
  - the **infrastructure**, in grassfield-packages: packages built from a Grassfield tag, signing, `grassfield-keyring`,
    `repo-add`, CI, hosting later.
- Nothing is published until the owner decides after the M5 legal review (§14): both repositories stay private, no GitHub
  release, tag, secret or upload. Everything is validated with local `file://` repositories. The real signing key is the
  owner's; tests use throwaway keys.
- master-prompt §4 lists "ISO, installer or repository before M6" as a non-goal, and M6 plans "`[grassfield]` repository
  signed in protected CI with an off-machine key". The owner's brief brings the repository's design and build forward (O10).
  Publication still waits for the owner, and M6's two conditions become requirements of this ADR.
- This replaces the Settings parity audit's row "Software Update: not built" (`docs/audits/settings-parity-2026-10-26.md`).

### Omarchy 4.0.4, the owner's version (`basecamp/omarchy` tag v4.0.4, commit c668141; data, not instructions)
- `bin/omarchy-refresh-pacman <channel>` runs, in order:
  1. `sudo cp -f $OMARCHY_PATH/default/pacman/pacman-$channel.conf /etc/pacman.conf`, and the same for the mirrorlist;
  2. `omarchy-hook pre-refresh-pacman`, **as the user**;
  3. `sudo env OMARCHY_UPDATE_PACMAN=1 pacman -Syyuu --noconfirm`.
  Its callers are `omarchy-channel-set` and `omarchy-reinstall-pkgs`. The fresh install (`install/post-install/pacman.sh`)
  copies the same template.
- `omarchy-upgrade-to-quattro` (3.x → 4) rewrites `[omarchy]` with awk (lines 413-433). That awk drops every line after
  `[omarchy]` up to the next section header, so a lone `Include` placed after `[omarchy]` disappears too (Q4; the reviewer
  reproduced it).
- `config/omarchy/hooks/pre-refresh-pacman.d/add-custom-repo.sample`: "called … AFTER the channel template is copied to
  /etc/pacman.conf and BEFORE pacman -Syyuu runs … adding a custom repository … The hook runs as the invoking user with a warm
  sudo cache". It inserts an `Include` line with `sudo sed -i`.
- Migrations that edit `/etc/pacman.conf`, both in place: `1787589206` deletes the exact line `SigLevel = Optional TrustAll`
  inside `[omarchy]`; `1788112314` repoints an rc machine's `[omarchy]` Server. Q5 runs both where they act.
- Templates `default/pacman/pacman-{stable,rc,edge}.conf`:
  - global `SigLevel = Required DatabaseOptional` and `LocalFileSigLevel = Optional` (Q0: `pacman-conf LocalFileSigLevel` →
    `PackageOptional`, `PackageTrustedOnly`);
  - `[core]`, `[extra]`, `[multilib]` from the mirrorlist, then `[omarchy]` last;
  - no `Include` of a drop-in folder.
- `omarchy-channel-set` runs `omarchy-refresh-pacman`, then `pacman -S --needed omarchy omarchy-settings`, then
  `omarchy-update -y`.
- `omarchy-update-available` (no root) runs `checkupdates --nocolor` and keeps the first line for `omarchy` (or
  `omarchy-dev`). Omarchy's bar runs it at start and every 6 h (`SystemUpdate.qml`, `interval: 21600000`). The bar's click and
  the menu entry `update.omarchy` run `omarchy-launch-floating-terminal-with-presentation omarchy-update`
  (`default/omarchy/omarchy-menu.jsonc:341`).
- `omarchy update` (no `-y`):
  - it takes `${XDG_RUNTIME_DIR:-/tmp}/omarchy-update.lock` (lines 15-16) and asks "Continue with update?";
  - snapshot, keyrings, `pacman -Syu`, migrations, `post-update` hooks;
  - `omarchy-update-status` (line 55, still under the lock): `omarchy-shell -q omarchy.system-update refresh|clear`;
  - `omarchy-update-restart`: a reboot offer when the kernel changed, when `~/.local/state/omarchy/reboot-required` exists or
    when Hyprland was replaced; then `omarchy-restart-shell`.
  A pacman hook (`00-omarchy-update-guard.hook`) refuses a direct `pacman -Syu` without `OMARCHY_UPDATE_PACMAN=1`.
- `omarchy-keyring` 20251027-1: `/usr/share/pacman/keyrings/omarchy{.gpg,-trusted,-revoked}` and an install script running
  `pacman-key --populate omarchy`, with no removal step. `omarchy-update-keyring` bootstraps it (`--recv-keys <fingerprint>
  --keyserver keys.openpgp.org`, `--lsign-key`, `pacman -Sy`, then the keyring package). `omarchy-4.0.6-1` depends on
  `omarchy-keyring`, `pacman-contrib` and `fakeroot`.

### Omarchy 4.0.6, now its stable channel (tag v4.0.6, commit 237f1b4)
Every Omarchy file this ADR relies on is byte-identical to 4.0.4, except these:
- `default/pacman/pacman-*.conf` now put **`[omarchy]` first**, before `[core]`;
- **new migration `1791403252`** moves the `[omarchy]` section of an existing `pacman.conf` to the top (awk by section
  headers, then `omarchy-update-system-pkgs`). A lone `Include` placed after `[omarchy]` would travel with it (Q4);
- the sample hook now inserts its `Include` above `[omarchy]`;
- `omarchy-channel-set` clones from `omacom/omarchy`, and `omarchy-update-keyring` installs `archlinux-keyring` with
  `--needed`.
Files compared with sha256: `bin/omarchy-{refresh-pacman,hook,update,update-available,update-status,update-restart,
update-lock,update-system-pkgs,update-pacman-guard,launch-floating-terminal-with-presentation,state,system-reboot,
reinstall-pkgs}`, `default/libalpm/hooks/00-omarchy-update-guard.hook`, `default/omarchy/omarchy-menu.jsonc`,
`shell/plugins/bar/widgets/SystemUpdate.qml`, migrations `1787589206` and `1788112314`, `install/omarchy-base.packages`.

### Omarchy's servers (2026-10-27)
- `pkgs.omarchy.org/{stable,rc,edge}/x86_64/omarchy.db` answer 200. `stable/x86_64/omarchy.db.sig` answers 404: the database
  is not signed, the packages are. Stable serves `omarchy-4.0.6-1`; rc and edge serve `omarchy-4.5.0rc1-1`.
- **Hyprland is not in `[omarchy]`.** It comes from Arch's `[extra]` through Omarchy's dated mirrors (`stable-mirror`,
  `rc-mirror`, `mirror.omarchy.org`). All three serve `hyprland-0.56.2-4`.
- Omarchy's own plugin package `omarchy-hyprland-titlebars-0.2.2-2` depends on `hyprland=0.56.2`. Grassfield keeps ADR-0009
  (no pin, degraded mode on a mismatch).

### Grassfield today
- `VERSION` is 1.0.0-rc1. `packaging/arch/PKGBUILD` builds `grassfield-desktop`, `grassfield-compositor` and
  `grassfield-icons` from a `git archive` of HEAD, with `pkgver=${VERSION//-/}` and `pkgrel=3`. Its install script is
  `grassfield-desktop.install`.
- `shell/platform/UpdateNotice.qml` (GF-083) shows "Log out to finish updating". The ADR-0009 loader degrades on a
  plugin/Hyprland mismatch.
- Shims in a Grassfield session: `omarchy-shell` (only `lock lock|status`; anything else fails silently with `-q`) and
  `omarchy-restart-shell` (no-op). `grassfield-session-end` clears Omarchy's `re*-required` markers on restart.

## Decision

### Overview
```
grassfield tag vX.Y.Z[-betaN|-rcN]
  └ grassfield-packages CI: an Arch container with Omarchy stable's package set → makepkg (this repository's PKGBUILD)
      → sign packages, database and notes → repo-add → an immutable snapshot of the channel (a CI artifact; published later)
User's machine (Omarchy 4)
  /etc/pacman.conf, last two lines:  [grassfield]
                                     Include = /etc/pacman.d/grassfield.conf   ← put back by Omarchy's pre-refresh-pacman hook
  /etc/pacman.d/grassfield.conf:     SigLevel = Required
                                     Server = <base>/<channel>/$arch   (+ mirrors)
        written only by grassfield-channel-helper (pkexec, from grassfield-channel-set) or grassfield-channel-scriptlet (pacman)
  grassfield-shell → grassfield-update-check (the user; checkupdates and a [grassfield]-only check on its own databases)
        → pane, Dock badge, menu, banners; "Turn Off Grassfield Updates…" when [grassfield] blocks every update
  "Update Now" → omarchy-launch-floating-terminal-with-presentation omarchy-update        (Omarchy's command, unchanged)
```

### a. The [grassfield] section survives Omarchy
1. **Layout.** `/etc/pacman.conf` gets two lines, last: `[grassfield]` and `Include = /etc/pacman.d/grassfield.conf`. This is
   how `[core]` includes its mirrorlist. The included file holds `SigLevel = Required` and the `Server` lines (one per mirror,
   g). Omarchy never writes that file. Why the header sits in `pacman.conf` (round 1 had it in the included file): Omarchy
   rewrites `pacman.conf` section by section.
   - Q4, the 3.x→4 upgrade's awk: the old layout is reduced to `core extra multilib omarchy`; the new one keeps `grassfield`.
   - Q4, 4.0.6's migration 1791403252: the old layout ends as `omarchy grassfield core extra multilib` (Grassfield ahead of
     Arch); the new one as `omarchy core extra multilib grassfield`.
   - Q5: migrations 1788112314 and 1787589206, run where they act (an rc mirror with `[omarchy]` on edge; `SigLevel =
     Optional TrustAll` in `[omarchy]`), leave both lines in place.
   - P2: both layouts parse (`--repo grassfield` shows `DatabaseRequired`, `PackageRequired` and the Server).
2. **Last.** `[grassfield]` comes after every Omarchy and Arch repository (4.0.4 and 4.0.6 templates alike, Q4) and never
   shadows one of their packages. Nothing may be appended after the `Include` without a section header (P2 "after").
3. **Never owned by a package, never left half.** An `Include` whose file is missing stops every pacman command (P2: `pacman
   -Qq pacman` exits 1 with "config file … could not be read"; a glob that matches nothing fails the same way). The file is
   written and removed only by `grassfield-channel-helper` and `grassfield-channel-scriptlet` (c). `off` removes the two lines
   before the file. Uninstalling cannot leave the lines without their file: `grassfield-desktop`'s `pre_remove` runs the
   scriptlet's `remove`, which does what `off` does (c, b.8). In Q6, `pacman -R` of a
   package whose `pre_remove` does the same leaves `--repo-list` without `grassfield` and `pacman -Qq pacman` exits 0.
4. **Persistence: Omarchy's own extension point (O4).** `grassfield-channel-set` links
   `~/.config/omarchy/hooks/pre-refresh-pacman.d/50-grassfield` to the packaged
   `/usr/share/grassfield/omarchy-hooks/pre-refresh-pacman`. When `/etc/pacman.d/grassfield.conf` exists and `pacman.conf` has
   no `[grassfield]` line, the hook appends the two lines with `sudo tee -a`, under the warm sudo cache of Omarchy's sample.
   Omarchy's `-Syyuu` then syncs `[grassfield]` too.
   - P10: without the hook the section is gone and the file stays; with it the two lines are back, last, and
     `/var/lib/pacman/sync/grassfield.db` exists.
   - It is a link, not a copy, so a package update updates the hook.
   - After an uninstall the dangling link is skipped silently (P11: `omarchy-hook pre-refresh-pacman` exit 0, no "Hook
     failed").
5. **Fallback.** The checker reads `pacman-conf --repo-list`, with no root. When `grassfield` is not listed:
   - if `/etc/pacman.d/grassfield.conf` exists, the state is `repair`: the pane says Omarchy reset the package configuration
     and offers "Repair…" (the helper's `restore`, c);
   - otherwise the state is `not-set-up` ("Set Up…").
   This covers another user's Omarchy channel change (the hook is per user), a sudo cache that is cold with no terminal, and a
   hand edit.

Rejected: an alpm hook re-adding the lines (Grassfield code as root in every transaction, and no hook fires on Omarchy's
`cp`); the whole section in `pacman.conf` (more lines to restore, the same loss); detection and "Repair…" alone (every Omarchy
channel change would pause Grassfield updates until the user acts).

### a2. A [grassfield] that cannot sync stops every update
pacman aborts `-Syu` when any database fails to sync.
- Q1: `[grassfield]` offline → "failed to synchronize all databases", exit 1, and `other-pkg 1.1`, waiting in another
  repository, is not installed.
- P7 and P8: a database without its signature or with a mismatched one fails the same way.
So a `[grassfield]` that cannot sync makes **every** `omarchy update` fail, security fixes of Arch and Omarchy included, and
4.0.6's migration 1791403252 with it (it runs `omarchy-update-system-pkgs`). The causes: the server offline, a missing `.sig`,
a rotation done wrong, the only key revoked, an upload caught half way. The defences:
1. **Mirrors.** `grassfield.conf` may hold several `Server` lines. pacman tries the next one when a download fails (Q1: the
   first offline, the second answering → exit 0, `other-pkg` upgraded). It does not when a signature is wrong (Q1: a mismatched
   `.sig` on the first server, a good copy on the second → exit 1). Mirrors therefore cover outages, not bad publications.
2. **Atomic publication (h).** The database and its signature switch together, through one pointer to an immutable snapshot
   (Q2).
3. **Key rotation with an overlap (b.4).**
4. **Detection and "Turn Off" (owner decision O18).** The checker also syncs `[grassfield]` alone, as the user:
   - its own minimal configuration (`[options]` plus the `Include`, no `DisableSandbox`) and its own database;
   - under `fakeroot`, with stdin from `/dev/null`;
   - with checkupdates' own flag `--disable-sandbox-filesystem` (pacman-contrib 1.13.1, line 150).
   Q3: reachable → exit 0; offline → exit 1 within a second; untrusted key → exit 1 at once with "keyring is not writable",
   no prompt. Q3 ran with `DisableSandbox` in that configuration. R5 runs it as specified (no `DisableSandbox`, the flag):
   exit 0. In the same container, root pacman without `DisableSandbox` fails: "the Landlock ruleset could not be applied:
   Operation not permitted", Docker refusing Landlock. With `--disable-sandbox-filesystem` it works. The containers'
   `DisableSandbox` is therefore a Docker necessity. How Landlock behaves for a user under `fakeroot` on a real Omarchy
   machine is NOT VERIFIED here; the flag follows checkupdates, which runs the same way.
   **One failure is not enough:** a failed `[grassfield]`-only sync while online schedules a second one 15 minutes later, and
   only two failures in a row make the state `blocking`. A transient error never raises the notification. In `blocking`:
   - the pane says that Grassfield's repository cannot be used and that this stops every system update;
   - it offers **"Turn Off Grassfield Updates…"**, the helper's `off` behind the polkit dialog;
   - one notification per episode says the same, and its action opens the pane.
   Nothing is turned off without the user. Once turned off, `pacman -Syu` works again (Q1: `--repo-list` without `grassfield`,
   exit 0), and "Set Up…" brings the section back later.
5. **Documented** as a known limit in the spec.

### b. Signing and trust
1. **What is signed (O5).** `SigLevel = Required` in Grassfield's own file covers both databases and packages, with trusted
   keys only, so a change to the global setting cannot weaken it. Omarchy signs only its packages; Grassfield signs its
   database too:
   - P8: no `grassfield.db.sig` → "failed to synchronize all databases";
   - P7: a database that does not match its signature → "signature … is invalid".
   Packages are refused in three cases, and nothing is upgraded (`pacman -Q` keeps the version installed before):
   - unsigned (P8, 1.1.1);
   - signed by an unknown key (1.1.2, "required key missing from keyring");
   - changed after signing (1.1.3, "signature … is invalid").
2. **`grassfield-keyring`**, built in grassfield-packages (infrastructure; the desktop's single build definition, ADR-0023,
   stays this repository's PKGBUILD):
   - `arch=any`, `pkgver` = date (`YYYYMMDD`);
   - `grassfield.gpg`, `grassfield-trusted` (`<fingerprint>:4:` lines) and `grassfield-revoked`, in a **private folder,
     `/usr/share/grassfield/pacman-keyring/`**, not in `/usr/share/pacman/keyrings/`;
   - an install script whose `post_install`/`post_upgrade` run `pacman-key --populate-from
     /usr/share/grassfield/pacman-keyring --populate grassfield`, only when `grassfield.gpg` is not empty and
     `/etc/pacman.d/grassfield.conf` exists (Grassfield updates are on);
   - a `pre_remove` step (b.8).
   This departs from omarchy-keyring's layout on purpose (R2):
   - in `/usr/share/pacman/keyrings/`, a plain `pacman-key --populate`, run by a user or by any other keyring's install,
     made a key that "Turn Off…" had deleted trusted again (`f`);
   - in the private folder it stays absent, and only `--populate-from` brings it back;
   - an upgrade of the keyring package while Grassfield updates are off trusts nothing.
   `grassfield-desktop` depends on it, as `omarchy` depends on `omarchy-keyring` (O12).
   **Until the owner's key exists (O11, owner decision O20), `grassfield-keyring` holds no key** (empty files). It installs
   and trusts nothing (R1: 184 keys in pacman's keyring before and after; the install script skips an empty keyring, since
   `--populate` of it only prints "no valid OpenPGP data found"). So the owner's machine, which needs the package for local
   `makepkg -si` builds (O12), never trusts a test key.
   **Test keys** are generated at each test run, inside the throwaway test container (P3, Q0, R0). They are never committed,
   never installed outside a container, and never part of a published artifact. A test keyring is built inside the container
   from them and dies with it.
3. **Bootstrap by the helper (kept, owner decision O17).** This repository pins the signing key: `packaging/pacman/
   repository.conf` holds its fingerprint, and the public key ships beside it. Until the owner provides them (O11), both are
   empty and `grassfield-channel-set` refuses ("no signing key in this build"). The helper's `set` tests the key's **trust**,
   not its presence: its validity in pacman's keyring must be full or ultimate (`--with-colons`). pacman can import a key on
   its own (P5: "Import PGP key …? [Y/n]"), which leaves it present but untrusted. When the key is not trusted, `set` checks
   that the shipped key file has exactly the pinned fingerprint, then runs `pacman-key --add` and `--lsign-key <fingerprint>`
   (P5: before, the database is refused, "key … is unknown"; after, the packages install). `set` then always runs
   `pacman-key --populate-from /usr/share/grassfield/pacman-keyring --populate grassfield`, so every key of the installed
   keyring is trusted again, including one newer than the pinned key, and every revoked one disabled. R3: after "Turn Off…",
   trusting only the pinned K1 left a database signed by the newer K2 refused ("key … is unknown"); after `--populate-from`,
   `pacman -Sy` and the install worked.
   Residual risk, accepted by the owner: the first `grassfield-desktop` installed is the trust anchor. A package installed
   with `pacman -U ./file` is not verified (`LocalFileSigLevel = Optional`, Q0) and could pin a key of its own. The first
   installation is therefore specified as a verified procedure (b.3a); `pacman -U` of downloaded files is not one.
3a. **First installation, verified.** The signing key's fingerprint is published out of band: at least two places the owner
   controls, such as the project site and the public repository's README, once hosting exists. The documented steps:
   1. `sudo pacman-key --recv-keys <FINGERPRINT> --keyserver keys.openpgp.org` (gpg checks that the key it receives has that
      fingerprint). Without a keyserver: `sudo pacman-key --add grassfield.asc`, downloaded from the host.
   2. `sudo pacman-key --lsign-key <FINGERPRINT>`. It signs only a key with exactly that full fingerprint and fails when the
      keyring holds none, so a substituted key file is refused at this step.
   3. The section, by hand this once: `printf 'SigLevel = Required\nServer = <base>/stable/$arch\n' | sudo tee
      /etc/pacman.d/grassfield.conf`, then `printf '\n[grassfield]\nInclude = /etc/pacman.d/grassfield.conf\n' | sudo tee -a
      /etc/pacman.conf`.
   4. `omarchy update` (which syncs `[grassfield]`), then `sudo pacman -S grassfield-desktop grassfield-compositor
      grassfield-icons`. These come from the repository, so every signature is required and checked against the key of step 2
      (P5, P8): an unsigned or foreign package is refused and nothing is installed.
   5. `grassfield-channel-set stable`. It rewrites the hand-written file from the packaged template (with the mirrors),
      populates the installed keyring (b.3), and links the Omarchy hook (a.4). Until then, an Omarchy channel change would
      drop the section.
   The owner's own `makepkg -si` build trusts the owner's own checkout and needs `grassfield-keyring` installed first (O12).
4. **Rotation, with an overlap.** A new key K2 is added to `grassfield-keyring`'s trusted list while K1 still signs. CI starts
   signing with K2 only after that keyring has been in both channels for at least 30 days and one release. K1 stays trusted
   for 30 more days, and only then goes to `grassfield-revoked`. Throughout, any database or package signed by K1 or K2
   verifies, so no client is ever left with a database it cannot check. The key that signs the current database is never
   revoked: that stops every client's update (P13 with Q1).
5. **Revocation and compromise** (P13): a keyring that lists a key in `grassfield-revoked` disables it ("Disabled 1 key").
   After that, a database signed by it is refused ("key … is disabled", "database 'grassfield' is not valid"). With one key
   (O6), a compromise proceeds as follows:
   - the revoking keyring, signed by that key, still installs, and then every client's `[grassfield]` stops;
   - every system update therefore fails (a2) until the user turns Grassfield updates off ("Turn Off…") or trusts a new key
     through b.3a. The owner publishes the incident with those steps, and tells users to come back through b.3a only,
     never through "Set Up…": a user who turned updates off before receiving the revoking keyring would otherwise trust
     the compromised pinned key again (b.3 bootstrap plus populate).
   The owner accepted this rather than a second, offline key trusted from day one.
6. **What the key can do.** A locally signed key is trusted for **every** repository; pacman does not scope keys (Q6: a
   package of another repository, signed by the Grassfield key under `SigLevel = Required`, installs). Packages also run their
   install scripts as root, and `omarchy update` runs `pacman --noconfirm`, which accepts package replacements. The channel
   holds only packages named `grassfield-*`, none with `replaces=`; grassfield-packages' CI refuses anything else.
7. **Where the key lives (O6, one key in CI).** It is a secret (`GRASSFIELD_SIGNING_KEY`, plus
   `GRASSFIELD_SIGNING_PASSPHRASE` if it has one) of a protected GitHub environment of grassfield-packages:
   - only the signing and publishing jobs use it, never on a `pull_request`;
   - the owner approves each run;
   - builds and tests sign with throwaway keys, and every CI build artifact carries the keyless `grassfield-keyring` (U23)
     until O11.
   The owner creates the environment and the secret after M5.
8. **The key leaves with Grassfield.** Grassfield takes back the trust it gave:
   - the helper's `off` deletes from pacman's keyring every key of `grassfield-trusted` and the pinned key (`pacman-key
     --delete`), after removing the section; `off` and the scriptlet's `remove` skip `pacman-key --delete` for an empty
     fingerprint (an empty pin in `repository.conf`, or an empty `grassfield-trusted` list, as with the keyless keyring of
     U23). Since the keyring lives in its private folder (b.2), a later plain `pacman-key --populate` does not trust them
     again (R2);
   - `grassfield-keyring`'s `pre_remove` deletes the keys of its own trusted list. omarchy-keyring has no such step; Grassfield
     adds one;
   - `grassfield-desktop`'s `pre_remove` runs `off`, so `pacman -Rns grassfield-desktop …` leaves no `[grassfield]` and no
     trusted Grassfield key.
   Q6: after `pacman-key --delete`, a package signed by that key is refused in any repository ("key … is unknown"). After
   `pacman -R` of a package whose `pre_remove` deletes it, the key is absent from pacman's keyring.

### c. Changing the channel: a helper behind Grassfield's own polkit action (owner decision O1)
Writing `/etc/pacman.d/*` and `/etc/pacman.conf` needs root, and no system service owns these files, so there is no service
polkit action to call (ADR-0030's route). The owner chose a Grassfield helper behind its own polkit action (option B). The
other option was Omarchy's model, sudo in its floating terminal (A). The pieces:
1. **`/usr/lib/grassfield/grassfield-channel-helper`** and **`/usr/lib/grassfield/grassfield-channel-scriptlet`** are the only
   Grassfield code that runs as root. They are two entry points over one shared library,
   `/usr/lib/grassfield/grassfield-channel.sh`. **They need an opus security review before merge.**
   - Its interface is its argument vector, nothing else.
   - pkexec gives it a clean environment; both set their own `PATH` and `umask 022` and read **no environment variable**.
   - It refuses to run unless its effective uid is 0.
   - It writes to `/etc` only from root-owned packaged files: `/usr/share/grassfield/pacman/grassfield-<channel>.conf`,
     generated at build time from `repository.conf`. Each write goes through a temporary file in the same folder and a rename,
     keeping the mode, so pacman never sees a file missing (P2).
   - It installs no package, uses no network and writes nothing in a user's home. The only variable input is the channel
     name, checked against the two names.

   `grassfield-channel-helper`, the polkit action's only program, knows only these verbs, all refused while pacman's
   `/var/lib/pacman/db.lck` exists:
   - `set stable|beta`:
     1. the trust bootstrap of b.3 when the pinned key is not trusted;
     2. `pacman-key --populate-from … --populate grassfield` (b.3);
     3. the file from the template;
     4. the two lines in `pacman.conf` when missing;
     5. delete pacman's synced `[grassfield]` files (`/var/lib/pacman/sync/grassfield.{db,files}{,.sig}`, below).
   - `restore` ("Repair…" in the `repair` state): the two lines, only when the file exists.
   - `off` ("Turn Off…"): the two lines, then the file, then the synced files, then the keys (b.8).

   `grassfield-channel-scriptlet`, called only by `grassfield-desktop`'s install script (pacman holds `db.lck`, so it does not
   check it), knows only:
   - `remove` (`pre_remove`): what `off` does;
   - `upgrade` (`post_upgrade`): the host migration of h.3.
   It is not the polkit action's program. Through pkexec it falls under polkit's generic `org.freedesktop.policykit.exec`
   (an administrator's password, not kept), the same as running any program as root, so it adds no privilege. Unlike the
   first version of this section, nothing depends on `PKEXEC_UID`. A `pkexec pacman -R grassfield-desktop`, whose scriptlets
   inherit that variable, therefore still removes the section and the keys.

   Editing `pacman.conf` inside a transaction affects only the next run (Q6).
2. **The polkit action** `org.grassfield.packages.set-channel`, in `/usr/share/polkit-1/actions/org.grassfield.packages.policy`:
   - `allow_any` and `allow_inactive` are `no`, `allow_active` is `auth_admin_keep`;
   - `org.freedesktop.policykit.exec.path` is the helper;
   - the message, in English and French: "Authentication is required to change where Grassfield gets its updates" (« Une
     authentification est nécessaire pour changer la source des mises à jour de Grassfield »).
   The dialog is Grassfield's polkit sheet in a Grassfield session (SEC6), Omarchy's agent in an Omarchy session, and pkexec
   itself on a text console.
3. **`grassfield-channel-set [stable|beta|off|repair]`**, in `/usr/bin`, is the user's command; it refuses to run as root.
   - It runs `pkexec <helper> <verb>`, then, as the user, links the hook (or, for `off`, removes the link).
   - `repair` runs `restore` in the `repair` state. In the `custom` state, `restore` would not touch the file, so `repair`
     runs `set <channel>` instead, rewriting it from the template. The channel is the one the file's Server names when its
     path ends in `/stable/$arch` or `/beta/$arch`; otherwise it is `stable`.
   - Without an argument it prints the channel.
   - Settings' "Beta Updates", "Set Up…", "Repair…" and "Turn Off…" run it as a child process, with no terminal, following
     ADR-0030's pattern: a worker; the argument checked in QML and in C++; "Waiting for permission…" while the dialog is up;
     one action at a time; up to 120 s; a refusal or a cancel shown on one line.

The persistence hook (a.4) keeps `sudo tee -a`. It runs inside `omarchy-refresh-pacman`, whose sudo cache is warm, so it adds
no prompt; a pkexec dialog there would interrupt Omarchy's channel change.

**Why `set` drops the synced database.** After a Server change, pacman kept the other channel's newer database and fetched
the new channel's signature, so every `[grassfield]` operation failed (P7: "signature … is invalid"). After the drop, `-Syu`
works and does not downgrade (P7).

**O2: switch only.** Switching installs nothing. Leaving the beta keeps the installed version (P7: "local (1.1.0beta1-1) is
newer than grassfield (1.0.1-1)"). The pane watches `/etc/pacman.d/grassfield.conf`, checks again, and offers the beta with
"Update Now", as macOS does.

Rejected:
- option A, by the owner;
- `pkexec` on `install`, `sed` and `rm` themselves, since a policy for generic programs authorises any argument.

### d. Checking for updates
1. **`grassfield-update-check`** (Python 3, standard library only; `/usr/lib/grassfield/`) is a one-shot child of
   grassfield-shell; there is no daemon (§5.8).
   - It runs as a Quickshell `Process`, asynchronously, so the UI never waits. Its output is capped at 256 KiB, one JSON
     object (`version: 1`).
   - **One at a time:** it holds `flock -n` on `$XDG_CACHE_HOME/grassfield/checkup.lock`, and a second run answers `busy`.
     Because only one checker can run, a `db.lck` left in its own database folder is stale by definition and is removed
     before `checkupdates` runs (Q8: a leftover `db.lck` gives "Cannot fetch updates"; removed, exit 2).
   - It is stopped after 180 s: SIGTERM first, so checkupdates' trap clears its lock, then SIGKILL 5 s later.
   - Every child runs with stdin from `/dev/null`. Q8 saw no hang either way, since the user cannot import a key ("keyring is
     not writable"), but nothing reads a terminal.
2. It never runs as root and never touches pacman's databases (P6, P9). `checkupdates` gets its own folder,
   `CHECKUPDATES_DB=$XDG_CACHE_HOME/grassfield/checkup-db`. Omarchy's checker uses the default `/tmp/checkup-db-$UID`, so the
   two never lock each other out. The checker drops its own `[grassfield]` files when the Server changes (P7).
3. **Steps:**
   1. `pacman-conf --repo-list` → `not-set-up` or `repair`.
   2. `pacman-conf --repo grassfield Server` → the channel (P6: the Server comes back with `$arch` expanded).
   3. The `[grassfield]`-only sync of a2 → `blocking`.
   4. `checkupdates --nocolor`: exit 0 updates, 2 none, 1 failure (P9).
   5. Split the result:
      - `[grassfield]` packages: the names that `pacman --dbpath <own db> -Sql grassfield` lists;
      - Omarchy: the `omarchy` or `omarchy-dev` line;
      - the rest: a count (`others`).
      Step 2 adds the list beside the count (`otherPackages`: name, installed and available version, sorted by name), which
      the pane and the Store (PR #15, ADR-0037) need. When the output would pass its 256 KiB cap, that list is cut first
      (truncated, `otherPackagesTruncated: true`), then the notes (`notesError`); the counts always stay.
4. **What counts as an update (O3)** for the badge, the menu and the notification: a Grassfield release (a new
   `grassfield-desktop` version, pkgrel included) and an Omarchy release.
5. **When.**
   - Automatic checks (`updates.automaticCheck`, default on): 10 minutes after login, then every 6 hours, skipped while
     offline or on a metered connection.
   - The pane checks when it opens and on "Check Now".
   - **During `omarchy update`:** a check that finds the lock held does not run. It hands over to a waiter, which checks once
     the lock is released. This applies to the shim's `omarchy.system-update refresh|clear`, which `omarchy-update-status`
     sends from inside the update while the lock is still held.
     - The waiter opens the lock file and blocks on `flock -x -w 7200`; once it gets the lock it releases it at once, then
       checks (Q8: while `omarchy-update-lock run sleep 3` holds it, the waiter returns 0 when it is released).
     - The quick test before a check is `flock -n`, released at once.
     - For the microseconds either one holds the lock, an `omarchy update` started at that very instant would report
       "already running". This is accepted.
     - A lock-free watch through `/proc/locks` is not relied on: in the test container, `/proc/locks` and `lslocks` showed
       nothing while the lock was held (Q8).
     - The waiter never inherits Omarchy's lock descriptor, since a child holding it would keep the lock: the shim starts
       nothing itself; it only sends the request to the shell.
     The pane says "Update in progress" meanwhile.
   - A check downloads databases and notes only, never packages.
6. **Failure kinds:** `offline`, `unavailable` (a check failed and the cause is not known), and `blocking` (a2, with "Turn
   Off…"). The previous successful result is kept with its time. Nothing crashes, and nothing retries in a loop.
7. **Where the result lives.** The shell is the only checker. It writes `$XDG_STATE_HOME/grassfield/software-update.json`
   (state class, `version: 1`, ADR-0020). Settings reads it and asks the shell to check over IPC; with no shell, Settings runs
   the checker itself.
8. **Release notes.**
   - Source: `grassfield-notes.json` and its `.sig`, in the channel's snapshot.
   - Fetched only for an available Grassfield release, with curl (`--proto =https`, plus `file` in tests; `--max-filesize
     65536`; `--max-time 15`).
   - Verified with `gpgv --keyring /usr/share/grassfield/pacman-keyring/grassfield.gpg --status-fd 1` (the keyring's private
     folder, b.2). The signer is VALIDSIG's
     **argument 10, the primary key's fingerprint**; argument 1 is the subkey that signed (Q7). That primary must be listed in
     `grassfield-trusted` and absent from `grassfield-revoked`. P12: good → exit 0; rogue → exit 2; changed text → exit 1.
   - Invalid or missing notes are not shown; the update is still offered.
   - Display: plain text, no link opened, control characters removed except line feeds, at most 8000 characters per release.

### e. Versions
- `VERSION` is `X.Y.Z`, `X.Y.Z-betaN` or `X.Y.Z-rcN`. pkgver is `VERSION` without the hyphen. P1 (vercmp):
  - `1.0.0rc1 < 1.0.0 < 1.0.1 < 1.1.0beta1 < 1.1.0beta2 < 1.1.0rc1 < 1.1.0`;
  - `1.1.0beta9 < 1.1.0beta10`;
  - `1.1.0beta1-1 > 1.0.1-1`.
  A dot before the suffix is refused: `1.1.0.beta1` sorts after `1.1.0` (`vercmp` = 1).
- A suffixed version goes to beta only (O15). A plain one goes to stable, and to beta when it is newer
  (`repo-add --prevent-downgrade`, P4).
- pkgrel (O7): the PKGBUILD reads `GRASSFIELD_PKGREL` (`^[1-9][0-9]*$`) when it is set and keeps its committed pkgrel
  otherwise.

### f. The compositor plugin and Omarchy's Hyprland
- The build container has an **Omarchy stable machine's package set** (P0): Hyprland, but also Qt and KF6, at the versions
  users run. The build records `pacman -Q` and the plugin's ABI stamp with the artifact.
- When Omarchy moves Hyprland first, ADR-0009's degraded mode and its notice apply. A scheduled watch job compares
  `stable-mirror`'s and `rc-mirror`'s Hyprland ABI with the channel's stamp and builds pkgrel + 1 for the owner to publish.
  The watch job stays disabled while nothing is published.

### g. The contract between the two repositories
| Item | Value |
|---|---|
| Base URLs | `packaging/pacman/repository.conf` in this repository: `GRASSFIELD_REPO_BASE` (the primary; `https://packages.grassfield.invalid` until hosting exists), `GRASSFIELD_REPO_MIRRORS` (more bases serving the same snapshots, each a `Server` line after the primary), `GRASSFIELD_REPO_BASE_PREVIOUS` (bases a migration rewrites, h). grassfield-packages reads them from the checkout it builds. |
| Channel URL | `<base>/<channel>/<arch>/`, channel `stable` or `beta`, arch `x86_64`; `Server = <base>/<channel>/$arch` |
| Repository | `grassfield`: `grassfield.db`, `grassfield.files`, each with `.sig`; real files, not repo-add's links |
| Packages | exactly the files the database names, each with `.sig`: `grassfield-desktop`, `grassfield-compositor`, `grassfield-icons` (this PKGBUILD) and `grassfield-keyring` (grassfield-packages). Names `grassfield-*` only, no `replaces=`. Package file names never change content. |
| Signatures | detached, binary; packages, both databases and the notes; by a key in `grassfield-trusted` or its signing subkey |
| Release notes | `grassfield-notes.json` and `.sig`, UTF-8, at most 64 KiB: `{"version":1,"channel":"stable","releases":[{"version":"1.0.1-1","date":"2026-11-02","notes":{"en":"…","fr":"…"}}]}`. Newest first, at most 20, `en` required, plain text, at most 8000 characters each. |
| Notes source | `packaging/release-notes/<VERSION>.{en,fr}.txt` in this repository at the tag (O9). A pkgrel rebuild gets "Rebuilt for Hyprland X.Y.Z" / « Reconstruit pour Hyprland X.Y.Z ». |
| Publication | atomic (h): an immutable snapshot, then one pointer write |
| Trust anchor | the pinned fingerprint and key (b.3) are in `grassfield-keyring`'s trusted list; CI checks it |
| Build input | a tag (or, for tests, a commit) of grassfield; `VERSION` decides the channel; `makepkg` of `packaging/arch/PKGBUILD` with `GRASSFIELD_PKGREL` |
| Source access | a read-only deploy key on grassfield (O13), secret `GRASSFIELD_DEPLOY_KEY`. Until it exists, the build is tested in a container with both checkouts. |
| Triggers | a poll of grassfield's tags every 15 minutes (O14; GitHub may start scheduled runs late), only when the deploy key exists. A tag is built once. `workflow_dispatch` with a `ref` stays for manual runs. Publishing is written and disabled. |
| From the owner, later | `GRASSFIELD_DEPLOY_KEY`; `GRASSFIELD_SIGNING_KEY` and its passphrase (b.7); `GRASSFIELD_S3_ACCESS_KEY_ID` and `GRASSFIELD_S3_SECRET_ACCESS_KEY` (write to the bucket only); the bucket name and S3 endpoint (variables); the public key, its fingerprint and the host name (this repository). None is created by the agent. |

### h. Hosting: own domain on S3-compatible storage behind a CDN (O8; activated after the legal review)
1. **The tree.** A bucket of S3-compatible storage (Cloudflare R2, AWS S3 or an equivalent) behind a CDN and a host name of
   the owner's, decided later. The publishing job runs only when the built tag's primary base is not the `.invalid`
   placeholder and the credentials exist.
2. **Atomic publication.** The fixed names of a channel are not objects: `grassfield.db`, `grassfield.files`, the notes and
   their signatures. The CDN's edge rule answers them with a redirect (302, not cached) to
   `<channel>/<arch>/snap/<id>/<name>`, where `<id>` comes from one pointer object (not cached). A publication runs in order:
   1. upload the packages, which have immutable names;
   2. upload a complete new snapshot;
   3. write the pointer, once.
   Snapshots are kept for 7 days. Q2: pacman followed the redirects for the database and its signature (`302`, then `200` from
   `/snap/A/`); one pointer write switched both to `/snap/B/`, and `-Syu` installed 1.0.1.
   **Rolling back is a new snapshot, never the pointer moved back.**
   - R4: with a client on B (1.0.1 installed), pointing back to the older A failed: its database answered `304`, since the
     client's copy is newer, while A's signature came as `200`, so "signature … is invalid", which is P7 over HTTP, for
     every client already on B.
   - A new snapshot C, built now with A's packages, worked: `200` for both, `-Sy` exit 0, and `-Syu` "local (1.0.1-1) is
     newer than grassfield (1.0.0-1)", no downgrade.
   So the previous release is published again as a new snapshot (a pkgrel above the bad one when clients must move to it). Residual: a client whose two
   requests straddle the pointer write gets a mismatched pair once; that run fails ("signature … is invalid"), the next one
   works. The window is the time between pacman's two requests. Mirrors serve the same snapshots and pointer.
3. **Changing hosts (O19), the migration path.** "One value" was wrong for installed machines: their `grassfield.conf` keeps
   the old Server until it is rewritten, and would drift to `custom`. So a change of host proceeds as follows:
   1. The release that carries the new `GRASSFIELD_REPO_BASE` lists the old base in `GRASSFIELD_REPO_BASE_PREVIOUS`, and is
      published on both hosts.
   2. `grassfield-desktop`'s `post_upgrade` runs `grassfield-channel-scriptlet upgrade`. When the file's primary Server is
      `<previous base>/<channel>/$arch` for `stable` or `beta`, it rewrites the file from the current template for that
      channel and drops the synced files. Any other content is left alone, and the pane shows `custom` with "Repair…", which
      rewrites the file from the template (c.3).
   3. The old host keeps serving, then redirects (301) to the new one, for at least 90 days. After that, the old base can
      leave `GRASSFIELD_REPO_BASE_PREVIOUS`.
   GitHub Releases (not chosen) would change the Server's shape too (`…/download/<channel>-$arch`). A shape change needs the
   same migration.
4. Considered and not chosen: GitHub Pages (a public repository and a 1 GB site), GitHub Releases, GitLab.

### i. After an update
- Logging out is needed and enough for a Grassfield update: Hyprland keeps the loaded plugin, and the shell and the plugin
  must stay the same version (ADR-0007). The pane shows "Log out to finish updating Grassfield" with "Log Out…". GF-083's
  notice stays the one banner.
- Omarchy's reboot marker (`~/.local/state/omarchy/reboot-required`) and the running kernel's modules folder are read, never
  written. When they say so, the pane offers "Restart…" instead.

### Dev sessions (ADR-0019)
The checker runs in a dev session read-only, with its cache under the dev state. "Update Now", "Set Up…", "Repair…", "Turn
Off…" and the beta switch never run there. Dev plumbing: `GRASSFIELD_UPDATE_FIXTURE`, `GRASSFIELD_UPDATE_CHECK_CMD`,
`GRASSFIELD_UPDATE_LAUNCHER`, `GRASSFIELD_UPDATE_PKEXEC`.

## Owner decisions (2026-10-27; O1-O16 confirmed again after the first review)
| Id | Question | Options | Answer |
|---|---|---|---|
| O1 | Channel change (c) | A: `grassfield-channel-set` in Omarchy's terminal with sudo (recommended) · B: a pkexec helper behind Grassfield's own polkit action | **B** |
| O2 | After switching to beta | switch only, the pane offers the beta (recommended) · switch then `omarchy-update -y` (Omarchy's model) | **switch only** |
| O3 | Badge, menu count, banner | Grassfield and Omarchy releases (recommended) · Grassfield only · every package | **Grassfield and Omarchy** |
| O4 | A link in `~/.config/omarchy/hooks/pre-refresh-pacman.d/` | yes, made by `grassfield-channel-set` (recommended) · no, detection and "Repair…" only | **yes** |
| O5 | Signed besides packages | database and notes (recommended) · packages only (Omarchy's level) · database only | **database and notes** |
| O6 | Keys | offline master + CI signing subkey + a second offline key (recommended) · the owner signs each channel by hand · one key in CI | **one key in CI** (b.5, b.7) |
| O7 | pkgrel of a rebuild | `GRASSFIELD_PKGREL` read by the PKGBUILD (recommended) · a commit and tag per rebuild | **`GRASSFIELD_PKGREL`** |
| O8 | Hosting, after the legal review | GitHub Pages (recommended) · GitHub Releases · own domain · decide after M5 | **own domain** |
| O8b | Own domain: storage | S3-compatible storage + CDN (recommended) · own server (rsync/SSH) · after M5 | **S3 + CDN**; host name later |
| O9 | Release notes source | `packaging/release-notes/<VERSION>.{en,fr}.txt` (recommended) · CHANGELOG.md sections · written at publication | **the text files** |
| O10 | master-prompt §4/M6 | build and contract now, publication after M5 (recommended) · wait for M6 | **now, unpublished** |
| O11 | Public key and fingerprint | later (recommended) · now | **later** |
| O12 | `grassfield-desktop` depends on `grassfield-keyring` | always (recommended) · only in channel builds | **always** |
| O13 | CI access to grassfield | read-only deploy key (recommended) · fine-grained read token · none for now | **deploy key** |
| O14 | Build trigger | manual + `repository_dispatch` (recommended) · tag poll · manual only | **tag poll every 15 minutes**, plus manual runs |
| O15 | rc versions | beta channel (recommended) · not published | **beta** |
| O16 | After the opus PASS | watch the PR and open step 1 at once (recommended) · watch and wait for the owner · no watch | **at once** |
| O17 | Trust at the first installation (review 1, MAJOR 4) | out-of-band fingerprint only, the helper never adds trust (recommended) · verified files then `pacman -U` · keep the helper's bootstrap | **keep the bootstrap**; b.3a documented, residual risk accepted |
| O18 | A `[grassfield]` that blocks every update (review 1, MAJOR 1) | pane + notification offering "Turn Off…" (recommended) · pane only · automatic removal | **pane + notification**, never automatic |
| O19 | Change of host (review 1, MAJOR 5) | `post_upgrade` migration + old host serving and redirecting ≥ 90 days (recommended) · redirect only · manual "Repair…" | **migration + redirect** |
| O20 | Keyring before the owner's key exists (review 2, MAJOR) | a keyring with no key until O11 (recommended) · withhold the dependency until O11 | **no key until O11** (b.2) |
| O21 | `grassfield-keyring` dependency until grassfield-packages builds the package (step 1 review, minor 5) | hold it back; a follow-up adds it once grassfield-packages' step 1b is merged (recommended) · keep it, the owner builds the keyring once · a keyless keyring from this repository's PKGBUILD | **hold it back** |

The owner gave every answer in this Claude Code session on 2026-10-27, through its question tool. The answers to O1-O16
were recorded in `fd49abc` and confirmed again after the first review; O21 was asked after the step 1 review.

## Evidence
- `adr0033-probes.sh` (P0-P13), `adr0033-probes-2.sh` (Q0-Q8) and `adr0033-probes-3.sh` (R0-R5), in
  `docs/audits/software-update-2026-10-27/`. Their outputs are `probes-output.txt`, `probes-2-output.txt` and
  `probes-3-output.txt` (docker exit 0 each).
- Where and how they ran: in this cloud session's container (Ubuntu 24.04, root inside the session's sandbox), with the
  Docker 29.9.2 daemon started in the session. The command was `docker run --rm --network host` with the session's HTTPS proxy
  and CA bundle mounted read-only, on `archlinux:base@sha256:52dfbd5afb23a220d5ee92dafcb4c788d96c026ed04179890c23adef4c897fa0`.
  Mounted read-only, as data:
  - Omarchy v4.0.4 (c668141), for all three scripts;
  - Omarchy v4.0.6 (237f1b4), for the Q round; both cloned from github.com/basecamp/omarchy;
  - `omarchy-keyring-20251027-1` from pkgs.omarchy.org, for the Q round.
  Each script refuses to run outside a container. Inside it is root, makes a `builder` user for makepkg and an `alice` user
  with passwordless sudo (standing for Omarchy's warm sudo cache), and generates throwaway ed25519 keys that expire in a day.
  Everything goes with the container. pacman 7.1.0.r9.g54d9411-3, pacman-contrib 1.13.1-1, gnupg 2.4.9-3, all from
  Omarchy's stable mirror.
- One deviation from Omarchy's template: `DisableSandbox`. Docker refuses Landlock (R5: root pacman without it fails with
  "the Landlock ruleset could not be applied: Operation not permitted"); R5 then removes it and shows the user-side checks
  working with checkupdates' `--disable-sandbox-filesystem`.

## Consequences
- **Step 1, here:**
  - `grassfield-channel-set`; `grassfield-channel-helper` with its polkit policy; `grassfield-channel-scriptlet`; their
    shared `grassfield-channel.sh`; `grassfield-update-check`; the hook;
  - `packaging/pacman/` (repository.conf, the section templates);
  - the shim's `omarchy.system-update` forward;
  - `pre_remove` and `post_upgrade` in `grassfield-desktop.install`, calling `grassfield-channel-scriptlet`;
  - in `depends`: `grassfield-keyring`, `pacman-contrib` and `fakeroot` (`omarchy` depends on the last two as well;
    declared, not assumed);
  - `GRASSFIELD_PKGREL`, `updates.automaticCheck`, `software-update.json`;
  - a container test.
  The Omarchy files it relies on are pinned in `docs/upstream/omarchy.lock`, with the step 1 files as their derived files.
  `scripts/dev/upstream-drift.sh` requires derived files that exist, so the pins land with them. The files to pin:
  - `bin/omarchy-refresh-pacman`, `omarchy-hook`, `omarchy-update`, `omarchy-update-lock`, `omarchy-update-status`,
    `omarchy-update-available` and `omarchy-launch-floating-terminal-with-presentation`: identical in 4.0.4 and 4.0.6;
  - `default/pacman/pacman-stable.conf`: different in 4.0.6.
- **Step 1, in grassfield-packages:**
  - the snapshot build;
  - `grassfield-keyring`: private folder, `--populate-from`, `pre_remove`, and **no key until O11**;
  - the workflows, publishing disabled;
  - the end-to-end exercise, with throwaway keys made per run in its container.
- **Step 2:** the pane, badge, menu count and notification, including the `blocking` state and "Turn Off…".
- **ADR-0030 is amended** (its end): Settings' Software Update runs a root helper through pkexec, by owner decision O1,
  where ADR-0030 had none.
- **Privileged code** (helper, scriptlet program, shared library, policy, package scriptlets, the hook's `sudo tee -a`) is named in the step 1 PR and needs an opus
  security review before merge. The owner checks the real polkit dialog in the real session.
- **Known limits** (spec):
  - a `[grassfield]` that cannot sync stops every `omarchy update` until it is fixed or turned off (a2);
  - Omarchy's own channel change (`-Syyuu`) and `omarchy-reinstall-pkgs` (`-Suu`) move a Grassfield beta back to stable
    (P11);
  - an old but validly signed database can be replayed;
  - a pointer switch can fail one run; a rollback is a new snapshot (h.2);
  - a Hyprland update can come before the matching plugin.

## Step 1 as built (2026-10-27, branch `claude/software-update-step1`)
Landed in this repository:
- `packaging/pacman/`: `repository.conf` (still the `.invalid` base and no key, O11), the empty
  `grassfield-signing-key.asc`, `generate.py` (build time: checks the values and the key file, which must be exactly the
  pinned public key, and writes `/usr/share/grassfield/pacman/{repository.conf,grassfield-stable.conf,grassfield-beta.conf,
  grassfield-signing-key.asc}`), `grassfield-channel-helper`, `grassfield-channel-scriptlet`, `grassfield-channel.sh`,
  `org.grassfield.packages.policy`, `pre-refresh-pacman` (the hook);
- `packaging/bin/grassfield-channel-set` (also `/usr/bin`) and `packaging/bin/grassfield-update-check`;
- `packaging/arch/PKGBUILD` (`GRASSFIELD_PKGREL`, the three dependencies, the files above) and
  `grassfield-desktop.install` (`pre_remove`, `post_upgrade`);
- the Omarchy pins of `docs/upstream/omarchy.lock`;
- `tests/shell/update_check.sh` (the checker, logic layer) and `tests/integration/software_update.sh` (the container test).

`grassfield-keyring` is not yet in grassfield-desktop's `depends` (owner decision O21): it joins in a follow-up once
grassfield-packages' step 1b, which builds it, is merged, so that a local `makepkg -si` never asks for a package that does
not exist. `makedepends` now holds everything the build compiles against (`makepkg -s` installs the global depends and
makedepends only): `hyprwayland-scanner`, `kio`, `solid`, `kcoreaddons`, `kservice`, `qt6-webengine`, `qt6-multimedia`,
found by the first builds in a clean container.

Moved to step 2, with the shell code that uses them: the shim's `omarchy.system-update` forward (its target, the shell's
`update check` IPC, belongs to the step 2 shell service), `updates.automaticCheck` (a key goes through
`ui/Grassfield/Ui/SettingsContract.js`, the settings vectors and the store, which the open Settings stack #8-#10 changes;
its only reader is the step 2 scheduler) and `software-update.json` (written by that service). The pins of
`omarchy-update-status` and `omarchy-launch-floating-terminal-with-presentation` move with their derived files. The
waiter of d.5 is the checker's `--after-update-lock` mode, which the step 2 service starts.

Choices made within this ADR:
- "Reads no environment variable" (c.1): both root programs start as `#!/bin/bash -p` (no `BASH_ENV`, no imported
  function) and remove every exported variable before sourcing their library, which then sets `PATH=/usr/bin`, `LC_ALL=C`,
  `umask 022` and `cd /`.
- One change at a time: both root programs take `flock` on `/run/grassfield/channel.lock`, in a folder only root can
  open (0700; the file 0600, made under umask 077 and checked before use: flock needs no write access, so a lock others
  can read would let any user block "Turn Off…" and the removal, step 1 review MAJOR 1). The helper refuses when it is
  held; the scriptlet program waits up to 120 s, since the helper can start just before a pacman transaction whose
  scriptlet runs it, and two rewrites of `pacman.conf` could otherwise lose one another. Under the lock, temporary files
  a killed run left in `/etc` are removed.
- No environment at all: while their environment holds anything, both programs run themselves again under `env -i`
  (entries such as `BASH_FUNC_x%%` are no variables, so no unset loop removes them, and `pacman-key` is a bash script).
- Exactly one `[grassfield]` section: `set` and `restore` replace several by one (the hook can append between the
  helper's read and its rename; pacman then refuses a database "already registered"). Several sections, or the lines
  without their file, read `repair` in the checker and in `grassfield-channel-set`.
- `[grassfield]` lines whose file is missing (pacman cannot run at all then) are removed first by `set`, `restore` and
  `off`, so `pacman-key` and `pacman-conf` can run; `grassfield-channel-set` shows that state as `repair`, and its
  `repair` runs `set stable` there.
- The checker keeps its failure count, the Server lines it last synced and its last success in `health-db/` (ADR-0020's
  row). Its `--offline` flag carries the shell's connectivity: a failure while offline is not counted.
- A notes file whose `channel` is not the client's channel is refused, like any other invalid notes.
- `grassfield-channel-set` honours `GRASSFIELD_UPDATE_PKEXEC` only in a dev session (ADR-0019's predicate) and never makes
  or removes the hook link there; without the stand-in, a dev session refuses the change.

## Review history
First opus review of PR #11 (integrator, 2026-10-27): FAIL, no blocker, 5 MAJOR. Each finding and where it is answered:
- **MAJOR 1**, a failing `[grassfield]` stops every update: a2 (Q1), mirrors, atomic publication (h.2, Q2), rotation
  overlap (b.4), detection and "Turn Off…" (O18, Q3).
- **MAJOR 2**, a check run under the update lock went stale: d.5, a waiter that checks once the lock is released (Q8).
- **MAJOR 3**, trust left behind: b.8, `off` and the two `pre_remove` steps delete the keys (Q6).
- **MAJOR 4**, the first installation: b.3a, a verified procedure; the owner kept the bootstrap (O17), and b.3 tests trust,
  not presence.
- **MAJOR 5**, "one value" did not hold for installed machines: h.3, the migration path (O19).
- **Minors:**
  - the quattro claim corrected (Q4);
  - migrations run where they act (Q5);
  - the trust test (b.3);
  - VALIDSIG argument 10 (Q7);
  - the checker's own lock, stale `db.lck` and stdin (d.1, Q8);
  - `fakeroot` declared;
  - the Omarchy pins (Consequences);
  - 4.0.6 rechecked (Context).
  The layout moved to a `[grassfield]` header in `pacman.conf`, because of 4.0.6's migration 1791403252 (Q4).

Second opus review (integrator, 2026-10-27): FAIL. Review 1's five MAJOR and its minors are confirmed closed. One new MAJOR
and minors, answered here:
- **MAJOR**, test keys trusted on the owner's machine through the O12 dependency: `grassfield-keyring` holds no key until
  O11 (owner decision O20, b.2, R1). Test keys are made per run inside containers only.
- **Minors:**
  - scriptlet verbs no longer depend on `PKEXEC_UID`: a separate program, and nothing reads the environment (c.1);
  - "Repair…" in `custom` rewrites the file (c.3);
  - `set` populates the installed keyring, and the keyring lives in a private folder that a plain `pacman-key --populate`
    does not reach (b.2, b.3, R2, R3);
  - rollback by a new snapshot (h.2, R4);
  - `blocking` after two failures in a row (a2.4);
  - the sandbox flag of the `[grassfield]`-only check, and why the containers use `DisableSandbox` (a2.4, R5);
  - b.3a ends with `grassfield-channel-set` (step 5);
  - stale text fixed (spec non-goals, ADR-0020's amendment), ADR-0030 amended;
  - the decisions table has its options again.
