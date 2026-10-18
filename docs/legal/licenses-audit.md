# Licence audit (M5)

Status: preparation material for the owner and a lawyer. **Not legal advice; no legal conclusion is stated here.**
Prepared 2026-10-18 from the repository at commit 53b6c10 and the packages installed on the development machine
(master-prompt §14, ADR-0005). Companion document: `docs/legal/visual-review.md`.

Tags: **VERIFIED** (checked in this session, source cited), **ASSUMPTION** (memory or project docs, unchecked),
**needs legal review** (question for counsel; the note states the question only).

## 1. Method

- Licences come from local files only: `pacman -Qi <pkg>` (field "Licenses"), `/usr/share/licenses/<pkg>/`, SPDX
  lines in installed headers, and headers of files in this repository. No network access was used; questions that
  would need upstream material are listed as open.
- How each component is used was read from `packaging/arch/PKGBUILD`, the CMake files, QML imports
  (`grep -rh -o -E '^import [A-Za-z.]+' shell ui apps --include=*.qml | sort | uniq -c`) and `readelf -d` on the
  development builds in the main checkout (`.dev/build/*`, `compositor/build/grassfield-compositor.so`).
- Versions are those installed on 2026-10-18 (`pacman -Qi`).

## 2. Project licence and current repository status

**Decision on file:** `docs/decisions/ADR-0005-license.md`, status **Proposed**, "needs legal review":
- code (shell QML, plugin C++, bridge, apps, scripts, config): MIT, a root `LICENSE`, `SPDX-License-Identifier: MIT`
  in new source files;
- code adapted from Omarchy keeps its MIT notice and attribution;
- assets in `branding/`: CC-BY-SA-4.0 unless stated otherwise, provenance per file in `branding/LICENSES.md`;
  fonts SIL OFL only, unmodified;
- third-party notices in `THIRD_PARTY.md`.

**What the repository does today (VERIFIED):**

| Item | State | Evidence |
|---|---|---|
| Root `LICENSE` | **absent** | `git ls-files \| grep -i -E 'licen\|copying\|notice'` → only `branding/LICENSES.md`, the ADR and an unrelated `NoticeDialog.qml` |
| `THIRD_PARTY.md` | **absent** | same command; also referenced as "to list" in `docs/specs/compositor.md:327-330` |
| SPDX headers | 6 files with `SPDX-License-Identifier: MIT`: `bridges/menu-bridge/src/main.cpp` and five test tools/fixtures; 1 file with LGPL-2.1-or-later (`compositor/protocols/appmenu.xml`); none in the other 485 tracked non-documentation files (code, config, SVG, JSON) | `grep -rl 'SPDX-License-Identifier' apps bridges compositor config shell ui scripts tests packaging`; `git ls-files \| grep -v -E '^docs/\|\.md$' \| wc -l` → 492 |
| `README.md` | "License: pending ADR-0005" | `README.md` last line |
| `packaging/arch/PKGBUILD` | `license=(MIT)` for both packages; installs `branding/LICENSES.md` as `/usr/share/licenses/grassfield-desktop/BRANDING.md`; installs **no** `LICENSE` and no third-party notice; `grassfield-compositor` installs only the `.so` | `packaging/arch/PKGBUILD` lines 14, 98-99, 102-106 |
| `branding/LICENSES.md` | covers the 40 SVG files and, since this audit, the procedural wallpaper; the first row says "(40 files)" although the logo has its own row (39 + 1) | file content |
| Omarchy-derived code | attribution header in 3 files (see 4.11) | file headers |

Observations for counsel (no conclusion):
1. `license=(MIT)` is declared while no MIT text with a copyright line exists in the repository or the package.
2. `license=()` does not mention CC-BY-SA-4.0 (icons) or the LGPL-2.1-or-later notice carried by generated code in
   the plugin (4.4).
3. ADR-0005 cites KIO as "LGPL-2.1+"; the installed headers say LGPL-2.0-or-later or "LGPL-2.0-only OR
   LGPL-3.0-only OR LicenseRef-KDE-Accepted-LGPL" (4.8).
