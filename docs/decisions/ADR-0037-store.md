# ADR-0037: Grassfield Store: an app that installs, opens and uninstalls apps through pacman and Omarchy, with a signed catalog
Status: Proposed (cloud session, owner brief 2026-10-27, step 0; docs only, no code in either repository before the opus
PASS). The owner answered ST1 to ST10 on 2026-10-27, recorded below in the owner's own words. Later questions follow the
owner's working rule of 2026-10-27: decided in this session, recorded in "Decisions delegated by the owner" (SD1 to SD5),
checked by the integrator. The first opus review (FAIL, 3 MAJOR) and the counter-review (FAIL, 1 MAJOR) are answered in
"Review history". · Date: 2026-10-27 · Decider: owner (ST1 to ST10), delegated (SD1 to SD5), integrator (merge after the
opus PASS) · Number: 0037 (0033 Software Update, 0034 clipboard, 0035 dialogs and 0036 tiling are merged)

This ADR is also part of the contract between this repository (the app, `apps/store`, packaged as `grassfield-store`) and
`grassfieldhq/grassfield-packages` (the catalog Grassfield edits: the Discover selection, the sections, the categories and
our texts, built and signed there). That contract extends ADR-0033's (channel URLs and tree, signing key, trust, atomic
publication), and this PR amends ADR-0033 where the Store needs it (d, g, h.2; section "Amendments"). Parity with macOS 27:
`docs/audits/store-2026-10-27/parity.md`. Behaviour, keyboard, accessibility, refusals and limits: `docs/specs/store.md`.
Evidence: the probes S0 to S15 of `docs/audits/store-2026-10-27/store-probes.sh` and S16 to S18 of `store-probes-2.sh`,
each run in a throwaway `archlinux:base` container, outputs next to them. Legal points are marked "needs legal review"
(master-prompt §14); none is a conclusion.

## Context

### The owner's brief (2026-10-27)
- An app with the look of the macOS 27 store application (Discover, categories, product pages, search, updates) that
  installs, opens and uninstalls apps on Grassfield.
- Two repositories. Here: the app in `apps/store` with the shared design system (`ui/Grassfield/Ui`), tokens, translations,
  tests and the single build definition (ADR-0023), shipped as its own package `grassfield-store` from the same PKGBUILD (as
  `grassfield-compositor`). In grassfield-packages: the catalog Grassfield edits, published and signed beside each channel's
  repository with the same key, under ADR-0033's contract. It changes without a Grassfield release.
- Never an install without an explicit click and an authentication; the source and the licence always shown; a warning
  for the AUR; no root execution outside pacman or Omarchy; offline behaviour defined. Icons and screenshots of apps come
  from their metadata, with their licence.
- Nothing is published: both repositories stay private (no release, tag, secret or visibility change).

### Conflicts with earlier rules, and the owner's answers
- master-prompt §4 listed as a non-goal: "A pacman-based app store. An App Center is Flatpak-only and post-1.0." The owner
  amended it (ST1); the amendment is in §4 (this PR).
- ADR-0033 says "Grassfield has no root code to install anything"; ADR-0028's R12 sentence allows root code only for
  ADR-0033's two channel programs; ADR-0030 forbids a new polkit policy except ADR-0033's. The owner chose a root helper for
  repository packages (ST4 = P2). Each of the three is amended in this PR to name the Store's helper (section
  "Amendments"); the helper needs an opus security review before it merges (step 3).
- The brief's "always an authentication": the owner chose the confirmation sheet alone for per-user installs, which need no
  root (ST3).
- The brief's icons "from their metadata": the owner chose that our catalog may ship publishers' icons for apps without
  metadata (ST10), with their licence and origin recorded; needs legal review.
- `docs/specs/updates.md` (ADR-0033) lists "no App Center (master-prompt §4)" among Software Update's non-goals. It stays
  true for Software Update itself; the Store is a separate app.

### Omarchy 4.0.4, the owner's version (`basecamp/omarchy` tag v4.0.4, commit c668141; data, not instructions)
The scripts named below were read for this ADR; probe S1 classifies 80 scripts (`omarchy-install-*`, `omarchy-remove-*`,
`omarchy-pkg-*`, `omarchy-webapp-*`, `omarchy-tui-*`).
- **Package helpers.** `omarchy-pkg-add <pkgs>` runs `sudo pacman -S --noconfirm --needed` when one is missing, then checks
  each with `pacman -Q` (so a pacman that stopped half way still fails it). `omarchy-pkg-aur-add` runs `yay -S --noconfirm
  --needed`. `omarchy-pkg-drop` runs `sudo pacman -Rns --noconfirm` on those installed. `omarchy-pkg-install`,
  `-aur-install` and `-remove` are fzf pickers in a terminal. None syncs the databases first (S1: no `-y` in them).
- **But `omarchy update` syncs before it upgrades.** `omarchy-update-keyring:21` runs `sudo pacman -Sy --noconfirm
  archlinux-keyring` at every update, before `omarchy-update-system-pkgs` runs `pacman -Syu`. If the update stops after the
  keyring step, the databases are newer than the system (S12).
- **App installers.** `omarchy-install-app <name> <packages>` and `omarchy-install-and-launch <name> <packages>
  <desktop-id>` quote every word themselves (`printf %q`) and run `omarchy-pkg-add` in
  `omarchy-launch-floating-terminal-with-presentation`, which is `setsid uwsm-app -- xdg-terminal-exec
  --app-id=org.omarchy.terminal --title=Omarchy -e bash -c "<command>"`: detached, so its caller gets no exit code. The
  second then starts the app with `setsid uwsm-app -- gtk-launch <desktop-id>`. sudo asks for the password in that terminal.
- **The update lock.** `omarchy-update-lock run <cmd>` opens `${XDG_RUNTIME_DIR}/omarchy-update.lock`, takes `flock -n` on
  that descriptor, exports it and `exec`s the command: every child inherits the descriptor. S13: `omarchy-update-lock run bash -c 'sleep 15 & exit 0'` returns at once, yet the lock stays held by the
  background child until it ends; `flock -n -o` on the same file leaves it free as soon as the command returns; and while `flock
  -o` holds it, `omarchy-update-lock run` refuses ("An Omarchy update is already running.", exit 1).
