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

## Amendment 2026-10-23 (owner delegation D-5, GF-017): governance record
Decider: owner, through the standing delegation recorded in docs/STATE.md ("Owner decisions", D-1 to D-13). Rule used for
every choice: how macOS does it.

1. **ADR acceptance (D-5).** All ADRs that were Proposed are Accepted on the owner's delegation; line 2 of each file
   says so and keeps the earlier status and every amendment. A later amendment still follows the usual rule: it is
   written at the end of the ADR with its date and decider.
2. **R3 and A1 amended** in docs/master-prompt.md section 10 (the gate table holds them as editable requirements).
   D-1: menu bar on every display, one Dock that follows the display whose bottom edge the pointer touches, a window
   restored from the Dock returns to the display and frame it was minimized from. D-7: keyboard access to Minimize,
   Zoom and Close through the Window menu for every window; Grassfield's own apps draw their controls; compositor-drawn
   controls of third-party windows are accepted given those equivalents.
3. **`docs/specs/alpha.md` is waived (written waiver).** The M2 alpha acceptance list was replaced in practice by the
   per-surface specs in docs/specs/, their nested scenarios and the final audit (docs/audits/final-1.0/). The 1.0
   release candidate is judged against those specs and the gate table, not against a separate alpha list. No file is
   created for it.
4. **M5 defect threshold (Q-18).** Zero open P0 and zero open P1 defects in docs/audits/final-1.0/13-defects-and-risks.md
   unless the owner waives the item in writing in docs/STATE.md; P2 defects are listed with an owner-visible workaround.
   This is the conservative reading the audit proposed.
5. **Milestone approvals.** M0 (ADRs 0001 to 0003, 0006, 0007, 0009, 0010 accepted by item 1), M1 and M2 (alpha waived
   by item 3): approved by the owner's delegation on 2026-10-23. M3 and M4: approved once the remediation programme
   (docs/audits/final-1.0/15-remediation-plan.md) closes, with the F1 sign-off per surface still owner-only. M5 and M6
   are not approved: they keep the owner-only items (L2 gates, R2, R3, C1 7 days, 30-day dogfood, hardware matrix,
   legal review).
