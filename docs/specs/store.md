# Store spec · apps-engineer (app), platform-engineer (sources, install path) · owner brief 2026-10-27
Status: step 0 (this spec, ADR-0037 and the parity matrix). Nothing is built. The owner answered ADR-0037 ST1 (§4 amended),
ST2 (AUR opt-in, Flathub optional), ST3 (the sheet alone for per-user installs) and ST8 (the only Dock badge stays on
Settings) on 2026-10-27; the choices still open (ST5, ST6, ST7, ST9) are marked **open**; the install path waits for
ADR-0033's PASS (ST4).
Decisions and evidence: `docs/decisions/ADR-0037-store.md` (probes S0 to S11). Parity and measures:
`docs/audits/store-2026-10-27/parity.md`. App id `org.grassfield.Store`, binary `grassfield-store`, package `grassfield-store`.
Name: "Grassfield Store" in both languages (a product name, like other stores in French). Never "App Store" or "Arcade" (§14).

## macOS reference behavior (described in words; no Apple image committed)
- One window with the macOS 27 unified sidebar: the search field at the top of the sidebar, then Discover, Arcade, Create,
  Work, Play, Develop, Categories, Updates; the account (initials circle, name, a red count badge) at the bottom.
- Discover: a large bold title, a carousel of large artwork cards (eyebrow in capitals, title, one line), then rows of
  smaller cards two by two with an eyebrow, a title, a grey subtitle and a round artwork (measures in the parity matrix).
- Search: words in the sidebar field and Return; results with their buttons.
- An app's page: screenshots, ratings and reviews, events, developer, size, compatibility, languages, age rating,
  accessibility, privacy. The price or "Get" button starts the download after the account's authentication; progress shows
  on the button with Pause and Resume; "Open" once installed.
- Updates: a list with "Update" per app and "Update All"; a badge on the Dock icon and a count in the sidebar; a
  notification with "Install". Uninstalling is not done in the store (Apps or Finder).
- Shortcuts: Command-1 to Command-8 for the sidebar items, Command-F search, Command-R refresh, Command-[ back.

## Purpose and non-goals
Purpose: find an app (Discover, sections, Categories, search), see what it is (source, licence, metadata), install it with
the user's explicit consent and authentication, open it, uninstall it, and see which installed apps the next system update
brings, on Grassfield over an unmodified Omarchy 4.

Non-goals:
- no account, purchase, payment, subscription, gift card, Family Sharing, region, content restrictions;
- no ratings or reviews (no identity leaves the machine); no stories, events, videos;
- no per-app update of repository or AUR apps (Arch: no partial upgrade; Flatpaks have one), no automatic updates, no pause
  or resume;
- no `pacman -Sy`, no `--overwrite`, no removal of `db.lck`, no root code of the Store's own under P1;
- no installer of its own: pacman, yay and Omarchy's commands install (ADR-0037 b);
- no publication of the catalog before the owner's decision (ADR-0033 h).

## Functional requirements
Window and navigation (step 2)
- SR1. One window `org.grassfield.Store`, the macOS 27 structure of the parity matrix: sidebar flush with the window, the
  search field at its top, the sections, then Categories and Updates; at the bottom the local user's row (initials or the
  user's picture from AccountsService, the full name) that opens **Installed**. Tokens only (`ui/Grassfield/Ui/Tokens.qml`,
  new `store.*` tokens with their source note); the shared components first (`SearchField`, `Material`, `Button`,
  `ProgressBar`, `Sheet`, `PopupMenu`, `ScrollBar`, `Tooltip`, the sidebar rows of Settings and Files); light and dark;
  Reduce Transparency and Reduce Motion honoured. F1 strict (ADR-0024): geometry ±1 pt, tints ±0.1, A2 contrast.
- SR2. The sections between Discover and Categories come from the verified catalog (ADR-0037 g), in its order, with its
  titles (en, fr) and symbols. Without a catalog only Discover (AppStream-based, no editorial block), Categories, Updates
  and Installed are shown.
- SR3. Back and forward in the toolbar capsule (as Settings): a product page or a category list pushes; Back returns with the
  scroll position kept.

