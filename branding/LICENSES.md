# Branding assets — provenance and licenses

Every file in `branding/` is listed here (master-prompt §14). No Apple asset is used, traced or redistributed.
License of Grassfield-made assets: CC-BY-SA-4.0 (proposed in ADR-0005, pending owner/legal review).

| Path | Author | Provenance | License |
|---|---|---|---|
| `icons/symbolic/*.svg` (40 files) | Grassfield project (drawn by Claude, 2026-10-17) | Original line icons on a 24 px grid, 1.75 px stroke, round caps; hand-written SVG paths, no tracing | CC-BY-SA-4.0 |
| `icons/symbolic/grassfield-logo.svg` | Grassfield project (2026-10-17) | Original grass-blade mark | CC-BY-SA-4.0 (trademark use pending legal review) |
| `../shell/desktop/WallpaperArt.qml` (wallpaper artwork, outside `branding/`; listed per ADR-0003) | Grassfield project (drawn by Claude, 2026-10-17, first in 1088f84) | Original procedural artwork ("Grassfield": sky gradient, sun, four layered hills) drawn in QML from constants; no image file, no tracing | Source code: MIT (proposed in ADR-0005); licence of the artwork as an asset pending legal review |

Icon files are monochrome (`#000`); the shell recolors them with token colors at runtime.
