# Third-party components

Facts taken from local files (installed headers, `pacman -Qi`, `/usr/share/licenses`, headers of files in this
repository), as of 2026-10-18. No legal conclusion is stated. Items marked **needs legal review** are open
questions for counsel; details and evidence are in `docs/legal/licenses-audit.md`.

Grassfield's own licence is not settled (ADR-0005 is Proposed; no root `LICENSE` yet). The package metadata says
`license=(MIT)` following ADR-0005 pending the owner's decision.

Licence texts shipped with the packages (`/usr/share/licenses/<package>/`):

| File | Package | Content |
|---|---|---|
| `THIRD_PARTY.md` | both | this file |
| `hyprland-BSD-3-Clause.txt` | grassfield-compositor | Hyprland BSD-3-Clause text, copied from `/usr/share/licenses/hyprland/LICENSE` |
| `appmenu-LGPL-2.1-or-later.txt` | grassfield-compositor | notice of the KDE appmenu protocol and the LGPL-2.1-or-later text |
| `BRANDING.md` | grassfield-desktop | `branding/LICENSES.md`, provenance of icons and wallpaper |
| `omarchy-MIT.txt` | grassfield-desktop | MIT notice for Omarchy-derived QML |

## 1. Built against, linked or generated from (grassfield-compositor)

### Hyprland headers (and Hypr libraries)

- Hyprland 0.56.2: BSD-3-Clause, "Copyright (c) 2022-2026, vaxerski" (`/usr/share/licenses/hyprland/LICENSE`).
  The installed headers carry no per-file licence line (ADR-0009, section "Header licence check"). Full text:
  `hyprland-BSD-3-Clause.txt`.
- aquamarine, hyprutils, hyprlang, hyprgraphics, hyprcursor: BSD-3-Clause per `pacman -Qi` (aquamarine and
  hyprutils: "Copyright (c) 2024, Hypr Development" per the audit). Headers are included and the shared
  libraries are linked by the plugin.
- hyprwayland-scanner 0.4.6: BSD-3-Clause, build tool that generated the appmenu server code.
- The plugin is loaded into Hyprland's process and compiled from its C++ headers.
  **Needs legal review:** whether the BSD-3 notice must accompany the binary plugin (it is shipped as a precaution),
  and the licence status of scanner-generated code.

### KDE appmenu protocol and generated code

- `compositor/protocols/appmenu.xml`: KDE `org_kde_kwin_appmenu`, "SPDX-FileCopyrightText: 2017 David Edmundson",
  "SPDX-License-Identifier: LGPL-2.1-or-later" (notice kept in the file). Grassfield's copy is version 2.
- The server code generated from it by hyprwayland-scanner (`appmenu.hpp`/`.cpp`, copying the same notice) is
  compiled into `grassfield-compositor.so`.
- The same protocol ships with Qt (`/usr/share/qt6/wayland/protocols/appmenu/qt_attribution.json`: LGPL-2.1-or-later,
  "Copyright 2017 David Edmundson"). Hyprland's `kde-server-decoration.hpp` carries LGPL-2.1-or-later in the same way.
- Notice and licence text shipped: `appmenu-LGPL-2.1-or-later.txt`.
  **Needs legal review:** obligations for the MIT plugin that compiles code generated from this XML.

### DBusMenu and AppMenu Registrar interfaces

The menu bridge calls `com.canonical.dbusmenu` and implements `com.canonical.AppMenu.Registrar` from interface names
and method signatures (`bridges/menu-bridge/src/DBusObjects.cpp`). No upstream XML file is in the repository and no
upstream licence text was available locally. **Needs legal review.**

### Other libraries linked by the plugin (dynamic, unmodified, not shipped by Grassfield)

cairo, libxkbcommon, libinput, wayland, libxcb, pixman, libdrm, libglvnd, libstdc++/libgcc, glibc. Licences per
`pacman -Qi` are listed in `docs/legal/licenses-audit.md` section 4.1 row 5. They are installed by the distribution.

## 2. Runtime dependencies (grassfield-desktop; dynamically linked or run, unmodified, not shipped)