Discover and sections (step 2)
- SR4. Blocks: `hero` (the carousel: 880 x 340 at the reference width, radius 12, the next card peeking 20; arrows on hover;
  the artwork is Grassfield's: the app's icon large on a tint derived from its colours), `cards` (two per row, 430 x 230,
  fill and type per the matrix, the app's icon in the round artwork place), `row` (a titled horizontal list of apps: icon,
  name, summary, button). Widths follow the window: the content keeps 40 pt margins; below the reference width the cards
  become one per row.
- SR5. Every card and list item shows the app's source badge; a click opens the product page; the item's button acts as on
  the product page.

Search (step 2)
- SR6. Typing in the sidebar field (Ctrl+F focuses it) shows results while typing from the local merged catalog (our catalog,
  AppStream, the `[omarchy]` list): name, keywords, summary and package name, ranked name-prefix first; Esc clears, then
  leaves the field. Empty result: "No Results for “…”" (« Aucun résultat pour « … » »).
- SR7. AUR results (only when the AUR source is turned on, ADR-0037 ST2/ST7) appear after Return in their own section "From
  the AUR (not reviewed)" (« Depuis l'AUR (non vérifié) »), with votes and the out-of-date flag.
- SR7b. Flathub apps (only when Flathub is turned on, ST2) are part of the local search (their AppStream is in the user's
  installation), each with the "Flathub" badge.

Categories (step 2)
- SR8. A grid of the catalog's categories (symbol, name); a category opens its list, sorted by name, with a source filter
  (All, and one per enabled source). Apps that our catalog does not list are placed by their AppStream categories.

Product page (step 2)
- SR9. Header: icon, name, summary, developer, the button (SR13), source badge and licence ("Licence not stated" when none).
- SR10. Screenshots (when AppStream has them; **open** ADR-0037 ST6), a gallery with arrows; description (plain text,
  paragraphs and bullets); What's New (AppStream releases, else the version and the package's build date).
- SR11. Information: Source (with the repository, e.g. "Arch Linux · extra", "Omarchy", "Omarchy setup", "Web app", "AUR"),
  Package, Version, Download size, Installed size, Category, Languages (AppStream), Content rating (OARS, else "Not rated"),
  Licence, Homepage and Bug tracker (buttons that open the browser on click, https only). For an Omarchy setup: "What this
  setup changes" (our catalog's text) and the recipe's name. For the AUR: Maintainer (or "Orphaned"), Votes, Popularity, Last
  updated, "Flagged out of date" when so, and "View Build Script" (the PKGBUILD as plain text in a sheet, fetched on click).
  For a Flatpak: the app id, the runtime, "Can access" (its permissions in plain words: files, devices, network) and
  Flathub's verified-developer flag when its AppStream carries one.
- SR12. An app with several launchers names the one "Open" uses; an app with none (a command-line tool) says so and has no
  "Open".

Get, Open, Uninstall (step 3; the path is ADR-0037 ST4)
- SR13. The button: "Get" (« Obtenir ») when not installed; "Open" (« Ouvrir ») when installed with a launcher ("Update"
  « Mettre à jour » for a Flatpak with an update; never for a repository or AUR app); a progress
  ring while its operation runs or waits in the queue ("Waiting" « En attente »); "Installed" (« Installée ») when installed
  without a launcher. Disabled with a tooltip when offline, while an update or another package manager runs, or when the source
  is turned off.
