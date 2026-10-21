# ADR-0017: WhiteSur as the default app icon theme of the Grassfield session (optional), selected per session
Status: Proposed (applied provisionally; amended 2026-10-21: WhiteSur dropped, see "Amendment 2026-10-21" at the end). Earlier status: Accepted (owner decision 2026-10-20, batch 10); implemented in slices I0-I3 and I5 (slice I4, the icon-mode retune, is not part of this fix); Apple-artwork handling amended 2026-10-20 (pkgrel 5: logo files; pkgrel 6: perceptual detector and blocklist, see "Apple artwork" below) · Date: 2026-10-20 · Decider: owner

## Context

### Owner decision (2026-10-20, docs/STATE.md:125-126)
WhiteSur, the GPL-3.0 macOS-inspired icon theme, becomes the default app icon theme of the Grassfield session as an
**optional** dependency. Owner statement: it contains no Apple files.
**That statement was not true of upstream's default install**, and a first guard (pkgrel 5, byte matching of 12 logo
files) did not make it true: the counter-review of merge de09465 found the Apple logo in 22 more files (iMac and Magic
Mouse icons, the menu-bar window icons, the iPod-mini frames), Apple app icons reproduced 1:1 (Finder, App Store, Xcode,
iCloud, Safari, System Preferences) and iPhone/iPod silhouettes. Owner decision 2026-10-20 ("filtered WhiteSur"): keep
WhiteSur for the internal phase but FILTER it; what the filter removes and how is in "Apple artwork" below. The claim is
limited to what the detector and the review prove, not "nothing Apple". The trade-dress resemblance of the remaining
app icons stays on the legal-review list (docs/legal/). Earlier decisions that this one builds on or changes:
- ADR-0014 (Proposed): WhiteSur is the base icon theme for the internal phase, "a dependency of the session package
  ... never copied into the repository". Grassfield sets the theme for its session and shell "(Quickshell's IconTheme
  pragma or QT_ICON_THEME/environment, whichever the installed version supports — verify)".
- STATE 2026-10-19 (owner): "WhiteSur must NOT be installed on the owner's system; it is provisioned only inside the
  dev environment". Batch 9 (2026-10-20) made this machine dedicated to Grassfield. Batch 10 makes WhiteSur the
  session's default, which implies installing it on this machine: owner question 2 confirms that.

### Grassfield today (VERIFIED: read in this session)
- **Dev only.** `scripts/dev/whitesur.sh` fetches vinceliuice/WhiteSur-icon-theme at the pinned commit
  `73d8040da51a9ed74e47c7366e7e9ff437601a5c` (:18). It checks the commit and the SHA-256 of the reviewed upstream
  `install.sh` (:19, :66-69), and installs `WhiteSur`, `WhiteSur-light` and `WhiteSur-dark` into `.dev/share/icons`
  only, with `COPYING` and `AUTHORS` next to each (:71-80). `scripts/dev/devenv.sh:13-21` puts `.dev/share` first in
  `XDG_DATA_DIRS` and sets `QT_QPA_SYSTEM_ICON_THEME=WhiteSur` when the theme is there (docs/dev-themes.md:6-18).
- **The real session sets no icon theme.** Grep of `config/`, `packaging/`, `shell/`, `ui/` and `apps/` for `iconTheme`,
  `setThemeName`, `QT_QPA_SYSTEM_ICON_THEME` and `icon-theme`: only the dev scripts. `packaging/arch/PKGBUILD` has no
  WhiteSur. It is a local build "no source download" (:2).
- **Every shell surface resolves app and file icons through Qt.** `Quickshell.iconPath(...)` is used by:
  - the Dock: `shell/dock/Dock.qml:861`, `:941`, and `:977` (`user-trash` / `user-trash-full`);
  - Apps: `shell/launchpad/AppsCell.qml:59`;
  - Search: `shell/search/Search.qml:157`, `:166`;
  - Overview: `shell/overview/OverviewWindow.qml:503`, `:799`;
  - the switcher: `shell/switcher/SwitcherWindow.qml:183`;
  - Force Quit and About: `shell/overlay/ForceQuitPanel.qml:85`, `AppAboutPanel.qml:30`;
  - the desktop: `shell/desktop/DesktopIcon.qml:106`, `:115`;
  - notifications: `shell/notifications/Notifications.qml:105-127`.
  Grassfield Files uses `QIcon::fromTheme` (`apps/files/src/imageproviders.cpp:60`, `foldermodel.cpp:129`). Quickshell's
  `iconPath` exists in three overloads (`/usr/lib/qt6/qml/Quickshell/quickshell-core.qmltypes:1071-1090`). That it
  resolves through `QIcon` is an ASSUMPTION, consistent with ADR-0014.
- **Icon modes and folder colours** (ADR-0014; docs/specs/ui.md:44-56) are GPU effects on whatever image the theme
  returns. The measurements in ui.md:53 were taken **with WhiteSur** in nested sessions.
- **The session already refuses to touch dconf**: `config/hypr/session.lua:20-23` sets
  `cursor.sync_gsettings_theme = false` because dconf is "a database shared with the Omarchy session".
- **Session environment paths.**
  - The real session starts as `uwsm start -e -D Hyprland:Grassfield ...`
    (`packaging/wayland-sessions/grassfield.desktop:4`).
  - `config/hypr/grassfield/autostart.lua:5-9` hands named variables to systemd with `uwsm finalize` (the cursor
    variables, ADR-0014), then starts `grassfield-shell.service` (:21).
  - Omarchy's environment, included by `config/hypr/grassfield/omarchy.lua:43`, sets `QT_QPA_PLATFORMTHEME=gtk3`
    (`/usr/share/omarchy/default/hypr/envs.lua:14`).

