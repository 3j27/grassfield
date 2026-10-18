# ADR-0005: License of Grassfield code and assets
Status: Accepted by the owner 2026-10-18 (MIT for Grassfield's own code; root LICENSE) · Date: 2026-10-17 · Decider: owner · Asset/trade-dress questions still need legal review (§14)

## Context
Grassfield reuses or links: Omarchy (MIT), Hyprland headers (BSD-3-Clause), Quickshell (LGPL-3.0-only,
unmodified, used as a runtime), Qt (LGPL-3.0/GPL), KDE Frameworks KIO (installed headers: LGPL-2.0-or-later, or "LGPL-2.0-only OR LGPL-3.0-only OR
LicenseRef-KDE-Accepted-LGPL"; Solid: "LGPL-2.1-only OR LGPL-3.0-only OR LicenseRef-KDE-Accepted-LGPL"). The compositor plugin is
loaded into Hyprland's process. The repository stays private until the M5 legal review.

Observed, not decided: `pacman -Qi omarchy` reports the URL `https://github.com/basecamp/omarchy`, while the
master prompt and the Omarchy-derived file headers name `omacom/omarchy`. The installed package carries no
licence file, so the upstream copyright line is unverified.

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