- SR14. "Get" opens the confirmation sheet; its default button is "Install" (« Installer »), "Install from the AUR"
  (« Installer depuis l'AUR ») for the AUR. It lists: source, licence, sizes, every package the plan adds (from `pacman -S
  --print` as the user), for a setup what it changes, for the AUR the warning (SR16), for a Flatpak what it can reach and the
  runtimes it pulls. Cancel (Esc) closes it and nothing runs.
- SR15. Before the operation runs, the plan check of ADR-0037 e.4: a plan that upgrades an installed package, an unresolvable
  plan, or a package file the mirror no longer has → the sheet says "Update your system first" (« Mettez d'abord le système à
  jour ») with "Open Software Update"; `db.lck` present or Omarchy's update lock held → "Another installation or an update is
  running" (« Une autre installation ou une mise à jour est en cours »). Nothing is queued then.
- SR16. The AUR warning, on the sheet, every time (en / fr):
  "AUR packages are made by users and reviewed by no one, neither Arch Linux nor Grassfield. Their build script runs on this
  computer and the package is then installed with administrator rights. Install only what you trust." /
  « Les paquets de l'AUR sont faits par des utilisateurs et ne sont vérifiés par personne, ni Arch Linux ni Grassfield. Leur
  script de construction s'exécute sur cet ordinateur, puis le paquet est installé avec les droits d'administrateur.
  N'installez que ce en quoi vous avez confiance. »
- SR17. The authentication is the path's: sudo's prompt in Omarchy's terminal (P1) or the polkit dialog (P2). Per-user installs
  (web apps, Flatpaks): the sheet alone, its default button being the consent; no password (owner, ST3, 2026-10-27).
- SR18. One operation at a time; later ones wait in the queue (shown on their buttons and in a queue popover in the toolbar,
  where a waiting one can be removed). The running one shows progress: indeterminate while downloading, then "n of N" from
  pacman's log; P1 also names the terminal ("Installing in Terminal…" « Installation dans le Terminal… »).
- SR19. Success is the system's state after the operation (ADR-0037 f): the packages of the plan present (`pacman -Q`), the web
  app's `.desktop` file present. Then the button becomes "Open". A failure shows one line under the button and a "Details"
  popover (pacman's message when there is one, and what to do); "Try Again" re-runs the same plan.
- SR20. Recovery at start (ADR-0037 f): an operation recorded in `store.json` and not running is compared with the system and
  reported as done (silently), interrupted ("16 of 110 packages were installed", with "Try Again"), or not finished; a stale
  `db.lck` is explained with Arch's recovery as text to copy, never removed by the Store.
- SR21. "Open" starts the app through ADR-0011 (`uwsm-app -- <desktop-id>` in a real session, `apps/appscope.h`); the Store
  stays open. In a dev session only fixture apps open (ADR-0011 dev open policy).
- SR22. "Uninstall…" (« Désinstaller… »): in the product page's "…" menu, in Installed, and in the context menu of an installed
  app's item. Its sheet lists what goes: the packages (the plan of `pacman -Rns`, asked as `pacman -Rs --print` by the user,
  S10), or the setup's removal recipe and the user data it deletes (our catalog's `removes`), or the web app's launcher and
  icon, or the Flatpak (its data in `~/.var/app/<app-id>` stays, and the sheet says so). A package other installed packages
  need is not removable (S10: "removing glib2 breaks dependency … required by
  accountsservice"): the sheet says which ones need it, and nothing runs. Default button "Uninstall" (« Désinstaller »),
  destructive style.

Installed (step 2 read-only, step 3 actions)
- SR23. The apps installed from the Store's sources that have a launcher or a catalog entry: explicitly installed packages
  (`pacman -Qe`) with an AppStream or catalog entry, setups whose packages are present, Omarchy web apps
  (`~/.local/share/applications/*.desktop` whose Exec is `omarchy-launch-webapp`), AUR packages (`pacman -Qm`), Flatpaks of
  the user's installation (`flatpak list --user --app`, when Flathub is on). Each with Open and Uninstall…. Grouped by source,
  sorted by name.

Updates (step 4; ADR-0037 d, owner ST8)
- SR24. From ADR-0033's result (`software-update.json`): the installed apps with an update, each marked "Updates with the
  system" (« Mise à jour avec le système »), then "N other system packages", the Grassfield and Omarchy releases as Software
  Update names them, and "Update All…" (« Tout mettre à jour… ») which starts ADR-0033's "Update Now". "Check Now" asks the shell
  to check (ADR-0033). States: checking, up to date (with the last check time), update running, failed (offline or
  unavailable, with the last success), blocking (ADR-0033 a2: a link to Software Update's "Turn Off…").
  Flatpaks (Flathub on) form their own group: "Update" per app and "Update All" for the group (`flatpak update --user`),
  checked by the Store when it opens and on "Check Now" (`flatpak remote-ls --user --updates`).
- SR25. The sidebar's Updates row shows the number of apps with an update, Flatpaks included. The Store's Dock tile has no
  badge: the only update badge is Software Update's, on Settings (owner, ST8).

Catalog and network (step 1)
- SR26. The catalog is fetched at start when the cached one is older than 6 h, and on Ctrl+R (« Actualiser »), never while the
  Store is closed, never on a metered connection without Ctrl+R; verified (`gpgv` with the keyring of
  `/usr/share/grassfield/pacman-keyring/`, VALIDSIG argument 10 in its `grassfield-trusted`, not in its `grassfield-revoked`),
  validated, then cached; a lower serial than the accepted one is refused (ADR-0037 g).
- SR27. Requests per ADR-0037 c: https only, no cookie, no referer, User-Agent `Grassfield-Store/1`, 15 s, size caps. No search
  query leaves for Grassfield's host. The Store's settings window lists what is fetched and from where, in plain words.

Settings window (Ctrl+, ; step 2 reads, step 3 writes)
- SR28. "Sources": switches for the optional sources, both off until turned on, each with one line saying what it means: AUR;
  Flathub, shown only when the `flatpak` package is installed (otherwise the line "Flathub needs the flatpak package" with a
  link to its product page); turning Flathub on adds the Flathub remote to the user's installation
  (`flatpak remote-add --user --if-not-exists`).
  "Screenshots": the ST6 switch. "Catalog": the channel and the date of the catalog in use, "Refresh". Stored through the
  settings contract (ADR-0020).

Offline
- SR29. ADR-0037 "Offline": the bar "You're offline. The catalog is from 27 October." (« Vous êtes hors ligne. Le catalogue date
  du 27 octobre. »), Get and Update All disabled with the reason, Open and Uninstall available, uncached screenshots replaced
  by a placeholder; a catalog older than 30 days is used with a note.

Dev sessions (ADR-0019)
- SR30. No real operation, ever: the queue runs the fake installer only (`GRASSFIELD_STORE_INSTALLER`); catalogs, keyrings and
  package roots from fixtures (`GRASSFIELD_STORE_CATALOG_URL`, `GRASSFIELD_STORE_KEYRING`, `GRASSFIELD_STORE_FIXTURE`); without a
  fixture installer the buttons show "dev: not applied".

## Keyboard
| Keys | Action |
|---|---|
| Ctrl+1 … Ctrl+n | the sidebar items in order (Discover, the sections, Categories, Updates) |
| Ctrl+F | focus the search field |
| Ctrl+R | refresh the catalog (and the page) |
| Ctrl+[ / Ctrl+] , Alt+Left / Alt+Right | back / forward |
| Ctrl+, | the Store's settings |
| Ctrl+W, Ctrl+Q | close the window, quit (a running operation goes on, ADR-0037 f) |
| Tab / Shift+Tab | sidebar → content → toolbar; inside the content, the cards and buttons in reading order |
| Arrows | inside a carousel or a grid, move between items; Up/Down in the sidebar |
| Return / Space | open the focused item / press the focused button |
| Esc | close a sheet or popover (Cancel); in the search field, clear then leave |
Shortcuts are shown in the menus in the user's shortcut style (`apps/shortcutstyle.h`). The menus are exported to the menu bar
(T1, as the other apps): Store (About, Settings…, Quit), Edit, View (the sidebar items, Refresh), Window, Help.

## Accessibility
- Every control reachable by keyboard with a visible focus ring (A1); `Accessible.name`, `role` and `description` on the
  sidebar rows, cards ("<app>, <source>, <summary>"), buttons ("Get <app>", "Open <app>", "Uninstall <app>"), the progress ring
  (value and "n of N"), the badges and the warning (role alert).
- Progress and results are announced (live region) when they change state; never more often than once a second.
- Text over the hero tint meets A2 (≥ 4.5:1) in both appearances: the tint is darkened as needed, never the text lightened.
- Reduce Motion: the carousel does not auto-advance (it never does by default) and page pushes cross-fade (≤ 100 ms).
- Screenshots have their caption (AppStream) as accessible text, else "Screenshot n of N of <app>".

## i18n (en and fr)
- Every visible string in `qsTr()`; the fr catalog complete (I1). Our catalog's texts carry `en` and, when written, `fr`; the
  Store shows `fr` when the session's language is French and the field has it, else `en`. AppStream texts use their
  translation for the language when present.
- Sizes and dates in the user's region (`region.formats`, as Settings): « 12,4 Mo », "12.4 MB"; "27 October" / « 27 octobre ».
- The main labels: Discover / Découvrir, Create / Créer, Work / Travailler, Play / Jouer, Develop / Développer, Categories /
  Catégories, Updates / Mises à jour, Installed / Installées, Search / Rechercher, Get / Obtenir, Open / Ouvrir, Install /
  Installer, Uninstall… / Désinstaller…, Update All… / Tout mettre à jour…, Try Again / Réessayer, Licence / Licence, Source /
  Source, Omarchy setup / Configuration Omarchy, Web app / App web, Not rated / Non classé. (The section titles come from the
  catalog.)

## Refusals (what is refused, and what the user sees)
| Case | Behaviour |
|---|---|
| A plan that upgrades an installed package or cannot be resolved (database newer than the system, S4) | sheet: "Update your system first", "Open Software Update"; nothing runs |
| A package the mirror no longer has (database older than the mirror, S5) | same message |
| `db.lck` present, or Omarchy's update running (S11) | "Another installation or an update is running"; nothing queued |
| A stale `db.lck` with no pacman running | an explanation and Arch's recovery as text; the Store never removes it |
| An uninstall that would break another installed package | the sheet names the packages that need it; nothing runs |
| A catalog with a bad or missing signature, a key not trusted or revoked, a lower serial, an invalid top level | not used, not cached; the previous catalog stays; one line in the settings window "The catalog could not be verified" |
| A catalog entry that breaks a rule (unknown repo, bad name, http URL, oversized icon, wrong hash) | that entry is dropped, the rest is used |
| A recipe the installed Omarchy does not have | the setup is hidden |
| An AUR install while the AUR source is off | not offered |
| A web app URL that is not https | not offered (the catalog's CI refuses it too) |
| Offline / metered | Get and Update All disabled with the reason; no automatic fetch on a metered link |
| Dev session | no real operation; "dev: not applied" without a fixture installer |

## Acceptance criteria (each mapped to a test; level)
| Id | Criterion | Test | Level |
|---|---|---|---|
| A1 | a valid fixture catalog signed by a throwaway key is accepted; a changed byte, another key, a revoked key, a lower serial, an oversized file are refused | unit (C++), throwaway gpg homedir | L0 |
| A2 | entry rules: each broken rule drops only its entry | unit with vectors shared with grassfield-packages' validator | L0 |
| A3 | merge: catalog over AppStream over pacman; source precedence; licence fallback | unit with fake AppStream and pacman roots | L0 |
| A4 | search ranking and the AUR section (fake RPC answers) | unit | L0 |
| A5 | plan check: a plan with an upgrade, an unresolvable plan, a 404 first package, a held lock → refused with the right message | unit with a fake pacman | L0 |
| A6 | queue: one at a time; success read from the system (an exit 0 with a partial install is "interrupted") | unit with the fake installer | L0 |
| A7 | recovery: each start case of SR20 | unit with recorded `store.json` | L0 |
| A8 | real install, open (`uwsm-app` argv), uninstall of a repository package, a web app, a setup and a small Flatpak (`--user`); a cancelled Flatpak install measured | throwaway Arch container with Omarchy's scripts (step 3) | L1 (container) |
| A9 | Discover, a product page, search, Categories, Installed, Updates, sheets, offline bar; light and dark; en and fr | offscreen captures with the fake backend, then a nested shot by the integrator | L0/L1 |
| A10 | F1 geometry and tints against the parity matrix | measurement script on the captures | L1 |
| A11 | keyboard paths and accessible names | QML tests + checklist | L0/L1 |
| A12 | the real sudo prompt or polkit dialog, the terminal, an interrupted install, the badge | owner, real session | L2 |

## Interfaces / contracts (versions)
- Catalog `grassfield-catalog.v1.json` + `.sig` + `catalog/<sha256>.png` (ADR-0037 g; the contract with grassfield-packages).
- ADR-0033: the channel URL tree and key; `software-update.json` (with the added list of other updates, ADR-0037 d); "Update
  Now"; the request to check.
- `store.json` (state, `version: 1`); Store preference keys in `grassfield.json` (schema, ADR-0020).
- Launch: ADR-0011 (`apps/appscope.h`). Badge: none of the Store's own (ST8); Software Update's on Settings (ADR-0033 U18).
- Flatpak 1.18 (when installed): `flatpak install|uninstall|update --user --noninteractive`, `flatpak remote-ls --user
  --updates`, `flatpak list --user --app`, `flatpak remote-info --show-metadata`, `flatpak remote-add --user --if-not-exists`.
- Omarchy 4.0.4 commands, pinned in `docs/upstream/omarchy.lock` with the step that uses them: `omarchy-install-app`,
  `omarchy-install-and-launch`, `omarchy-pkg-add`, `omarchy-pkg-aur-add`, `omarchy-pkg-drop`,
  `omarchy-launch-floating-terminal-with-presentation`, `omarchy-webapp-install`, `omarchy-webapp-remove`, the recipes the
  catalog names.

## Dependencies (verified versions, S3 and S8; at step 1 again)
`grassfield-desktop` (same version), `archlinux-appstream-data` 20261017-1 and `appstream-qt` 1.2.1 (if ST5 = A),
`kimageformats` (JPEG XL icons), `gnupg` (`gpgv`), Omarchy 4.0.4's commands, `pacman` 7.1, `yay` (Omarchy's, only for the AUR),
`flatpak` 1.18.4 as an `optdepends` only (ST2; not installed on the owner's machine).

## Degraded behavior
- No catalog (no hosting yet, offline at first start, verification failed): no editorial sections; AppStream and pacman still
  give Discover's lists, Categories and search.
- No `grassfield-keyring`, or one without a key (until the owner's key exists, ADR-0033 O20): the catalog is never used; the
  settings window says why.
- No `archlinux-appstream-data` (ST5 ≠ A): pacman's descriptions only, catalog icons where we have them, generic icons
  elsewhere.
- Omarchy's commands missing (a non-Omarchy system): no install, no uninstall; the Store browses and opens.
- No shell (Updates): the Store shows the last `software-update.json` and its date; "Check Now" is disabled for system updates
  (Flatpak updates are still checked by the Store).
- No `flatpak`: no Flathub source, no Flatpak group; the settings say how to get it.

## Automated tests · Manual verification steps
- Unit (C++ and QML, offscreen): A1 to A7, A9, A11. Fake pacman (`GRASSFIELD_STORE_FIXTURE`: a script answering `-Sl`, `-Si`,
  `-Q`, `-S --print`, `-Sp`), fake AppStream pool, fake RPC files, throwaway keyring.
- Container (step 3, A8): the real Omarchy commands from a pinned checkout, real pacman installs from a mirror, in a
  throwaway Arch container only.
- Manual, nested (integrator): the visual scenarios; manual, real session (owner): A12.

## Performance (gates affected) · Accessibility · i18n
- The Store is a separate app: no effect on P1/P2 of the shell. Its own budget: first window under 1 s warm with a cached
  catalog; search under 50 ms per keystroke (P4's rule) on 2000 catalog apps plus 1390 AppStream apps; AppStream is read once
  per start in a worker thread; images decode off the GUI thread.
- Accessibility and i18n: above.

## Known limitations
- No per-app update for repository or AUR apps, and no "Update" button for them: they update with the whole system (Arch).
- No ratings or reviews; the AUR's votes and popularity are its own facts, not ratings.
- No pause or resume; under P1, cancelling happens in Omarchy's terminal and can leave a part of the packages installed (S6);
  the Store reports it.
- Apps outside AppStream and our catalog show pacman's one-line description and a generic icon.
- Omarchy's recipes are Omarchy's: their effects are those of the installed Omarchy release; our catalog's text describes the
  release it was written against (4.0.4), and CI checks the names, not the behaviour.
- A replayed old catalog is refused only once a newer one has been seen on that machine.
- Flatpaks are not updated by `omarchy update` (the Store updates them) and have no Dock badge (ST8); cancelling a Flatpak
  operation is offered only once step 3 has measured what it leaves.
- Screenshots come from third-party hosts (ST6).
- Visual parity of the product page, search, Categories and Updates rests on the guide and the macOS 27 Settings panes: no
  public capture of those pages exists (parity matrix).