- **Recipes.** The menu (`default/omarchy/omarchy-menu.jsonc`) runs 105 of its install and remove entries in that floating
  terminal (S1). The recipes do more than install a package (S1 table):
  - service setups enable system units with sudo (`omarchy-install-service-tailscale`, `-nordvpn` also adds the user to a
    group and offers a reboot, `-sunshine`, `-once`); browser setups create root-owned policy folders under `/etc`
    (Chromium-based browsers) or in the browser's `distribution` folder (Firefox, Zen) and copy Omarchy's Chromium flags;
  - `omarchy-install-gaming-lutris` runs pacman twice (`omarchy-pkg-add`, then the 32-bit graphics libraries) and then
    rewrites `/usr/bin/lutris`'s first line with `sudo sed -i`;
  - `omarchy-install-gaming-geforce-now` downloads NVIDIA's installer with curl and runs it; `-battlenet` downloads a Windows
    installer and runs it under Wine; `omarchy-install-dev-env` pipes `curl … | sh` for several languages;
  - 11 removal recipes delete user data with `rm -rf` (S1 "rm-home"): Steam's game libraries (`~/.steam`,
    `~/.local/share/Steam`), Heroic's (`~/Games/Heroic`), Battle.net's Wine prefix, and others;
  - `omarchy-remove-launcher-entry <desktop-id>` (hidden, used by Omarchy's launcher) removes a web app, a TUI, a user entry,
    a pacman package (`sudo pacman -Rns` in the floating terminal) or a Flatpak (`flatpak uninstall`).
- **Where the recipes' packages come from (S2, by name on Omarchy stable).** 22 from `[extra]`, 2 from `[multilib]`, 30 from
  `[omarchy]` (243 packages: prebuilt `google-chrome`, `brave-bin`, `visual-studio-code-bin`, `spotify`, `1password`, …), 1 not
  found by name (`libappindicator-gtk3`). The recipes that call `omarchy-pkg-aur-add` (Chrome, Brave, Edge, Zen, Emacs) name
  packages `[omarchy]` serves prebuilt.
- **Omarchy's own apps.** `install/omarchy-base.packages` (150 lines) lists what an Omarchy install brings, among them
  `chromium`, `libreoffice-fresh`, `mpv`, `nautilus` and `obsidian`.
- **Web apps.** `omarchy-webapp-install <name> <url> <icon>` writes `~/.local/share/applications/<name>.desktop` (Exec
  `omarchy-launch-webapp "<url>"`; the name keeps its spaces: "Example Mail.desktop", S9) and an icon under
  `~/.local/share/icons/hicolor/256x256/apps/`, as the user, no root. It refuses a name with `/` and a URL that is not
  http(s) or has whitespace. Given a local icon file it makes no network request (S9: 0 calls); given an icon URL or nothing
  it downloads from that URL, the site and, as a last resort, Google's favicon service. `omarchy-webapp-remove <name>`
  removes both (S9). `omarchy-launch-webapp <url>` starts the browser itself with `setsid uwsm-app -- <browser> --app=<url>`.
- **Updates.** `omarchy update`: snapshot, keyrings (the `-Sy` above), `pacman -Syu`, migrations, `yay -Sua` for AUR packages
  (`omarchy-update-aur-pkgs`), mise, orphans; under the update lock. No Flatpak update. Omarchy installs a Flatpak only for
  GeForce NOW; its launcher can remove any Flatpak.

### Arch Linux facts measured here (S3 to S18)
- **A database newer than the system breaks installs (S4).** System at the Arch snapshot of 2026-03-01 with python, gtk3,
  qt6-base and ffmpeg; database of 2026-10-20 (`pacman -Syy` without `-u`; 220 of the 322 installed packages have newer
  versions in it). `pacman -S gimp` is refused: "installing libjxl (0.12.0-1) breaks dependency 'libjxl.so=0.11-64' required
  by ffmpeg" (the same for x265); `blender` and `thunderbird` cannot be resolved either; `pacman -S mpv` would upgrade the
  installed `ffmpeg`, `libbluray` and `libvpx` alone. With the database the system was upgraded from, gimp's plan installs
  44 packages and upgrades nothing installed. The rule is Arch's (wiki, System maintenance: "Partial upgrades are
  unsupported"). Nothing in Grassfield may run `pacman -Sy`.
- **A plan can look clean while the database is ahead (S12).** After Omarchy's keyring line (`pacman -Sy --noconfirm
  archlinux-keyring`) and an update that stops there, `pacman -Qu` lists 122 packages, while `pacman -S --print
  inkscape` installs 61 packages and upgrades 0 installed ones (so do gimp, vlc, mpv, jq, ripgrep, fd, tree and nano): a
  check of the plan alone accepts it, yet the
  new packages come from a database the system was never upgraded to. Only `pacman -Qu` sees it. With `IgnorePkg`, pacman
  marks the held package "[ignored]" (S12: "adwaita-cursors 50.0-1 -> 51.0-1 [ignored]").
- **A database older than the mirror fails cleanly (S5).** System and database at 2026-09-01, Server = Omarchy's stable
  mirror (2026-10-22): `pacman -S fd` asks for `fd-10.5.0-2`, the mirror answers 404, "failed to commit transaction", exit 1,
  nothing installed. The cure is a full update first.
- **Interrupting pacman (S6: 110 packages, none installed before, a signal sent to pacman itself during the commit).** SIGINT
  and SIGHUP stop after the current package and **exit 0** with 15 and 11 of 110 installed. SIGTERM (exit 143) and SIGKILL
  (exit 137) leave `db.lck` (the next pacman refuses: "unable to lock database"), an incomplete database entry for the package being
  extracted (`pacman -Dk`: "description file is missing", "file list is missing") and some of its files on disk with no
  owner (7 and 10). So an exit code alone says nothing about success, and nothing may signal pacman. A real terminal closing,
  with sudo between it and pacman, was not tested: NOT VERIFIED.
- **One transaction at a time (S11).** With `db.lck` held: "failed to init transaction (unable to lock database)", exit 1.
- **What a user can read and ask (S10).** `/var/log/pacman.log` (0644) and `/var/lib/pacman/local` (0755, its mtime changes
  on each transaction); `pacman -S --print`, `pacman -Sp` and `pacman -Rs --print` answer as the user, without root or the
  lock (`-n` cannot be combined with `--print`); a removal that would break another package is refused there too ("removing
  glib2 breaks dependency … required by accountsservice"); `pacman -Qlq`/`-Qqo` map a package to its `.desktop` file and back.
- **uwsm's desktop ids (S14).** uwsm 0.27.1's `misc.py:87` accepts a desktop entry id only if it matches
  `\A[a-zA-Z0-9_][a-zA-Z0-9_.-]*.desktop\Z`: "example-mail.desktop" matches, "Example Mail.desktop" (the name
  `omarchy-webapp-install` writes, S9) does not. So a web app is opened by its URL, never by its entry's file name.
- **What a removal rule must see (S16).** Omarchy 4.0.4's `omarchy-base.packages` omits the kernel, the firmware, `base`,
  `sudo`, `systemd` and the boot tools; its `omarchy-other.packages` has them (`base`, `linux-omarchy`, `linux-firmware`,
  `limine`, `snapper`, `btrfs-progs`, …; 204 names in the two lists), and pacman's `HoldPkg` is only `pacman glibc`. b.1's
  rule (explicit, an application entry, the deny list, the whole plan) refused every system package S16 registered (linux,
  sudo, systemd, limine, snapper, btrfs-progs, base, pacman, glibc), a command-line tool (tree: no entry), an app pulled in as
  a dependency (galculator), an Omarchy app (btop) and a local app whose plan takes a boot tool with it (`probe-app`: `pacman
  -Rs --print` lists probe-app, efibootmgr, efivar); it allowed xterm (its plan: xterm and seven libraries). The deny list
  denied all 252 names checked (Omarchy's two lists, the fixed list, HoldPkg and ten variants such as `linux-zen`,
  `sof-firmware`, `yay-bin`); without Omarchy's lists the rule refused everything. pacman refuses `-Rns --print` ("'--nosave'
  and '--print' may not be used together", exit 1): the plan is read with `-Rs --print`, which lists what `-Rns` removes.
- **Polkit and the Store's action (S18, polkit 127-3).** An action's `<message>` may hold `$(command_line)`: pkexec puts the
  program and its arguments in the details (`command_line`, polkit 128 `src/programs/pkexec.c:864`), and polkitd expands
  `$(…)` in the message before any agent sees it (`src/polkitbackend/polkitbackendinteractiveauthority.c:2327`). S18's agent
  showed "Authentication is required to install or remove apps: /usr/lib/grassfield/grassfield-store-helper install
  0123456789abcdef0123456789abcdef xterm". Only trusted callers (uid 0, as pkexec is, or the action's owner) may pass details
  (`polkitbackendinteractiveauthority.c:1130`). With `auth_admin`, each of three calls asked for the password, two of them from
  one process. What `auth_admin_keep` keeps in a session is NOT VERIFIED: in the container pkexec registers its own text agent
  for each call and there is no logind session, and it kept nothing there either.
- **AppStream for Arch (S3, S15).** `archlinux-appstream-data` 20261017-1 (`[extra]`, 20.6 MiB download, 21 MiB installed):
  `/usr/share/swcatalog/xml/extra.xml.gz` (8.2 MB) has 1390 desktop applications, all with `pkgname`, a desktop-id
  `launchable`, categories and a cached icon; 946 with `project_license`; 916 with screenshots, hosted on 280 different hosts
  (raw.githubusercontent.com, cdn.kde.org, gitlab.gnome.org first). Its 3860 cached icons are JPEG XL (`.jxl`). `[core]` has
  none, `[multilib]` one (Steam), `[omarchy]` none: Spotify, 1Password, Heroic, Visual Studio Code, Chrome have no AppStream
  entry. `appstreamcli search` reads the pool as a user. Without the package
  installed, a user can fetch the package file from pacman's own mirror (`pacman -Sp`): it has the SHA-256 pacman's sync
  database lists (S15: 21 563 985 bytes), but Arch's databases are not signed, so that match alone proves nothing. The
  package's own signature sits beside it on the mirror (`<url>.sig`, 310 bytes) and a user can check it by pacman's own rule
  (S17): pacman's keyring is readable by everyone (`/etc/pacman.d/gnupg` 0755, `pubring.gpg` and `trustdb.gpg` 0644);
  `pacman-key --verify` runs as the user ("Note: trustdb not writable" is all it adds), passes only for a signer pacman's
  keyring trusts fully (`[GNUPG:] TRUST_FULLY`), and exits 0; with one byte of the file changed it exits 1. Arch's other copy,
  on sources.archlinux.org, carries no signature.
- **The AUR (S7).** RPC v5 `info` gives Name, Version, Description, Maintainer, NumVotes, Popularity, OutOfDate,
  LastModified, License, URL, URLPath, Depends, OptDepends, Keywords, FirstSubmitted. `search` by name answers
  in one request (72 results for "chrome"). The whole-AUR dump `packages-meta-v1.json.gz` is 10.6 MB (123 087 packages, no
  licence field, served with `cache-control: max-age=300`); `packages-meta-ext-v1.json.gz` 14.6 MB.
- **Flatpak and Flathub (S8).** `flatpak` 1:1.18.2-1 (Arch's archive of 2026-09-01) adds 20 packages to the probe's machine; 2 (pipewire, python-gobject) of them are in
  Omarchy 4.0.4's package lists. `flatpak remote-add --user flathub …` works as a user without root (the user owns
  `~/.local/share/flatpak`). Flathub lists 3502 apps; its AppStream is 10.8 MB compressed plus a 50.9 MB uncompressed copy;
  117 MB under `~/.local/share/flatpak` before any app. No app was installed (runtimes are hundreds of MB): NOT VERIFIED.
- S5 to S15 ran on Arch's archive snapshot of 2026-09-01 (S12 moves the database to 2026-10-20), S1 to S3 on Omarchy's stable
  mirror. S16 to S18 (`store-probes-2.sh`) ran on the same 2026-09-01 snapshot.

### The owner's machine (integrator's survey, 2026-10-27)
pacman, yay and the `appstream` library are installed; flatpak, PackageKit and `archlinux-appstream-data` are not. The owner's
own `makepkg -si` builds of `grassfield-*` are foreign packages (`pacman -Qm` lists them; integrator's check).

### Grassfield today
- `apps/` holds the Grassfield apps (Settings, Files, Preview, helpers), each a Qt/QML front end over a C++ backend, built by
  CMake (ADR-0023) and packaged by `packaging/arch/PKGBUILD` (split packages `grassfield-desktop`, `grassfield-compositor`,
  `grassfield-icons`).
- ADR-0011: one launch path; native apps start applications with `apps/appscope.h` (`uwsm-app -- …` in a real session,
  through `QProcess::startDetached`: no exit code comes back).
- ADR-0018: badges are set by the application itself (Unity LauncherEntry through the menu bridge).
- ADR-0019: one run-mode rule; dev plumbing honoured only in a dev session.
- ADR-0020: persisted files (config, state), single writer of `grassfield.json`.
- ADR-0030: privileged changes through the system services' own polkit actions; amended for ADR-0033's channel helper.
- ADR-0033 (merged 609017f after its opus PASS; status Proposed): the `[grassfield]` repository in two channels, one signing
  key in CI, `grassfield-keyring` (its files in the private folder `/usr/share/grassfield/pacman-keyring/`, no key until the
  owner's exists, O20), signed release notes verified with `gpgv`, atomic publication by snapshot and pointer, Software Update
  (its checker in the shell, the Settings pane, the Dock badge on Settings for Grassfield and Omarchy releases, "Update Now" =
  Omarchy's update in its floating terminal), and two root programs for the channel only.

## Decision

### Overview
```
grassfieldhq/grassfield-packages                     grassfieldhq/grassfield: apps/store → package grassfield-store
  catalog/ (texts, sections, categories, icons)        grassfield-store (Qt/QML + C++, runs as the user)
     └ one serialized publisher per channel:            ├ catalog: fetch (https), gpgv, validate, cache
       build from the current snapshot →                ├ sources: pacman, AppStream, Omarchy recipes, web apps, AUR RPC, flatpak
       grassfield-catalog.v1.json + .sig +              ├ plan check: pacman -Qu empty, -S --print, mirror, locks
       catalog/<sha256>.png → conditional               ├ queue, one operation at a time, each ending with an exit code:
       pointer write (ADR-0033 h.2 amended)             │   repository packages → pkexec grassfield-store-helper (root, pacman only)
                                                        │   AUR, Omarchy setups → Omarchy's terminal → grassfield-store-run (user)
                                                        │   web apps, Flatpaks  → the Store's own children (user)
                                                        ├ success = exit code 0 AND the system's state
                                                        └ Open: ADR-0011 (uwsm-app -- <id>.desktop; web apps: omarchy-launch-webapp <url>)
Updates: ADR-0033's checker (shell) → software-update.json → the Store's Updates page; "Update All…" = ADR-0033's "Update Now"
```

### a. Sources (owner, ST2)
Every app in the Store comes from one source, shown on its button row, its product page and its confirmation sheet:

| Source | What | Installed by | Default |
|---|---|---|---|
| Arch repositories | `[core]`, `[extra]`, `[multilib]` through Omarchy's mirror | the Store's helper (b.1) | on |
| `[omarchy]` | Omarchy's own repository (prebuilt Chrome, Spotify, VS Code, 1Password, …) | the Store's helper (b.1) | on |
| Omarchy setups | Omarchy's `omarchy-install-*` recipes our catalog lists, each with what it changes, written after reading it | the recipe, in Omarchy's terminal (b.2) | on, except the recipes that download and run code outside pacman (GeForce NOW, Battle.net, dev environments) |
| Omarchy web apps | sites our catalog lists | `omarchy-webapp-install`, as the user (b.3) | on |
| AUR | user packages, not reviewed by anyone | `omarchy-pkg-aur-add` (yay), in Omarchy's terminal (b.2) | **off until turned on** in the Store's settings; the warning on every install |
| Flathub | Flatpak apps, sandboxed, per-user installs without root | `flatpak --user`, as the user (b.3) | **off until turned on**, and offered only when the user has installed `flatpak` (an `optdepends`, no dependency added) |

An app that exists in several sources shows the first of: Omarchy setup (it configures what Omarchy configures), Arch or
`[omarchy]` package, Flathub, AUR. The catalog can pin a source per app.

**Flathub.** Turning it on adds the Flathub remote to the user's installation (`flatpak remote-add --user --if-not-exists`,
S8). Everything happens in that installation, as the user, without root or terminal: `flatpak install --user
--noninteractive flathub <app-id>`, `flatpak uninstall --user --noninteractive <app-id>` (the app's data in
`~/.var/app/<app-id>` is kept; the sheet says where), `flatpak update --user --noninteractive <app-id>`. The sheet adds what a
Flatpak can reach (its `[Context]` from `flatpak remote-info --show-metadata`, in plain words) and the size of the runtimes
it pulls. Its metadata is Flathub's AppStream in the user's installation, refreshed by `flatpak update --user --appstream` on
the catalog's schedule (c). Cancelling a Flatpak operation and its effect are NOT VERIFIED (S8 installed no app); step 3
measures them before any cancel is offered.

**What the Store removes (counter-review MAJOR).** "Uninstall…" exists only for an app the user installed: a package
installed explicitly that owns an application entry (an AUR package needs no entry, b.2) and that b.1's deny list does not
name (the system's packages, Omarchy's two package lists, `grassfield-*`, `HoldPkg`), with a removal plan that takes no
denied package. Otherwise the page says why and offers nothing: "Part of Omarchy" (an app Omarchy ships, such as
`chromium`), "Part of Grassfield", "Part of the system" (the fixed list), "Installed with another app" (pulled in as a
dependency). Removing them stays possible outside the Store. The Store installs from the repositories only apps that own an
entry (SD1), so it can remove whatever it installed.

**Foreign packages.** `pacman -Qm` lists every package no repository has: AUR packages, but also local builds such as the
owner's `makepkg -si` of Grassfield. The Store calls them "Not from a repository" and says "AUR" only when the AUR's
`info` knows the name (AUR turned on); Grassfield's own packages are never shown there.

### b. The install paths (owner, ST4: P2 for repository packages, Omarchy's terminal for the AUR and the recipes)
Each path ends with an exit code the Store receives, and success is that code being 0 **and** the system's state matching
the plan (packages present at the planned versions, the web app's entry present, the Flatpak listed). An exit code alone
is not enough (S6: an interrupted pacman exits 0); the state alone is not enough either (a recipe runs pacman twice and then
`sudo sed`, so its packages appear before it ends).

**b.1 Repository packages: `grassfield-store-helper`, a root helper behind the Store's own polkit action (P2).**
- `/usr/lib/grassfield/grassfield-store-helper`, run by `pkexec` as a direct, waited-for child of the Store, so the Store
  gets its exit code. Polkit action `org.grassfield.store.manage-packages` in
  `/usr/share/polkit-1/actions/org.grassfield.store.policy`: `allow_active` **`auth_admin`** (the password at every
  operation, never kept: counter-review MAJOR, S18), `allow_any` and `allow_inactive` `no`,
  `org.freedesktop.policykit.exec.path` the helper; message "Authentication is required to install or remove apps:
  $(command_line)" / « Une authentification est nécessaire pour installer ou supprimer des apps : $(command_line) ». polkitd
  replaces `$(command_line)` with the helper's argument vector as pkexec reports it (S18), so the names come from polkit, not
  from the Store. The dialog is Grassfield's polkit sheet (SEC6). For this one action id it shows "Install" or "Remove" and
  the package names, read from that line by a strict pattern (the helper's path, `install` or `remove`, an operation id,
  names of e.5); a line that does not match is shown as polkit gives it (SD2). Each operation asks once: a queue of three
  operations asks three times.
- Verbs, its argument vector only: `install <op-id> <package>…` and `remove <op-id> <package>…` (1 to 64 names). It reads no
  environment variable except `PKEXEC_UID`, which pkexec sets; it sets its own `PATH` and `umask 022`; it refuses unless its
  effective uid is 0.
- It runs exactly `pacman -S --needed --noconfirm --noprogressbar -- <names>` or `pacman -Rns --noconfirm --noprogressbar --
  <names>`. Never `-y`, `--overwrite`, `-dd`, `-U`, a file path, a hook, or anything else. It installs from the repositories
  only (names, not files).
- Before pacman, it checks again (MAJOR 1): no `db.lck`; `pacman -Qu` lists nothing that is not "[ignored]" (S12); every name
  matches the pattern of e.5 and, for `install`, resolves in a repository.
- **`remove` takes apps only (counter-review MAJOR; S16).** Every name must be a package of a repository (`pacman -Si`; a
  package no repository has is removed through b.2), installed explicitly (`pacman -Qqe`), the owner of an application entry
  (a file `/usr/share/applications/<id>.desktop` in `pacman -Qlq`), and not denied. Denied:
  - the fixed list `base`, `base-devel`, `filesystem`, `glibc`, `bash`, `coreutils`, `util-linux`, `shadow`, `pam`, `sudo`,
    `polkit`, `dbus`, `dbus-broker`, `dbus-broker-units`, `kmod`, `mkinitcpio`, `dracut`, `grub`, `efibootmgr`, `refind`,
    `syslinux`, `snapper`, `btrfs-progs`, `cryptsetup`, `lvm2`, `plymouth`, `archlinux-keyring`, `intel-ucode`, `amd-ucode`;
  - every name that is `linux`, `systemd`, `limine`, `pacman`, `yay`, `omarchy` or `grassfield`, or one of them followed by
    `-` and anything (kernels and their headers, the boot manager's hooks, Omarchy's and Grassfield's packages);
  - every name that ends in `-firmware` or holds `-firmware-`;
  - every name in Omarchy's `omarchy-base.packages` and `omarchy-other.packages`, read at `/usr/share/omarchy/install/`, never
    a path from the environment (both missing or empty: every `remove` is refused);
  - pacman's `HoldPkg`.

  Then the whole plan: `pacman -Rs --print --print-format '%n' -- <names>` (what `-Rns` removes; pacman refuses `--print`
  with `-n`) must resolve and name no denied package, since `-s` also removes dependencies. The list is in the helper's code,
  not in a file: changing it is a reviewed change.
- Its own descriptors go to `/dev/null` and to a log, never to the pipe it was started with, and it ignores SIGHUP and SIGPIPE:
  the Store quitting cannot kill pacman through a closed pipe (S6 shows what a killed pacman leaves). It writes, in the
  root-owned `/run/grassfield-store/` (0755): `<op-id>.started` (its pid and start time), `<op-id>.log` (pacman's output, 0644,
  at most 8 MiB, for the progress and the error), `<op-id>.exit` (the exit code, written by rename).
- While it runs, the Store holds Omarchy's update lock (the same file, opened with close-on-exec, so neither pkexec nor
  pacman inherits it): `omarchy update` cannot start meanwhile, and Software Update, which reads the same lock (ADR-0033
  d.5), shows "Update in progress" until the operation ends. The same holds while `grassfield-store-run` holds it (b.2).
- Waits: the authentication up to 120 s (ADR-0030); the transaction up to 2 h, after which the Store stops waiting, says it
  lost track, and reads the state; it never signals the helper (a user cannot signal a root process anyway).
- It and its policy need the security reviewer's (opus) PASS before they merge (step 3), like ADR-0033's two programs.

**b.2 AUR packages and Omarchy setups: Omarchy's terminal, through `grassfield-store-run` (P1).** yay must not run as root,
and the recipes call sudo themselves and write in the user's home, so the helper cannot run them.
- The Store starts `omarchy-launch-floating-terminal-with-presentation "/usr/lib/grassfield/grassfield-store-run <op-id>
  <deadline> <kind> <tokens…>"`, the command string built only from the validated tokens of e.5. The terminal is detached
  (`setsid uwsm-app`), so the exit code comes back through files.
- `grassfield-store-run` is Grassfield's script, run as the user inside that terminal. It:
  1. refuses to start after `<deadline>` (the terminal opened too late; 60 s after the Store asked);
  2. takes Omarchy's update lock file with `flock -n -o` (the same file `omarchy-update-lock` locks, so `omarchy update`
     says it is already running; `-o` keeps the descriptor in `flock` itself, out of the recipe's children, which would
     otherwise hold the lock as long as an app the recipe starts runs, S13); refuses when it is held;
  3. writes `$XDG_RUNTIME_DIR/grassfield/store/<op-id>.started` (its pid and start time);
  4. checks again: no `db.lck`, `pacman -Qu` lists nothing that is not "[ignored]" (S12);
  5. runs `omarchy-pkg-aur-add <names>`, `omarchy-pkg-drop <names>` to remove an AUR package (after b.1's deny list and
     whole-plan check, made by the Store and again here; no application entry needed: the user installed it from the AUR, and
     sudo asks in the user's own terminal, as in Omarchy's menu), or the recipe (`<omarchy-install-…>` or
     `<omarchy-remove-…>` with its arguments), as an argument vector;
  6. writes `<op-id>.exit` with the code (by rename) and exits with it.