| Component | Use | Licence per local files |
|---|---|---|
| Quickshell 0.3.1 | host that runs the QML shell; `Grassfield.I18n` plugin loads into it | LGPL-3.0-only (`/usr/share/licenses/quickshell/LICENSE`) |
| Qt 6.11.2 (base, declarative, wayland, svg, imageformats, tools) | linked and loaded | headers: "LicenseRef-Qt-Commercial OR LGPL-3.0-only OR GPL-2.0-only OR GPL-3.0-only" |
| QtPdf, QtPdfQuick (package qt6-webengine) | Preview | as Qt; Chromium/PDFium notices in `/usr/share/licenses/qt6-webengine/LICENSE.chromium` |
| QtMultimedia + FFmpeg backend | Preview | as Qt; ffmpeg 9.0.1 is GPL-3.0-only per pacman. **Needs legal review.** |
| KF6 KIO, Solid, CoreAddons, Service 6.29.0 | linked by `grassfield-files` | headers: LGPL-2.0-or-later (`kio/job.h`, `kio/renamedialog.h`); "LGPL-2.0-only OR LGPL-3.0-only OR LicenseRef-KDE-Accepted-LGPL" (`kio/openurljob.h`); "LGPL-2.1-only OR LGPL-3.0-only OR LicenseRef-KDE-Accepted-LGPL" (`solid/device.h`) |
| extra-cmake-modules (build) | CMake modules | pacman "LGPL"; module headers BSD-3-Clause/BSD-2-Clause |
| uwsm | session launcher | MIT |

Grassfield patches none of these. **Needs legal review:** obligations for MIT code and plugins running inside or
linked to LGPL hosts, and for the GPL-3.0 ffmpeg loaded by Preview.

## 3. Omarchy-derived code (MIT)

Portions adapted from Omarchy (`pacman -Qi omarchy` 4.0.4: MIT, URL `https://github.com/basecamp/omarchy`; the
Grassfield source headers name `omacom/omarchy`, branch quattro; both are recorded as observed, not decided):

| Grassfield file | Adapted from | What |
|---|---|---|
| `shell/security/lock/Lock.qml` | `shell/plugins/lock/Service.qml` | PamContext wiring, WlSessionLock secure state, stranded-lock signal |
| `shell/security/idle/Idle.qml` | `shell/plugins/services/idle/Service.qml` | IdleMonitor with respectInhibitors |
| `shell/security/polkit/AuthAgent.qml` | `shell/plugins/polkit/PolkitAgent.qml` | PolkitAgent/AuthFlow wiring |

These three files are security modules; their headers say "MIT License, Copyright (c) the Omarchy authors" and are
left unchanged. The full notice, with that wording, follows (also shipped as `omarchy-MIT.txt`). The installed
omarchy package has no licence file, so the exact upstream copyright line is unverified: **needs legal review**.