4. Authorship: `branding/LICENSES.md` records icons and wallpaper "drawn by Claude"; most code is also AI-written
   under the owner's direction. needs legal review: whether such material can carry the chosen licences
   (copyrightability of AI-generated works varies by jurisdiction, ASSUMPTION).
5. Licence choice itself (MIT for code, CC-BY-SA-4.0 for assets, ShareAlike applied to a trademark logo).
   needs legal review.

## 3. What Grassfield distributes

| Package (PKGBUILD) | Contents | Built from |
|---|---|---|
| `grassfield-desktop` | QML shell (`/usr/share/grassfield/shell`), `Grassfield.Ui` QML module + 40 SVG icons, `Grassfield.I18n` QML plugin `.so` + `.qm` catalogues, Hyprland Lua session config, JSON defaults and schema, session `.desktop`, systemd user units, `grassfield-menu-bridge`, `grassfield-settings`, `grassfield-files`, `grassfield-preview` binaries and their QML, `.desktop` files, README, `BRANDING.md` | this repository only |
| `grassfield-compositor` | `/usr/lib/grassfield/grassfield-compositor.so` (Hyprland plugin) | this repository, compiled against Hyprland headers, with code generated from `compositor/protocols/appmenu.xml` |

Everything else (Hyprland, Quickshell, Qt, KF6, fonts) is a declared dependency installed from the Arch/Omarchy
repositories; Grassfield does not redistribute it today. The ISO (M6) changes that (section 6).

## 4. Third-party components

### 4.1 Summary table