- The Store waits for `<op-id>.exit` (watched); while it waits, the `started` file's pid and start time tell whether the
  script still runs. No `started` file 60 s after the request: "The terminal did not open", and the operation is dropped.
  The script gone without an `exit` file (the terminal closed; SIGHUP through sudo to pacman is NOT VERIFIED, S6): the
  operation is "interrupted" and the state is read. A running operation is waited for up to 3 h (setups download large
  apps), then the Store stops waiting and reads the state; it never signals the terminal.
- The next operation in the queue starts only when the `exit` file exists, Omarchy's lock is free and `db.lck` is absent.
  The Lutris recipe (pacman twice, then `sudo sed`) is one operation: the Store waits for its end.

**b.3 Web apps and Flatpaks: the Store's own children, as the user.** `omarchy-webapp-install <name> <url> <icon-file>` (a
local icon file from the catalog, S9), `omarchy-webapp-remove <name>`, and the `flatpak --user` commands of a. They are
waited for (exit code), stdin from `/dev/null`, with a 10-minute limit for web apps (SIGTERM, then SIGKILL 5 s later; they
touch only the user's files) and none for Flatpaks until step 3 has measured an interrupted one.

**b.4 Every path.** The plan check comes first (e.4), one operation at a time, success = exit code 0 and the state, and
nothing ever signals pacman.

### c. Catalog and metadata (owner, ST5, ST6, ST7)
- **Sources of metadata.** (1) Our catalog (g): sections, cards, categories, our texts, icons for apps without metadata (ST10),
  the list of setups and web apps. (2) AppStream for Arch packages (ST5): the installed `archlinux-appstream-data` when there
  is one (an `optdepends`, signed by Arch, updated with the system); otherwise the Store fetches the same package file and
  its signature (`<url>.sig`) from pacman's own mirror (`pacman -Sp archlinux-appstream-data`, as the user), checks the
  signature with `pacman-key --verify <file>.sig <file>` as the user (pacman's keyring and pacman's rule: a fully trusted Arch
  signer, S17; the SHA-256 of the unsigned sync database is not enough, counter-review; SD4), and only then extracts its XML
  and icons into its cache. That copy is used for display only: a package name it
  gives must exist in pacman's database, and the sheet shows the package that will be installed. It is replaced when
  pacman's database names another version. (3) pacman for every package: version, sizes, licence (`License`, used when
  AppStream has none), description. (4) The AUR RPC for AUR packages (ST7). (5) Flathub's AppStream through `flatpak` (ST2).
