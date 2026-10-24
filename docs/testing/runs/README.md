# Archived gate run reports

`just gate-archive` copies the dated reports of `.dev/gate-runs/` (and their logs) here. One file per run:
`<UTC stamp>-<gate>.md` with the commit, the build id, the exit code, the result and the log path and hash.
Format and rules: [`docs/testing/README.md`](../README.md), "Gate run reports".