| # | Component (version) | How Grassfield uses it | Licence per local files | Obligation type (to confirm) | Status in this repo |
|---|---|---|---|---|---|
| 1 | Hyprland headers 0.56.2 | compile-time includes of the plugin; the plugin runs inside Hyprland | BSD-3-Clause, "Copyright (c) 2022-2026, vaxerski" | notice (binary redistribution reproduces the copyright, conditions, disclaimer); no-endorsement clause | no notice shipped; no THIRD_PARTY.md; needs legal review |
| 2 | aquamarine 0.15.0, hyprutils 0.14.2, hyprlang 0.6.8, hyprgraphics 0.5.1, hyprcursor 0.1.13 | headers included; shared libraries linked by the plugin (`NEEDED`) | BSD-3-Clause ("Copyright (c) 2024, Hypr Development" for aquamarine and hyprutils) | notice | as row 1 |
| 3 | hyprwayland-scanner 0.4.6 | build tool generating the plugin's appmenu server code | BSD-3-Clause | none identified for generated output (ASSUMPTION) | needs legal review (licence of generated code) |
| 4 | KDE `org_kde_kwin_appmenu` protocol XML | file `compositor/protocols/appmenu.xml`; generated server code compiled into the plugin | LGPL-2.1-or-later, "SPDX-FileCopyrightText: 2017 David Edmundson" | LGPL-2.1 terms for the XML and possibly the generated code | notice kept in the XML and in the generated header; not in a notices file; needs legal review |
| 5 | Other libraries linked by the plugin: cairo 1.18.4, libxkbcommon 1.13.2, libinput 1.31.3, wayland 1.26.0, libxcb 1.17.0, xcb-util-errors, xcb-util-wm, pixman 0.46.4, libdrm 2.4.134, libglvnd (libEGL), libstdc++/libgcc, glibc | dynamic (`NEEDED`) | cairo LGPL-2.1-only OR MPL-1.1; xkbcommon, libinput, wayland, pixman, libdrm, xcb-util-errors MIT; libxcb X11; xcb-util-wm X11-distribute-modifications-variant; libglvnd custom BSD-like; gcc-libs GPL-3.0-or-later WITH GCC-exception-3.1; glibc LGPL-2.1-or-later | obligations fall on whoever distributes these libraries (the distribution today) | none needed for the add-on as far as identified; ISO: section 6 |
| 6 | Lua 5.5.1 | headers at build time; symbols resolved from Hyprland's liblua | MIT | notice if redistributed | build-time only |
| 7 | Quickshell 0.3.1 | runtime host: `grassfield-shell` is QML run by `qs`; `Grassfield.Ui` (QML) and `Grassfield.I18n` (MIT plugin `.so`, links Qt only) are loaded into it | LGPL-3.0-only (`/usr/share/licenses/quickshell/LICENSE`) | LGPL-3.0; unmodified per §14 | unmodified (no patch in the repo; PKGBUILD depends on the Arch package); needs legal review (4.7) |
| 8 | Qt 6.11.2 (base, declarative, wayland, svg, imageformats, tools) | dynamic linking (Core, Gui, Widgets, OpenGL, Qml, Quick, Network, DBus); QML imports; run-time plugins; build tools | header SPDX: "LicenseRef-Qt-Commercial OR LGPL-3.0-only OR GPL-2.0-only OR GPL-3.0-only"; package: GPL-3.0-only, LGPL-3.0-only, LicenseRef-Qt-Commercial, Qt-GPL-exception-1.0 | LGPL-3.0 (dynamic linking, notice, relinking possible) | dynamic linking VERIFIED; no notice shipped; 4.5 |
| 9 | QtPdf / QtPdfQuick (package qt6-webengine 6.11.2) | QML import `QtQuick.Pdf` in Preview | header SPDX as Qt; Chromium/PDFium notices in `/usr/share/licenses/qt6-webengine/LICENSE.chromium` (BSD-style, "Copyright 2015 The Chromium Authors") | LGPL-3.0 + third-party notices | dependency only; 4.5 |
| 10 | QtMultimedia 6.11.2 + FFmpeg backend | QML import `QtMultimedia` in Preview; backend `qt6-multimedia-ffmpeg` loads **ffmpeg 9.0.1** | QtMultimedia as Qt; `qt6-multimedia-ffmpeg` as Qt; **ffmpeg: GPL-3.0-only** (pacman) | GPL-3.0 on ffmpeg | needs legal review (4.6) |
| 11 | KF6 KIO, Solid, CoreAddons, Service 6.29.0 | dynamic linking by `grassfield-files` (`libKF6KIOCore`, `KIOGui`, `KIOWidgets`, `CoreAddons`, `Service`, `Solid`) | headers: LGPL-2.0-or-later (`kio/job.h`, `kio/copyjob.h`, `kio/renamedialog.h`, `kjob.h`, `kservice.h`); "LGPL-2.0-only OR LGPL-3.0-only OR LicenseRef-KDE-Accepted-LGPL" (`kio/openurljob.h`); "LGPL-2.1-only OR LGPL-3.0-only OR LicenseRef-KDE-Accepted-LGPL" (`solid/device.h`); package: LGPL-2.0-only LGPL-3.0-only | LGPL (dynamic linking) | dynamic linking VERIFIED; no notice shipped |
| 12 | kio-extras 26.08.0 (optional) | run-time KIO workers for network places and thumbnails | LGPL-2.0-or-later | none for the add-on (separate program) | optdepends only |
| 13 | extra-cmake-modules 6.29.0 | build-time CMake modules (Files) | pacman says "LGPL"; module headers say BSD-3-Clause (37 files) and BSD-2-Clause (1) | none (build tool) | metadata/header mismatch noted |
| 14 | libnotify 0.8.8 | declared in `depends=()`; **no linking or execution found** in shipped code (only a comment in `shell/notifications/History.js:139`; `notify-send` appears in dev scripts) | LGPL-2.1-or-later | none identified | dependency without visible use: keep or drop is an owner choice |
| 15 | Inter 4.1 (package inter-font) | UI font by family name; not bundled | `/usr/share/licenses/inter-font/LICENSE.txt`: SIL OFL 1.1, "Copyright (c) 2016 The Inter Project Authors"; pacman: OFL-1.1-RFN | OFL (licence text with the fonts, no sale alone, Reserved Font Name rules if modified) | not redistributed; RFN discrepancy (4.9) |
| 16 | Noto Sans (noto-fonts 2026.09.01) | fallback family | OFL-1.1-no-RFN | OFL | not redistributed |
| 17 | Grassfield icons (40 SVG) | shipped in `grassfield-desktop` | own; CC-BY-SA-4.0 proposed (`branding/LICENSES.md`) | attribution + ShareAlike if adopted | provenance complete; 2.4 and 2.5 |
| 18 | Procedural wallpaper | QML code in `shell/desktop/WallpaperArt.qml` | own; MIT as code (proposed) | — | provenance line added in this audit |
| 19 | Omarchy 4.0.4 code | portions adapted in 3 QML files; run-time `require` of Omarchy Lua modules; reuse of its PAM service | MIT (pacman); no licence file installed under `/usr/share/omarchy` or `/usr/share/licenses` | MIT notice (copyright line + permission notice) | partial (4.11) |
| 20 | DBusMenu and AppMenu Registrar interfaces | bridge calls `com.canonical.dbusmenu` (`GetLayout`, `AboutToShow`, `Event`) with explicit signatures; owns `com.canonical.AppMenu.Registrar` and answers introspection with an inline XML of 4 methods (`bridges/menu-bridge/src/DBusObjects.cpp:23-31`) | no upstream file copied (grep: no `com.canonical` XML file in the repo); licence of the original interface definitions not available locally | unknown | needs legal review (4.12) |
| 21 | googletest 1.18.0 | `makedepends`; unit tests of plugin, bridge, Files, Preview; test binaries built in `check()` | BSD-3-Clause, "Copyright 2008, Google Inc." | notice only if test binaries were distributed | not packaged (VERIFIED: the package functions and the CMake `install()` rules install no test binary) |
| 22 | wlr-virtual-pointer protocol (test tool) | `tests/tools/vpointer/wlr-virtual-pointer-unstable-v1.xml`, "reconstructed from the request signatures" of Hyprland's generated header | upstream notice in `/usr/include/hyprland/protocols/wlr-virtual-pointer-unstable-v1.hpp`: MIT, "Copyright © 2019 Josef Gajdusek" | MIT notice if distributed | test-only, not packaged; no notice in the reconstructed file |
| 23 | uwsm 0.26.7 | session launcher in `grassfield.desktop` `Exec=` | MIT | none (separate program) | dependency |

