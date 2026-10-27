# ADR-0037: Grassfield Store: an app that installs, opens and uninstalls apps through Omarchy, with a signed catalog
Status: Proposed (cloud session, owner brief 2026-10-27, step 0; docs only, no code in either repository before the opus
PASS). Every choice marked **open** waits for the owner ("Owner decisions"); the install path (b) stays open until ADR-0033
passes its review. · Date: 2026-10-27 · Decider: owner (every open choice), integrator (merge after the opus PASS) ·
Number: 0037 (0033 Software Update, 0034 clipboard, 0035 dialogs, 0036 tiling are taken by open PRs)

This ADR is also part of the contract between this repository (the app, `apps/store`, packaged as `grassfield-store`) and
`grassfieldhq/grassfield-packages` (the catalog Grassfield edits: the Discover selection, the sections, the categories and
our texts, built and signed there). That contract extends ADR-0033's (channel URLs and tree, signing key, trust, atomic
publication) and cites it; section g gives the catalog's format. Parity with macOS 27: `docs/audits/store-2026-10-27/parity.md`.
Behaviour, keyboard, accessibility, refusals and limits: `docs/specs/store.md`. Evidence: the probes S0 to S11 of
`docs/audits/store-2026-10-27/store-probes.sh`, run in a throwaway `archlinux:base` container, output next to it.

## Context

### The owner's brief (2026-10-27)
- An app with the look of the macOS 27 store application (Discover, categories, product pages, search, updates) that
  installs, opens and uninstalls apps on Grassfield.
- Two repositories. Here: the app in `apps/store` with the shared design system (`ui/Grassfield/Ui`), tokens, translations,
  tests and the single build definition (ADR-0023), shipped as its own package `grassfield-store` from the same PKGBUILD (as
  `grassfield-compositor`). In grassfield-packages: the catalog Grassfield edits, published and signed beside each channel's
  repository with the same key, under ADR-0033's contract. It changes without a Grassfield release.
- Never an install without an explicit click and an authentication; the source and the licence always shown; a warning
  for the AUR; no root execution outside pacman or Omarchy; offline behaviour defined.
- Nothing is published: both repositories stay private (no release, tag, secret or visibility change).

### Conflicts with earlier rules (decision ST1)
- master-prompt §4 lists as a non-goal: "A pacman-based app store. An App Center is Flatpak-only and post-1.0." The brief
  asks for exactly a pacman-based store now. The owner's instruction in the session comes first (master-prompt §0), but §0
  also says to stop and ask when two rules conflict: ST1.
