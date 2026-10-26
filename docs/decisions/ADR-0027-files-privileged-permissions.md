# ADR-0027: Ownership and permission changes in Files, privileged ones through polkit
Status: Proposed (integrator, under owner delegation D-5). The unprivileged part is applied with Files PR 4; the
privileged part needs an `opus` reviewer PASS on this ADR and on its code (privileged action, master-prompt R12 spirit)
before it merges · Date: 2026-10-26 · Decider: integrator

## Context
- Owner goal (2026-10-26, `docs/specs/files.md` FP-60, FP-61): in Get Info, the owner, the group and the permissions can be
  changed (section "Sharing & Permissions"); "what needs rights goes through polkit, with an ADR and an opus review".
- Files shows owner, group and permissions read-only today (`apps/files/qml/InfoWindow.qml`).
- macOS: Sharing & Permissions lists the owner, the group and everyone with a privilege each (Read & Write, Read only,
  Write only, No Access), +/− for users and groups, "Apply to enclosed items", and a padlock that asks for an
  administrator before changes to items the user does not own.
- Linux: mode bits for owner, group and others (ACLs exist but are rarely used on a desktop). Without privileges a user
  can `chmod` items they own and `chgrp` them to a group they belong to; changing the owner needs `CAP_CHOWN`.
- KIO's own privilege path (the KAuth `file_helper` and the `org.kde.kio.file` polkit action) is not built into Arch's
  `kio` (verified 2026-10-26 on kio 6.31 from the Arch mirror: no helper and no policy file in the package), so it is not
  available on Omarchy.
- Grassfield never writes code that runs as root (R12). The session's polkit agent is the shell's (Quickshell Polkit,
  `shell/security`, R12 PASS). `pkexec` (polkit) and GNU coreutils 9.12 are installed on Arch; coreutils' `chmod` and
  `chown` take `--no-dereference` (`-h`), so a symbolic link given as the last component is never followed.

## Options
1. **Unprivileged only.** Items the user owns: privileges and group (to the user's groups) through `KIO::chmod` and
   `KIO::chown`; anything else read-only, with the reason. Safe, but not the Finder's padlock.
2. **pkexec + the system's coreutils** for the rest: Files runs `pkexec /usr/bin/chown|chmod` with fixed options and no
   shell; polkit asks for an administrator through the session's agent (`org.freedesktop.policykit.exec`, auth_admin;
   the prompt names the program and its arguments). No Grassfield code runs as root.
3. **An own polkit helper** (a D-Bus system service or a pkexec target) that resolves paths with `openat2(RESOLVE_NO_SYMLINKS)`.
   Closes path races fully, but it is root code: excluded by R12.
4. KIO's KAuth helper: not available (context).

## Decision (proposed)
Option 1 now, option 2 behind the review, with these rules:
- The editor is Finder's: rows for the owner, the group and "everyone" (others), each with a privilege popup (Read &
  Write, Read only, Write only, No Access), the padlock, and "Apply to enclosed items…" (confirmed). Execute bits keep
  their state on files; on folders "Read" maps to r-x (macOS lists folder access, not execute). Special bits (setuid,
  setgid, sticky) are shown and never changed by the popup; the editor refuses to add setuid or setgid.
- Unprivileged path: `KIO::chmod` / `KIO::chown` jobs; errors in the window's banner.
- Privileged path (after review): the padlock opens the polkit prompt for one `pkexec` call per change:
  `pkexec /usr/bin/chown --no-dereference [-R] -- USER:GROUP -- TARGET` or
  `pkexec /usr/bin/chmod --no-dereference [-R] -- MODE -- TARGET` (absolute program paths; USER and GROUP looked up from
  the system databases and passed as names that exist; MODE built from the popups as octal), where TARGET pins the item
  Files checked: Files opens it with `O_PATH | O_NOFOLLOW`, verifies that the descriptor is the item shown (device and
  inode from `fstat`, not a symbolic link), and passes `/proc/<files pid>/fd/<n>` to the command; the descriptor is kept
  open until the command ends, so a swap of the item or of a parent folder between the check and the command does not
  redirect it. Recursion uses coreutils' physical walk (`-R` without `-L`, the default `-P`).
- Refusals before any prompt: items outside local filesystems, the Trash, symbolic links (they are shown with their own
  owner and never changed), and anything under `/proc`, `/sys` and `/dev`.
- A cancelled or failed authentication leaves everything unchanged and says so; Files re-reads the item afterwards and
  shows what the system reports, never what it asked for.
- Dev and tests: the privileged path is refused in a dev session (`runmode::dev`) and in tests, except a test mode that
  replaces `pkexec` with a recording stub (no privilege ever used by the agent).

## Risks for the review
- Whether `pkexec` keeps the caller's descriptor reachable through `/proc/<pid>/fd` for the root child (polkit 126:
  pkexec does not close inherited descriptors; to be verified in the review, else the pinning falls back to a re-check
  after the command and the residual race is documented).
- The polkit prompt shows a `/proc/.../fd/n` path instead of the item's name: the Files sheet before it names the item
  and the change in plain words, and the prompt's message names `chown`/`chmod`.
- `org.freedesktop.policykit.exec` is a generic action: an administrator may have disabled it; then the padlock reports
  that changes need an administrator in a terminal.

## Consequences
- PR 4 ships option 1 and the editor; option 2 lands in the same PR only with the review PASS, otherwise in a follow-up.
- Tests: the mode arithmetic and the argv builder in gtests (no privilege), the stub-pkexec flow in a headless test,
  the polkit prompt itself on the owner's machine (L2).