### 4.2 Hyprland and its libraries (rows 1, 2, 5)

- VERIFIED: `pacman -Qi hyprland` → 0.56.2-2, BSD-3-Clause; `/usr/share/licenses/hyprland/LICENSE` is the
  three-clause text. `grep -rl -i -E 'GPL|Lesser General|SPDX' /usr/include/hyprland/src /usr/include/aquamarine
  /usr/include/hyprutils` → 1 file, a false positive (`m_lastConfigPlugins`): the headers carry no per-file licence,
  so the package licence applies.
- `pkg-config --print-requires hyprland` → aquamarine, hyprcursor, hyprgraphics, hyprlang, hyprutils, libdrm, egl,
  cairo, xkbcommon, libinput, wayland-server, xcb (+ render, xfixes, icccm, composite, res, errors).
- `readelf -d compositor/build/grassfield-compositor.so` (main checkout build) → NEEDED: libaquamarine, libhyprcursor,
  libhyprgraphics, libhyprlang, libhyprutils, libEGL, libcairo, libxkbcommon, libinput, libwayland-server,
  libxcb-icccm/composite/xfixes/render/res/errors, libxcb, libpixman-1, libdrm, libstdc++, libm, libgcc_s, libc.
- The plugin is a shared object loaded into Hyprland's process and compiled from Hyprland's C++ headers, which contain
  inline and template code. needs legal review: whether shipping the `.so` counts as redistributing Hyprland code in
  binary form, so that the BSD-3 notice must accompany `grassfield-compositor` (today the package ships only the `.so`).
- master-prompt §14 asks to "verify header licenses in the ADR"; ADR-0009 does not record this check. The evidence
  above can be moved there.

### 4.3 hyprwayland-scanner output

