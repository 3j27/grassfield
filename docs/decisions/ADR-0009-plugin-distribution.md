# ADR-0009: Plugin distribution
Status: Proposed · Date: 2026-10-17 · Decider: owner

## Context
Hyprland plugins must match the exact Hyprland build: Hyprland compares `__hyprland_api_get_hash()` with the
plugin's client hash (git commit + aquamarine/hyprutils/hyprgraphics/hyprcursor/hyprlang minor versions;
on this machine `efb50993…_aq_0.15_hu_0.14_hg_0.5_hc_0.1_hlg_0.6`). Omarchy updates Hyprland through
`omarchy update`; an exact `hyprland=` pin would block it (§5.6). Omarchy has stable and rc channels.

## Options
1. **Prebuilt variants keyed by ABI string** + runtime selection + degraded mode on mismatch.
2. alpm hook rebuilding the plugin as root during the pacman transaction. Builds code as root; slow; makes
   cmake/gcc hard dependencies.
3. User-level rebuild at session start (hyprpm-like) into `~/.cache/grassfield/`. Needs a toolchain on
   every machine; first login after an update is slow.

## Decision (proposed)
Option 1, with option 3 as an opt-in setting:
- `grassfield-compositor` package ships `/usr/lib/grassfield/compositor/<abi>.so` for each Hyprland build in
  the Omarchy stable and rc channels (CI builds both, gate C3).
- The session config computes the running ABI (`hl.version()`/`hyprctl version` once at start) and loads
  the matching `.so` with `hl.plugin.load`. No match → no load, shell degraded mode (C2), one notification
  "Window titlebars and minimize are unavailable until Grassfield is updated for Hyprland X.Y".
- Optional Settings toggle "Rebuild compositor extension after Hyprland updates" → user-level rebuild from
  `/usr/src/grassfield-compositor` (requires `cmake`, `gcc`; listed as optdepends).
- No `hyprland=` or `hyprland<` constraints in `depends`.

## Header licence check (master-prompt §14)
Checked 2026-10-18 against the installed Hyprland 0.56.2 (`pacman -Qi hyprland`: BSD-3-Clause;
`/usr/share/licenses/hyprland/LICENSE`, "Copyright (c) 2022-2026, vaxerski"):
`grep -rh "SPDX-License" /usr/include/hyprland | sort | uniq -c` → 1 line, `SPDX-License-Identifier:
LGPL-2.1-or-later` (the generated `protocols/kde-server-decoration.hpp`, "SPDX-FileCopyrightText: 2015 Martin
Gräßlin"). The other headers carry no per-file licence line. `grep -rl -i -E 'GPL|Lesser General|SPDX'` over
`/usr/include/hyprland/src`, `/usr/include/aquamarine` and `/usr/include/hyprutils` found one false positive
(`m_lastConfigPlugins`). Notices are listed in `THIRD_PARTY.md` and shipped by `grassfield-compositor`. Not a
legal conclusion.

## Consequences
- Release cadence must follow Omarchy's Hyprland updates; the rc build gives one cycle of warning.
- Revisit if Hyprland gains a stable plugin ABI.
