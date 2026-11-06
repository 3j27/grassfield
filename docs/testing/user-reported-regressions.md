# User-reported regressions

The ledger of failures that people using Grassfield reported (the owner, beta testers), ADR-0053 D-5. One entry per reported
failure, under a stable ID that never changes and is never reused: `URR-NNN` (three digits, in the order the reports arrive).
Commits, tests and STATE.md cite the ID.

**A source fix is not a shipped fix.** An entry stays open until a released version carries the fix and the reporter's case
was verified on that version. "Fixed on main" is a status, not the end.

How to fill an entry:
- Reported: the date, who (a role, never a name: "owner", "beta tester"), and the version they ran (`Grassfield version` of
  their diagnostic report, `grassfield-report`; never "latest").
- Reproduction: the steps that show the failure, on which hardware or setup, and how often. Attach nothing private here:
  the report itself stays with the person or in the private channel it came through.
- Cause: what was wrong, with the commit that introduced it when known.
- Fix: the commit(s) and the test that now fails without the fix (a regression test is required; name its file).
- Verification: how the fix was seen to work (the test, and the reporter's own check on the shipped version when possible),
  with the evidence reference (gate run report, screenshot, log line).
- First shipped version: the first released version (`VERSION` of a published package) that carries the fix; empty until
  then.
- Status: `open` (reported, not fixed) · `fixed in source` (merged, not released) · `shipped` (released, verified) ·
  `not reproduced` (closed without a fix, with the reason) · `duplicate of URR-NNN`.

## Entries

None yet. Template:

```markdown
### URR-001: <one line: what the user saw>
- Status: open
- Reported: YYYY-MM-DD, <role>, Grassfield <version> (diagnostic report: yes/no)
- Reproduction: <steps; setup; frequency>
- Cause: <what was wrong; introduced by <commit> if known>
- Fix: <commit(s)>; regression test: <file>
- Verification: <how, evidence reference>
- First shipped version: <version, or empty>
```