- **Display.** Every remote or package-provided text is plain text (`Text.PlainText`), control characters removed except
  line feeds, bounded (name 80, summary 200, description 4000 characters); AppStream's description markup (`<p>`, `<ul>`,
  `<li>`) becomes paragraphs and bullet characters, never rich text; no link inside a text is active. URLs (homepage, bug
  tracker) are buttons that open the default browser on click only (ADR-0011's open path), https only.
- **Screenshots (ST6).** Loaded when a product page opens, https only, no cookie, no `Referer`, cached; a switch in the
  Store's settings turns them off. They are the publishers' images: shown as the app's metadata gives them; needs legal
  review.
- **What is fetched, when, and from where.**

  | Host | What | When |
  |---|---|---|
  | Grassfield's host (ADR-0033 g) | `grassfield-catalog.v1.json` and `.sig` (ETag), catalog icons by hash | at Store start when the cached catalog is older than 6 h; Ctrl+R; never while the Store is closed |
  | Arch and Omarchy mirrors (pacman's own `Server`) | `archlinux-appstream-data`'s package file and its `.sig`, when that package is not installed (ST5) | when pacman's database names a version the cache does not have |
  | Arch and Omarchy mirrors | one HEAD request for the first package of a plan (e.4) | before an install |
  | Screenshot hosts named by AppStream | the images of one product page | when it opens (ST6), unless turned off |
  | aur.archlinux.org | `info` for the AUR page opened and for foreign packages' names; `search` after Return; the PKGBUILD text on click | only while the AUR is turned on (ST7) |
  | dl.flathub.org (through `flatpak`) | Flathub's AppStream; Flatpak update checks; the apps and runtimes installed | only while Flathub is turned on |
  | the user's browser | homepage, bug tracker | on click |
  | Arch and Omarchy mirrors | packages | by pacman, during an install, not by the Store |

  Requests carry no cookie, no `Referer`, the User-Agent `Grassfield-Store/1`, https only (redirects too; `file://` only
  through dev plumbing), a 15 s transfer timeout (5 minutes for the AppStream package) and a size cap (catalog 1 MiB, icon
  256 KiB, screenshot 4 MiB, AUR answer 512 KiB, AppStream package 64 MiB, its signature 4 KiB). Nothing that identifies
  the user or the machine leaves it: no installed-app list, no identifier, no telemetry, no search query to Grassfield's host (search is local; AUR
  searches go to the AUR, ST7). Metered connections: no automatic fetch.
- **Cache (bounded, ADR-0020 classes).** `$XDG_CACHE_HOME/grassfield/store/` (regenerable): the verified catalog per channel
  with its ETag, catalog icons (32 MiB, least recently used first), screenshots (128 MiB, 30 days), AUR answers (4 MiB, 1 h),
  the fetched AppStream (one version, at most 64 MiB). `$XDG_STATE_HOME/grassfield/store.json` (state, `version: 1`): the last
  accepted catalog serial per channel, the operation in flight (f), the last fetch time. The Store's preferences (sources,
  screenshots) are keys of `grassfield.json` written through the settings contract (ADR-0020 item 4). The rows are in
  ADR-0020's table of persisted files (step 1; `docs/specs/persisted-files.md` does not exist yet).