### Facts about this machine (VERIFIED)
- `/usr/share/icons`: Adwaita, AdwaitaLegacy, breeze, breeze-dark, default, grassfield-cursors, hicolor, HighContrast and
  the Yaru variants. **No WhiteSur** system-wide.
- **WhiteSur at the pin** (the main checkout's dev install, `.dev/share/icons/WhiteSur`):
  - `Inherits=hicolor,breeze` in all three variants;
  - `Comment=MacOSX style icon theme for linux.`, an Apple mark inside the theme's metadata;
  - about 30 MB apparent size for the `WhiteSur` variant;
  - 6477 scalable app icons and 1478 mime icons;
  - `COPYING` is the GNU GPL version 3 text ("or later" or "only": VERIFY in upstream's README);
  - `AUTHORS`: Vince Liuice.
- **Icons the shell asks for**, present at the pin: `application-x-executable` (mimes), `text-x-generic`, `user-trash`,
  `user-trash-full`, `folder`, `preferences-system`, `system-file-manager`, `image-x-generic`, and the default Dock apps
  `foot`, `chromium`, `org.gnome.Nautilus`. No `org.grassfield.*` icon: the Grassfield apps' desktop entries use stock
  names (settings.md:90).
- **Omarchy sets the GTK icon theme in the shared dconf database.**
  - `omarchy-theme-set-gnome` runs `gsettings set org.gnome.desktop.interface icon-theme "$(<…/icons.theme)"`, else
    `Yaru-blue`, at every theme change (`/usr/share/omarchy/bin/omarchy-theme-set-gnome`).
  - First run: `install/user/first-run/gnome-theme.sh:3`.
  - Omarchy installs `xdg-desktop-portal-gtk` and `xdg-desktop-portal-hyprland` (`install/omarchy-base.packages:142-143`).
- **dconf.** `/etc/dconf` contains only `db/.placeholder`: no profile, so every process uses dconf's default profile
  (`user-db:user`, ASSUMPTION about dconf's default). No dconf documentation is installed (`/usr/share/doc` has no dconf
  entry): every profile rule below comes from upstream knowledge and is the first thing the spike checks.
- **Qt plugins.** `/usr/lib/qt6/plugins/platformthemes`: `libqgtk3.so`, `libqxdgdesktopportal.so` (no qt6ct, no KDE
  platform theme). `/usr/lib/qt6/plugins/kiconthemes6/iconengines/KIconEnginePlugin.so` is installed (KF6
  KIconThemes). Kdenlive is installed (`/usr/share/doc/Kdenlive`).
- **uwsm documentation** (`/usr/share/doc/uwsm/README.md`):
  - uwsm sources `uwsm/env-${desktop}` files from `${XDG_CONFIG_HOME}:${XDG_CONFIG_DIRS}:${XDG_DATA_DIRS}`, `${desktop}`
    being each lowercased item of `XDG_CURRENT_DESKTOP` (:112-114);
  - it exports the difference into the systemd user manager (and the reference D-Bus daemon's activation environment),
    and unsets it at shutdown (:118-126);
  - the reference dbus-daemon cannot unset, so its variables are **emptied** instead (:38-45). Which D-Bus
    implementation runs here is UNKNOWN (an owner read-only check).

### What each toolkit reads for the icon theme
Status per row: VERIFIED where a file is cited; otherwise ASSUMPTION from upstream source knowledge, to be checked by
spike I0.
| Client | What decides its icon theme | Session-scoped handle |
|---|---|---|
| Qt 6 apps, Quickshell (the shell), Grassfield Settings, Files and Preview | `QIcon::themeName()`, in this order: an app's own `QIcon::setThemeName()`; else env `QT_QPA_SYSTEM_ICON_THEME` (Qt's `systemThemeName()`); else the platform theme's hint. With `QT_QPA_PLATFORMTHEME=gtk3` (this session) that hint is GTK's `gtk-icon-theme-name`, i.e. dconf. Lookups follow the theme's `Inherits` depth first, and Qt adds `hicolor` last | **env `QT_QPA_SYSTEM_ICON_THEME`**. Repo evidence: dev sessions show WhiteSur through it (dev-themes.md:13-16, ui.md:53); whether `gtk3` was set in those runs is not recorded |
| KDE Frameworks apps (KIconThemes: Kdenlive, Dolphin, maybe Files through KIO widgets) | `kdeglobals` `[Icons] Theme=` through the KConfig cascade (`$XDG_CONFIG_HOME`, then `$XDG_CONFIG_DIRS`). Some KF6 apps call `KIconTheme::initTheme()`, which may force Breeze outside Plasma | a `kdeglobals` in a directory prepended to `XDG_CONFIG_DIRS` for the session (the user's own `kdeglobals` wins), only if the spike shows KF6 apps ignore the Qt variable |
| GTK 3 and GTK 4 apps (Nautilus, Firefox) | On Wayland, `gtk-icon-theme-name` comes from GSettings `org.gnome.desktop.interface icon-theme`, read **from dconf**. `settings.ini` (`$XDG_CONFIG_HOME/gtk-3.0`, `$XDG_CONFIG_DIRS`) is only used when that GSettings schema is missing, because the backend value wins for string settings. No environment variable selects an icon theme (`GTK_THEME` is the widget theme). GTK drops a theme whose `index.theme` has no `Directories` key, together with its `Inherits` | **dconf only** (`DCONF_PROFILE`) |
| Flatpak apps | the xdg-desktop-portal Settings interface, served by `xdg-desktop-portal-gtk`, which reads GSettings in its own process | the portal backend's environment: `DCONF_PROFILE` must be in the systemd user environment before the portal starts |
| Chromium, Electron | their own UI icons are bundled. File-type icons, GTK dialogs and the GTK theme mode read GTK settings (dconf); file choosers go through GTK or the portal | dconf only |
| App icons of any app shown by the shell (Dock, Apps, Search) | the shell's own Qt lookup | the Qt variable in the shell's environment (`grassfield-shell.service` gets the systemd user environment) |
| Omarchy session (must stay unchanged) | dconf's default profile (`Yaru-blue` or the Omarchy theme's `icons.theme`); Qt via gtk3 | nothing of this ADR may reach it |

Quickshell's `//@ pragma IconTheme`: existence not verified for 0.3.1, and not needed: the Qt variable covers the shell.

## Options

### 1. Distribution
- **A. `optdepends` on the AUR package**, installed by the owner (`whitesur-icon-theme` or `whitesur-icon-theme-git`:
  names from memory, VERIFY; no network in this session).
  - Pros: Grassfield redistributes nothing; nothing to build.
  - Cons:
    - The AUR PKGBUILD is third-party, untrusted data (R4); the owner must review it at each update.
    - Its version drifts from the pin that was reviewed and measured (ui.md:53).
    - An AUR helper or manual `makepkg` from the AUR.
- **B. Vendored, pinned split package `grassfield-whitesur-icons`** from `packaging/arch/PKGBUILD`.
  - Contents:
    - `source=` the upstream git at commit `73d8040…`, the same pin as dev;
    - `build()` checks `install.sh`'s SHA-256 (as `whitesur.sh:68-69`) and runs it into `$pkgdir/usr/share/icons` with a
      scratch `HOME`;
    - `COPYING` and `AUTHORS` go to `/usr/share/licenses/grassfield-whitesur-icons/`;
    - `arch=(any)`, `provides=(whitesur-icon-theme)`, `conflicts=(whitesur-icon-theme whitesur-icon-theme-git)`;
    - `grassfield-desktop` gets `optdepends+=('grassfield-whitesur-icons: WhiteSur app icon theme (third party, GPL-3.0)')`.
  - Pros: the reviewed pin, reproducible; the owner's usual `makepkg -si`; updates only when Grassfield bumps the pin.
  - Cons:
    - The PKGBUILD downloads at build time (today it does not).
    - GPL-3.0 obligations apply whenever the package leaves the owner's machine: licence text, corresponding source
      (the SVG tree is its own source; the PKGBUILD, URL and commit reproduce it), notice of any change. Needs legal
      review.
    - About 90 MB installed for three variants (ASSUMPTION: 3 x 30 MB).
- **C. Both**: B, plus `provides`, so an AUR install also satisfies the optional dependency.

### 2. Selecting the theme for the Grassfield session only
- **Q-A. `QT_QPA_SYSTEM_ICON_THEME`** in the session environment: every Qt process, the shell included.
- **Q-B.** qt6ct profile per session: not installed; it would replace Omarchy's gtk3 platform theme (palette, fonts).
  Rejected.
- **Q-C.** The shell's own `QIcon::setThemeName` (pragma or C++ plugin): the shell only. Not needed with Q-A.
- **G-A.** Write `icon-theme` in the user's dconf: this changes Omarchy too. The next Omarchy theme change overwrites it,
  and restoring it at logout is fragile. Rejected (and against session.lua:20-23).
- **G-B.** A `gtk-3.0/settings.ini` under a session-only `XDG_CONFIG_DIRS`: ignored on Wayland while the GSettings
  schema exists (above). Rejected unless the spike proves otherwise (cheap to test).
- **G-C. A session dconf profile** (`DCONF_PROFILE`, set only in the Grassfield session):
  - **G-C1, read-only overlay**: `user-db:user` first (every key reads and writes the normal database, shared with
    Omarchy), then a Grassfield database built at package time holding **only** `icon-theme='grassfield-icons'` with a
    **lock** on that key. Profile path and database form: `file-db:/usr/share/grassfield/dconf/grassfield.db`
    (`dconf compile` at build time), or `system-db:grassfield` (`/etc/dconf/db/grassfield.d` plus `locks/`, compiled by
    `dconf update`) if file databases do not honour locks. Nothing is written to the user's database; the key cannot be
    changed inside this session.
  - **G-C2, writable overlay**: `user-db:grassfield` first, then `user-db:user` read-only. Every GSettings write made in
    the Grassfield session (Nautilus state, colour scheme, fonts) then stays in the Grassfield database and shadows
    later Omarchy changes to those keys. Needed only if Settings ever offers an icon-theme picker.
- **G-D.** A Grassfield `org.freedesktop.impl.portal.Settings` backend: it reaches only portal readers (Flatpak), and it
  is a new daemon (§5.8). Rejected.

### 3. Fallback for icons WhiteSur lacks, and for a machine without WhiteSur
- **F-A. A Grassfield-owned wrapper theme `grassfield-icons`**: `/usr/share/icons/grassfield-icons/index.theme`, shipped
  by `grassfield-desktop`, `Inherits=WhiteSur,Adwaita,hicolor`, plus one real, empty `scalable/apps` directory (GTK drops
  a theme without directories, see above). The session always names `grassfield-icons`:
  - with WhiteSur installed, lookups go WhiteSur, then its own parents `hicolor` and `breeze`, then Adwaita, then
    hicolor;
  - without it, they go Adwaita, then hicolor. Qt and GTK skip a missing parent (ASSUMPTION).
  - Grassfield's own icon set (the designer, 6-8 months) later goes into this same theme, with no session change.
- **F-B.** F-A, and the vendored package rewrites WhiteSur's `Inherits` to `Adwaita,hicolor`, so Breeze is never mixed
  in. This modifies a GPL work: the change must be noted. Possible only with distribution option B.
- **F-C.** Name `WhiteSur` directly and set the variable only when its `index.theme` exists, as `devenv.sh` does. GTK
  would need the same check inside dconf: impossible with a static database.

## Decision (proposed)

### Distribution: option B (C-compatible)
- The vendored, pinned split package `grassfield-whitesur-icons`, optional for `grassfield-desktop`, with `provides`
  and `conflicts` as above. Pin updates follow the `whitesur.sh` procedure: read the new `install.sh` in full, update
  both hashes, re-run the measurements of ui.md:53. Dev keeps `scripts/dev/whitesur.sh` on the same pin.
- Icon caches: the package ships no `icon-theme.cache` (they would list removed icons); the gtk-update-icon-cache pacman
  hook builds them on the target.
- Uninstall: removing the package makes the session fall back to Adwaita through the wrapper. No configuration to
  undo.

### The session theme: `grassfield-icons` everywhere in the Grassfield session, nothing in the Omarchy session
1. **Wrapper theme** (F-A). Source: `branding/icons/theme/index.theme` (Grassfield's own file, MIT, listed in
   `branding/LICENSES.md`). `Name=Grassfield`, `Hidden=true` so that theme pickers in other sessions do not list it.
2. **Qt and the shell** (Q-A). A package file `/usr/share/uwsm/env-grassfield`:
   ```sh
   # Grassfield session only (uwsm sources env-${desktop} for XDG_CURRENT_DESKTOP=Hyprland:Grassfield).
   export QT_QPA_SYSTEM_ICON_THEME=grassfield-icons
   ```
   uwsm exports it before the compositor and every user service start, and unsets it at the end of the session.
   - The reference dbus-daemon only empties it; Qt ignores an empty value (ASSUMPTION: `isEmpty()` check), so that is
     harmless.
   - If the spike finds that uwsm does not read `/usr/share/uwsm`, fall back to the cursor pattern: `hl.env` in
     `config/hypr/session.lua`, plus the name added to the `uwsm finalize` list in `autostart.lua:8`.
   - Dev: `devenv.sh` installs the wrapper into `.dev/share/icons/grassfield-icons` and sets the variable to it always
     (no WhiteSur → Adwaita), so dev and real sessions resolve the same way.
3. **GTK, Electron, Chromium, Firefox, Flatpak** (G-C1, owner question 3, after spike I0). The same env file adds:
   ```sh
   [ -r /usr/share/grassfield/dconf/profile ] && export DCONF_PROFILE=/usr/share/grassfield/dconf/profile
   ```
   The profile holds `user-db:user` and then the Grassfield database (file-db or system-db as the spike decides).
   - If absolute profile paths are not supported, the profile goes to `/etc/dconf/profile/grassfield` with
     `DCONF_PROFILE=grassfield`.
   - The guard matters: a profile dconf cannot open is believed to give a "null configuration" (every GTK setting at
     its default), and so might an empty `DCONF_PROFILE` left behind by the reference dbus-daemon. The spike checks
     both. If either is unsafe, G-C1 requires dbus-broker, which the owner checks once with a read-only command.
4. **KDE Frameworks apps**: only if the spike shows that a KF6 app ignores the Qt variable. Then the env file prepends
   `/usr/share/grassfield/xdg` to `XDG_CONFIG_DIRS`, holding a `kdeglobals` with `[Icons] Theme=grassfield-icons`.
   The user's own `kdeglobals` still wins.
5. **What is never done.** No write to the user's dconf database or the owner's dotfiles. No system-wide default (no
   `/etc/xdg/kdeglobals`, no `/etc/gtk-3.0/settings.ini`, no `/etc/dconf/profile/user`). No running setting is changed
   at run time.

### Fallbacks
Through the wrapper only (F-A), as above. Both resolution orders are tested: lookups depth first, Qt and GTK appending
`hicolor`. Accepted consequence: the few icons WhiteSur lacks come from Breeze (installed here), because WhiteSur
itself inherits it. F-B is the owner's alternative.

### Icon modes and folder colours (ADR-0014)
- **`default` mode**: unchanged; the theme's icon as is.
- **`dark`, `clear`, `tinted`** draw every icon on a system plate (owner batch 6, STATE:103-105). WhiteSur icons are
  already rounded squares with their own margin. The plate scale and inset tokens (`iconMode.*`) are re-tuned so that a
  WhiteSur icon sits on the plate the way the reference shows. They are then checked on the Adwaita fallback, which has
  mixed shapes.
- **Folder colours**: `icons.folderColor = theme` now shows WhiteSur's blue folders. `accent` and custom colours
  recolour the luminance of the theme's folder (`FolderEffect`). Folder symbols read the raw folder icon per file
  (`FolderPlate`), so they are theme-independent. Repeat their contrast check (≥ 3:1, docs/specs/files.md) on WhiteSur
  and on the fallback.
- **The Dock Trash** shows WhiteSur's `user-trash` and `user-trash-full`, as the owner asked (STATE:88-90).
- **Settings previews**: the sample icon of the Appearance mode tiles must be a name present in both WhiteSur and
  Adwaita (for example `preferences-system`), so the preview matches the real icons.

### THIRD_PARTY.md and legal entries to add (drafts; no legal conclusion)
- **THIRD_PARTY.md §5**, new paragraph "WhiteSur icon theme (optional package `grassfield-whitesur-icons`)":
  - upstream URL, author (`AUTHORS`: Vince Liuice), commit `73d8040…`;
  - licence GPL-3.0 (`COPYING`; version qualifier to VERIFY);
  - data files read by Qt, GTK and KDE, not linked, not modified;
  - `COPYING` and `AUTHORS` shipped in `/usr/share/licenses/grassfield-whitesur-icons/`;
  - the source is the upstream repository at that commit, and the PKGBUILD reproduces the package;
  - the theme's metadata contains "MacOSX", and its name alludes to an Apple product name. Grassfield never displays
    either, except in the licence and acknowledgements text.
  - **Needs legal review:** the source offer if the package leaves the owner's machine.
- **docs/legal/licenses-audit.md:**
  - §3: a third package row (optional, GPL-3.0 data);
  - §4.1: a new row (WhiteSur, use: icon theme data, licence GPL-3.0 per COPYING);
  - §5: gap **G12** "GPL-3.0 icon data in an optional package: licence and source offer for any distribution; the
    aggregation with MIT packages" (options: keep AUR-only, ship with source, replace with Grassfield's own set);
  - §6 (ISO): ship the source with the ISO, or leave the package out of it;
  - §7: the aggregation question.
- **docs/legal/visual-review.md E27:**
  - from `distinct` (none shipped) to `close` (the default theme imitates the macOS icon style);
  - flag `1:1 copy?` per icon for any WhiteSur icon that reproduces an Apple app icon. Already noted: WhiteSur's Files
    icon is a Finder look-alike (STATE:147, review of 68bf3fc);
  - inventory of the icons Grassfield shows by default, for a side-by-side check by counsel:
    - the Dock's pinned `foot`, `chromium` and `org.gnome.Nautilus`;
    - the Trash;
    - the stock names of Grassfield's own entries: `preferences-system`, `system-file-manager`, `image-x-generic`.
  - Options:
    - map Grassfield's own apps to icons that do not imitate Apple's;
    - Grassfield's own set replaces WhiteSur before any public release (already planned);
    - removing the package restores Adwaita.
  - Summary row E27 and §6 updated: trade dress of a default third-party theme that imitates Apple icons. Needs legal
    review.
- **docs/dev-themes.md and ADR-0014**: point to this ADR; `QT_ICON_THEME` and the pragma are no longer the plan.

### Tests
- **L0:**
  - `tests/shell/icon_env.sh`, in the style of `cursor_env.sh`:
    - the env file sets the Qt variable;
    - `DCONF_PROFILE` is set only when the profile file exists;
    - `devenv.sh` selects the wrapper with and without a dev WhiteSur;
    - the wrapper's `index.theme` has `Inherits=WhiteSur,Adwaita,hicolor` and one existing directory.
  - `Hyprland --verify-config` if `session.lua` changes.
  - `tests/unit/tst_icontheme.qml`, offscreen, with fixture themes under a temporary `XDG_DATA_DIRS` (a fake WhiteSur
    with two icons, a fake Adwaita): an icon present in WhiteSur comes from WhiteSur; a missing one from Adwaita; with no
    WhiteSur at all, from Adwaita; `hicolor` last.
- **dconf (L0/L1, isolated):** `tests/shell/dconf_profile.sh` uses a temporary `XDG_CONFIG_HOME` and
  `XDG_RUNTIME_DIR` and the dev private bus, so the owner's dconf is never touched. With the profile:
  - `gsettings get org.gnome.desktop.interface icon-theme` returns `grassfield-icons`;
  - `gsettings set` on that key fails (not writable);
  - `gsettings set … color-scheme` lands in the isolated user database;
  - without `DCONF_PROFILE`, the isolated user's own value is read;
  - with `DCONF_PROFILE=""` and with a missing profile, the outcome is recorded (the safety rule above).
- **L1 nested screenshots:**
  - Dock, Apps, Search, the desktop and Files, with the dev WhiteSur and without it (`XDG_DATA_DIRS` without it);
  - Nautilus, isolated through `isolated.sh`, under the profile;
  - a KF6 app (Kdenlive) for the KDE row;
  - every icon mode and folder colour on both themes.
- **L2 (owner, real session, read-only commands):**
  - `gsettings get org.gnome.desktop.interface icon-theme` gives `grassfield-icons` in Grassfield, and is unchanged in
    the Omarchy session;
  - `dconf dump /org/gnome/desktop/interface/` is identical before and after a Grassfield session in which nothing was
    changed by hand;
  - `systemctl --user show-environment` lists the variables during the Grassfield session and not after it;
  - screenshots of Dock, Nautilus and Chromium.
- **Reviewer:** the session environment contract, the packaging and licence files, and the look of icon modes and
  folder colours on WhiteSur.

### Size of work (agent-days, estimates)
| Slice | Days |
|---|---|
| I0 spike | 1 |
| I1 wrapper and Qt environment | 0.5 |
| I2 split package | 0.5 |
| I3 dconf profile | 0.5-1 |
| I4 icon modes and folder colours re-tuned and re-measured | 0.5-1 |
| I5 THIRD_PARTY and legal documents | 0.5 |
| **Total** | **≈ 3.5-4.5**, plus owner build, install and one L2 check |

## Owner questions (recommended proposal first)
1. **Distribution.**
   (a) Vendored, pinned split package `grassfield-whitesur-icons` (same pin as dev, `provides`/`conflicts` with the AUR
       package).
   (b) `optdepends` on the AUR package; the owner reviews its PKGBUILD and installs it.
   (c) Not packaged: dev only (the session then shows Adwaita through the wrapper).
2. **Installing WhiteSur on this machine** (replaces the 2026-10-19 "dev only" rule).
   (a) Yes, system-wide through the package, now that the machine is dedicated.
   (b) No: keep it dev-only until the legal review.
3. **GTK, Electron, Firefox and Flatpak apps.**
   (a) Session dconf profile G-C1: the normal user database plus a locked Grassfield database holding only
       `icon-theme`, after spike I0.
   (b) G-C2: a writable Grassfield database over the user's (every GNOME setting changed in Grassfield stays in
       Grassfield; needed only for a future icon-theme picker).
   (c) Qt only; GTK apps keep Omarchy's icon theme (a documented mix).
4. **Fallback chain.**
   (a) Wrapper `grassfield-icons`: WhiteSur, then Adwaita, then hicolor (Breeze still serves the few icons WhiteSur
       lacks, through WhiteSur's own `Inherits`).
   (b) As (a), and the vendored package patches WhiteSur's `Inherits` to `Adwaita,hicolor` (a noted modification of a
       GPL work).
5. **Variant.**
   (a) The base `WhiteSur` in both appearances (what the dev measurements used).
   (b) `WhiteSur-dark` or `WhiteSur-light` chosen from `appearance` at login and passed in the launch environment; apps
       already running keep theirs.
6. **Attribution in the UI.**
   (a) Settings > About > Acknowledgements lists the icon theme, its author and its licence (this also closes gap G10);
       theme names are shown nowhere else.
   (b) Licence files only.

## Implementation plan (slices; each ends with `just check`, its tests, its shots, and the reviewer where marked)
| Slice | Content | Gate before the next slice |
|---|---|---|
| I0 spike (nested and temporary directories; no system or owner file touched) | (1) A tiny Qt program prints `QIcon::themeName()` under `QT_QPA_PLATFORMTHEME=gtk3` with and without the variable. (2) The wrapper in Qt and GTK, with and without a dev WhiteSur, and a wrapper without `Directories`. (3) dconf: absolute profile path, `file-db` locks, read fallthrough to `user-db:user`, writes, empty and missing `DCONF_PROFILE`. (4) A KF6 app. (5) How uwsm reads `env-${desktop}` (its code, read only) | results recorded here; owner answers 3-5 |
| I1 wrapper and Qt environment | `branding/icons/theme/index.theme`, the env file, `devenv.sh`, PKGBUILD install lines | `icon_env.sh`, `tst_icontheme`, nested shots with and without WhiteSur; reviewer (session environment contract) |
| I2 package | `grassfield-whitesur-icons` split package, `optdepends`, licence files | `bash -n` on the PKGBUILD and `makepkg --printsrcinfo` (owner if blocked); reviewer (packaging, licence); owner `makepkg -si` |
| I3 dconf (per answer 3) | profile, compiled database, the guard in the env file | `dconf_profile.sh`; owner L2 check that the Omarchy session is unchanged |
| I4 look | plate tokens, folder colour checks, previews | shots per mode on both themes; folder-symbol contrast check; reviewer on look; F1 owner glance |
| I5 docs and legal | THIRD_PARTY.md, licenses-audit (G12), visual-review E27, dev-themes.md, ADR-0014 note, BRANDING | reviewer; "needs legal review" marks present |

## Evidence
Design only. Read in this session with `ls`, `grep`, `sed -n`, `head` and `du`, on the repository, `/usr/share/omarchy`,
`/usr/lib/qt6`, `/usr/share/icons` (names), `/etc/dconf`, `/usr/share/doc/uwsm`, and the main checkout's dev WhiteSur
(`index.theme`, `COPYING`, `AUTHORS`, the stamp, file presence). No nested session, no measurement, no network, no
package command.

## Consequences
- **New session contract** (Grassfield session only):
  - `QT_QPA_SYSTEM_ICON_THEME=grassfield-icons`;
  - optionally `DCONF_PROFILE` and an `XDG_CONFIG_DIRS` prefix;
  - the theme name `grassfield-icons` is stable; its content changes when Grassfield's own icons arrive.
- **Packaging:**
  - `grassfield-desktop` ships the wrapper theme, `/usr/share/uwsm/env-grassfield` and, with G-C1, the dconf profile
    and database;
  - a new optional GPL-3.0 package;
  - the PKGBUILD downloads one pinned git source.
- **The Omarchy session is unaffected by construction**: no shared file or database is written, and every variable
  lives only in the Grassfield session's environment. L2 confirms it.
- **What we give up:**
  - with G-C1, the GTK icon theme cannot be changed from inside the Grassfield session (`gsettings` refuses the locked
    key, and Omarchy's theme script run there would fail on that key only);
  - apps already running keep their icon theme;
  - Breeze icons can appear for names WhiteSur lacks (unless 4b).
- **Re-verify on updates:** Qt minor versions (the variable), uwsm (env file lookup), dconf (profile rules), and any pin
  bump of WhiteSur (icon names used by the shell, the measurements of ui.md:53).

## Apple artwork (amendments 2026-10-20: review of merge 7cdbd68, then counter-review of merge de09465)
Hard rule: no Apple assets or Apple-trademark artwork in the UI or in any package. Owner decision 2026-10-20: WhiteSur
stays for the internal phase, filtered; every icon that shows the Apple logo, an Apple product's trademark artwork or an
Apple product silhouette is removed; the names that pointed at it fall back to Adwaita/Breeze through `grassfield-icons`;
the build FAILS if any known one remains; Grassfield's own app icons come from another work item; legal review is still
required before any public release.

What upstream WhiteSur at the pin ships (found by rendering, by IoU comparison and by viewing contact sheets):
- the Apple logo as `start-here*`, `folder-apple*` (12 files, with 27 names linked to them), and inside 22 more files
  (`devices/{16,22,24}/multimedia-player-ipod-mini-blue`, `apps/scalable/preferences-desktop-icons`, the iMac of
  `computer`, `video-television`, `putty`, `variety*`, `accessories-system-cleaner`, `xwaylandvideobridge`, the Magic Mouse
  of `input-mouse`, `preferences-desktop-mouse`, `preferences-desktop-peripherals`, the menu bar of
  `preferences-system-windows`, `remote-desktop`), reachable through about 100 names (`computer`, `display`, `monitor`,
  `system`, `edit-clear`, ...);
- Apple app icons reproduced 1:1 and reused for generic names (`file-manager` is Finder and `system-file-manager`,
  `org.gnome.Nautilus`, ... resolve to it; `softwarecenter` is the App Store; `jockey` is Xcode; `preferences-system` is the
  System Preferences gear; Safari, iCloud, Dictionary, Podcasts, Music, Photos, Calendar, Contacts, Messages, Time Machine,
  Chess, Photo Booth, QuickTime, Activity Monitor, Font Book, TextEdit, Stickies, Reminders, Terminal, Clock, Weather,
  Voice Memos), the Apple Music note and the QuickTime and Xcode art on the generic `audio-x-generic`, `video-x-generic`,
  `text-x-makefile` document icons, the AirPlay mark, the Swift logo, and the iPhone, iPad and iPod silhouettes.

Enforcement (`packaging/arch/whitesur-guard.sh`, `whitesur-detect.py`, `whitesur-apple-logos.txt`, `whitesur-blocklist.txt`):
- `build()` runs install.sh with `-p` in a clean environment, then `clean`, then `check` on the build tree;
  `package_grassfield-whitesur-icons()` runs `check` again on the packaged tree; `scripts/dev/whitesur.sh` runs the same
  guard (stamp `<pin>-noapple2`, so installs made before the detector are rebuilt). `check` fails on any hit and on any
  dangling symlink; a detector that can not run (no reference masks, no python3) fails the guard, it never reads as "no hit".
- Layers, all in the guard: file names (`folder-apple*`, `*apple-logo*`); whole-file SHA-256 and path-data prefixes of the 12
  upstream logo files (cheap, byte-level); **the perceptual detector**; **the curated blocklist**.
- **Perceptual detector** (standard-library Python): every drawable part of every SVG of the three variants (each shape
  element, each run of 1 to 3 sub-paths, each run of 2 to 3 sibling elements, each group of at most 12 elements, with
  transforms) is filled, cropped to its bounding box, scaled into a 64x64 grid and compared by intersection-over-union with
  4 reference masks (the Apple logo, its folder variant, the App Store "A" and the Finder face outline, derived from the
  pinned checkout by `whitesur-guard.sh list`) in all 8 rotations and mirrors; alpha PNGs embedded in an SVG are compared
  the same way (opaque pixels, and pixels that differ from the border colour). Threshold 0.88 (tuned on the data: the 22
  logo files and the 12 known files score 0.935 to 1.0, the best non-logo of 20335 files scores 0.835; the margin is
  small, so the threshold is tested on fixtures and re-checked on a pin change). The path syntax (`m` or `M`, relative or
  absolute, arcs or curves), the colour, the size and the position do not matter. 36 files are found this way in the
  unfiltered tree. The App Store "A" glyph is found inside the `folder-templates*` icons too.
- **Blocklist** (`whitesur-blocklist.txt`, a reason on every entry): 126 icon names (every size and variant of that name,
  links included) and 103 colour-normalised drawing hashes (the same drawing under another name, recoloured). Method: the
  whole package, 10799 distinct drawings of the three variants, was viewed on contact sheets (docs/legal/visual-review.md
  E27 lists the sheets) and every Apple app icon, hardware silhouette or mark found was listed; `whitesur-detect.py derive`
  produces the hashes and the copies' names. A hash entry follows links: a listed name that is only a link lists the file it
  points at.
- **Fallback.** `clean` removes the hits, every file or link with the basename of a hit, the links left dangling and, in
  every folder, every other file or link whose name was the name of a dangling link (so `display` does not resolve to another
  WhiteSur icon), until stable. On the pin this removes about 350 regular files and 1600 links of the three variants. The
  names then fall back to Breeze or Adwaita through the wrapper (`tests/shell/icon_theme.sh` checks `computer`, `display`,
  `system-file-manager`, `preferences-system`, `input-mouse`, `phone` resolve to Breeze; `display` is in neither Breeze nor Adwaita, so it resolves to nothing and never to WhiteSur; on a fixture and on the built package tree).
- **Limits, stated.** Not detected: logos drawn only as strokes, logos tilted by an angle that is not a multiple of 90
  degrees, logos inside an opaque raster or a JPEG, and any Apple artwork that is neither a logo shape nor on the blocklist.
  The review is by eye on contact sheets of one drawing per icon name: it proves what is listed, not that nothing else
  exists. The remaining app icons imitate the macOS style (squircle, gradients); that trade-dress question stays with counsel
  (visual-review E27). Generic artwork kept on purpose: the pkpass ticket, the disk image, laptops, keyboards, trackpads,
  monitors and the generic outlined symbolic phones.
- `tests/shell/whitesur_guard.sh` tests the guard (rewritten `m`/`M` path, recoloured, mirrored, rotated, body and leaf as two
  elements, a small logo inside a larger icon, an embedded PNG, generic shapes that must pass, the blocklist, fail-closed,
  alias removal); `tests/shell/whitesur_package.sh` scans the built package tree when it exists.
- A pin change requires re-viewing the new tree, regenerating the list (`whitesur-guard.sh list`) and re-deriving the
  blocklist.

## Spike I0 results (2026-10-20, implementation session)
Scratch files under `.dev/spikes/i0` and the automated tests `tests/shell/icon_theme.sh`, `tests/shell/dconf_profile.sh`.
No owner file, database or bus was touched; every dconf call ran under `env -i` with a scratch `DCONF_PROFILE` and
`XDG_CONFIG_HOME`.
1. **Qt.** `QT_QPA_SYSTEM_ICON_THEME` is read by `QIconLoader::updateSystemTheme` (disassembly of libQt6Gui 6.11.2) and
   gives `QIcon::themeName() == grassfield-icons`; an empty value is ignored. Only the `generic`/unset platform themes
   could be run here: the `gtk3` platform theme needs a GDK display (none in the sandbox), so its precedence over the
   variable is NOT verified in a run (it is by Qt's code order, and by the dev sessions that show WhiteSur). The offscreen
   platform adds no icon search paths: tests set them from `XDG_DATA_DIRS`.
2. **dconf (dconf 0.49, no D-Bus available in the sandbox, so reads and lock checks only; writes NOT run).**
   `DCONF_PROFILE` takes an absolute path. `file-db:<path>` is supported, and the lock table is compiled into it
   (`dconf compile` of a `.d` directory with `locks/`, or `dconf update`): with `user-db:user` first, `icon-theme` reads
   `grassfield-icons` even when the user database holds another value, `gsettings writable` says false and
   `gsettings set` fails with "The key is not writable"; other keys read from the user database and stay writable;
   without `DCONF_PROFILE` the user's own value is read. **Unsafe cases:** an empty or missing profile gives dconf's
   "null configuration" (every key at its schema default, the user database ignored); a profile naming a missing file-db
   only warns and keeps the user database. Hence the readability guard in `env-grassfield`. This system's D-Bus is
   dbus-broker (`dbus.service` links to `dbus-broker.service`), which can unset variables.
3. **Wrapper and lookups.** `Inherits=WhiteSur,Adwaita,hicolor` with `Directories=scalable/apps`: Qt, GTK 3 and GTK 4
   all resolve WhiteSur first, then Adwaita, then hicolor, and skip a missing WhiteSur. Without `Directories`: GTK drops
   the theme and its parents ("Theme file for wrapper-nodirs has no directories": only hicolor answers); Qt still
   follows the parents. uwsm 0.26.7 (`/usr/lib/uwsm/prepare-env.sh`) sources `env-<desktop>` from each of
   `XDG_CONFIG_HOME`, `XDG_CONFIG_DIRS` and `XDG_DATA_DIRS`, so `/usr/share/uwsm/env-grassfield` is read.
4. **Not done:** KF6 app check (slice item 4, no display), Quickshell `iconPath` offscreen (returned empty paths in the
   sandbox), nested shots.

## Owner answers (2026-10-20)
- Distribution: a split package grassfield-whitesur-icons built by makepkg from the pinned upstream commit (nothing
  vendored in the MIT repo); it replaces the 2026-10-19 "WhiteSur only in .dev" rule on this dedicated machine.
- `grassfield-icons` stays Grassfield's app icon theme: Grassfield's own icons first (drawn over time), then WhiteSur,
  then Breeze/Adwaita/hicolor. The 41 symbolic system icons are unchanged.
- GTK/Electron/Flatpak: session dconf profile with a locked icon-theme key, after spike I0.
- Other questions: the recommended options (wrapper fallback accepting Breeze, base WhiteSur in both appearances,
  Acknowledgements in Settings > About).

## Amendment 2026-10-21: WhiteSur dropped; the chain is own icons, Breeze, Adwaita, hicolor
Status of this amendment: Proposed (applied provisionally). Decider: integrator, recorded in docs/STATE.md. It supersedes
every WhiteSur decision above (distribution, the split package, the Apple-artwork guard, the Acknowledgements row).

- **What happened.** The filtered WhiteSur package was reviewed four times (the review of merge 7cdbd68, the
  counter-review of de09465, and further passes in the fix series, the last one "counter-review #4 FAIL" in
  docs/STATE.md). Each pass found more Apple app-icon artwork left after the guard. Filtering a theme whose purpose is to
  imitate macOS does not converge: every pin change needs a new full review by eye. The package was withheld on
  2026-10-21 and is now removed.
- **New chain.** `grassfield-icons` inherits `breeze,Adwaita,hicolor` after its own (so far nearly empty) directory:
  Grassfield's own icons, then Breeze (KDE art, `breeze-icons`, now a dependency of `grassfield-desktop`), then Adwaita
  (GNOME art, installed with GTK and Omarchy), then hicolor. All are original KDE/GNOME art installed by pacman; nothing
  is vendored. The locked dconf profile (`icon-theme='grassfield-icons'`, GTK) and `QT_QPA_SYSTEM_ICON_THEME` (Qt) are
  unchanged. Dev sessions use the same chain through devenv.sh.
- **Papirus considered and rejected.** It would be a new dependency (owner approval needed), and it ships brand logos,
  Apple ones included, which cannot be filtered in a system package we do not build.
- **The shape.** The macOS 26 rounded-square look will come from the shell's system plate (ADR-0014), drawn by the shell
  around any icon, not from a theme. That is a separate pass and not part of this amendment.
- **Removed.** `grassfield-whitesur-icons`, `packaging/arch/whitesur-{guard.sh,detect.py,blocklist.txt,apple-logos.txt}`,
  `scripts/dev/whitesur.sh` (and `just whitesur`), the About page Acknowledgements row, the four whitesur_* tests and the
  WhiteSur fixtures. The perceptual detector was deleted rather than repurposed: its logo masks were derived from the
  WhiteSur checkout, and re-deriving them for Grassfield's own three icons costs more than a review by eye.
- **Tests.** `tests/shell/icon_theme.sh` (Breeze, Adwaita, hicolor order in Qt and GTK 3/4, plus the installed themes),
  `tests/shell/no_whitesur.sh` (the wrapper never inherits WhiteSur; no tracked file outside docs and licence notices
  mentions it). `tests/shell/dconf_profile.sh` is unchanged: it does not depend on the chain.
- **Consequence.** Icons that Breeze and Adwaita lack fall to a generic icon until the system plate and Grassfield's own
  icons cover them. needs legal review before any public release (no claim that Breeze or Adwaita contain nothing that
  resembles an Apple icon).
