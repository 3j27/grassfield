# Compatibility matrix

Compare these with the installed versions at the start of every session (master-prompt §13).
If Hyprland or Quickshell changed: rebuild the plugin and run the C2 degradation test first.

| Component | Version | Verified | How |
|---|---|---|---|
| Omarchy | 4.0.4 (package; `/usr/share/omarchy/version` says `4.0.0.alpha`) | 2026-10-17 | `pacman -Q omarchy`, `/etc/os-release` |
| Hyprland | 0.56.2 (commit efb50993, tag v0.56.2) | 2026-10-17 | `hyprctl version` |
| Hyprland plugin ABI string | `efb50993780079460b0cbed1363e2166a2de1d9f_aq_0.15_hu_0.14_hg_0.5_hc_0.1_hlg_0.6` | 2026-10-17 | `hyprctl version` |
| Hyprland headers | 0.56.2 | 2026-10-17 | `pkg-config --modversion hyprland` |
| aquamarine / hyprutils | 0.15.0 / 0.14.2 | 2026-10-17 | `pacman -Q` |
| Quickshell | 0.3.1 | 2026-10-17 | `pacman -Q quickshell`, `qs --version` |
| Qt | 6.11.2 | 2026-10-17 | `pacman -Q qt6-base` |
| KIO (KF6) | 6.29.0 | 2026-10-17 | `pacman -Q kio` |
| Compilers | gcc 16.2.1, clang 22.1.8 | 2026-10-17 | `pacman -Q` |
| Mesa | 26.2.2 | 2026-10-17 | `pacman -Q mesa` |
| Kernel | 7.2.5-3-omarchy | 2026-10-17 | `uname -r` |
| grassfield-compositor built for | — (not built yet) | — | — |
