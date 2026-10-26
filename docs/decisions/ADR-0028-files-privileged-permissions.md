# ADR-0028: Ownership and permission changes in Files, privileged ones through polkit
Status: Proposed (integrator, under owner delegation D-5). The unprivileged part is applied with Files PR 4; the
privileged part needs an `opus` reviewer PASS on this ADR and on its code (privileged action, master-prompt R12 spirit)
before it merges. Revised 2026-10-26 after the first opus review (FAIL; see "Review history") · Date: 2026-10-26 ·
Decider: integrator

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
  `shell/security`, R12 PASS). `pkexec` (polkit) and GNU coreutils 9.12 are installed on Arch.
- A descriptor's `/proc/self/fd/<n>` entry is a "magic link": a path walk through it lands on the opened inode itself,
  not on a path looked up again, so a program given that name acts on exactly the item the descriptor pins. Acting on
  the entry with `--no-dereference` (`-h`) would act on the `/proc` link instead and change nothing.

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
- Privileged path (after review): the padlock opens the polkit prompt for one `pkexec` call per item and change, with
  one `--` before the operands and no shell:
  `pkexec /usr/bin/chown -- USER:GROUP /proc/self/fd/0` or `pkexec /usr/bin/chmod -- MODE /proc/self/fd/0`.
  - Pinning: Files opens the item with `O_PATH | O_NOFOLLOW | O_CLOEXEC`, checks the descriptor (`fstat`: the device
    and inode it showed, a regular file or a folder, not a symbolic link, on a local filesystem) and gives that
    descriptor to `pkexec` as its standard input (no other descriptor is passed). The root child names its own standard
    input, `/proc/self/fd/0`, and follows it (no `-h`): no path is looked up again, and no other process's `/proc/<pid>`
    entry is used, so a swapped item, a swapped parent folder or a reused process number cannot redirect the change.
  - USER and GROUP are looked up from the system databases and passed as names that exist. MODE is four octal digits
    built from the popups and the item's current special bits (kept as they are: the editor never adds setuid or
    setgid).
  - No recursion: "Apply to enclosed items…" runs only where it needs no privilege (every enclosed item is the user's:
    one unprivileged `KIO::chmod` / `KIO::chown` per item). A privileged recursive change is not offered: a root walk of
    a tree that other users can change cannot be pinned with coreutils (`-R` needs `-H` to enter `/proc/self/fd/0`, and
    then `chown` changes the targets of symbolic links inside the tree, as root), and a single octal mode would be wrong
    for files and folders alike.
- Refusals before any prompt: items outside local filesystems, the Trash, symbolic links (they are shown with their own
  owner and never changed), and anything under `/proc`, `/sys` and `/dev`.
- A cancelled or failed authentication leaves everything unchanged and says so; Files re-reads the item afterwards and
  shows what the system reports, never what it asked for.
- Dev and tests: the privileged path is refused in a dev session (`runmode::dev`) and in tests, except a test mode that
  replaces `pkexec` with a recording stub (no privilege ever used by the agent).

## Risks for the review
- `pkexec` must hand its standard input to the program it runs (it keeps descriptors 0 to 2 for its textual agent; to
  be verified on the owner's machine before the code lands, with the recording stub first, then once with a real
  prompt on a test file). If it does not, the privileged path is not shipped: there is no fallback that looks the path
  up again as root.
- `chown` and `chmod` reached through an `O_PATH` descriptor's magic link: to be verified the same way (a test file and
  a test folder owned by another test user, never the owner's files).
- The polkit prompt shows `/proc/self/fd/0` instead of the item's name: the Files sheet before it names the item and
  the change in plain words, and the prompt's message names `chown`/`chmod`.
- `org.freedesktop.policykit.exec` is a generic action: an administrator may have disabled it; then the padlock reports
  that changes need an administrator in a terminal.

## Review history
- 2026-10-26, opus, FAIL on the first version. BLOCKER: `--no-dereference` on `/proc/<pid>/fd/<n>` acted on the link and
  changed nothing; a working recursion (`-R -H`) would follow symbolic links inside the tree as root. MAJOR: two `--`
  (the second read as a file name), one octal mode for a recursive change, the caller's process number reusable while
  the prompt waits, and the hidden ⌘X of decision F-6. This version: the child's own standard input, followed; one `--`;
  no privileged recursion; F-6 drops ⌘X for files (`docs/specs/files.md`). A new opus review is needed before any code.

## Consequences
- PR 4 ships option 1 and the editor; option 2 lands in the same PR only with the review PASS, otherwise in a follow-up.
- Tests: the mode arithmetic and the argv builder in gtests (no privilege), the stub-pkexec flow in a headless test,
  the polkit prompt itself on the owner's machine (L2).