The generated `appmenu.hpp` starts with "Generated with hyprwayland-scanner 0.4.6" and copies the protocol authors'
notice (VERIFIED in the main checkout's `compositor/build/protocols/appmenu.hpp`). The scanner itself is BSD-3-Clause.
needs legal review: licence status of scanner-generated code (ASSUMPTION: usually treated as derived from the input
XML, not from the scanner).

### 4.4 KDE appmenu protocol (row 4)

- VERIFIED: `compositor/protocols/appmenu.xml` header "SPDX-FileCopyrightText: 2017 David Edmundson /
  SPDX-License-Identifier: LGPL-2.1-or-later"; Grassfield's copy is version 2 (adds the manager `release`).
- Same text and licence ship with Qt: `/usr/share/qt6/wayland/protocols/appmenu/appmenu.xml` and
  `qt_attribution.json` ("LicenseId": "LGPL-2.1-or-later", "Copyright 2017 David Edmundson", source
  plasma-wayland-protocols v1.14.0).
- Precedent noted in the file and in `docs/specs/compositor.md`: Hyprland (BSD-3) compiles KDE's server-decoration
  protocol, also LGPL-2.1-or-later; VERIFIED in `/usr/include/hyprland/protocols/kde-server-decoration.hpp`
  ("SPDX-FileCopyrightText: 2015 Martin Gräßlin", "SPDX-License-Identifier: LGPL-2.1-or-later").
- needs legal review: obligations for the MIT plugin that compiles code generated from an LGPL-2.1-or-later protocol
  description (notice only, or LGPL terms for that object file, or relinking material).

### 4.5 Qt (rows 8, 9)

- Modules used (VERIFIED):
  - linked (`readelf -d` of `.dev/build/*`): Qt6Core, Qt6Gui, Qt6Widgets (Files), Qt6OpenGL (transitive),
    Qt6Qml, Qt6Quick, Qt6Network, Qt6DBus (bridge); KF6 for Files;
  - QML imports: QtQuick, QtQml, QtQuick.Effects, QtQuick.Shapes, Qt.labs.folderlistmodel, QtMultimedia,
    QtQuick.Pdf, plus Quickshell modules;
  - run time: Wayland QPA, SVG (icons), image formats;
  - build: LinguistTools (`lrelease`, `lupdate`), qt6-declarative tools.
- Licence lines checked: `qobject.h`, `qquickitem.h`, `qmediaplayer.h`, `qpdfdocument.h`, `qsvggenerator.h`,
  `qdbusabstractadaptor.h`, `qabstractnetworkcache.h`, `qabstractbutton.h`, `qjsengine.h`, the export headers of
  QtQuickEffects, QtQuickShapes, QtLabsFolderListModel, and headers of QtPdfQuick, QtWaylandClient, QtMultimediaQuick
  all read "LicenseRef-Qt-Commercial OR LGPL-3.0-only OR GPL-2.0-only OR GPL-3.0-only".
- Some Qt add-ons are offered only under GPL-3.0 or commercial terms (ASSUMPTION: for example Qt Charts, Qt Graphs,
  Qt Virtual Keyboard, Qt Quick 3D). None of them appears in the imports or link lines above.
- QtPdf lives in qt6-webengine (`pacman -Ql qt6-webengine` → `/usr/lib/libQt6Pdf.so.6.11.2`, `libQt6PdfQuick`) and
  embeds Chromium/PDFium code with its own notices (`LICENSE.chromium`).
- Grassfield links Qt dynamically and does not ship Qt. needs legal review: whether anything beyond dynamic linking is
  expected from Grassfield for the add-on (notice of Qt use, relinking information), and for the ISO (section 6).

### 4.6 FFmpeg through QtMultimedia (row 10)

VERIFIED: `qt6-multimedia` depends on `qt6-multimedia-backend`; `qt6-multimedia-ffmpeg` provides
`/usr/lib/qt6/plugins/multimedia/libffmpegmediaplugin.so` and depends on `ffmpeg`; `pacman -Qi ffmpeg` → 2:9.0.1-4,
**GPL-3.0-only**. When Preview or Glance plays audio or video, this plugin and the GPL-3.0 ffmpeg libraries are loaded
into the `grassfield-preview` process (MIT code). needs legal review: effect on distributing `grassfield-preview`
alone (add-on) and together with ffmpeg (ISO); options include an LGPL-only ffmpeg build on the ISO or another
multimedia backend (engineering options, no conclusion).

### 4.7 Quickshell (row 7)

VERIFIED: `pacman -Qi quickshell` → 0.3.1-1, LGPL-3.0-only; licence text in `/usr/share/licenses/quickshell/LICENSE`.
Grassfield does not patch or bundle Quickshell (no patch in the repository; `depends=(… quickshell …)`). The shell is
QML executed by Quickshell; `Grassfield.I18n` is an MIT QML plugin (`libgrassfield_i18nplugin.so`, NEEDED Qt6Qml,
Qt6Network, Qt6Core only) loaded into the Quickshell process. needs legal review: obligations, if any, for MIT QML
code and a QML plugin run inside an LGPL-3.0-only host.

### 4.8 KDE Frameworks (rows 11 to 13)

VERIFIED as in the table. No `/usr/share/licenses/<pkg>` directory exists for kio, solid, kcoreaddons or kservice on
this machine (licence texts are expected from Arch's common licences; ASSUMPTION). ADR-0005 says "LGPL-2.1+": the
headers say otherwise (LGPL-2.0-or-later and dual LGPL-2.x-only/3.0-only variants). Correcting the ADR is an owner
task.

### 4.9 Fonts (rows 15, 16)

- VERIFIED: Inter's `LICENSE.txt` copyright line names no Reserved Font Name, while Arch metadata says
  `OFL-1.1-RFN`. Grassfield uses Inter by name and does not bundle, subset or modify it (no font file in the repo;
  `git ls-files | grep -i -c -E '\.(ttf|otf|woff2?|ttc)$'` → 0).
- ADR-0003 names JetBrains Mono for monospace; it is not installed (`pacman -Qi ttf-jetbrains-mono` → not found) and
  the tokens use the generic `monospace` family. The ADR and the implementation disagree (owner task, not legal).
- The plugin titlebar uses Hyprland's default font family (`kTitleFontFamily = ""`), resolved by fontconfig; which
  font that is on a given system is not controlled by Grassfield.
- needs legal review: none expected for the add-on; for the ISO the OFL text must travel with the font files
  (ASSUMPTION: Arch packages do this).

### 4.10 Grassfield's own assets (rows 17, 18)

`branding/LICENSES.md` lists every file in `branding/` (40 SVG). The procedural wallpaper was missing although
ADR-0003 asks for wallpaper provenance there; a line was added (commit "docs(branding): record the provenance of the
procedural wallpaper"). Open points: the "(40 files)" count overlaps the logo row; CC-BY-SA-4.0 is not in
`license=()`; AI authorship (2.4).

### 4.11 Omarchy (row 19)

- VERIFIED: `pacman -Qi omarchy` → 4.0.4-1, MIT, URL `https://github.com/basecamp/omarchy` (master-prompt §2 names
  `omacom/omarchy`; the discrepancy is factual and should be resolved before writing notices).
- `pacman -Ql omarchy | grep -i -E 'licen|copying'` → nothing: the installed package carries no licence file, so the
  exact upstream copyright line cannot be read offline. **Open question** (needs the upstream `LICENSE`).
- Adapted code (VERIFIED headers):
  - `shell/security/lock/Lock.qml:3-6` (PamContext wiring, WlSessionLock secure state, stranded-lock signal);
  - `shell/security/idle/Idle.qml:2-3` (IdleMonitor with respectInhibitors);
  - `shell/security/polkit/AuthAgent.qml:2-3` (PolkitAgent/AuthFlow wiring).
  Each says "Portions adapted from Omarchy … MIT License, Copyright (c) the Omarchy authors". The MIT licence asks that
  "the above copyright notice and this permission notice" be included; the headers name the licence but do not
  reproduce the permission notice or the exact copyright line. needs legal review: whether the header plus a future
  `THIRD_PARTY.md` with the full text is enough.
- Run-time reuse without copying: `config/hypr/grassfield/omarchy.lua` `require`s Omarchy's Lua modules from
  `/usr/share/omarchy`; the lock uses the PAM service `/etc/pam.d/omarchy-lock-password` (configuration, not code).
- Names: the About pane shows "Omarchy" and the OS label from `/etc/os-release`; the session comment says "built for
  Omarchy" (§14 wording). needs legal review: trademark use of "Omarchy" (owner of the mark unknown offline).

### 4.12 DBusMenu and AppMenu Registrar interfaces (row 20)

The bridge reimplements, from public interface names and signatures, a minimal registrar
(`RegisterWindow(u, o)`, `UnregisterWindow(u)`, `GetMenuForWindow(u) → (s, o)`, `GetMenus() → a(uso)`) and calls the
DBusMenu methods it needs. Its own interface `org.grassfield.MenuBridge1` is defined in
`bridges/menu-bridge/dbus/org.grassfield.MenuBridge1.xml` (own work). ASSUMPTION: the original definitions come from
Canonical's libdbusmenu and appmenu registrar projects; their licence could not be checked offline. needs legal review:
whether reproducing interface names and method signatures for interoperability carries any obligation.

### 4.13 Runtime tools executed as separate processes

The shell starts these programs by name; none is linked or shipped by Grassfield (VERIFIED by
`grep -rh -o -E 'command: \["[a-z0-9_.-]+"|\["(…)"' shell apps`, then `pacman -Qi`):

| Program | Package (licence) | Used for |
|---|---|---|
| `qs` | quickshell (LGPL-3.0-only) | IPC between shell parts |
| `gio`, `gdbus` | glib2 (LGPL-2.1-or-later) | trash, open, D-Bus calls |
| `wpctl` | wireplumber (MIT) | volume |
| `brightnessctl` | brightnessctl (MIT) | brightness |
| `systemctl`, `busctl` | systemd (LGPL-2.1-or-later, GPL-2.0-or-later, CC0-1.0, MIT-0) | power actions, D-Bus |
| `setpriv` | util-linux (mixed: BSD, GPL-2.0, GPL-3.0, LGPL-2.1, ISC…) | child processes die with the shell |
| `lspci` | pciutils (GPL-2.0-only) | About This Computer |
| `xdg-open` | xdg-utils (MIT) | open |
| `gtk-launch` | gtk3 (LGPL-2.1-or-later) | app launch |
| `xdg-user-dir` | xdg-user-dirs (GPL-2.0-or-later) | Desktop folder |
| `find`, `mkdir`, `stat`, `kill`, `sh` | findutils, coreutils (GPL-3.0-or-later), bash (GPL-3.0-or-later) | scripts |
| `localsearch`, `plocate` | localsearch (GPL-2.0-or-later), plocate (GPL-2.0-or-later / GPL-2.0-only) | file search |

needs legal review: confirmation that executing separately distributed programs creates no obligation for the add-on
(ASSUMPTION: commonly treated as aggregation). For the ISO these programs are redistributed (section 6).

## 5. Gap list (options for the owner, not decided)

| # | Gap | Options |
|---|---|---|
| G1 | No root `LICENSE` | add the MIT text with a copyright line once ADR-0005 is accepted; or keep "pending" and drop `license=(MIT)` until then |
| G2 | No `THIRD_PARTY.md` | create it with Hyprland and Hypr libraries (BSD-3), KDE appmenu XML (LGPL-2.1-or-later), Omarchy (MIT full text), Quickshell, Qt, KF6, Inter; install it in both packages |
| G3 | `grassfield-compositor` ships no notice | install a notices file (BSD-3 Hyprland text, appmenu LGPL notice) under `/usr/share/licenses/grassfield-compositor/` |
| G4 | `license=()` incomplete | list the licences of shipped content (e.g. `MIT`, `CC-BY-SA-4.0`, and whatever counsel says about the generated LGPL code) |
| G5 | Omarchy attribution partial | add the upstream MIT text and copyright line (needs the upstream `LICENSE`) to `THIRD_PARTY.md`, keep the file headers |
| G6 | SPDX headers missing in most files | add `SPDX-License-Identifier: MIT` across the code base after ADR-0005 is accepted |
| G7 | ADR mismatches | ADR-0005 KIO licence; ADR-0003 JetBrains Mono; ADR-0009 missing the header licence check; README "pending" vs PKGBUILD MIT |
| G8 | libnotify dependency without use | drop it, or document why it is needed |
| G9 | FFmpeg GPL-3.0 at run time in Preview | ask counsel; engineering options: other backend, LGPL build of ffmpeg on the ISO |
| G10 | No in-app notices | optional "Acknowledgements"/licences page in Settings › About |
| G11 | Test-only protocol XML without notice | add the MIT notice to `tests/tools/vpointer/wlr-virtual-pointer-unstable-v1.xml` before publishing the repository |

## 6. Grassfield OS ISO (M6): items to plan

These are obligations to examine with counsel before any ISO is distributed. None is stated as a conclusion.

1. **Corresponding source for GPL and LGPL software on the image.** On this machine `pacman -Qq | wc -l` → 978
   packages; the ISO package set is not defined yet. Each GPL/LGPL package needs either its source alongside the
   image or a written offer (GPL-2.0 §3, GPL-3.0 §6; ASSUMPTION on the clause numbers). Decide how: mirror Arch and
   Omarchy sources (PKGBUILDs, upstream tarballs, patches) for the exact versions shipped, and for how long.
2. **Linux kernel.** `linux-omarchy` 7.2.5-3, GPL-2.0-only, URL `https://omarchy.org`, "Unknown Packager"
   (VERIFIED). Source must match the shipped binary, including Omarchy's config and patches.
3. **Firmware.** `linux-firmware` meta package lists CC0-1.0; sub-packages carry `LicenseRef-WHENCE` and others, for
   example `linux-firmware-intel`: LicenseRef-WHENCE, Apache-2.0, GPL-2.0-only, LicenseRef-intel (VERIFIED). Ship the
   WHENCE file and check redistribution terms of each blob.
4. **GNU and core userland.** bash, coreutils, findutils (GPL-3.0-or-later), glibc (LGPL-2.1-or-later), gcc-libs
   (GPL-3.0-or-later WITH GCC-exception-3.1), systemd (LGPL-2.1-or-later, GPL-2.0-or-later), util-linux (mixed),
   sddm (GPL-2.0-or-later), pciutils (GPL-2.0-only), localsearch/tinysparql (GPL-2.0-or-later), plocate
   (GPL-2.0-or-later/only), ffmpeg (GPL-3.0-only as built by Arch).
5. **LGPL libraries Grassfield links.** Qt (LGPL-3.0-only option), KF6 (LGPL), Quickshell (LGPL-3.0-only), cairo,
   glib2: source availability and the LGPL-3.0 relinking/"Installation Information" questions (relevant for
   "User Products", i.e. if Grassfield OS ever ships preinstalled on hardware; ASSUMPTION).
6. **Notices on the image.** Collect licence texts for every package (Arch's `/usr/share/licenses` plus the common
   licences package), Qt and Chromium third-party notices (qt6-webengine), OFL texts with fonts, Grassfield's own
   `LICENSE`, `THIRD_PARTY.md` and `BRANDING.md`.
7. **omarchy-iso fork** (MIT, master-prompt §12 M6): keep its copyright and permission notice.
8. **Proprietary or restricted packages.** If the image includes proprietary applications, drivers or codecs (for
   example NVIDIA drivers or apps from Omarchy's default set; ASSUMPTION), check each redistribution licence;
   patent-encumbered codecs in ffmpeg may matter in some jurisdictions.
9. **Default themes.** Icon and cursor themes on the image must not imitate Apple assets (see visual-review E27,
   E28).
10. **Trademarks.** Arch Linux and Omarchy names on the image and website ("based on Arch Linux", "built for
    Omarchy" per §14); Hyprland, KDE, Qt names in credits. needs legal review.
11. **Repository signing and distribution** (M6 signed `[grassfield]` repository): export-control or notification
    rules for cryptographic software, if any apply to the owner's jurisdiction (ASSUMPTION). needs legal review.

## 7. Open questions (all: needs legal review)

1. BSD-3 notice for the binary plugin built from Hyprland headers (4.2).
2. LGPL-2.1-or-later protocol XML compiled into the MIT plugin (4.4) and scanner output (4.3).
3. MIT QML code and plugin inside the LGPL-3.0-only Quickshell host (4.7).
4. GPL-3.0 ffmpeg loaded by Preview through QtMultimedia (4.6).
5. Sufficiency of the Omarchy attribution headers; upstream copyright line needed (4.11).
6. Interface definitions of DBusMenu and the AppMenu Registrar (4.12).
7. Licence choice in ADR-0005 (MIT, CC-BY-SA-4.0 on a trademark logo) and AI authorship (2.4, 2.5).
8. Runtime execution of GPL tools by the add-on (4.13).
9. ISO source and notice plan (section 6).