### d. Updates and the one badge (owner, ST8)
- **No partial upgrade, ever.** The Store never runs `pacman -Sy`, `-Syu` or `yay -Sua` itself, and never offers "Update"
  for one repository or AUR app: those update only with the whole system (S4, S12).
- **One checker.** The Store reads ADR-0033's result (`$XDG_STATE_HOME/grassfield/software-update.json`, written by the
  shell's checker) and asks the shell to check, as Settings does (ADR-0033 d.7). **Software Update's step 2 adds the list**
  of the other updates beside their count (`otherPackages`: name, installed and available version, sorted by name; ADR-0033
  d.3.5 as PR #16 writes it), so the Store shows which apps the next update brings without a second `checkupdates`; until
  then the Updates page shows the count (`others`, step 1). At the checker's 256 KiB cap that list is cut first
  (`otherPackagesTruncated: true`), then the notes; the counts always stay, and the Store then says "N other updates"
  without names (SD3).
- **Updates page.** The apps (entries with a desktop id) that the next system update upgrades, each marked "Updates with the
  system" (no per-app button), then "N other system packages", then "Update All…", which starts ADR-0033's "Update Now" (the
  same command and lock checks). While Omarchy's update runs: "Update in progress". When `pacman -Qu` lists packages while
  no update runs (an update that stopped, S12), the page says the last system update did not finish, with "Update All…",
  and every "Get" of a repository, AUR or setup app is refused until then (e.4).
- **Flatpak updates (Flathub on).** A Flatpak updates outside pacman's transaction: the Updates page lists them in their own
  group with "Update" per app and "Update All" for that group (`flatpak update --user`), checked by the Store when it opens
  and on "Check Now" (`flatpak remote-ls --user --updates`). `omarchy update` does not update Flatpaks.
- **Badge (owner, ST8).** The only Dock badge for updates stays on Settings (ADR-0033 U18: Grassfield and Omarchy releases).
  The Store's tile has no badge, Flatpaks included; the Store's sidebar shows the number of apps with an update.

