# ADR-0005: License of Grassfield code and assets
Status: Proposed · Date: 2026-10-17 · Decider: owner · Needs legal review (§14)

## Context
Grassfield reuses or links: Omarchy (MIT), Hyprland headers (BSD-3-Clause), Quickshell (LGPL-3.0-only,
unmodified, used as a runtime), Qt (LGPL-3.0/GPL), KDE Frameworks KIO (LGPL-2.1+). The compositor plugin is
loaded into Hyprland's process. The repository stays private until the M5 legal review.

## Options
1. **MIT for code** — matches Omarchy; maximal reuse; plugin compatible with BSD-3 Hyprland.
2. GPL-3.0 — copyleft; compatible with everything above, but blocks reuse in MIT Omarchy upstream.
3. MPL-2.0 — file-level copyleft; less common in this ecosystem.

## Decision (proposed)
- Code (shell QML, plugin C++, bridge, apps, scripts, config): **MIT**, `LICENSE` at the root,
  SPDX headers `SPDX-License-Identifier: MIT` in new source files.
- Code adapted from Omarchy keeps its MIT notice and attribution in the file header.
- Assets in `branding/`: **CC-BY-SA-4.0** unless a file states otherwise; provenance per file in
  `branding/LICENSES.md`. Fonts: SIL OFL only, shipped unmodified.
- Third-party notices collected in `THIRD_PARTY.md` (Omarchy MIT, Hyprland BSD-3 headers, Quickshell LGPL
  runtime, Qt, KF6).

## Consequences
- LGPL obligations for Qt/Quickshell/KIO are met by dynamic linking and unmodified distribution; GPL source
  obligations apply to the ISO (M6) and are flagged there.
- Not a legal conclusion: needs legal review before any public release.