```
MIT License

Copyright (c) the Omarchy authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

Run-time use without copying: `config/hypr/grassfield/omarchy.lua` requires Omarchy's Lua modules from
`/usr/share/omarchy`; the lock uses the PAM service `omarchy-lock-password`. Trademark use of "Omarchy" in the UI:
**needs legal review**.

## 4. Fonts

Inter 4.1 (package `inter-font`): SIL OFL 1.1, "Copyright (c) 2016 The Inter Project Authors
(https://github.com/rsms/inter)" (`/usr/share/licenses/inter-font/LICENSE.txt`); pacman says `OFL-1.1-RFN`.
Referenced by family name, not bundled or modified. Noto Sans is the fallback family (OFL-1.1-no-RFN per pacman).
No font file is in this repository. The session fontconfig (`packaging/fontconfig/fonts.conf`, ADR-0003) only names
Inter and Inter Display; the `SF Pro*`, `-apple-system` and `BlinkMacSystemFont` entries are aliases that resolve to Inter, and
no Apple font is used, shipped or required.

## 5. Icons and wallpaper

Provenance per file: `branding/LICENSES.md` (shipped as `BRANDING.md`). 40 SVG icons are Grassfield's own
(CC-BY-SA-4.0 proposed, ADR-0005); the procedural wallpaper is QML code in `shell/desktop/WallpaperArt.qml`.
No Apple asset is used. Authorship by an AI assistant and the licence choice: **needs legal review**.

Cursors (ADR-0014): the `grassfield-cursors` theme (hyprcursor SVG theme plus XCursor fallback, installed under
`/usr/share/icons/grassfield-cursors`) is generated at package build time from Grassfield's own templates in
`branding/cursors/` (CC-BY-SA-4.0 proposed, listed in `BRANDING.md`). No file of Adwaita, Yaru, WhiteSur or capitaine is
used; only cursor names (a vocabulary shared by CSS and X11) were read from installed themes. The build uses
`hyprcursor-util` (BSD-3-Clause), `rsvg-convert` (librsvg, LGPL-2.1-or-later) and Python as build tools; the XCursor
writer is Grassfield's own stdlib script. The runtime regeneration for the pointer colours (Settings > Accessibility >
Pointer, `grassfield-cursors-custom` under `$XDG_DATA_HOME/icons`, owner decision 2026-10-19) runs the same script
(`/usr/share/grassfield/cursors/build.sh`) with the same three tools, so `python`, `librsvg` and `hyprcursor` are runtime
dependencies of `grassfield-desktop` (declared in `packaging/arch/PKGBUILD`); they are used as separate programs, nothing
of them is linked or copied. The generated custom theme is derived from the same CC-BY-SA-4.0 templates.

App icon theme (ADR-0017): `grassfield-icons` (`/usr/share/icons/grassfield-icons`, `branding/icons/theme/index.theme`,
Grassfield's own file) is a wrapper whose own directory holds no icon yet; it inherits `WhiteSur,Adwaita,hicolor`. The
session selects it with `QT_QPA_SYSTEM_ICON_THEME` (uwsm `env-grassfield`) and, for GTK, a locked dconf database that
holds only `icon-theme='grassfield-icons'`.

WhiteSur icon theme (optional package `grassfield-whitesur-icons`, built by `makepkg` from a pinned upstream commit):
- upstream: https://github.com/vinceliuice/WhiteSur-icon-theme, author per its `AUTHORS`: Vince Liuice; commit
  `73d8040da51a9ed74e47c7366e7e9ff437601a5c`;
- licence: GPL-3.0-only. Upstream ships only `COPYING` (the unmodified GPL version 3 text); no file carries a copyright
  or "or later" notice (checked at the pin), so no "or later" grant exists;
- data files read by Qt, GTK and KDE, not linked; nothing of it is in this repository: it is fetched at build time
  (checksummed `git archive` of the pinned commit), and the PKGBUILD runs upstream's `install.sh` (with `-p`, in a clean
  environment) only while its SHA-256 is the reviewed one. **Modification, to be noted under GPL-3.0:** the package
  FILTERS the theme (owner decision
  2026-10-20): it removes every icon that shows the Apple logo (found by a perceptual detector, also inside larger icons
  such as the iMac and Magic Mouse icons; the 12 logo files `start-here*` and `folder-apple*` and 22 more files at the
  pin), every icon of a curated blocklist (Apple app icons that WhiteSur reproduces, such as Finder, App Store, Safari,
  Xcode, iCloud and the System Preferences gear, and iPhone, iPad and iPod silhouettes; 126 names and 103 drawings), the
  icons that share a name with them, the links left dangling (about 350 files and 1600 links in all) and the
  `icon-theme.cache` files. `packaging/arch/whitesur-guard.sh` and `whitesur-detect.py` do it and fail the build if
  anything they know remains (ADR-0017). This is a statement about what the detector and a review by eye on contact
  sheets found, not a proof that no Apple artwork remains; the style imitation of the other icons and the review stay
  with counsel (visual-review E27);
- `COPYING`, `AUTHORS` and a `SOURCE` line (URL and commit) are installed in `/usr/share/licenses/grassfield-whitesur-icons/`;
  the PKGBUILD reproduces the package from that commit;
- the theme's metadata contains the words "MacOSX", and its name alludes to an Apple product name. Grassfield displays
  neither, except in the licence and acknowledgements text (Settings > About > Acknowledgements).
- **needs legal review:** the source offer if the package leaves the owner's machine, and the aggregation with the
  MIT packages.

## 5a. Unicode character data (derived tables)

`ui/Grassfield/Ui/GraphemeData.js` (shipped with the shell) and `apps/files/src/graphemedata.inc` (compiled into
Files) are generated by `scripts/dev/gen-glyph-tables.sh` from the Unicode properties (Grapheme_Cluster_Break,
Extended_Pictographic, Indic_Conjunct_Break, Emoji, general category) of the installed ICU (ICU 78.3, Unicode 17.0),
read at generation time only: no product code links ICU. `scripts/dev/glyph-icu-compare.sh` (development, not shipped)
links it to check the rule.
The data is under the Unicode License v3 as shipped with ICU, "Copyright © 2016-2025 Unicode, Inc."
(`/usr/share/licenses/icu/LICENSE`); the licence asks that the copyright and permission notice accompany copies of the
Data Files or appear in associated documentation.
**Needs legal review:** whether tables generated from ICU's character properties count as a copy of the Data Files,
and whether the full notice must ship as a separate licence file in the grassfield-desktop package.

## 6. Test and build only (not shipped)

- googletest 1.18.0: BSD-3-Clause, "Copyright 2008, Google Inc." (`/usr/share/licenses/gtest`). Used by unit tests
  built in `check()`; no test binary is installed.
- `tests/tools/vpointer/wlr-virtual-pointer-unstable-v1.xml`: reconstructed from the generated Hyprland header
  `/usr/include/hyprland/protocols/wlr-virtual-pointer-unstable-v1.hpp`, which carries MIT, "Copyright © 2019 Josef
  Gajdusek". Test tool, not packaged; the file itself has no notice yet (audit gap G11).
- Lua 5.5.1 headers (MIT) at build time; CMake, Ninja, Qt tools (build tools).
