# Gate tooling (GF-008, D-6)

How each measurable gate of master-prompt section 10 is run. Every tool prints numbers, sample counts and the threshold,
and ends with a verdict. Exit codes: 0 PASS, 1 FAIL, 2 INCONCLUSIVE or usage error (no valid evidence is never a pass).
All of them are registered in `tests/inventory.json`; the pure logic is tested offline by `tests/shell/gates.sh`
(part of `just test`). Bare commands (outside the Claude sandbox) are marked.

| Gate | Command | Notes |
|---|---|---|
| P1 idle CPU, <= baseline + 0.5 pt | `just gate-idle --nested` (this tree's nested session) or `just gate-idle --real [--baseline-pid PID]` (the owner's session, read only) | utime + stime from `/proc/<pid>/stat` of grassfield-shell and the menu bridge over 600 s (`--seconds`); the desktop must be idle; bare |
| P2 memory, <= baseline + 150 MB | `just gate-rss --real --baseline-pid PID` (omarchy-shell in the Omarchy session) or `--baseline-mb N` | VmRSS (and PSS); without a baseline the verdict is INCONCLUSIVE; bare |
| P3 frames < 16.7 ms, >= 95 % | `just gate-frames [dock\|overview\|apps\|all] [N=20]` | nested session on the reference machine, shell render timing, 100 frames minimum; the Balanced profile in force is printed; bare |
| P5 session to usable, <= 2 s | `just gate-startup [--boots N]` | journal: uwsm start line to the shell's `grassfield-shell: usable` line (menu bar and Dock of every output drew a frame); a shell without the marker is INCONCLUSIVE; bare |
| Q1 lint | `just check` (qmllint and `scripts/dev/tidy.sh`) | tidy runs over every compositor translation unit; a passing run is stamped, `scripts/dev/tidy.sh --force` re-runs |
| Q3 coverage >= 70 % | `just coverage` | gcov JSON summary (`scripts/gates/coverage_report.py`) of `compositor/src/core` and the menu bridge logic; the Hyprland glue and the bridge's Bridge/main/LauncherWatcher are listed as not measured |
| local CI | `just release-check [--rc-headers ROOT]` | clean build of `git archive HEAD`: `just check`, `just test`, coverage, gitleaks of the history, plugin build (and against rc-channel headers when given); the summary lists the skipped cases of `just test`; bare |
| C1 soak | `tests/compositor/soak.sh [seconds] [stages]` | aims at each window's real titlebar; counts effective actions; FAIL on a shell restart, an RSS slope above `SOAK_MAX_RSS_MB_H` (10), an unreadable log; HARNESS ERROR (exit 2) when an action type never took effect; bare, nested |
| off-machine copy | `just backup DIR` | git bundle of every ref, verified, with its SHA-256 |

P4 (Search latency), R1 to R3 and A1 have no tool yet (GF-008 remains open for them).
