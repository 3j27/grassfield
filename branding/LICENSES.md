# Branding assets — provenance and licenses

Every file in `branding/` is listed here (master-prompt §14). No Apple asset is used, traced or redistributed.
License of Grassfield-made assets: CC-BY-SA-4.0 (proposed in ADR-0005, pending owner/legal review).

| Path | Author | Provenance | License |
|---|---|---|---|
| `icons/symbolic/*.svg` (41 files) | Grassfield project (drawn by Claude, 2026-10-17) | Original line icons on a 24 px grid, 1.75 px stroke, round caps; hand-written SVG paths, no tracing | CC-BY-SA-4.0 |
| `icons/symbolic/grassfield-logo.svg` | Grassfield project (2026-10-17) | Original grass-blade mark | CC-BY-SA-4.0 (trademark use pending legal review) |
| `cursors/src/*.svg.in` (25 templates), `cursors/cursors.tsv` | Grassfield project (drawn by Claude, 2026-10-19) | Original cursor drawings on a 32 px grid (arrow, hand, I-beam, resize arrows, spinner, badges); hand-written SVG paths and primitives with `{{FILL}}`/`{{OUTLINE}}`/`{{ANGLE}}` template variables, no tracing, nothing derived from macOS, WhiteSur, capitaine or Adwaita files; only the cursor NAMES were taken from installed themes (ADR-0014) | CC-BY-SA-4.0 |
| `cursors/build.sh`, `cursors/xcursor-pack.py` | Grassfield project (2026-10-19) | Build scripts: render the templates, hyprcursor theme through `hyprcursor-util --create`, XCursor files written by a stdlib packer (xcursorgen is not installed) | MIT (source code, like the repository) |
| `../shell/desktop/WallpaperArt.qml` (wallpaper artwork, outside `branding/`; listed per ADR-0003) | Grassfield project (drawn by Claude, 2026-10-17, first in 1088f84) | Original procedural artwork ("Grassfield": sky gradient, sun, four layered hills) drawn in QML from constants; no image file, no tracing | Source code: MIT (proposed in ADR-0005); licence of the artwork as an asset pending legal review |

| `icons/theme/index.theme` | Grassfield project (2026-10-20) | The `grassfield-icons` wrapper theme (ADR-0017): metadata only (`Inherits=WhiteSur,Adwaita,hicolor`, one empty directory); contains no icon and nothing of WhiteSur | MIT (configuration file, like the repository) |

Cursor themes built from `cursors/` (`grassfield-cursors`, default black fill and white outline) are generated artefacts; they carry the licence of the sources (CC-BY-SA-4.0).

Icon files are monochrome (`#000`); the shell recolors them with token colors at runtime.
