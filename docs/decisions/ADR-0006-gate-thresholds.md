# ADR-0006: Gate thresholds
Status: Proposed · Date: 2026-10-17 · Decider: owner

## Context
§10 thresholds are provisional until confirmed with M0 baselines on the reference machine
(Precision 7550, UHD 630, 1080p60, scale 1).

## Baselines (spike S6, main session, read-only, 2026-10-17)
| Metric | omarchy-shell (pid 7971, `quickshell -n -p /usr/share/omarchy/shell`) | How |
|---|---|---|
| RSS | 458 824 kB (VmHWM 534 456 kB), 37 threads | `/proc/7971/status` |
| CPU, 60 s sample during agent activity | 0.27 % of one core | `/proc/7971/stat` utime+stime delta |
| CPU, lifetime average (6180 s, interactive use) | 0.95 % of one core | `ps -o time,etimes` |

The 60 s sample is not a 10-minute idle run (P1 needs an owner-run idle measurement in L2).

## Decision
| Gate | Threshold (confirmed / changed) |
|---|---|
| P1† | grassfield-shell + menu-bridge idle CPU ≤ omarchy-shell idle baseline + 0.5 pt of one core over 10 min (owner measures both in L2 with the same method) |
| P2 | grassfield-shell RSS ≤ 458 MB + 150 MB = **608 MB** after 10 min with Dock, menu bar, Overview opened once |
| P3† | unchanged (≥ 95 % frames < 16.7 ms, Balanced) — method fixed in M1 (Hyprland `debug.overlay` is visual only; use `wp_presentation` timestamps from a probe client) |
| P4 | unchanged |
| P5† | unchanged (≤ 2 s) |
| C1 | 8 h nested soak with scripted churn; a **1 h shortened soak** is acceptable for M1 exit if the full run is scheduled before M2 exit |
| others | unchanged from §10 |

## Consequences
- P2 is measured in the nested session (L1) since memory does not depend on DRM.
- Thresholds are revisited at each milestone gate with new measurements.