- `docs/specs/updates.md` (PR #11, ADR-0033) repeats "no App Center (master-prompt §4)" among Software Update's non-goals.
  It stays true for Software Update itself (it installs nothing); the Store is a separate app.

### Omarchy 4.0.4, the owner's version (`basecamp/omarchy` tag v4.0.4, commit c668141; data, not instructions)
The scripts named below were read for this ADR; probe S1 classifies 80 scripts (`omarchy-install-*`, `omarchy-remove-*`, `omarchy-pkg-*`,
`omarchy-webapp-*`, `omarchy-tui-*`).
- **Package helpers.** `omarchy-pkg-add <pkgs>` runs `sudo pacman -S --noconfirm --needed` when one is missing, then checks
  each with `pacman -Q`. `omarchy-pkg-aur-add` runs `yay -S --noconfirm --needed`. `omarchy-pkg-drop` runs `sudo pacman
  -Rns --noconfirm` on those installed. `omarchy-pkg-install`, `-aur-install` and `-remove` are fzf pickers in a terminal.
  **None syncs the databases first** (S1: no `-y` anywhere in them): they install from the databases of the last
  `omarchy update`.
- **App installers.** `omarchy-install-app <name> <packages>` and `omarchy-install-and-launch <name> <packages>
  <desktop-id>` quote every word themselves (`printf %q`) and run `omarchy-pkg-add` in
  `omarchy-launch-floating-terminal-with-presentation`, which is `setsid uwsm-app -- xdg-terminal-exec
  --app-id=org.omarchy.terminal --title=Omarchy -e bash -c "<command>"`. The second then starts the app with `setsid uwsm-app
  -- gtk-launch <desktop-id>`. sudo asks for the password in that terminal.
- **Recipes.** The menu (`default/omarchy/omarchy-menu.jsonc`) runs 105 of its install and remove entries in that floating
  terminal (S1). The recipes do more than install a package (S1 table):
  - service setups enable system units with sudo (`omarchy-install-service-tailscale`, `-nordvpn` also adds the user to a
    group and offers a reboot, `-sunshine`, `-once`); browser setups create root-owned policy folders under `/etc`
    (Chromium-based browsers) or in the browser's `distribution` folder (Firefox, Zen) and copy Omarchy's Chromium flags;
  - `omarchy-install-gaming-lutris` rewrites `/usr/bin/lutris`'s first line with `sudo sed -i`;
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
- **Web apps.** `omarchy-webapp-install <name> <url> <icon>` writes `~/.local/share/applications/<name>.desktop` (Exec
  `omarchy-launch-webapp "<url>"`) and an icon under `~/.local/share/icons/hicolor/256x256/apps/`, as the user, no root. It
  refuses a name with `/` and a URL that is not http(s) or has whitespace. Given a local icon file it makes no network
  request (S9: 0 calls); given an icon URL or nothing it downloads from that URL, the site and, as a last resort, Google's
  favicon service. `omarchy-webapp-remove <name>` removes both (S9).
- **Updates.** `omarchy update`: snapshot, keyrings, `pacman -Syu`, migrations, `yay -Sua` for AUR packages
  (`omarchy-update-aur-pkgs`), mise, orphans; under `${XDG_RUNTIME_DIR}/omarchy-update.lock` (ADR-0033 Context). No Flatpak
  update. Omarchy installs a Flatpak only for GeForce NOW; its launcher can remove any Flatpak.

### Arch Linux facts measured here (S3 to S11)
- **A database newer than the system breaks installs (S4).** System at the Arch snapshot of 2026-03-01 with python, gtk3,
  qt6-base and ffmpeg; database of 2026-10-20 (`pacman -Syy` without `-u`; 220 of the 322 installed packages have newer
  versions in it). `pacman -S gimp` is refused: "installing libjxl (0.12.0-1) breaks dependency 'libjxl.so=0.11-64' required
  by ffmpeg" (the same for x265); `blender` and `thunderbird` cannot be resolved either; `pacman -S mpv` would upgrade the
  installed `ffmpeg`, `libbluray` and `libvpx` alone, leaving everything else that uses them at the old version. With the
  database the system was upgraded from, gimp's plan installs 44 packages and upgrades nothing installed; `pacman -Syu gimp`
  touches 285. The rule is Arch's (wiki, System maintenance: "Partial upgrades are unsupported"). Nothing in Grassfield may
  run `pacman -Sy`.
- **A database older than the mirror fails cleanly (S5).** System and database at 2026-09-01, Server = Omarchy's stable
  mirror (2026-10-22): `pacman -S fd` asks for `fd-10.5.0-2`, the mirror answers 404, "failed to commit transaction", exit 1,
  nothing installed. The cure is a full update first.
- **Interrupting pacman (S6: 110 packages, none installed before, a signal during the commit).** SIGINT (Ctrl+C) and SIGHUP
  (the terminal closed) stop after the current package and **exit 0** with 16 of 110 installed. SIGTERM (exit 143) and SIGKILL
  (exit 137) leave `db.lck` (the next pacman refuses: "unable to lock database"), an incomplete database entry for the package
  being extracted (`pacman -Dk`: "description file is missing", "file list is missing") and some of its files on disk with no
  owner (12 and 7). So an exit code says nothing about success, and nothing may signal pacman.
- **One transaction at a time (S11).** With `db.lck` held: "failed to init transaction (unable to lock database)", exit 1.
- **What a user can read (S10).** `/var/log/pacman.log` (0644) and `/var/lib/pacman/local` (0755, its mtime changes on each
  transaction); `pacman -S --print`, `pacman -Sp` and `pacman -Rs --print` answer as the user, without root or the lock (`-n`
  cannot be combined with `--print`); a removal that would break another package is refused there too ("removing glib2 breaks
  dependency … required by accountsservice"); `pacman -Qlq`/`-Qqo` map a package to its `.desktop` file and back.
- **AppStream for Arch (S3).** `archlinux-appstream-data` 20261017-1 (`[extra]`, 20.6 MiB download, 21 MiB installed):
  `/usr/share/swcatalog/xml/extra.xml.gz` (8.2 MB) has 1390 desktop applications, all with `pkgname`, a desktop-id
  `launchable`, categories and a cached icon; 946 with `project_license`; 916 with screenshots, hosted on 280 different hosts
  (raw.githubusercontent.com, cdn.kde.org, gitlab.gnome.org first). Its 3860 cached icons are **JPEG XL** (`.jxl`).
  `[core]` has none, `[multilib]` one (Steam), `[omarchy]` none: Spotify, 1Password, Heroic, Visual Studio Code, Chrome have
  no AppStream entry. `appstreamcli search` reads the pool as a user. `appstream-qt` 1.2.1 is 153 KiB over `appstream`.
- **The AUR (S7).** RPC v5 `info` gives Name, Version, Description, Maintainer, NumVotes, Popularity, OutOfDate,
  LastModified, License, URL, URLPath, Depends, MakeDepends, OptDepends, Keywords, FirstSubmitted. `search` by name answers
  in one request (72 results for "chrome"). The whole-AUR dump `packages-meta-v1.json.gz` is 10.6 MB (123 078 packages,
  refreshed every 5 minutes, no licence field); `packages-meta-ext-v1.json.gz` 14.6 MB.
- **Flatpak and Flathub (S8).** `flatpak` 1.18.4 adds 20 packages to the probe's machine (among them ostree, pipewire,
  polkit and xdg-desktop-portal, most of which Omarchy already has). `flatpak remote-add --user flathub …` works as a user
  without root (the user owns `~/.local/share/flatpak`). Flathub lists 3502 apps; its AppStream is 10.8 MB compressed plus a
  50.9 MB uncompressed copy; 117 MB under `~/.local/share/flatpak` before any app. No app was installed (runtimes are hundreds
  of MB): NOT VERIFIED.

### The owner's machine (integrator's survey, 2026-10-27)
pacman, yay and the `appstream` library are installed; flatpak, PackageKit and `archlinux-appstream-data` are not.

### Grassfield today
- `apps/` holds the Grassfield apps (Settings, Files, Preview, helpers), each a Qt/QML front end over a C++ backend, built by
  CMake (ADR-0023) and packaged by `packaging/arch/PKGBUILD` (split packages `grassfield-desktop`, `grassfield-compositor`,
  `grassfield-icons`).
- ADR-0011: one launch path; native apps start applications with `apps/appscope.h` (`uwsm-app -- …` in a real session).
- ADR-0018: badges are set by the application itself (Unity LauncherEntry through the menu bridge).
- ADR-0019: one run-mode rule; dev plumbing honoured only in a dev session.
- ADR-0020: persisted files (config, state), single writer of `grassfield.json`.
- ADR-0030: privileged changes through the system services' own polkit actions, `interactive = true`.
- ADR-0033 (PR #11, Proposed, in its second review; read at 3cec873): the `[grassfield]` repository in two channels, one
  signing key in CI, `grassfield-keyring` (its files in the private folder `/usr/share/grassfield/pacman-keyring/`, and no key
  at all until the owner's exists, O20), signed release notes verified with `gpgv`, atomic publication by snapshot and pointer,
  Software Update (its checker in the shell, the Settings pane, the Dock badge on Settings for Grassfield and Omarchy
  releases, "Update Now" = Omarchy's update in its floating terminal), and a root helper behind Grassfield's own polkit
  action for the channel only.

## Decision

### Overview
```
grassfieldhq/grassfield-packages                         grassfieldhq/grassfield
  catalog/ (our texts, sections, categories, icons)        apps/store  → package grassfield-store
     └ CI: validate → grassfield-catalog.v1.json + .sig       grassfield-store (Qt/QML + C++ backend, runs as the user)
          + catalog/<sha256>.png, in the channel's            ├ catalog: fetch (https), gpgv, validate, cache
          snapshot beside grassfield.db (ADR-0033 h)          ├ sources: pacman (-Sl/-Si/-Q, --print), AppStream pool,
                                                              │          Omarchy recipes, web apps, AUR RPC (if on)
                                                              ├ queue: one operation at a time → the install path (b)
                                                              ├ watcher: /var/lib/pacman/local, pacman.log, applications/
                                                              └ Open: ADR-0011 (uwsm-app -- <id>.desktop)
Updates: ADR-0033's checker (shell) → software-update.json → the Store's Updates page; "Update All…" = ADR-0033's "Update Now"
```

### a. Sources (open: ST2)
Every app in the Store comes from one source, shown on its button row, its product page and its confirmation sheet:

| Source | What | Installed by | Proposed default |
|---|---|---|---|
| Arch repositories | `[core]`, `[extra]`, `[multilib]` through Omarchy's mirror | pacman | on |
| `[omarchy]` | Omarchy's own repository (prebuilt Chrome, Spotify, VS Code, 1Password, …) | pacman | on |
| Omarchy setups | Omarchy's `omarchy-install-*` recipes our catalog lists, each with what it changes, written after reading it | the recipe | on, except the recipes that download and run code outside pacman (GeForce NOW, Battle.net, dev environments) |
| Omarchy web apps | sites our catalog lists, with the icon from our catalog | `omarchy-webapp-install` | on |
| AUR | user packages, not reviewed by anyone | `yay` through Omarchy's `omarchy-pkg-aur-add` | off; a Store setting turns it on, and every AUR install shows the warning |
| Flathub | Flatpak apps, sandboxed, per-user installs without root | `flatpak --user` | not in steps 1 to 4 (a new dependency, a second update path; see ST2) |

An app that exists in several sources shows the first of: Omarchy setup (it configures what Omarchy configures), Arch or
`[omarchy]` package, Flathub, AUR. The catalog can pin a source per app.

### b. The install path (open until ADR-0033's PASS: ST4)
The Store installs and uninstalls through **the same path ADR-0033 keeps for installing**. Until ADR-0033 passes, this section
does not choose. The candidates, and what each means here:
- **P1, Omarchy's own commands in Omarchy's floating terminal** (ADR-0033's current draft for "Update Now"): repository
  packages with `omarchy-install-and-launch` / `omarchy-install-app` (they quote their arguments) or `omarchy-pkg-add`;
  setups with their recipe; AUR with `omarchy-pkg-aur-add`; removals with `omarchy-pkg-drop` or the setup's removal recipe.
  sudo asks in the terminal. Progress: the Store reads pacman's log (installed packages over the planned ones, S10); the
  details stay in the terminal. Cancel: the terminal's own Ctrl+C or closing it, which interrupts pacman between packages
  (S6: exit 0, a part installed); the Store never signals the terminal.
- **P2, a Grassfield root helper behind its own polkit action** (ADR-0030's dialog; ADR-0033 uses this pattern for the
  channel only): `pacman -S --needed --noconfirm <validated names>` and `pacman -Rns`. No terminal; the helper reports
  progress. It covers repository packages only: yay must not run as root and the recipes call sudo themselves, so the AUR
  and the setups would still run as in P1.
Whichever path, sections e and f hold: the plan is checked first, one operation at a time, success is read from the system,
and nothing signals pacman.

### c. Catalog and metadata (open: ST5, ST6, ST7)
- **Sources of metadata.** (1) Our catalog (section g): sections, cards, categories, our texts, icons for apps without
  AppStream, the list of setups and web apps. (2) AppStream for Arch packages (ST5). (3) pacman for every package: version,
  sizes, licence (`License`, used when AppStream has none), description. (4) The AUR RPC for AUR packages (ST7).
- **Display.** Every remote or package-provided text is plain text (`Text.PlainText`), control characters removed except
  line feeds, bounded (name 80, summary 200, description 4000 characters); AppStream's description markup (`<p>`, `<ul>`,
  `<li>`) becomes paragraphs and bullet characters, never rich text; no link inside a text is active. URLs (homepage,
  bug tracker) are shown as a button that opens the default browser on click only (ADR-0011's open path), https only.
- **What is fetched, when, and from where.**

  | Host | What | When |
  |---|---|---|
  | Grassfield's host (ADR-0033 g) | `grassfield-catalog.v1.json` and `.sig` (ETag), catalog icons by hash | at Store start when the cached catalog is older than 6 h; Ctrl+R; never while the Store is closed |
  | Screenshot hosts named by AppStream | the images of one product page | ST6 |
  | aur.archlinux.org | `info` for the AUR page opened; `search` after Return; the PKGBUILD text on click | only while the AUR is turned on (ST7) |
  | the user's browser | homepage, bug tracker | on click |
  | Arch and Omarchy mirrors | one HEAD request for the first package of a plan (e.4) | before an install |
  | Arch and Omarchy mirrors | packages | by pacman, during an install, not by the Store |

  Requests carry no cookie, no `Referer`, the User-Agent `Grassfield-Store/1`, https only (redirects too; `file://` only
  through dev plumbing), a 15 s transfer timeout and a size cap (catalog 1 MiB, icon 256 KiB, screenshot 4 MiB, AUR answer
  512 KiB). Nothing that identifies the user or the machine leaves it: no installed-app list, no identifier, no telemetry,
  no search query to Grassfield's host (search is local). Metered connections: no automatic fetch.
- **Cache (bounded, ADR-0020 classes).** `$XDG_CACHE_HOME/grassfield/store/` (regenerable): the verified catalog per channel
  with its ETag, catalog icons (32 MiB, least recently used first), screenshots (128 MiB, 30 days), AUR answers (4 MiB, 1 h).
  `$XDG_STATE_HOME/grassfield/store.json` (state, `version: 1`): the last accepted catalog serial per channel, the operation in
  flight (f), the last fetch time. The Store's preferences (sources, screenshots) are keys of `grassfield.json` written through
  the settings contract (ADR-0020 item 4). The rows land in `docs/specs/persisted-files.md` with the code (step 1).

### d. Updates and the one badge (open: ST8)
- **No partial upgrade, ever.** The Store never runs `pacman -Sy`, `-Syu` or `yay -Sua` itself, and never offers "Update"
  for one repository or AUR app: under Arch, those update only with the whole system (S4).
- **One checker.** The Store reads ADR-0033's result (`$XDG_STATE_HOME/grassfield/software-update.json`, written by the
  shell's checker) and asks the shell to check, as Settings does (ADR-0033 d.7). ADR-0033's checker already runs
  `checkupdates` once; its JSON gains, in ADR-0033's step 1, a bounded list of the other updates (name, installed, available;
  at most 2000) so the Store can show which apps the next update brings. No second `checkupdates`, no second database copy.
- **Updates page.** The apps (entries with a desktop id) that the next system update upgrades, each marked "Updates with the
  system" (no per-app button), then "N other system packages", then **"Update All…"**, which starts ADR-0033's "Update Now"
  (the same command and the same lock checks). While Omarchy's update runs, the page says "Update in progress".
- **Badge.** Recommended (ST8): the Dock badge of the system update stays where ADR-0033 puts it (Settings, U18: Grassfield
  and Omarchy releases); the Store's tile shows no badge for repository or AUR apps, since they belong to that same update;
  the Store's sidebar shows the number of apps with an update. One pending transaction never shows as two badges.

### e. Security
1. **Explicit click, then a sheet, then an authentication.** "Get" opens a confirmation sheet; nothing starts without its
   default button. The sheet shows the source, the licence, the download and installed sizes, every package the plan adds
   (`pacman -S --print`, as the user, S10), and: for a setup, what it changes (our catalog's text, written after reading the
   recipe, plus the recipe's name); for a removal recipe, the user data it deletes; for the AUR, the warning (spec). The
   authentication is the path's (sudo in Omarchy's terminal, or the polkit dialog). Per-user installs (web apps, Flathub if
   chosen) have no system authentication: ST3.
2. **Source and licence always shown**, on results, cards, the product page and the sheet. Without a licence the Store says
   "Licence not stated"; it never hides the row.
3. **No root code of the Store's own** under P1: the Store runs as the user and starts only Omarchy's commands, which run
   pacman or yay through sudo. Under P2 the helper is the only root code, runs pacman only, takes an argument vector and
   follows ADR-0033 c's rules (clean environment, validated names, refused while `db.lck` exists), with an opus security
   review before merge.
4. **The plan is checked before anything runs** (as the user, no root, no lock, S10):
   - `pacman -S --print` refuses the install when the plan would upgrade an installed package (the database is newer than
     the system: S4) or pacman cannot resolve it: "Update your system first" with a button to Software Update;
   - the first package URL of `pacman -Sp` that answers 404 means the database is older than the mirror (S5): the same
     message;
   - an operation is refused while `/var/lib/pacman/db.lck` exists or Omarchy's update lock is held (S11, ADR-0033 d.5).
5. **Validated input, argument vectors only.** Package names `^[a-z0-9@_+][a-z0-9@._+-]{0,127}$`; Omarchy commands
   `^omarchy-(install|remove)-[a-z0-9-]+$` and run only when `${OMARCHY_PATH:-/usr/share/omarchy}/bin/<name>` exists; recipe
   arguments `^[a-z0-9][a-z0-9.-]{0,63}$` (at most 4); web app names `^[^/\x00-\x1f]{1,64}$` not starting with `.`, URLs
   `https://` without whitespace, at most 2048 bytes; desktop ids `^[A-Za-z0-9._-]{1,250}\.desktop$`. The one place a command
   string exists is P1's terminal (`bash -c`); it is built only from those validated tokens, and Omarchy's
   `omarchy-install-app` / `-and-launch` quote their own arguments.
6. **Untrusted data stays data.** The catalog is verified before it is parsed (g); AppStream comes from a signed Arch package;
   AUR answers and screenshots are third-party: bounded, never executed, never rendered as rich text. An AUR package's
   PKGBUILD is shown as plain text on request, never run by the Store (yay builds it, in P1's terminal).
7. **The AUR warning** before every AUR install, and the AUR's facts on the product page: maintainer (or "orphaned"),
   votes, popularity, last change, out-of-date flag.
8. **Dev sessions (ADR-0019)** never install, uninstall or start Omarchy's commands: the queue runs a fake installer only
   (dev plumbing `GRASSFIELD_STORE_INSTALLER`); catalogs and keys come from fixtures (`GRASSFIELD_STORE_CATALOG_URL`,
   `GRASSFIELD_STORE_KEYRING`, `GRASSFIELD_STORE_FIXTURE` for fake pacman and AppStream roots); "Open" follows ADR-0011's dev
   open policy. The four names join ADR-0019's dev plumbing table with the code (step 1).
9. **Reviews.** The catalog verification (step 1) and the install, uninstall and launch code (step 3) need an opus security
   review before merge.

### f. The app and its processes
- **A new app, `apps/store`, packaged as `grassfield-store`.** `apps/` is where Grassfield's apps live (master-prompt §5.2,
  §6); the new folder is the brief's deliverable. It is a separate application (macOS has one), not a Settings pane: its
  window, queue and caches have no place in Settings, and a separate package lets Grassfield ship without it and lets a user
  remove it. No new language (C++ and QML), no new service or daemon (the Store runs only while open; background checks are
  ADR-0033's), no new design components before the shared ones (`ui/Grassfield/Ui`). New runtime dependencies of
  `grassfield-store` only: `archlinux-appstream-data` and `appstream-qt` (if ST5 = A) and `kimageformats` (the JPEG XL icons,
  S3), `gnupg` (`gpgv`, already pulled by pacman, declared). PackageKit, GNOME Software and KDE Discover are not used: they
  need PackageKit's root daemon (§5.8, not installed) and bypass Omarchy's commands (D1).
- **Build.** A CMake target in `apps/store/CMakeLists.txt` with the same wrapper as the other apps (ADR-0023), and
  `package_grassfield-store()` in `packaging/arch/PKGBUILD`, depending on `grassfield-desktop=$pkgver-$pkgrel` (design system,
  translations, menu bridge).
- **Child processes the Store owns** (pacman queries, `gpgv`, `appstreamcli` if used): an argument vector, `LC_ALL=C`, stdin
  from `/dev/null`, output capped (8 MiB), each in its own process group, stopped after 20 s with SIGTERM then SIGKILL 5 s
  later, and all stopped the same way when the Store quits. None of them writes.
- **The operation itself is not a child the Store may stop.** Under P1 it runs in its own `uwsm-app` scope (ADR-0011) and
  goes on if the Store quits; under P2 it is a root process the user cannot signal. The Store never sends a signal to pacman,
  yay, makepkg, a recipe or their terminal (S6).
- **One operation at a time**, in a queue the user fills (Get, Uninstall, Update All). Before it starts, the operation is
  written to `store.json`: its id, kind, app, source, planned packages and versions, start time.
- **Success is read from the system, never from an exit code** (S6: an interrupted pacman exits 0). After the operation,
  and whenever `/var/lib/pacman/local`, `pacman.log` or `~/.local/share/applications` change (watched), the Store reads the
  state again: `pacman -Q` against the plan, the `.desktop` file of a web app, the recipe's packages. Then the record is
  cleared.
- **Recovery after a failure or a crash.** On start, a record without a running operation is compared with the system:
  - everything planned is there: done, nothing said;
  - a part is there: "The installation was interrupted: 16 of 110 packages were installed", with "Try Again" (the same plan;
    `--needed` completes it) and the list;
  - nothing is there: "The installation did not finish", with "Try Again";
  - `db.lck` exists and no pacman runs: the Store explains that a package manager stopped mid-way and shows Arch's recovery
    (remove the lock file only when no pacman runs), as text to copy. It never removes the root-owned lock itself;
  - pacman later reports files that "exist in filesystem" (left by a killed pacman, S6): the message is shown as is, with
    the explanation; the Store never runs `--overwrite`.
- **Open.** An installed app opens through ADR-0011: `uwsm-app -- <desktop-id>` in a real session, through `apps/appscope.h`
  (a desktop-id variant beside `startApplication`); web apps through their own `.desktop` file the same way. The desktop id
  comes from AppStream's launchable, our catalog, or the package's files (`pacman -Qlq`, S10). Several entries: the catalog's
  choice, else the one AppStream names, else the first; none: no "Open", and the product page says the app has no window
  (a command-line tool).

### Offline
- The Store opens with the cached catalog, AppStream (local) and pacman's databases: Discover, Categories, search and product
  pages work, with a bar "You're offline. The catalog is from 27 October." Screenshots not cached show a placeholder.
- "Get" and "Update All…" are disabled with the reason. "Open" and "Uninstall" work (no network needed).
- No catalog yet (first start offline, or no hosting: the base is still `packages.grassfield.invalid`): Discover shows what
  AppStream and our bundled defaults allow (no editorial sections), with a line saying the Grassfield catalog is unavailable.
  A catalog older than 30 days is used, with a note.
- Connectivity and metering come from Qt's network information (NetworkManager backend): no new dependency.

### g. The catalog: format, signature, publication (contract with grassfield-packages)
**Where.** Beside each channel's repository, in its snapshot (ADR-0033 g, h.2): `<base>/<channel>/<arch>/
grassfield-catalog.v1.json`, `grassfield-catalog.v1.json.sig`, and `<base>/<channel>/<arch>/catalog/<sha256>.png`. The fixed
names are redirected to the snapshot like the database, so one pointer write switches the database, the notes and the catalog
together; icons have immutable names. A catalog change is a new snapshot with the same packages: no Grassfield release, no
`pkgrel`. The Store derives the URL from the primary `Server` of `/etc/pacman.d/grassfield.conf` (`<base>/<channel>/$arch`,
ADR-0033 a), else from `GRASSFIELD_REPO_BASE` of `packaging/pacman/repository.conf` and `stable`. While the base is the
`.invalid` placeholder, nothing is fetched.

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
      "categories": ["productivity"] } ]
}
```
Rules (the CI of grassfield-packages refuses a catalog that breaks one; the Store drops an entry that breaks one and keeps the
rest, and refuses the whole file only when its top level is invalid):
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
  pacman's database has no such package), `aur`, `omarchy-setup` (names and arguments as in e.5; `packages` say when it is
  installed; optional `removes`, the user data its removal deletes), or `webapp` (an https URL; `icon` required). `flatpak`
  is reserved for ST2. `license` is SPDX or `LicenseRef-…`; the package's or AppStream's licence wins when present.
- `icon` assets: PNG only, at most 256 KiB and 512 x 512, named by the SHA-256 of their bytes, which the signed file lists:
  the Store checks the hash, no signature per icon. Each records its licence and where it came from (`origin`, never fetched
  by the Store). App icons are the app's own, under their owner's terms; they are listed for the legal review (§14).

**Signature and verification.** `grassfield-catalog.v1.json.sig` is a detached binary OpenPGP signature by the repository's
key (ADR-0033 b, O6: the same key, in CI; tests use throwaway keys). The Store verifies it before parsing, exactly as
ADR-0033 d.8 verifies the release notes: `gpgv --keyring /usr/share/grassfield/pacman-keyring/grassfield.gpg --status-fd 1`
(the keyring's private folder, ADR-0033 b.2), the signer is VALIDSIG's argument 10 (the primary key's fingerprint), listed in
`grassfield-trusted` and absent from `grassfield-revoked` of that folder. The check reads those files, not pacman's keyring,
so it works whether or not Grassfield updates are on. A catalog that fails is not used and not cached; the previous one stays.
While `grassfield-keyring` holds no key (until the owner's key exists, ADR-0033 O20) or is not installed, no catalog is used
and the Store says why.

**Built in grassfield-packages** from source files in its `catalog/` folder (one file per app, one per section, the
categories, the icons), by a standard-library Python tool, in CI: schema and lengths, PNG headers and sizes, every `repo`
package present in the build container's Omarchy stable package set (ADR-0033 f), every recipe name present in the pinned
Omarchy release, every URL https. CI produces the catalog as an artifact; publication stays disabled with ADR-0033's.

## Owner decisions (open; options, with the integrator's recommendation first)
| Id | Question | Options | Recommended |
|---|---|---|---|
| ST1 | master-prompt §4 lists a pacman-based store as a non-goal | **A** amend §4: the Store is in scope now, as the separate optional package `grassfield-store`, built on Omarchy's commands, published after M5 like everything else; **B** keep §4: a Flatpak-only App Center after 1.0; **C** the Store now but browsing only, installs after 1.0 | A |
| ST2 | Sources (a) | per source: Arch repositories and `[omarchy]` on; Omarchy setups on, without those that run downloaded code (GeForce NOW, Battle.net, dev environments) or with them; web apps on; AUR off by default and opt-in, or on, or never; Flathub **F1** not in steps 1-4, **F2** optional when the user installed flatpak (no dependency, `--user`), **F3** a dependency | the table in a, AUR opt-in, Flathub F1 (F2 as a later step if wanted) |
| ST3 | Authentication of per-user installs (web apps; Flathub if chosen) that need no root | **A** the confirmation sheet only (anything running as the user can already write those files, so a password protects nothing there); **B** also the user's own password through a Grassfield polkit action with `auth_self` checked by `pkcheck` (a new policy file, no root code), as the brief's "always an authentication" reads | B, to follow the brief to the letter; A if the owner prefers fewer prompts |
| ST4 | The install path (b) | P1 Omarchy's commands in its terminal; P2 a root helper behind a Grassfield polkit action for repository packages (AUR and setups stay P1) | **none until ADR-0033's PASS**; then the path ADR-0033 keeps for installing |
| ST5 | AppStream for Arch apps | **A** `grassfield-store` depends on `archlinux-appstream-data` (21 MiB, updated with the system, signed by Arch, no extra host) and reads it with `appstream-qt`; **B** the Store downloads Arch's AppStream itself; **C** none (pacman's one-line descriptions, no icons for most apps) | A |
| ST6 | Screenshots (third-party hosts, 280 of them) | **A** loaded when a product page opens, https only, no cookie or referer, cached, with a setting to turn it off; **B** only after a click "Show Screenshots"; **C** none | A |
| ST7 | AUR metadata, when the AUR is on | **A** the RPC: `info` for the page opened, `search` after Return (the query goes to the AUR); **B** the 10.6 MB dump once a day, searched locally (no query leaves, more traffic) | A |
| ST8 | Updates and the badge (d) | **A** the badge stays on Settings (ADR-0033 U18), none on the Store's tile for system packages, the count in the Store's sidebar, "Update All…" = ADR-0033's "Update Now"; **B** a badge on both tiles (one update, two badges); **C** move the badge to the Store (changes ADR-0033 O3/U18) | A |
| ST9 | Order of the steps | 1. catalog read-only (search, product data) with fake catalogs, and in grassfield-packages the catalog build and signature (throwaway key); 2. the app's UI; 3. install, open, uninstall (after ADR-0033's PASS and this one's); 4. updates and the badge with Software Update | as listed |

## Evidence
- `docs/audits/store-2026-10-27/store-probes.sh` (S0 to S11) and its output `probes-output.txt` (docker exit 0). It ran in this
  cloud session's container (Ubuntu 24.04, root in the session's sandbox) with the Docker 29.9.2 daemon started in the
  session: `docker run --rm --network host` with the session's HTTPS proxy and its CA mounted read-only, on
  `archlinux:base@sha256:52dfbd5afb23a220d5ee92dafcb4c788d96c026ed04179890c23adef4c897fa0` (ADR-0033's image). Mounted read-only,
  as data: Omarchy v4.0.4 (c668141), cloned from github.com/basecamp/omarchy. The script refuses to run outside a container;
  inside it is root, makes a user `alice`, installs packages from Omarchy's stable mirror and from Arch's archive
  (archive.archlinux.org, snapshots 2026-03-01, 2026-09-01, 2026-10-20), interrupts pacman on purpose, and everything goes with
  the container. The one change to Omarchy's template is `DisableSandbox` (Docker has no Landlock), as in ADR-0033.
- The macOS 27 reference: `docs/audits/store-2026-10-27/parity.md` (Apple's user guide, two public captures, not committed).

## Consequences
- **Step 1, grassfield-packages:** `catalog/` sources, the build and validation tool, a CI job producing the signed catalog
  as an artifact with a throwaway key, publication disabled; its README and CLAUDE.md name the role (done in step 0).
- **Step 1, here:** `apps/store` backend read-only: fetch, `gpgv` verification, validation, cache, AppStream and pacman
  readers, the merged model and search, all tested with fake catalogs, a throwaway keyring and fake pacman/AppStream roots;
  ADR-0019 dev plumbing rows; ADR-0020 persisted-file rows; opus security review of the verification.
- **Step 2:** the UI (Discover, sections, Categories, product page, search, Installed, the Updates list read-only), measured
  F1 against the captures, en and fr, light and dark, keyboard; offscreen captures with the fake backend; the nested shot by
  the integrator. The sidebar's copy of Apple's structure goes to `docs/legal/visual-review.md`.
- **Step 3:** install, open, uninstall through the path of ST4; container tests with real pacman installs (throwaway
  container), the fake installer everywhere else; opus security review; the owner checks the real sudo or polkit prompt in a
  real session.
- **Step 4:** the Updates page and the badge, with ADR-0033's checker and its added list of other updates.
- **IPC.** Steps 1 to 3 add no shell IPC. Any new `IpcHandler` function (for example, asking the shell to check for updates
  if ADR-0033's own call does not fit) is added to `docs/specs/security.md`'s table in the same PR (`ipc_inventory`).
- **Known limits** (spec): no per-app update for repository and AUR apps; no ratings or reviews; no pause or resume; cancel
  only in the terminal (P1); apps outside AppStream and our catalog show pacman's text only; Omarchy's recipes are Omarchy's,
  their effects as they are in the installed release; a replayed old catalog is refused only once a newer one was seen.

## Review history
None yet.