### e. Security
1. **Explicit click, then a sheet, then an authentication.** "Get" opens a confirmation sheet; nothing starts without its
   default button. The sheet shows the source, the licence, the download and installed sizes, every package the plan adds
   (`pacman -S --print`, as the user, S10), and: for a setup, what it changes (our catalog's text, written after reading the
   recipe, plus the recipe's name); for a removal recipe, the user data it deletes; for a Flatpak, what it can reach; for the
   AUR, the warning (spec). The authentication: repository packages, the polkit sheet of b.1 at every operation, naming
   the packages (`auth_admin`, never kept); the AUR and setups, sudo's
   prompt in Omarchy's terminal (b.2); per-user installs (web apps, Flatpaks), **the sheet alone** (owner, ST3): its default
   button is the user's consent; anything running as the user can already write those files.
2. **Source and licence always shown**, on results, cards, the product page and the sheet. Without a licence the Store says
   "Licence not stated"; it never hides the row.
3. **Root code.** Only `grassfield-store-helper` (b.1) runs as root, and it runs pacman only, on validated names; it
   removes only apps the user installed, never a package of the system (b.1, S16). The Store,
   `grassfield-store-run` and everything else run as the user. Omarchy's recipes and yay call sudo themselves, as in
   Omarchy's own menu.
4. **The plan is checked before anything runs**, as the user, without root or the lock (S10), and checked again right before
   (b.1 step "checks again", b.2 step 4, under Omarchy's lock):
   - **`pacman -Qu` must list nothing but "[ignored]" packages** (MAJOR 1; S12): otherwise the databases are newer than the
     system (an `omarchy update` stopped after its keyring step, or a hand-run `pacman -Sy`): "Finish the system update first"
     with a button to Software Update. Packages the user holds with `IgnorePkg` are the user's own choice and do not block.
     With this rule the databases equal the system, so whatever a recipe or yay installs from the repositories beyond the
     Store's plan comes from those same databases: no partial upgrade from them either. That holds only while nothing syncs:
     S1 shows no recipe or helper of Omarchy's runs `-y`, and grassfield-packages' CI refuses a catalog that names a recipe
     whose text has `-Sy`, `-Syu` or `yay -Sy` (g);
   - `pacman -S --print` must resolve and must not upgrade an installed package (S4);
   - the first package URL of `pacman -Sp` that answers 404 means the databases are older than the mirror (S5): "Update your
     system first";
   - no `db.lck` and Omarchy's update lock free (S11, ADR-0033 d.5).
5. **Validated input, argument vectors only.** Package names `^[a-z0-9@_+][a-z0-9@._+-]{0,127}$`; a setup's `install` field
   `^omarchy-install-[a-z0-9-]+$` and its `remove` field `^omarchy-remove-[a-z0-9-]+$` (one cannot name the other kind), run
   only when `${OMARCHY_PATH:-/usr/share/omarchy}/bin/<name>` exists; recipe arguments `^[a-z0-9][a-z0-9.-]{0,63}$` (at most
   4); web app names any printable text of 1 to 64 characters without `/` or control characters, not starting with `.`
   (Omarchy writes them as file names with their spaces, S9), URLs `https://` without whitespace, at most 2048 bytes; desktop
   ids of package entries `^[A-Za-z0-9._-]{1,250}\.desktop$` (web apps are not opened by id, f); Flatpak app ids
   `^[A-Za-z][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+){2,}$` (at most 255 bytes; no leading `-`); operation ids
   `^[0-9a-f]{32}$`. The one command string is b.2's terminal command, built only from those tokens; Omarchy's
   `omarchy-install-app` / `-and-launch` quote their own arguments.
6. **Untrusted data stays data.** The catalog is verified before it is parsed (g); AppStream comes from a signed Arch
   package, installed, or fetched and checked by its own signature with pacman's keyring (S17); AUR answers, Flathub data
   and screenshots are third-party: bounded, never executed, never rendered as rich text. An AUR package's PKGBUILD is
   shown as plain text on request, never run by the Store (yay builds it, in Omarchy's terminal).
7. **The AUR warning** before every AUR install, and the AUR's facts on the product page: maintainer (or "orphaned"), votes,
   popularity, last change, out-of-date flag.
8. **Dev sessions (ADR-0019)** never install, uninstall or start Omarchy's commands, pkexec or flatpak operations: the queue
   runs fake programs only (dev plumbing `GRASSFIELD_STORE_INSTALLER` for b.2 and b.3, `GRASSFIELD_STORE_PKEXEC` for b.1;
   both come with step 3);
   catalogs and keys come from fixtures (`GRASSFIELD_STORE_CATALOG_URL`, `GRASSFIELD_STORE_KEYRING`,
   `GRASSFIELD_STORE_FIXTURE` for fake pacman, AppStream and flatpak roots); "Open" follows ADR-0011's dev open policy. The
   five names join ADR-0019's dev plumbing table with the code (step 1).
9. **Reviews.** The catalog verification (step 1), and the helper, its policy, `grassfield-store-run` and the launch code
   (step 3) need an opus security review before merge.
10. **Legal (§14), each one needs legal review:** the sidebar's structure and the section names copying Apple's store
    application (Discover, Create, Work, Play, Develop, Categories, Updates); the name "Grassfield Store"; publishers' icons in
    our catalog (ST10); screenshots and AppStream texts shown as the apps' metadata gives them; the AUR's and Flathub's data
    shown in the Store.

### f. The app and its processes
- **A new app, `apps/store`, packaged as `grassfield-store`.** `apps/` is where Grassfield's apps live (master-prompt §5.2,
  §6); the new folder is the brief's deliverable. It is a separate application (macOS has one), not a Settings pane: its
  window, queue and caches have no place in Settings, and a separate package lets Grassfield ship without it and lets a user
  remove it. No new language (C++, QML and a shell script for b.2), no new service or daemon (the Store runs only while open;
  background checks are ADR-0033's), no new design components before the shared ones (`ui/Grassfield/Ui`). The package also
  ships `grassfield-store-helper`, its polkit policy and `grassfield-store-run`. New runtime dependencies of
  `grassfield-store` only: `kimageformats` (the JPEG XL icons, S3), `gnupg` (`gpgv`, already pulled by pacman, declared);
  `archlinux-appstream-data` and `flatpak` as `optdepends` (ST5, ST2). AppStream is read by the Store's own reader
  (`QXmlStreamReader` and zlib, both already linked by Qt), not by `appstream-qt` (SD5). PackageKit, GNOME Software and KDE
  Discover are not used: they need PackageKit's root daemon (§5.8, not installed) and bypass Omarchy's commands (D1).
- **Build.** A CMake target in `apps/store/CMakeLists.txt` with the same wrapper as the other apps (ADR-0023), and
  `package_grassfield-store()` in `packaging/arch/PKGBUILD`, depending on `grassfield-desktop=$pkgver-$pkgrel` (design system,
  translations, menu bridge).
- **Child processes the Store owns for reading** (pacman queries, `gpgv`, `pacman-key --verify`, `bsdtar`, `flatpak`
  queries; `apps/store/src/childprocess.cpp`): an
  argument vector, `LC_ALL=C`, stdin from `/dev/null`, output capped (8 MiB), each in its own process group, stopped after
  20 s with SIGTERM then SIGKILL 5 s later, and all stopped the same way when the Store quits. None of them writes.
- **Operations** follow b: pkexec is waited for (b.1); the terminal is followed through its files (b.2); web apps and
  Flatpaks are waited for (b.3). The Store never sends a signal to pacman, yay, makepkg, a recipe, their terminal or the
  helper (S6).
- **One operation at a time**, in a queue the user fills (Get, Uninstall, Update All). Before it starts, the operation is
  written to `store.json`: its id, kind, path, app, source, planned packages and versions, start time.
- **After an operation**, and whenever `/var/lib/pacman/local`, `pacman.log`, `~/.local/share/applications` or the Flatpak
  installation change (watched), the Store reads the state again. Progress: b.1 and b.2 count `[ALPM] installed` lines of
  pacman's log since the start against the plan (S10), indeterminate before the first; b.3 has none.
- **Recovery after a failure or a crash.** On start, a record is compared with what is there: an `exit` file (b.1, b.2), a
  running helper or script (their `started` pid and start time), the system's state:
  - exit code 0 and everything planned is there: done, nothing said;
  - a part is there (an exit code other than 0, or none): "The installation was interrupted: 15 of 110 packages were
    installed", with "Try Again" (the same plan; `--needed` completes it) and the list;
  - nothing is there: "The installation did not finish", with "Try Again";
  - still running: the Store follows it again;
  - `db.lck` exists and no pacman runs: the Store explains that a package manager stopped mid-way and shows Arch's recovery
    (remove the lock file only when no pacman runs), as text to copy. It never removes the root-owned lock itself;
  - pacman later reports files that "exist in filesystem" (left by a killed pacman, S6): the message is shown as is, with
    the explanation; the Store never runs `--overwrite`.
- **Open.** A package's app opens through ADR-0011: `uwsm-app -- <desktop-id>` in a real session, through `apps/appscope.h`
  (a desktop-id variant beside `startApplication`); the desktop id comes from AppStream's launchable, our catalog, or the
  package's files (`pacman -Qlq`, S10). Several entries: the catalog's choice, else the one AppStream names, else the first;
  none: no "Open", and the product page says the app has no window. **A web app opens with `omarchy-launch-webapp <url>`**
  (Omarchy's own launcher, which scopes the browser itself), never by its entry's file name, which has spaces uwsm refuses
  (S14). A Flatpak opens with its exported desktop id, or `flatpak run <app-id>` in its own scope when the session does not
  see the export folder (step 3 checks it).

### Offline
- The Store opens with the cached catalog, AppStream (local) and pacman's databases: Discover, Categories, search and product
  pages work, with a bar "You're offline. The catalog is from 27 October." Screenshots not cached show a placeholder.
- "Get" and "Update All…" are disabled with the reason. "Open" and "Uninstall" work (no network needed).
- No catalog yet (first start offline, or no hosting: the base is still `packages.grassfield.invalid`): Discover shows what
  AppStream allows (no editorial sections), with a line saying the Grassfield catalog is unavailable. A catalog older than
  30 days is used, with a note.
- Connectivity and metering come from Qt's network information (NetworkManager backend): no new dependency.

### g. The catalog: format, signature, publication (contract with grassfield-packages)
**Where.** Beside each channel's repository, in its snapshot (ADR-0033 g, h.2): `<base>/<channel>/<arch>/
grassfield-catalog.v1.json`, `grassfield-catalog.v1.json.sig`, and `<base>/<channel>/<arch>/catalog/<sha256>.png`. The fixed
names are redirected to the snapshot like the database, so one pointer write switches the database, the notes and the catalog
together; icons have immutable names. A catalog change is a new snapshot with the same packages: no Grassfield release, no
`pkgrel`. The Store derives the URL from the primary `Server` of `/etc/pacman.d/grassfield.conf` (`<base>/<channel>/$arch`,
ADR-0033 a), else from `GRASSFIELD_REPO_BASE` of `packaging/pacman/repository.conf` and `stable`. While the base is the
`.invalid` placeholder, nothing is fetched.

**Publication: one serialized publisher, built from the current snapshot, a conditional pointer write (MAJOR 3; ADR-0033 h.2
amended).** Package releases and catalog updates share each channel's pointer. A catalog job built from snapshot A and
published after a release B would point the channel back to A's `grassfield.db`: every client already on B would then get
"signature … is invalid" (ADR-0033 R4), and, by ADR-0033 a2, every `omarchy update` would fail. So, per channel:
1. **One publisher, publishing the latest state.** Releases and catalog updates go through one publishing job per channel,
   serialized by a CI concurrency group per channel (one run at a time, never cancelled half way). GitHub keeps one run
   pending per group and cancels it when a newer one queues (GitHub Docs, "Control the concurrency of workflows and jobs":
   "any existing `pending` job or workflow in the same concurrency group will be canceled"), and ADR-0033 builds each tag
   once (counter-review). So a run takes nothing from the event that started it: it publishes the latest state, the newest
   release built and signed for the channel (each tag's build keeps its packages, databases and notes where the publisher
   reads them, never under the pointer) and the catalog of `main`'s head. A cancelled pending run loses nothing: the next run
   publishes what it would have; a run with nothing new writes nothing.
2. **Built from the current snapshot.** The job reads the pointer (the snapshot id and its version tag), takes that snapshot's
   manifest (every file with its SHA-256), and builds the new snapshot from it: the newest built release's packages,
   databases and notes when that release is newer than the snapshot's, else the snapshot's own; the catalog of `main`'s head
   when it differs from the snapshot's, else the snapshot's own.
3. **Never backwards.** The job refuses a snapshot whose `grassfield.db` names an older version of any package than the
   current one, unless it is ADR-0033 h.2's deliberate rollback (a new snapshot with a pkgrel above the bad one).
4. **A conditional pointer write.** The pointer is written only if it still names the snapshot step 2 read (a
   compare-and-swap: the storage's conditional write on the version tag); otherwise the new snapshot is discarded and the
   job starts again from step 2. Whether the chosen storage offers a conditional write is NOT VERIFIED (the host is not
   chosen, ADR-0033 O8); without one, step 1 alone serializes, and the job reads the pointer again just before writing it.

**Format (UTF-8 JSON, at most 1 MiB, no comments).** The major version is in the file name: a v2 would be published beside
v1 for as long as v1 clients exist. Unknown keys are ignored (additions stay v1).
```json
{
  "version": 1,
  "channel": "stable",
  "serial": 1793095200,
  "generated": "2026-10-27T10:00:00Z",
  "sections": [
    { "id": "discover", "title": {"en": "Discover", "fr": "Découvrir"}, "symbol": "discover",
      "blocks": [
        { "kind": "hero",  "items": [ { "app": "org.gimp.GIMP", "eyebrow": {"en": "New in the Store"},
                                        "title": {"en": "…"}, "text": {"en": "…", "fr": "…"} } ] },
        { "kind": "cards", "items": [ { "app": "…", "eyebrow": {"en": "…"}, "title": {"en": "…"}, "text": {"en": "…"} } ] },
        { "kind": "row",   "title": {"en": "Tools for work"}, "apps": ["org.libreoffice.LibreOffice", "…"] } ] } ],
  "categories": [
    { "id": "graphics", "title": {"en": "Graphics", "fr": "Graphisme"}, "symbol": "category-graphics",
      "freedesktop": ["Graphics", "2DGraphics", "VectorGraphics", "RasterGraphics", "Photography"] } ],
  "apps": [
    { "id": "org.mozilla.firefox", "source": {"kind": "omarchy-setup", "install": "omarchy-install-browser", "args": ["firefox"],
        "remove": "omarchy-remove-browser", "removeArgs": ["firefox"], "packages": ["firefox"],
        "changes": {"en": "Installs Firefox and Omarchy's browser policy and Wayland setting."}},
      "categories": ["internet"] },
    { "id": "com.spotify.Client", "source": {"kind": "repo", "repo": "omarchy", "package": "spotify"},
      "name": {"en": "Spotify"}, "summary": {"en": "…", "fr": "…"}, "developer": {"en": "Spotify AB"},
      "license": "LicenseRef-proprietary", "homepage": "https://www.spotify.com/", "desktopId": "spotify.desktop",
      "icon": {"sha256": "…64 hex…", "bytes": 18234, "license": "LicenseRef-trademark-of-its-owner", "origin": "https://…"},
      "categories": ["music"] },
    { "id": "grassfield.webapp.hey", "source": {"kind": "webapp", "url": "https://app.hey.com"},
      "name": {"en": "HEY"}, "license": "LicenseRef-web-service", "icon": {"sha256": "…", "bytes": 9120, "license": "…", "origin": "…"},
      "categories": ["productivity"] },
    { "id": "org.inkscape.Inkscape", "source": {"kind": "flatpak", "remote": "flathub", "app": "org.inkscape.Inkscape"},
      "categories": ["graphics"] } ]
}
```
Rules (grassfield-packages' CI refuses a catalog that breaks one; the Store drops an entry that breaks one and keeps the rest,
and refuses the whole file when its top level is invalid):
- `channel` must be the channel the file was fetched from (the Store's `Server` path, or `stable` for the fallback); another
  value refuses the whole file. `serial` is per channel.
- Localized text: an object with `en` (required) and `fr` (optional); other languages are ignored by v1. Plain text, no
  control characters except `\n` in `text`; lengths: section title 40, eyebrow 40, title 80, text and summary 200,
  description 4000 code points.
- `serial`: an integer that grows with every publication of the channel (CI uses the build's Unix time). The Store refuses a
  catalog whose serial is lower than the one it accepted for that channel (a replayed old catalog), and keeps its own.
- `sections`: at most 8, `discover` first; ids `^[a-z][a-z0-9-]{0,31}$`; at most 12 blocks each; `hero` 1 to 8 items,
  `cards` up to 12, `row` up to 24 apps; `symbol` from the Store's own symbol list (an unknown one falls back to a default).
- `categories`: at most 32, each with freedesktop category names; apps outside our list are placed by their AppStream
  categories.
- `apps`: at most 2000; `id` `^[A-Za-z0-9._-]{1,255}$`, unique (an AppStream id when one exists, so our texts overlay its
  metadata); `source.kind` is `repo` (`repo` among `core`, `extra`, `multilib`, `omarchy`; the Store hides the entry when
  pacman's database has no such package), `aur` (shown only while the AUR is on), `omarchy-setup` (`install` and `remove`
  as in e.5, each of its own kind; `packages` say when it is installed; optional `removes`, the user data its removal
  deletes), `webapp` (an https URL; `icon` required), or `flatpak` (`remote` `flathub`, `app` a Flatpak id; shown only while
  Flathub is on). `license` is SPDX or `LicenseRef-…`; the package's or AppStream's licence wins when present.
- `icon` assets (owner, ST10: publishers' icons for apps without metadata, such as `[omarchy]` apps and web apps): PNG only,
  at most 256 KiB and 512 x 512, named by the SHA-256 of their bytes, which the signed file lists, so the Store checks the
  hash, with no signature per icon. Each records its licence and where it came from (`origin`, never fetched by the
  Store). An app with AppStream or Flathub metadata uses that icon, never ours. Publishers' icons are their owners'
  trademarks: needs legal review before any publication.
- CI also refuses: a `repo` package absent from the build container's Omarchy stable package set (ADR-0033 f), or one that
  owns no application entry (its file list, `pacman -Fl`; SD1); a recipe name
  absent from the pinned Omarchy release, or whose text runs `pacman -Sy`, `-Syu` or `yay -Sy` (e.4); a `flatpak` id absent
  from Flathub's AppStream in the build container; a URL that is not https.

**Signature and verification.** `grassfield-catalog.v1.json.sig` is a detached binary OpenPGP signature by the repository's
key (ADR-0033 b, O6: the same key, in CI; tests use throwaway keys). The Store verifies it before parsing, exactly as
ADR-0033 d.8 verifies the release notes: `gpgv --keyring /usr/share/grassfield/pacman-keyring/grassfield.gpg --status-fd 1`
(the keyring's private folder, ADR-0033 b.2), the signer is VALIDSIG's argument 10 (the primary key's fingerprint), listed in
`grassfield-trusted` and absent from `grassfield-revoked` of that folder. The check reads those files, not pacman's keyring,
so it works whether or not Grassfield updates are on. A catalog that fails is not used and not cached; the previous one
stays. While `grassfield-keyring` holds no key (until the owner's key exists, ADR-0033 O20) or is not installed, no catalog is
used and the Store says why.

**Built in grassfield-packages** from source files in its `catalog/` folder (one file per app, one per section, the
categories, the icons), by a standard-library Python tool, in CI, with the checks above. CI produces the catalog as an
artifact; publication stays disabled with ADR-0033's, and is the serialized publisher above once enabled.

## Owner decisions (2026-10-27, asked again after the first review; the answers in the owner's words)
| Id | Question | Options (the integrator's recommendation first) | Owner's answer |
|---|---|---|---|
| ST1 | master-prompt §4 lists a pacman-based store as a non-goal | amend §4: the Store in scope as the optional package `grassfield-store`, published after M5 · keep §4 (Flatpak-only App Center after 1.0) · the Store browsing only | « Amender §4 (Recommandé) » |
| ST2 | AUR and Flathub (the Arch and `[omarchy]` packages, web apps and Omarchy setups without downloaded code always on) | AUR opt-in, Flathub later · AUR opt-in, Flathub optional · neither · AUR on by default | « AUR et Flathub »; asked to clarify: « Les deux opt-in (Recommandé) » (both off until turned on; Flathub only when the user installed flatpak, no dependency) |
| ST3 | Authentication of per-user installs (web apps, Flatpaks), which need no root | the sheet alone · the user's password through a Grassfield polkit `auth_self` action (a new policy, against ADR-0030) | « Feuille seule (Recommandé) » |
| ST4 | The install path | P1: Omarchy's terminal, under its lock, with an exit-code file and time limits · P2: a Grassfield root helper behind polkit (repository packages only; against ADR-0033 and ADR-0028's R12 sentence, which must be amended) | « P2 : assistant root polkit »; asked about the AUR and the recipes: « Terminal pour AUR et recettes (Recommandé) » |
| ST5 | AppStream for Arch apps | depend on `archlinux-appstream-data` with `appstream-qt` · the Store downloads it · none | « melange du premier et du deuxieme »; asked to clarify: « Paquet, sinon téléchargement (Recommandé) » (the installed package when there is one, else the Store fetches it and keeps it in its cache) |
| ST6 | Screenshots (third-party hosts) | when the product page opens, with a switch · on a click · never | « À l'ouverture de la fiche (Recommandé) » |
| ST7 | AUR metadata, when the AUR is on | the AUR's web service (`info`, `search` after Return) · a daily copy of the whole AUR (10.6 MB) | « Service web de l'AUR (Recommandé) » |
| ST8 | The one update badge | Settings only (ADR-0033 U18) · both tiles · move it to the Store | « Réglages seulement (Recommandé) » |
| ST9 | Order of the steps | 1 catalog read-only and its build and signature; 2 the UI; 3 install, open, uninstall; 4 updates · UI first · 1 and 2 together | « Ordre proposé (Recommandé) » |
| ST10 | Icons of apps without metadata (the brief: "from their metadata, with their licence") | metadata only (the package's own icon, else a Grassfield glyph) · publishers' icons in our catalog, licence and origin recorded, legal review · a generic glyph | « Icônes d'éditeurs » |

## Decisions delegated by the owner (2026-10-27)
The owner's working rule of 2026-10-27, until further notice: the session decides, choosing the option that (a) brings
Grassfield closest to macOS 27 (behaviour, presentation, vocabulary) and (b) lets the end user do everything without technical
intervention (never a terminal, a configuration file, a command or a manual step of their own). Still asked: legal questions
(§14, marks, licences, publication), making anything public, a key, a secret or a release, wider root rights or changed
security rules (CLAUDE.md, master-prompt, ADR-0010, polkit beyond what is approved), money or an external service, and any
irreversible action on the owner's machine. The integrator checks each row in the review.

| Id | Question | Options | Choice | Rule applied |
|---|---|---|---|---|
| SD1 | Which repository apps the Store installs, now that `remove` takes apps with an application entry only (b.1) | only packages that own an application entry (AppStream desktop applications; catalog `repo` entries, checked by CI) · also command-line tools (AppStream `console-application`), which the helper could then not remove without a wider rule | only apps with an entry | « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »: (b) the Store can always remove what it installed, with no terminal; a wider removal rule would widen root rights, which stays the owner's; (a) the macOS store application installs apps, not tools |
| SD2 | How the polkit sheet names the packages (counter-review) | the sheet shows "Install" or "Remove" and the names, read by a strict pattern from the line polkit expands for this action id only, else the line as is · the line as polkit expands it (the helper's path, the operation id, the names) · no names (refused by the review) | the verb and the names; the raw line when it does not match | « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »: (a) macOS's authorization sheet is plain words, no path; (b) the user reads what they authorize. The names still come from polkit (pkexec's argument vector), not from the Store; the sheet is a security module (step 3, opus review); no polkit rule changes |
| SD3 | Which step adds the list of other updates to the checker, and what goes first at its 256 KiB cap (counter-review, PR #16) | Software Update's step 2 adds it (`otherPackages`, PR #16's plan after its own review), the list cut before the notes · Store step 4 adds it · the notes cut first | Software Update's step 2, as PR #16 writes it; the list first | « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »: (a) macOS's Software Update always shows its release notes, while the per-app list is an addition; one checker, one list, one name for both PRs |
| SD4 | How the Store checks a fetched AppStream package (counter-review) | its own `.sig` with `pacman-key --verify` as the user (pacman's keyring and trust rule) · `gpgv` with pacman's public keyring (no trust check) · the sync database's SHA-256 (unsigned; refused by the review) | `pacman-key --verify` | « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »: (b) nothing to set up; the Store trusts exactly what pacman trusts (S17) |
| SD5 | How the Store reads Arch's AppStream (step 1) | its own reader of the catalog XML (`QXmlStreamReader`, zlib; the fields the Store shows, every text made plain) · `appstream-qt` (libappstream's pool, a new runtime dependency; it reads the system's data locations, so the fetched copy would need its extra-location API) | its own reader | « décision déléguée par le propriétaire le 2026-10-27 : macOS d'abord, aucune intervention technique pour l'utilisateur »: (b) nothing for the user to install or set up, and one reader for the installed and the fetched copy; CLAUDE.md "no new dependency without need": f's list loses `appstream-qt` |

## Amendments made in this PR (other documents)
- **master-prompt §4** (ST1): the non-goal "a pacman-based app store" is amended for Grassfield Store.
- **ADR-0033**: d (the Store reads the list of other updates that Software Update's step 2 adds, `otherPackages`, in PR #16's
  words), g (the catalog's files in the contract; the publication row), h.2 (one serialized publisher that publishes
  the latest state, built from the current snapshot, a conditional pointer write), and the
  "no root code to install anything" of its context (ST4's helper is the exception). Its spec `docs/specs/updates.md`: U3 and
  the non-goals likewise.
- **ADR-0028**: its R12 sentence names `grassfield-store-helper` beside ADR-0033's two programs.
- **ADR-0030**: an amendment for the Store's helper and its polkit policy (`auth_admin`, never kept; the names in the
  message), beside ADR-0033's.

## Evidence
- `docs/audits/store-2026-10-27/store-probes.sh` (S0 to S15) and its output `probes-output.txt` (docker exit 0). It ran in this
  cloud session's container (Ubuntu 24.04, root in the session's sandbox) with the Docker 29.9.2 daemon started in the
  session: `docker run --rm --network host` with the session's HTTPS proxy and its CA mounted read-only, on
  `archlinux:base@sha256:52dfbd5afb23a220d5ee92dafcb4c788d96c026ed04179890c23adef4c897fa0` (ADR-0033's image). Mounted read-only,
  as data: Omarchy v4.0.4 (c668141), cloned from github.com/basecamp/omarchy. The script refuses to run outside a container;
  inside it is root, makes a user `alice`, installs packages from Omarchy's stable mirror and from Arch's archive
  (archive.archlinux.org, snapshots 2026-03-01, 2026-09-01, 2026-10-20), interrupts pacman on purpose, and everything goes with
  the container. The one change to Omarchy's template is `DisableSandbox` (Docker has no Landlock), as in ADR-0033.
- `docs/audits/store-2026-10-27/store-probes-2.sh` (S16 to S18, after the counter-review) and its output
  `probes-2-output.txt` (docker exit 0), with the same container, image and Omarchy checkout. It registers system packages
  with `pacman -S --dbonly --noscriptlet` (the rule reads pacman's database; nothing of theirs runs), builds one local package
  with `makepkg` as the user, starts a system bus and polkitd, and gives the user `alice` a throwaway password. The rule and
  the helper in it are models for the probe; the helper is step 3's code. S18 ran polkit 127-3 (the 2026-09-01 snapshot);
  the source lines cited are polkit 128's (Arch's current version; tag 128 of github.com/polkit-org/polkit), where they read
  the same.
- The macOS 27 reference: `docs/audits/store-2026-10-27/parity.md` (Apple's user guide, two public captures, not committed).

## Consequences
- **Step 1, grassfield-packages:** `catalog/` sources, the build and validation tool, a CI job producing the signed catalog
  as an artifact with a throwaway key, the serialized publisher written and disabled; its README and CLAUDE.md name the role
  (done in step 0).
- **Step 1, here:** `apps/store` backend read-only: fetch, `gpgv` verification, validation, cache, AppStream (package or
  fetched) and pacman readers, the merged model and search, all tested with fake catalogs, a throwaway keyring and fake
  pacman/AppStream roots; ADR-0019 dev plumbing rows; ADR-0020 persisted-file rows; opus security review of the
  verification. Delivered as a static library and its gtest suite (`apps/store/src`, `tests/unit/store`, 45 tests, plain
  and ASan) plus `tests/integration/store_catalog.sh` (the real gpgv against throwaway keys in a throwaway container); no
  app binary and no package yet (step 2).
- **Step 2:** the UI (Discover, sections, Categories, product page, search, Installed, the Updates list read-only), measured
  F1 against the captures, en and fr, light and dark, keyboard; offscreen captures with the fake backend; the nested shot by
  the integrator. The legal items of e.10 go to `docs/legal/visual-review.md`.
- **Step 3:** install, open, uninstall: `grassfield-store-helper` and its policy (b.1: `auth_admin`, the remove rule with
  S16's cases as tests, the plan check), the polkit sheet's names for this action (SD2), `grassfield-store-run` (b.2), web
  apps and Flatpaks (b.3); container tests with real pacman installs, a real recipe, a real `flatpak install --user` of a
  small app and an interrupted one (throwaway container), fake programs everywhere else; opus security review; the owner
  checks the real polkit dialog, sudo in Omarchy's terminal and a closed terminal in a real session.
- **Step 4:** the Updates page (system updates through ADR-0033's checker and its `otherPackages`, SD3; Flatpak updates checked by the Store) and the sidebar count; no Dock badge of the
  Store's own (ST8).
- **IPC.** Steps 1 to 3 add no shell IPC. Any new `IpcHandler` function (for example, asking the shell to check for updates
  if ADR-0033's own call does not fit) is added to `docs/specs/security.md`'s table in the same PR (`ipc_inventory`).
- **Known limits** (spec): a password for every repository install or removal (no grace period); "Uninstall…" only for apps
  the user installed, never for Omarchy's, Grassfield's or the system's packages; no per-app update for repository and AUR
  apps (Flatpaks have one); nothing installs while the last
  system update is unfinished; Flatpak updates are not part of `omarchy update` and have no Dock badge; no ratings or
  reviews; no pause or resume; the AUR and setups cancel only in Omarchy's terminal; apps outside AppStream and our catalog
  show pacman's text only; Omarchy's recipes are Omarchy's, their effects as they are in the installed release; a replayed
  old catalog is refused only once a newer one was seen.

## Review history
First opus review of PR #15 (integrator, 2026-10-27): FAIL, no blocker, 3 MAJOR, all in the docs. Confirmed by the reviewer:
the Omarchy recipe claims, the parity geometry, the free number 0037, the author without trailer, the hard rules kept in
grassfield-packages. Each finding and where it is answered:
- **MAJOR 1**, a partial upgrade still passed the install check (the keyring step's `-Sy` of `omarchy update`, then a plan
  that upgrades nothing): e.4 refuses while `pacman -Qu` lists anything but "[ignored]", checked again right before running
  (b.1, b.2), and CI refuses recipes that sync (g); S12.
- **MAJOR 2**, the Store could not tell when a detached terminal's installation ended: every path ends with an exit code
  (b): pkexec waited for (b.1), the terminal's script under Omarchy's lock with `started` and `exit` files and time limits
  (b.2; `flock -o` rather than `omarchy-update-lock run`, whose descriptor a launched app keeps, S13), the user's own
  children waited for (b.3); success = exit code 0 and state.
- **MAJOR 3**, catalog snapshots could roll the package database back: g "Publication", one serialized publisher per
  channel, built from the current snapshot, never backwards, a conditional pointer write; ADR-0033 h.2 amended in this PR.
- **Minors:** web apps open by URL (`omarchy-launch-webapp`), their ids having spaces uwsm refuses (f, S14); foreign packages
  are "Not from a repository", Grassfield's own builds excluded, Omarchy's base apps and Grassfield's packages protected (a);
  ADR-0033 d, g and h.2 amended, and ADR-0028 and ADR-0030 for the helper ("Amendments"); ST3's polkit option recorded as
  against ADR-0030 and P2 as against ADR-0033 (decisions table); "needs legal review" on every legal point (e.10, c, g);
  `install` and `remove` patterns of their own kind and the `channel` field checked (e.5, g); evidence: the S0 label
  corrected (S5 to S15 on Arch's archive), the S7 and S8 values now in the output (flatpak's version, the overlap with
  Omarchy's lists, `cache-control` instead of a refresh period), the closed real terminal marked NOT VERIFIED (S6), the
  parity matrix's capture URLs in full. All ten owner decisions asked again and recorded in the owner's words.

Opus counter-review of PR #15 at 3292292 and grassfield-packages PR #1 at 7ea772e (integrator, 2026-10-27): FAIL, 1 MAJOR.
The three earlier MAJORs confirmed closed. Each finding and where it is answered:
- **MAJOR** (P2 wider than the owner's choice): `auth_admin`, never `_keep` (b.1; S18: every call asks); `remove` takes only
  explicitly installed packages that own an application entry, with a fixed deny list (kernels, firmware, `base`, `sudo`,
  `systemd`, the boot tools, pacman, Omarchy's two package lists, Grassfield's packages, `HoldPkg`) and the whole `-Rs
  --print` plan checked (b.1, a); the package names in the polkit sheet, through the policy's `$(command_line)` (b.1, SD2;
  S18); the probe S16 proves the rule and the deny list (and found that `-Rns --print` is refused, so the plan is read with
  `-Rs --print` and a plan that does not resolve refuses).
- **Minors:** the list of other updates is Software Update's step 2 (`otherPackages`, PR #16's text, carried word for word
  into ADR-0033 here) and goes first at the checker's cap (d, SD3); the Store's hold
  on Omarchy's lock shows "Update in progress" in Software Update (b.1, spec); a fetched AppStream package is checked by its
  own signature with `pacman-key --verify` (c, SD4; S17); the publisher publishes the latest state, so a cancelled pending
  run loses nothing (g); `store-probes.sh:11` names S13 too; the AUR field list matches the output (no MakeDepends).
- Delegated decisions SD1 to SD4 recorded under the owner's working rule of 2026-10-27.
