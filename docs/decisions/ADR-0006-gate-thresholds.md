# ADR-0006: Gate thresholds
Status: Accepted (owner delegation D-5, 2026-10-23; status before acceptance: Proposed) · Date: 2026-10-17 · Decider: owner

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

## Amendment 2026-10-23 (GF-017): governance record
Items 1 and 2 restate owner decisions (docs/STATE.md "Owner decisions", D-1 to D-13: the owner's delegation, rule used for
every choice: how macOS does it). Items 3 to 5 are **PROPOSED by the integrator, owner sign-off pending**: none of them is in
D-1 to D-13 (D-5 covers the acceptance of ADRs only), so they are not recorded as decided.

1. **ADR acceptance (D-5, decided).** All ADRs that were Proposed are Accepted on the owner's delegation; line 2 of each file
   says so and keeps the earlier status and every amendment. A later amendment still follows the usual rule: it is
   written at the end of the ADR with its date and decider.
2. **R3 and A1 (D-1 and D-7, decided; restated in docs/master-prompt.md section 10).**
   D-1: menu bar on every display, one Dock that follows the display whose bottom edge the pointer touches, a window
   restored from the Dock returns to the display and frame it was minimized from. D-7: keyboard access to Minimize,
   Zoom and Close through the Window menu for every window; Grassfield's own apps draw their controls; compositor-drawn
   controls of third-party windows are accepted given those equivalents.
3. **`docs/specs/alpha.md` waiver (PROPOSED, owner sign-off pending).** The M2 alpha acceptance list was replaced in
   practice by the per-surface specs in docs/specs/, their nested scenarios and the final audit (docs/audits/final-1.0/).
   Proposal: judge the 1.0 release candidate against those specs and the gate table, with no separate alpha list.
4. **M5 defect threshold, Q-18 (PROPOSED, owner sign-off pending).** Zero open P0 and zero open P1 defects in
   docs/audits/final-1.0/13-defects-and-risks.md unless the owner waives the item in writing; P2 defects listed with an
   owner-visible workaround. This is the conservative reading the audit proposed.
5. **Milestone approvals (PROPOSED, owner sign-off pending).** M0 to M2 (with item 3), then M3 and M4 once the remediation
   programme (docs/audits/final-1.0/15-remediation-plan.md) closes and F1 is signed per surface; M5 and M6 keep the
   owner-only items (L2 gates, R2, R3, C1 7 days, 30-day dogfood, hardware matrix, legal review). No milestone is approved
   until the owner signs it off.

## Amendment 2026-10-23 (GF-040): resource guard of grassfield-shell.service
Measured: idle CPU 0.25 to 0.33 % of one core, RSS 530 MB growing about 6 MB/h (566 MB after 6 h), other real sessions up to
725 MB, one historical runaway of 118 % CPU and 9.5 GB (docs/audits/final-1.0/benchmarks/real-session-samples.md,
08-performance-audit.md PERF-04). The unit sets `MemoryHigh=1536M`, `MemoryMax=3G`, `CPUQuota=150%`: every limit is far
above any healthy figure (P2 stays 608 MB, a measured gate, not a limit) and below the runaway. Revisit when the long
nested slope test exists.
