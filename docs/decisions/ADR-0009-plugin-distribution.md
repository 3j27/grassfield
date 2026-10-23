# ADR-0009: Plugin distribution
Status: Accepted (owner delegation D-5, 2026-10-23; see "Amendment 2026-10-23" at the end) · Date: 2026-10-17 · Decider: owner

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

## Amendment 2026-10-23, integrator under owner delegation D-5 (audit GF-033 / ARCH-01)
Owner rule for the audit decisions: "rassure-toi que cela fonctionne comme sur macOS". macOS never compiles code as root
behind the user's back; an incompatible extension is disabled with a clear notice until it is updated. Option 1 is the
default path, option 3 the opt-in recovery; option 2 stays rejected.

What ships (`grassfield-compositor`, `depends=(hyprland)` only, no version constraint):
- `/usr/lib/grassfield/grassfield-compositor.so` and its stamp `grassfield-compositor.abi`: the ABI string it was built
  for, computed from Hyprland's `version.h` with Hyprland's own formula (`PluginAPI.hpp` `__hyprland_api_get_client_hash`:
  commit, then the aquamarine, hyprutils, hyprgraphics, hyprcursor and hyprlang minors). One build per package for now;
  more prebuilt variants (one per ABI of the stable and rc channels) can be added later next to it, with their stamps.
- The plugin sources in `/usr/src/grassfield-compositor` (CMakeLists.txt, src/, protocols/, VERSION) and
  `grassfield-compositor-rebuild` (on PATH). cmake, gcc, make and pkgconf are optdepends (the rebuild's toolchain);
  libnotify too (the notice).

Loader order (`config/hypr/grassfield/compositor.lua`, run by `session.lua` at parse time): the first build whose stamp
is the ABI of the Hyprland that runs (the installed `version.h`, its commit checked against `HYPRLAND_INSTANCE_SIGNATURE`):
1. the packaged build;
2. the user's build, `$XDG_CACHE_HOME/grassfield/compositor/<abi>/grassfield-compositor.so`;
3. none: nothing is loaded. The session runs in degraded mode (gate C2) and `grassfield-compositor-rebuild --session`
   shows one notice naming the Hyprland version and the recovery.
A config reload after Hyprland was updated under a running session keeps the build loaded at login (its stamp names the
running commit). If the loader itself fails, the packaged build is loaded: it compares Hyprland's hash itself and refuses
another build with its own notice.

User rebuild (option 3): `grassfield-compositor-rebuild` refuses to run as root. It builds the shipped sources with CMake
and the compiler, in a private temporary directory, with a clean environment, at low priority, with at most 4 compilers and
a 15-minute bound per step. It installs the result in the user's cache: 0700 directories, symlinks refused (cache
directories, the build's result, planted files), the plugin then its stamp each written to a new file and renamed into
place, the stamp last. Opt-in Settings toggle `windows.rebuildExtension`, "Rebuild the compositor extension after Hyprland
updates" (Desktop & Dock, off by default): on a mismatch the session's `--session` run builds in the background, then
loads the result into the running Hyprland (`hyprctl plugin load`) when its ABI is the running one, else tells the user
to log out and back in. With the toggle off the notice gives the command.

Why the root pacman hook of the first remediation (2026-10-23, branch only, never released) was dropped: it was option 2.
A root process handed its build directory to `nobody` and then installed the result as root, so any uid-65534 process
could swap the file (a link to a secret became a world-readable copy, or its own ELF got a matching stamp and loaded into
every user's Hyprland). It also compiled code as root without the user asking, could block pacman for up to twice 900 s,
and made the toolchain a hard dependency. Nothing in the amended design runs as root after the package is installed.

Tests: `tests/shell/compositor_rebuild.sh` (logic): the formula in bash and Lua, the loader's choice including the
mismatch and the update under a session, root and symlink refusal, the cache install, the `--session` notice and build. The
nested part of the C2 mismatch test (a mismatched build loaded by hand) is still to be written (audit plan 1.8).
