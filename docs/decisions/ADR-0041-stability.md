# ADR-0041: Stability: every process comes back, the session never unlocks by itself, no update installs an untested combination
Status: Proposed (step 0 of the owner's brief « Stabilité », 2026-10-29; documents only, no code). Six owner questions are
open (SQ-1 to SQ-6); every other choice follows the owner's rule of 2026-10-28 ("the closest to macOS 27, no technical
step for the end user") and is listed in "Decisions taken under the owner's rule" (SD-1 to SD-8), which the owner can
revisit. Revised after the integrator's opus review of 2c0bd74 (FAIL: one MAJOR, eight MINORs, three NITs), answered in
"Review history"; each changed place says "review of 2c0bd74". The owner answered SQ-1 to SQ-6 on 2026-10-29 (asked by
the integrator, recorded in "Owner decisions"): SQ-1 B makes ADR-0010's separate security process the path of step 1;
the other five take the recommended option. · Date: 2026-10-29 · Decider: owner (SQ), integrator (merge; SD under the rule) · Number: 0041 (0040 is the
identity ADR on main b345334; the open pull requests #48 and #49 add none)

This ADR proposes the "Stability" work: what happens when a process of the Grassfield session crashes, hangs, loops or
leaks, and what happens when the system under it moves. Its audit is `docs/audits/stability-2026-10-29/audit.md`
(findings P-1 to P-13, U-1, I-1 to I-7, T-1 to T-10, M-1 to M-11, each with file and line); this ADR cites them by number.
Nothing here is verified at runtime: this container has no Hyprland, no Quickshell and no systemd user session, so every
runtime claim is **NOT VERIFIED** until the integrator's nested pass and the owner's real-session checks named per step.

**The target, in the owner's words.** Grassfield as stable as a Mac: an app that crashes never takes the session down;
the shell or a service that crashes restarts by itself, and when it crashes in a loop the session falls back to a safe
mode **without ever unlocking the screen**; a system update (Arch/Omarchy: Qt, Quickshell, Hyprland) can never install an
incompatible combination; no infinite loop, memory leak or hang lasts.

## Context

### The owner's brief (2026-10-29)
- One pull request per step. Step 0 (this one): the measured inventory of every process, the update compatibility
  matrix, the known incidents as case studies, the tests and their gaps, the macOS model per case, a plan in short steps
  ordered by user impact (each with its proof, its tests and what the integrator checks in nested), and the owner's
  questions with two or three options each. No code.
- Everything that touches `shell/security` (the lock during a crash, the safe mode) goes through the opus security
  review and never unlocks on a failure. No new service and no new dependency without a justification here.
- Coordination: the delay of the red "lock screen died" screen (IQ-T5) belongs to the identity work (ADR-0040); it is
  referenced here, not redone.

### Rules this ADR works under
- master-prompt §3: R1 (evidence before claims), R2 (the agent runs nothing privileged: every unit, hook or package change
  is installed by the owner), R5 (no new service, daemon or dependency without a need in the current milestone: the
  table "New units, packages and dependencies" justifies each one or hands it to the owner), R12 (security modules:
  `WlSessionLock`, `PamContext("omarchy-lock-password")`, Quickshell's polkit only; an opus reviewer PASS and the L1-L5
  gates for every change; a failure leaves the session locked), R13 (the compositor plugin degrades, never blocks).
- Gates touched: R1 (shell crash recovery ≤ 3 s, state restored), L1 (killing the shell while locked leaves the session
  locked), C1-C3 (plugin stability, degradation, upstream), P2 (memory), Q3 (tests), S1 (no prohibited command in scripts).
- Upstream code is data (R4): the Quickshell, Hyprland, systemd and pacman behaviours named here are those the audit
  read in Grassfield's own records; each step re-verifies the ones it relies on.

### What the audit found (the short version)
1. **The crash loop is not handled** (P-2a). `grassfield-shell.service` restarts after 1 s and stops only after 10 starts
   in 30 s; the arithmetic trips the limit only for a shell that dies within 2.0 s of each start (the eleventh start is
   the refused one). The 2026-10-29 loop
   (a crash 5 s after every start) restarted for ever; the owner's recovery was a snapshot. While it loops, a locked
   session stays locked (the compositor keeps the lock; only a PAM success unlocks: fail closed) but cannot be unlocked
   either: the password field exists for a few seconds per cycle. Unlocked, the desktop blinks out every cycle, the polkit
   agent, the idle lock and the sleep inhibitor are absent while the shell is down (Omarchy's sleep-lock unit covers a
   sleep). Nothing tells the user what is happening. There is no safe mode.
2. **An update is checked on one path only** (U-1, section 2 of the audit). Update Now refuses an untested Qt, Quickshell,
   Hyprland, aquamarine or KF6 (ADR-0033 s3.4). `omarchy update` and `pacman -Syu` have only pacman's rules:
   `conflicts=('quickshell=0.3.2')`, found after the incident. Files, Settings, Store, Preview, Activity Monitor and the
   portal link Qt's private API, Quickshell itself imports 61 private Qt symbols (review of 2c0bd74), and the shell runs
   on whatever Quickshell is installed at its next start.
3. **Every other process has a policy, some fail silently** (P-4 to P-13): the bridge backs off and degrades to T0 menus
   after 5 crashes an hour, for the session; the portals are re-activated by D-Bus; crash-watch, battery-watch and
   automount give up after 5 failures in 2 minutes with nothing said; apps crash alone and get "quit unexpectedly" with
   Reopen; the root helpers run once and leave status files.
4. **The compositor is the one process nothing can bring back** (P-1, P-3): a crash in Hyprland, the plugin included,
   ends the session, as a WindowServer crash does on macOS. The plugin's guards, the ABI refusal and the C1-C3 gates are
   the whole defence.
5. **Nothing measures the long run** (T-3, T-7): a real session rose about 6 MB/h at idle with no known cause; at that
   slope the unit's `MemoryHigh` arrives after about 7 days and `MemoryMax` after 17 (a kill and a restart). No fuzzing
   (T-1), no chaos test (T-2), no hang detection (T-6), no gate against the next toolkit (T-5, T-10).
6. **Seven incidents** (I-1 to I-7) teach the same lesson: the damage was bounded by luck or by the owner, not by the
   session: a toolkit update on an unchecked path, a hot reload of a half-written tree, a timer that spun for an hour, a
   portal that waits 25 s for a reason this audit can only hypothesise, a Store that depends on the system's databases,
   a compositor loop that filled a disk, a shell runaway with no cause.

### Coordination with other ADRs (one owner per overlap)
| Overlap | This ADR | The other |
|---|---|---|
| The red "lock screen died" screen's delay during a shell restart | names it; step 1's nested pass records what is drawn, nothing more | ADR-0040 IQ-T5 (owner question) |
| A separate security process (lock, polkit, idle, sleep inhibitor) | step 1 builds it (the owner's SQ-1 B, 2026-10-29): ADR-0041 carries the S1-S5 plan in the integrator's order (the process and its unit first, then the lock, polkit, idle and the inhibitor one per step, safe mode last), each S-step under the opus security review; ADR-0010 is amended to say so | ADR-0010 "Separate security process", amended 2026-10-29 |
| The compatibility check, the `[grassfield]` repository, the rc-channel watch job | SQ-3 revisits one rejected option (versioned bounds) with a new shape; the check U27, the a2 "Turn Off" path and the watch job stay as they are | ADR-0033 s3.4, a2, f |
| The compositor extension's ABI, rebuild and degraded mode | the ABI rule, the user-only rebuild and the degraded mode unchanged; step 2d reverses one line of ADR-0009's amendment ("With the toggle off the notice gives the command"): the notice gives one action, the toggle stays off by default, and 2d amends ADR-0009 explicitly (review of 5a20d19); SQ-6 adds one rule for the login after a compositor crash | ADR-0009 and its amendment |
| The session configuration under a package upgrade | step 2 adds one guard to the shell's explicit reloads; the watcher stays off | ADR-0001 amendment 2026-10-29 |
| The portals' start-up and the `GTK_USE_PORTAL` loop | step 7 verifies the 25 s hypothesis (I-4) and, if confirmed, ships one drop-in | ADR-0035 D-4, D-8, 2b-12, 2b-14 |
| The persisted files and their readers | step 5 fuzzes each reader of the ADR-0020 table and adds the bound every reader must keep | ADR-0020 |
| The `/proc` and `/sys` readers of Activity Monitor | step 5 fuzzes them with the fixtures the sampler's tests already hold | ADR-0038 |
| The crash watcher and the "quit unexpectedly" notice | unchanged; SQ-4 adds one action | `docs/compat.md` "What Grassfield provides itself", `tests/shell/crash_watch.sh` |

## Principles
- **SP-1 Fail closed, always.** No step unlocks, weakens a lock, approves an authorization or sleeps unlocked to recover
  from a failure. A recovery that cannot keep the lock does not happen; the compositor's lock is the floor (SEC2, L1).
- **SP-2 An application is never the session.** Every app runs in its own scope; nothing an app does reaches the shell
  but through bounded inputs (ADR-0011, MB14). This holds today and stays a gate of every step.
- **SP-3 Every process comes back, or says so.** A process that restarts says nothing (macOS). One that cannot come back
  says so once, in the user's language, with the one action that helps (Try Again, Log Out, Open Software Update), never
  a command.
- **SP-4 Bounded everything.** Restarts, retries, logs, memory, CPU, timers, reads of a file, waits on a socket: each has
  a limit written next to it and a test that reaches the limit.
- **SP-5 The session is never surprised by a package.** A running session keeps running on what it loaded; a toolkit that
  Grassfield has not been built against never becomes the one the next start uses unless the owner said so (SQ-3).
- **SP-6 No technical step.** The user never types a command, never reads a journal, never edits a file to recover; what
  cannot meet that is a documented known limit, not a hidden one.
- **SP-7 Evidence.** A step is done when its nested test reaches the failure on purpose and the session comes back as
  the row says; "it should" is not a result (R1).

## Decision: the plan

Steps ordered by what the user would otherwise suffer first; each step is one pull request (or two where marked),
reviewed, with its nested pass before merge. Steps 1 and 2 need owner answers (SQ-1 to SQ-3); the rest can start now.
"Integrator, nested" lists what the integrator verifies in a nested session before merging; "Owner, real session" what
only the owner can check (L2); "Review" names the required reviewer.

### Step 1: the loop stops, and the lock lives apart from the UI (P-2a, M-4, M-5, M-9; SQ-1 B, SQ-2 A) — **opus security review on every part**
Goal: a UI that crashes in a loop, at any pace, stops looping within minutes; the lock, the polkit agent, idle and the
sleep inhibitor keep running whatever the UI does; the session stays locked if it was; safe mode is "the UI unit
failed, the security process is up", with a way out (Try Again, Log Out), never a lock-out. Rewritten after the owner's
answers of 2026-10-29 (SQ-1 B: ADR-0010's separate security process now, S1-S5; SQ-2 A): the first version built a safe
configuration of the one shell process. Order and rules set by the integrator under the owner's rule: 1a ships first and
unchanged (independent, it stops a slow loop today); then the security process, its unit first with nothing moved yet
(S1), then everything that locks together (S2: the lock, idle and the sleep inhibitor, with every `Lock.lock` caller
switched in the same step; the integrator's review of f018b42 found that moving the lock alone would leave the UI's
inhibitor and idle unable to lock while the security process restarts), then the polkit agent (S3); safe mode is the
last step (S4). The UI keeps refusing while locked from state it receives, and a missed push can never fail it open
(ADR-0010's risk 2; review of f018b42): the heartbeat carries the state and a sequence number, and `SessionState.locked`
is the pushed state OR the compositor's own lock signal (hyprland-lock-notify-v1, which `shell/services/Clipboard.qml:28`
already ORs in) OR "no state yet" OR a stale heartbeat OR a security unit that is not active and running. The second Qt
Quick process's memory and start time are measured at S1 against the budgets; IQ-T5 (the compositor's lockdead delay,
ADR-0040) still applies to a crash of the security process itself. Each part is its own pull request under the opus
security review (R12), and the invariant of every intermediate state (which process locks, what happens when either is
down, how sleep behaves) is written in the table at the end of this step.
- **1a. The loop detector** (SQ-2 A: 3 failures within 10 minutes; systemd's start limit raised to 10 starts in 5 minutes
  as the backstop). `grassfield-shell.service` gains a second `OnFailure=` unit, `grassfield-shell-failed.service`
  (`Type=oneshot`, a POSIX sh script, standard tools only), which records each failure's monotonic time in
  `$XDG_RUNTIME_DIR/grassfield/shell-failures` (0600), prunes the window and, at the threshold, cancels the pending restart
  (`systemctl --user stop grassfield-shell.service`, which a unit in auto-restart accepts) and writes the safe-mode state
  file the security process reads from S5 on. A logout does not count: the script applies the same "compositor gone"
  test as the sleep-lock gate (`packaging/systemd/sleep-lock-gate`), so the 255 exit of every logout (GF-081) never
  counts as a failure. `OnFailure=omarchy-sleep-lock.service` stays, unchanged. Before S5 ships, what the user sees at
  the threshold is what the start limit gives today, reached now for a slow loop too: the UI stays stopped (no bars,
  the windows over the ground colour), the compositor keeps a lock if there was one (fail closed, out of reach from the
  session: a TTY or the power button are the exits, as today), Omarchy's sleep lock stays armed and its stand-in tries
  the shell once more at sleep time (`reset-failed` + start). Proof: a nested run where the shell is killed with SIGSEGV
  every 5 s while locked: Hyprland reports `LOCK` on every monitor throughout, nothing typed reaches a probe window, the
  restarts stop after the third failure; the same unlocked; a logout during the window does not count. Tests:
  `tests/shell/unit_restart_limits.sh` gains the lifetime model (it must fail on today's unit, then pass); a logic test
  of the detector on a fake `systemctl` and a fake runtime directory (`tests/shell/shell_failures.sh`);
  `tests/security/sleep_lock_units.sh` for the gate with the stopped unit; `tests/security/reload_locked.sh` gains the
  `crash-loop` step (nested, bare). Owner, real session: `kill -SEGV $(systemctl --user show -p MainPID --value
  grassfield-shell.service)` three times within ten minutes while locked: the session stays locked and the restarts stop
  (`scripts/gates/r1-restart.sh --journal` then has its first real restarts, gate R1). Review: opus security (R12).
- **S1. The security process and its unit, nothing moved yet.** `shell/security/` is made free of UI imports (ADR-0010 S1:
  the lock backdrop through a `Grassfield.Ui` type; popups closed by the UI on `SessionState.locked`, so `Lock.lock()`'s
  `Popups.close()` goes; the sleep notice through the notification server's public D-Bus interface), without a
  behaviour change. A second root, `shell/security/shell.qml`, and its unit `grassfield-security.service` (`Restart=always`,
  `RestartSec=1`, `StartLimitIntervalSec=300`, `StartLimitBurst=5`, `PartOf=` and `Requisite=graphical-session.target`,
  `ConditionEnvironment=GRASSFIELD_SESSION=1`, the same `UnsetEnvironment=` lines as the shell's, no
  `NoNewPrivileges` for the same reason as the shell's, `MemoryHigh=`/`MemoryMax=`/`CPUQuota=` set from the S1
  measurement) run beside the UI, started by `autostart.lua` before the shell, hosting nothing but the IPC target
  `security state` (answers `starting`) and a heartbeat the UI reads. Measured and recorded against the budgets: the
  process's RSS at idle (gate P2's accounting gains a second process), its start time to the first IPC answer (gate P5:
  the session to a usable menu bar and dock stays ≤ 2 s). Tests: `tests/security/shell_unit_env.sh` and
  `session_services.sh` for the unit; `ipc_inventory.sh` for the new target; `import_graph.py` for the import freedom;
  `scripts/gates/rss.sh --nested` with both processes. Review: opus security.
- **S2. Everything that locks moves together: the lock, idle and the sleep inhibitor.** `Lock`, `LockView`, the
  crash-recovery marker, the stranded-lock takeover, `Idle` (dim, lock, display off) and `SleepInhibitor` with its
  `PrepareForSleep` watcher run in the security process. The IPC targets `lock lock`, `lock lid` and `lock status`
  answer on the security instance (`qs ipc -p /usr/share/grassfield/security`), and every caller of `Lock.lock` or of
  the targets switches in the same pull request: in-process callers become IPC callers (`shell/overlay/SystemMenu.qml:72`,
  `shell/services/SessionState.qml:21` `requestLock`, `shell/shell.qml:88`, `shell/services/Popups.qml`,
  `shell/services/TilingSuggest.qml`), and the external ones change their path (the key bindings in
  `config/hypr/grassfield/bindings.lua`, `grassfield-lid`, the `omarchy-shell` stand-in, the screen corners, the apps'
  `shellIpcArgs()` callers of `lock`, the tests); `Idle.qml:142` and `SleepInhibitor.qml:72, :84` stay in-process because
  they move with the lock (review of f018b42). In the same step `OnFailure=omarchy-sleep-lock.service` moves to
  `grassfield-security.service` (the shell's unit keeps `Restart=always` and 1a's detector, and loses that `OnFailure=`:
  it no longer holds an inhibitor), the sleep-lock gate is keyed on the security unit (`active`/`running` of
  `grassfield-security.service` alone: the UI's state is no longer part of the sleep question), and the stand-in's
  `lock lock` starts the security unit when it is not running. The UI reads `lock state` at start and receives a push on
  every transition; the heartbeat (every 2 s) carries the state and a sequence number, so a lost push is corrected by
  the next heartbeat; `SessionState.locked` is the pushed state OR the compositor's lock signal (hyprland-lock-notify-v1)
  OR no state yet OR a stale heartbeat (no beat for 5 s) OR a security unit that is not active and running: every UI
  refusal (GF-116, "Show previews: When Unlocked", Overview, Switcher, the Dock's reopen) reads locked in each of these
  cases, fail closed. The idle and sleep notices go through the notification server's D-Bus interface (journal only
  while the UI is down). Proof: ADR-0010's crash-injection test moved here: a crash signal to the UI process while
  locked leaves the lock surface in place (no lockdead screen) and nothing typed reaches a window; while unlocked, the
  idle lock still fires and a sleep still locks first; a crash of the security process while locked keeps `LOCK` on
  every monitor until its restart takes the lock back, and a sleep requested while it restarts is delayed by Omarchy's
  unit until the restarted process reports `secure`. Tests: L1-L5 against the security process (`reload_locked.sh`
  every step, `l2_wrong_password.sh`, `lock_privacy.sh`, `lock_surfaces.sh`, `lock_monitor_model.sh`, `marker_read`,
  `reload_order`); `sleep_lock_units.sh` for the gate and the stand-in keyed on the security unit, `tst_idlemodel`,
  `lid.sh`, `screensaver_inhibit.sh`; a UI-side test that every refusal reads locked on no state, a stale heartbeat, a
  lost push with the compositor's signal set, and a stopped security unit (mutants on each); a scan that no `Lock.lock`
  caller is left in the UI tree (`ipc_inventory.sh`). Owner, real session: DT-01 and DT-21 re-run (kill the UI while
  locked, kill the security process while locked), L3 (lock before sleep) and the lid. Review: opus security.
- **S3. The polkit agent moves.** `AuthAgent` and its dialog run in the security process, drawn with `Grassfield.Ui`
  only; exactly one agent in the session (L5: registration, action id and program shown, cancel works, never
  auto-approves); the UI's `polkit status` dev hook moves with it. Tests: `authagent_flows.sh`, `tst_authdialog*`,
  `mutate_authdialog.sh` against the security process. Review: opus security.
- **S4. Safe mode, last.** When 1a's state file says the UI is stopped for a loop, the security process maps one layer
  surface: the Grassfield mark, the sentence "Grassfield is running in safe mode: its desktop stopped working and was
  turned off." and the Grassfield menu with Try Again…, Log Out…, Restart…, Shut Down… (the existing session-end path),
  drawn with `Grassfield.Ui` only, under the lock surface when locked. Try Again starts `grassfield-shell.service` and
  empties the failures file; a second loop returns here. Nothing else: no Dock, desktop, Search, notification server or
  request socket to the plugin (the 2026-10-29 crash lived in those sockets, I-1, which the security process never
  opens). Proof: the 1a nested run, now ending with the safe-mode bar after the third failure, the password unlocking
  at the first attempt, Try Again restoring the desktop; captures (en, fr, light, dark). Tests: the safe-mode surface
  offscreen (`tests/security/safe_mode.d/`), `reload_locked.sh` gains `safe-mode`, `ipc_inventory.sh` for its actions.
  Owner, real session: the 1a kills, then safe mode, the password, Try Again. Review: opus security.
- The invariant of each state (review of f018b42: which process locks, what happens when either is down, how sleep
  behaves). "Down" means not active/running: restarting, failed, or stopped at its limit.

  | From | Who locks | The UI process down | The security process down | Sleep |
  |---|---|---|---|---|
  | today, and after 1a | the UI (`grassfield-shell`) | the compositor keeps an existing lock (lockdead screen, IQ-T5); no idle lock and no inhibitor until the restart or the stop; after 1a's stop, the compositor's lock stays and the session is out of reach from itself | n/a | the UI's inhibitor while it runs; Omarchy's sleep lock (armed by `OnFailure=`, the gate skips it only while the UI runs) asks the stand-in, which starts the UI and asks it to lock; a sleep that cannot lock in logind's window is the known limit |
  | S1 | the UI, unchanged | unchanged | nothing: the security process hosts nothing yet | unchanged |
  | S2 | the security process, and only it: every lock request goes to it over IPC | the lock, idle and the inhibitor keep running; the UI's refusals read locked from the compositor's signal, the pushed state or the absence of a state; nothing about the lock changes | the compositor keeps an existing lock (lockdead screen, IQ-T5); no idle lock and no inhibitor until its restart (1 s) or its stop at the limit; the UI's refusals read locked (the unit is not active/running); Omarchy's sleep lock is armed by the security unit's `OnFailure=` | the security process's inhibitor while it runs; the gate skips Omarchy's unit only while the security unit is active/running; Omarchy's stand-in starts the security unit and asks it to lock; the same known limit when it cannot start in logind's window |
  | S3 | the security process | as S2; an authorization asked while the security process restarts fails, as it does today while the UI restarts | as S2, plus no polkit agent until the restart | as S2 |
  | S4 | the security process | as S2; after 1a's stop the safe-mode bar appears under the lock surface | as S2; the safe-mode bar is gone with it | as S2 |

- Known limits (written in the spec): a Quickshell bug that takes the security process down in a loop leaves the
  compositor's lock in place and the session out of reach from itself (the TTY or the power button); a second Qt Quick
  process costs memory (measured at S1, the budget recorded in `docs/testing/gates.md`); until S4 ships, a crash of the
  UI still takes the inhibitor down for the restart's second (Omarchy's sleep lock covers it, as today).
- Integrator, nested: every proof above, step by step; `lock_surfaces.sh`, `ipc_inventory.sh`, `shell_unit_env.sh`,
  `session_services.sh` after each move; what the compositor draws during a security-process restart is recorded for
  IQ-T5.

### Step 2: no untested toolkit reaches the session, on any path (U-1, I-1, M-7) — **opus security review** (2a's helper verbs; nothing else runs as root)
Goal: what Update Now refuses today, every path refuses or at least detects; the user is told what to do in the words
of the session, never in a terminal.
- **2a. The hold** (SQ-3; the owner decides its shape, and it ships only once the `[grassfield]` repository is published,
  ADR-0033 h: before that there is no build to wait for and a hold would refuse every system update with no end; review
  of 2c0bd74, MAJOR 1). With option A: two split packages in `packaging/arch/PKGBUILD`. `grassfield-hold` holds nothing but
  `depends` on the toolkit `BUILD-DEPS` records: `quickshell=<that exact version>`, `qt6-base>=<major.minor>` and
  `qt6-base<<the next minor>`; never `hyprland` (ADR-0009: degraded mode and the rebuild) and never `kcoreaddons` (KF6
  releases monthly with a public ABI; a bound would refuse every release for nothing). `grassfield-unhold` is its empty
  twin: `provides=(grassfield-hold)`, `conflicts=(grassfield-hold)`, no bound. `grassfield-desktop` depends on
  `grassfield-hold`: a fresh install and the next `-Syu` of an existing system both pull the real hold (pacman resolves a
  dependency by its literal package name before it asks about providers), and the twin satisfies the same dependency
  without the bounds, so neither can be removed by mistake and both are reachable. "Allow system updates Grassfield
  hasn't tested…" in Software Update runs a new verb of `grassfield-channel-helper` behind its polkit action, `unhold`:
  one root transaction, `pacman -S --noconfirm --ask 4 grassfield-unhold` (`--ask` is pacman's bitmask that answers its
  conflict question, so the twin replaces the hold in one step; if pacman 7 no longer keeps it, `pacman -Rdd
  grassfield-hold` followed by `pacman -S grassfield-unhold` is the fallback: step 2a's first container test decides),
  and `hold` runs the reverse ("Hold untested system updates again"). Once the toolkit has moved past the bounds, that
  reverse cannot be satisfied (pacman answers "unable to satisfy dependency 'qt6-base<6.12'"; review of 5a20d19): the pane
  then shows "Hold again" greyed with the reason, "Your system already moved past the versions this Grassfield was built
  for; holding comes back with the next Grassfield update", decided by the same comparison as 2b (`pacman -Q` against the
  hold's bounds); the next `grassfield-desktop` build, made against the new toolkit, carries a hold whose bounds match, so
  the button works again after it. pacman then refuses, on every path, any
  transaction that moves `quickshell` or `qt6-base` past the bounds, until the repository ships the build made against
  the new toolkit, which joins the same transaction (ADR-0033 f's watch job, extended from Hyprland's ABI to Qt and
  Quickshell on Omarchy's rc mirror). What the user sees when it refuses: on Update Now, the helper's plan step fails
  before any change; today that step exits 8, "pacman cannot plan this update" (`packaging/pacman/grassfield-update-helper:242-243`),
  which the pane shows as a failed preparation, so step 2a makes the helper read pacman's refusal and, when it names
  `grassfield-hold`, answer exit 6 (`incompatible`, the U27 path): the pane then says "This update needs a newer version of
  Grassfield, which isn't available yet." with "Allow…" one click away. That reading is a root-side change of the helper,
  under the opus security review (review of 5a20d19, finding 4). On `omarchy update` in a terminal, pacman's
  own error names `grassfield-hold` and the bound and Omarchy's script reports a failed update, and the session's next
  scheduled check (ADR-0033 d) raises the same notice with the same action.
- **2b. Detection as the user, on every path.** Nothing runs as root: ADR-0009's amendment says "Nothing in the amended
  design runs as root after the package is installed" (`docs/decisions/ADR-0009-plugin-distribution.md:112`), and the
  first version of this step planned a root alpm hook against it (review of 2c0bd74, finding 6). Instead the shell's
  update checker (ADR-0033 d, already a one-shot child of the shell as the user) watches `/var/lib/pacman/local` (its
  modification time moves at every transaction; readable by every user) and, when it moved, compares `pacman -Q` of the
  tracked packages with `/usr/share/grassfield/BUILD-DEPS`; a difference posts "Log out to finish updating" (the family of
  `shell/shell.qml:267-279`; today only the install scriptlet prints it, to a terminal), Settings' Software Update pane
  shows the same with "Log Out…", and the compositor rebuild's opt-in path reads the same comparison at the next login.
  The shell's explicit reloads of the session configuration (`SessionConfig.qml`, `Displays.qml`) wait while
  `/var/lib/pacman/db.lck` exists, bounded, so a display trial never reloads a half-written tree (I-2's residual).
- **2c. The rc-channel gate** (T-5, T-10). `just release-check` and CI gain a container run of the headless suites, the
  QML lint against the rc channel's Quickshell `qmltypes` and the plugin build against the rc Hyprland headers (the
  existing C3), so an incompatibility is known one Omarchy cycle before stable; the result feeds the watch job's build.
- **2d. The extension notice without a command** (review of 2c0bd74, finding 9). `windows.rebuildExtension` is off by
  default, so two of the degraded notices name `grassfield-compositor-rebuild` as a command to type (`shell/shell.qml:270,
  276`), against SP-6. The notice gains one action, "Update Extension", which runs what the opt-in runs
  (`grassfield-compositor-rebuild --session`, as the user, in the background) and then says "log out and back in"; the
  setting keeps its default. Until 2d ships, this is a known limit under SP-6.
- Proof: `tests/integration/update_helper.sh`'s container with the hold pair installed: an update that moves Quickshell is
  refused by pacman on `pacman -Syu`, on `omarchy update`'s command and on Update Now (the pane's sentence), nothing
  installed; the same transaction with the matching `grassfield-desktop` in a test repository goes through; "Allow…"
  swaps the hold for its twin through polkit (`--ask 4`, or the `-Rdd` fallback) and the update goes through; "Hold
  again" swaps them back; the checker's comparison on a fake `/var/lib/pacman/local` and `BUILD-DEPS` posts the notice
  (offscreen harness); the extension notice's action runs the rebuild (nested).
- Tests: the container cases above, with the helper's reading of a hold refusal (exit 6, `incompatible grassfield-hold`)
  in `tests/integration/update_helper.sh`; `tests/shell/session_services.sh` for the checker's reader;
  `tst_softwareupdate.qml` for the pane's sentences and the greyed "Hold again"; a `tests/ci` check that `BUILD-DEPS`, the hold's `depends` and the s3.4 table name the same
  packages; `tests/shell/compositor_rebuild.sh` for the notice's action.
- Integrator, nested: the notice on a fake `/var/lib/pacman/local`; the reload guard with a fake `db.lck` during a display
  trial; "Update Extension" from the notice.
- Owner, real session: the next Omarchy toolkit move: Update Now says "needs a newer version of Grassfield" (today's
  L2 item of ADR-0033) and `omarchy update` is refused by pacman with the hold's name; after the matching build is
  published both go through, then "Log out to finish updating" appears once.
- Review: opus security for the helper's two verbs (root through polkit, the same rules as `grassfield-channel-helper`);
  the integrator for the rest; two pull requests at least (2b and 2d need no owner answer, 2a waits for SQ-3 and the
  repository).

### Step 3: chaos: every process killed, every return verified; R1 measured (T-2, T-4, M-3)
Goal: the inventory's "how it comes back" column becomes a test, and every silent loss becomes at least a journal line.
- `tests/integration/chaos.sh` (nested, bare): for each row of audit section 1.1 that the nested session can run (the
  shell unlocked and locked, SIGSEGV and SIGKILL, once and in a loop until safe mode; the bridge; both portals mid-request;
  crash-watch, battery-watch, automount; the ANR stand-in; one Grassfield app and one third-party app), kill it and
  check: the unit's state and the time to come back (R1 ≤ 3 s for the shell, from the journal), the lock state
  (`hyprctl -j monitors` `LOCK`) before, during and after, what was replayed (badges and registrations after a bridge
  restart, the notification history after a shell restart, the Open panel's last folder after a portal restart), the
  notice for an app (one, with Reopen) and none for a service, and one journal line per silent loss (`P-8`, `P-9`: the
  unit's own `Restart=` log is enough when it comes back; the start-limit failure must say what stopped).
- Proof: the script's report, one row per process, with the capture of what the user sees at the worst moment.
- Tests: the script itself (inventory layer `nested`), plus a `logic` self-test on fakes; `scripts/gates/r1-restart.sh
  --journal` on the nested unit's journal becomes the R1 verdict.
- Integrator, nested: the whole script on a quiet machine, twice; the R1 figure recorded in `docs/testing/gates.md`.
- Owner, real session: nothing until step 1 ships; then the R1 journal check after their step-1 kills.
- Review: the integrator; security only where the script touches the lock (it reads, never unlocks).

### Step 4: endurance and bounds: the memory slope, descriptors, timers; the plugin's log budget; the guards proven (T-3, T-7, I-6, I-7, M-10, M-11)
Goal: the 6 MB/h is explained or fixed; every resource guard is seen to act; a loop in the compositor cannot fill a disk.
- `tests/shell/endurance.sh` (nested, bare, hours): scripted activity in rounds (Overview open and close, Apps, Search
  typing, notifications in and out, lock and unlock with the dev PAM gate, a display added and removed, an icon-mode
  switch, the DST hour simulated with `TZ` and a fake clock, a sleep simulated through the marker's sleep count),
  sampling every minute RSS and `RssAnon`, the count of `/proc/<pid>/fd`, `Threads`, and the number of live repeating
  QML timers through a dev-only IPC hook (`SEC-04` class dev); verdict by `soak_lib.sh`'s slope function against a
  threshold the owner accepts (proposed: RSS slope ≤ 1 MB/h after the first 30 min, descriptors and timers flat).
- The guards proven: a dev-only hook allocates until `MemoryMax` (the shell is killed, back within 3 s, the lock kept),
  another spins the GUI thread (the compositor's frame time stays within P3 under `CPUQuota`), the bridge's `MemoryMax`
  (already `menu_bridge_memory.sh` case G).
- The compositor: every loop-prone path (layer-pointer refresh, overview retargeting, stages focus) gets the plugin's
  log budget (`compositor/src/core`), with a unit test that a path logging in a loop stops after its budget; the real
  session's Hyprland log state is recorded (`hyprctl getoption debug:disable_logs`, owner) and, if logs are on, the
  session sets the bound Hyprland offers (NOT VERIFIED which option exists in 0.56.2: the step reads the installed
  `hl.meta.lua`).
- Proof: an 8 h endurance report with the four series and the verdict; the guard hooks' three captures; the log-budget
  unit test; if the slope is above the threshold, the allocation site (Qt's own tools, `malloc_info` through a dev
  hook, or the icon-mode and wallpaper paths first, the two known growers) and the fix in its own pull request.
- Tests: the endurance script (nested), the guard hooks' tests (nested), the budget test (compositor gtest).
- Integrator, nested: the 8 h run on a quiet machine; a 1 h run becomes part of `just release-check`.
- Owner, real session: `scripts/gates/rss.sh` over a week of normal use (the existing P2 tool, repeated), to compare
  with the nested slope.
- Review: the integrator; R13 (compositor-engineer) for the plugin changes; security for the dev hooks' gates.

### Step 5: fuzzing of the parsers (T-1)
Goal: no input a process reads from the system, a file or another process can crash or hang it.
- In-tree, no new dependency: a mutation harness (`tests/fuzz/`, gtest for C++, a Python mutator for the scripts' readers,
  a QML harness for the JS readers) that takes each existing corpus and applies random byte and token mutations for a
  budget of iterations under ASan/UBSan (the `--asan` builds exist), with a saved seed so a failure reproduces. Readers,
  in the order of exposure: the plugin's gfc/1 request reader and the shell's event parser (another process of the user
  can send either), the menu bridge's socket and DBusMenu layouts (any app), the ANR stand-in's `anr report`, `qs ipc`
  arguments of every action, `hyprctl -j` consumers (`grassfield-session-end`, `grassfield-lid`, the `omarchy-shell`
  stand-in's `jq` filter, the lock's monitor model), `/proc` and `/sys` readers (Activity Monitor, the crash watcher),
  `.desktop` readers (the Apps model, the crash watcher, `entry-names.sh`, `hidden-entries.sh`), every file of the
  ADR-0020 table (JSON readers; the Lua files Settings writes are checked by `Hyprland --verify-config` on the mutated
  output, so a Settings write can never produce a file the compositor refuses), the Store's catalog, AppStream and pacman
  output readers, the journal JSON of the crash watcher. libFuzzer behind a CMake option, dev only, is a later option
  (clang is already a `just check-tidy` tool; it adds no package).
- Proof: the harness's report per reader (iterations, mutations, 0 crashes, 0 hangs over the bound); every finding fixed
  in its own commit with the reproducing seed as a regression case.
- Tests: the harness runs in `scripts/dev/test.sh`'s sanitized pass with a short budget; `just release-check` runs the
  long budget.
- Integrator, nested: none needed (offscreen); the gfc/1 cases also run against the nested plugin through
  `scripts/nestctl` for the request side.
- Review: the integrator; security for the lock's monitor model and the stand-in (they are security modules' inputs).

### Step 6: hang detection, and the extension after a compositor crash (T-6, M-8, M-10) — SQ-5, SQ-6
- **6a. The liveness probe** (SQ-5, option A): `grassfield-shell-watchdog.timer` and its `.service` (`Type=oneshot`,
  every 30 s): `qs ipc -p /usr/share/grassfield/shell call capabilities status` with a 5 s `timeout`; three misses in
  a row (a state file in the runtime directory) → `systemctl --user kill --signal=SIGKILL grassfield-shell.service`: the
  main process dies by a signal, so the unit fails, `Restart=always` brings it back, `OnFailure=` runs and step 1's
  detector counts it (a hang that repeats ends in safe mode too). A plain `systemctl restart` is a stop, which never
  fails the unit and would never reach safe mode (review of 2c0bd74, finding 3). Hyprland's ANR pings xdg toplevels only;
  the shell's surfaces are layer surfaces and get no ping: nothing else can see a frozen shell. The probe reads, never
  unlocks; a restart while locked keeps the compositor's lock (L1).
- **6b. The extension after a crash** (SQ-6, option A): `compositor.lua` reads, at the first parse, whether a Hyprland
  crash report newer than the last login names `grassfield-compositor` (the report's path and shape are read from the
  installed Hyprland, data; `coredumpctl` is the fallback); if so it loads nothing, writes why in the runtime note, and
  the shell posts "The compositor extension was turned off after a crash" with "Turn On Again" (Settings > Desktop &
  Dock > Windows). One login without the extension, never a silent permanent loss.
- Proof: a dev-only hook blocks the GUI thread 20 s → the probe restarts the shell within 100 s, the lock kept; a
  nested Hyprland crash with the plugin loaded (the C1 soak's own crash classification) → the next nested start loads
  no extension and shows the notice; `abi_mismatch.sh` unchanged.
- Tests: the probe's logic on a fake `qs` and `systemctl`; `tests/shell/compositor_rebuild.sh` gains the crash-report
  case; the hook under `qs` offscreen.
- Integrator, nested: both proofs. Owner, real session: nothing specific.
- Review: security (the probe restarts the process that holds the lock; the dev hook's gate); R13 for `compositor.lua`.

### Step 7: the known incidents as regressions, and the two open ones (T-8, I-2, I-3, I-4, I-5)
- A package-upgrade simulation in nested: replace the installed-layout copy of `config/hypr` under a running session
  (unlink and recreate, as pacman does), then reload: no error bar, every bind present (I-2's proof made repeatable).
- `tst_wallclock` gains the spring-forward night (the skipped hour): no freeze, no spin; `wall_clock_only.sh` stays.
- The portal's 25 s (I-4): the owner runs `systemctl --user show-environment | grep GTK_USE_PORTAL` and
  `journalctl --user -b -u xdg-desktop-portal-gtk -u xdg-desktop-portal -o short-monotonic` (read-only, provided as a
  script `docs/audits/stability-2026-10-29/owner-checks.sh`); if the hypothesis holds (x-d-p-gtk inherits
  `GTK_USE_PORTAL=1` and waits out D-Bus's 25 s method timeout on itself), the fix is one packaged drop-in,
  `xdg-desktop-portal-gtk.service.d/10-grassfield.conf` with `UnsetEnvironment=GTK_USE_PORTAL`, checked by
  `tests/integration/portal_settings.sh` on the private bus with the real x-d-p-gtk; if it does not, the measurement
  says what does.
- The Store's stale-database wording (I-5): the messages asked on PR #36 are settled in that lane; this ADR adds only
  the chaos row (a Store operation in flight when the Store is killed shows its outcome at the next start).
- `tests/ci/socket_errors.py` stays; the r7 proof of I-1 becomes a container case of step 2c (Quickshell from the rc
  mirror).
- Proof, tests, integrator: each item names its own; owner: the portal measurement.
- Review: the integrator; ADR-0035's owner for the drop-in.

### Step 8: crash reports, local only (SQ-4, M-1, M-6)
- With option A: the crash watcher's notice gains a second action, "Show Report", which writes
  `$XDG_STATE_HOME/grassfield/crash-reports/<app>-<time>.txt` (0600; `coredumpctl info` of that dump, the signal, the
  executable, the time, the Grassfield and toolkit versions; never the core itself) and opens it in a Grassfield text
  window of the system dialogs (ADR-0035) with Copy and Close. Nothing is sent anywhere, ever (`PrivateNetwork=yes` stays
  on the watcher); at most 32 reports are kept, the oldest removed.
- Proof: `tests/shell/crash_watch.sh` gains the action and the file; a capture of the window (en, fr).
- Review: the integrator; security for the new window (it shows untrusted text: plain `textFormat`, the existing rule
  of `scripts/dev/check-textformat.py`).

### Delivery order and what each step waits for
| Step | Waits for | Pull requests |
|---|---|---|
| 1 | answered (SQ-1 B, SQ-2 A): 1a now; S1 after the merge of step 0; then S2, S3, S4 in that order | 1a; S1; S2; S3; S4 |
| 2 | SQ-3 and the repository's publication (2a); 2b, 2c and 2d can start now | 2a; 2b; 2c; 2d |
| 3 | step 1 for the loop rows; the rest now | 1 |
| 4 | nothing | 1 or 2 (the fix of a found leak apart) |
| 5 | nothing | 1 or 2 |
| 6 | answered (SQ-5 A, SQ-6 A) | 6a, 6b |
| 7 | the owner's portal measurement (7c) | 1 |
| 8 | answered (SQ-4 A) | 1 |

## New units, packages and dependencies (R5)
| Item | Kind | Justification | Decided by |
|---|---|---|---|
| `grassfield-shell-failed.service` | a `Type=oneshot` user unit, a POSIX sh script | systemd counts starts, not failures, and cannot see a lifetime; nothing but the `OnFailure=` path sees each failure as it happens; it runs for a moment, never a daemon | step 1a (SQ-2 sets its numbers) |
| `grassfield-security.service` | a second Quickshell process (the same `qs` binary, the root `shell/security/shell.qml`) and its user unit | the owner's SQ-1 B (ADR-0010's direction, GF-050): the lock, polkit, idle and the inhibitor apart from the UI, as loginwindow is apart from the Dock; its memory and start time measured at S1 against P2 and P5 | SQ-1 B (owner, 2026-10-29) |
| `grassfield-hold` and `grassfield-unhold` | two split packages with `depends`, `provides` and `conflicts` only | the only mechanism pacman offers that refuses on every path and can be undone in one transaction; no code, no service; shipped only once the `[grassfield]` repository is published | SQ-3 |
| the checker's toolkit comparison | no new unit: a read-only step of the shell's existing update checker, as the user | learns on every path that the toolkit moved under the session, with nothing run as root (ADR-0009:112; review of 2c0bd74 dropped the alpm hook of the first version) | step 2b |
| `grassfield-shell-watchdog.timer` | a user timer and a `Type=oneshot` unit | a frozen shell is otherwise invisible; a timer runs no daemon; Quickshell offers no `sd_notify` watchdog (NOT VERIFIED: the step checks `qs --help`) | SQ-5 |
| `tests/fuzz/` | test code, no runtime dependency | ASan/UBSan builds exist; the mutator is in-tree | step 5 |
| No new runtime dependency | — | every program named above is in the session's `depends` already (`systemd`, `pacman`, `polkit`, `coreutils`, `jq` through the stand-in's existing use) | — |

## Owner decisions (2026-10-29, asked by the integrator; recorded from PR #50)
| Question | The owner's choice | Option |
|---|---|---|
| SQ-1 safe mode | « Processus sécurité séparé » | **B**: ADR-0010's separate security process now: the lock, polkit, idle and the sleep inhibitor always run apart from the UI; safe mode is "the UI unit failed, the security process is up" (S1-S4 after the review of f018b42: everything that locks moves together at S2) |
| SQ-2 the loop detector | « 3 plantages en 10 min » | **A** (recommended) |
| SQ-3 an untested toolkit | « Détecter maintenant, bloquer plus tard » | **B now, A after the `[grassfield]` repository is published** (recommended) |
| SQ-4 crash reports | « Afficher le rapport » | **A** (recommended) |
| SQ-5 a frozen shell | « Sonde toutes les 30 s » | **A** (recommended) |
| SQ-6 the extension after a compositor crash | « La couper si elle est en cause » | **A** (recommended) |

Integrator decisions under the owner's rule that come with SQ-1 B (the closest to macOS, no technical step for the end
user): step 1 is rewritten around ADR-0010's S1-S5, each S-step its own pull request under the opus security review,
every intermediate state keeping "failures stay locked"; the order is 1a first (independent, it stops a slow loop today),
then the security process (its unit first with nothing moved yet, then the lock with idle and the sleep inhibitor
together and every `Lock.lock` caller switched in the same step, then the polkit agent: the review of f018b42 merged
the idle step into the lock's, since a lock moved alone left the UI's inhibitor unable to lock while the security
process restarts), safe mode last; the UI keeps refusing while locked from state it receives and treats "no state yet",
a stale heartbeat, a stopped security unit or the compositor's own lock signal as locked; the second Qt Quick process's memory and start time are measured at S1 and recorded against the budgets; IQ-T5
(ADR-0040) still applies to a crash of the security process itself; ADR-0010 is amended to carry the decision.

## Owner questions
Answered on 2026-10-29 (above); the options stay as they were asked.


**SQ-1. The shape of safe mode** (step 1; the brief requires one; it reverses nothing decided). Answered: B (owner, 2026-10-29). Both A and B are
security modules under R12; the compositor keeps the lock in every option (SP-1).
| Option | For | Against |
|---|---|---|
| **A. A safe configuration of the same shell tree: `GRASSFIELD_SAFE_MODE=1` loads only the lock, the polkit agent, idle, the sleep inhibitor, plain banners and a one-strip bar (Try Again, Log Out, Restart, Shut Down) (recommended)** | small (one root file, two unit files); the reviewed security modules unchanged; no second process in normal use; the IPC path, the bindings, the lid helper and the stand-in need no change; it avoids the request sockets where the 2026-10-29 crash lived; it is ADR-0010's S2 root in all but name, so it is a step toward B | it shares Quickshell with the full shell: a bug in Quickshell's lock or monitor code crashes it too (the compositor then keeps the lock: fail closed, out of reach); the sleep-lock gate and the stand-in learn a second unit name |
| B. ADR-0010's separate security process now (S1-S5): the lock, polkit, idle and sleep inhibitor always run apart from the UI; safe mode is "the UI unit failed, the security process is up" | the macOS model (loginwindow apart from the Dock): no lock restart on any UI crash, no red screen ever, the crash loop never touches the lock | ADR-0010 rated it not low-risk: the IPC contract moves, the lock state must cross processes (a missed push fails the UI's refusals open), `LockView` still imports UI, a second Qt Quick process's memory is unmeasured; five reviewed steps before any safe mode exists |
| C. No safe mode: raise the start limit so a slow loop stops; the compositor keeps the lock (red screen), Omarchy's sleep-lock covers sleep; the user logs out from a TTY | nothing to build beyond 1a | the brief is not met; a locked session cannot be unlocked by the user: a lock-out that needs a technical step |

**SQ-2. When the loop detector trips** (step 1a). Today: 10 starts in 30 s, which a crash slower than 2.0 s per cycle
never reaches (audit 1.2).
| Option | For | Against |
|---|---|---|
| **A. A failure counter in the `OnFailure=` path: 3 failures within 10 minutes enter safe mode; systemd's start limit raised to 10 starts in 5 minutes as the backstop (recommended)** | counts failures, not starts: a deliberate `systemctl --user restart` never counts; catches a 5 s loop in about 20 s and a 3-minute loop in under 10 minutes; a single crash a day never trips | one more small unit (justified above); two numbers to document |
| B. systemd's start limit alone, raised to 10 starts in 5 minutes; safe mode at the limit | one mechanism, systemd's own | a 25 s loop takes 4.5 minutes to stop, a 40 s loop never; manual restarts count toward it; the limit counts starts of the safe unit too unless split |
| C. Keep 10 in 30 s; safe mode at the limit | nothing changes for fast loops | every loop slower than 2.0 s per cycle, the 2026-10-29 one included, goes on for ever |

**SQ-3. How an untested toolkit is kept out of the session** (step 2a; it revisits ADR-0033 s3.4's rejection of
versioned bounds with a removable shape). "Never" is only reachable with a pacman-level refusal; its price is the lag
between Omarchy moving and Grassfield publishing. Rewritten after the review of 2c0bd74 (MAJOR 1): each option is now
mechanically possible, and a hold before the `[grassfield]` repository publishes (ADR-0033 h) would refuse every system
update with no end, so A waits for the publication and B is the floor under it. The reviewer recommends B now and A after
the publication; so does this ADR.
| Option | For | Against |
|---|---|---|
| **B. Now, and the floor under A: detection on every path. The user-side comparison with `BUILD-DEPS` (step 2b) says "Log out to finish updating" after any transaction that moved the toolkit; Update Now keeps the U27 check; `conflicts` on versions found bad after the fact; no hold before the repository exists (recommended now)** | never blocks a security fix; nothing runs as root; no new package; ships without an owner answer | it detects, it does not prevent: on the terminal path the incident can happen again, and the user learns after the reboot, from a crash-looping shell (safe mode then catches it: step 1) |
| **A. Once the repository is published: the hold pair. `grassfield-hold` (`quickshell` at the exact built version, `qt6-base` at its major.minor; never `hyprland`, never `kcoreaddons`), which `grassfield-desktop` depends on, and its empty twin `grassfield-unhold` (`provides` the same name, `conflicts` with it, no bound); "Allow system updates Grassfield hasn't tested…" swaps them in one root transaction through the channel helper's polkit action, "Hold again" swaps them back; the watch job builds against Omarchy's rc channel ahead of stable (recommended after the publication)** | literally never an incompatible combination, on every path, transactionally (nothing half-installed); the matching Grassfield build joins the same transaction; a non-technical exit and return; the 2026-10-29 incident becomes a refused update with the session's own sentence | while Grassfield lags, every system update, Arch's security fixes included, is refused on every path; `omarchy update` in a terminal shows pacman's dependency error (the session's notice says it plainly); two more packages; depends on the watch job being run (ADR-0033 f, disabled while nothing is published) |
| C. `IgnorePkg` lines for the toolkit written by the channel helper | refuses the toolkit only, the rest of the update goes through | a partial upgrade: Arch does not support it (Qt modules and KF6 libraries move together; a mismatch breaks every Qt app, not only Grassfield's); `omarchy update` prints warnings; rejected unless the owner wants it anyway |

**SQ-4. Crash reports** (step 8). macOS keeps them locally and asks before sending any; Grassfield sends nothing.
| Option | For | Against |
|---|---|---|
| **A. The notice gains "Show Report": the local report (text, never the core) opens in a Grassfield window with Copy; nothing is sent; the notice's body no longer names `coredumpctl list` (the reviewer's note on 2c0bd74) (recommended)** | the macOS "Report…" without the sending; the user can paste it into an issue by hand; small (the watcher already has the dump id); no command in the user's face | one more window to review (untrusted text, plain format) |
| B. A crash reporter window like macOS's (Ignore, Report, Reopen) instead of the notice | the exact model | a window that steals attention for every crash, where macOS users expect it but the brief asked for notices; more UI, same data |
| C. Today: the notice with Reopen, `coredumpctl list` named in its body | nothing to build | the body names a command (a technical step, SP-6) |

**SQ-5. Hang detection for the shell** (step 6a). Nothing sees a frozen shell today; `CPUQuota` only keeps the
compositor usable.
| Option | For | Against |
|---|---|---|
| **A. A liveness probe: a user timer every 30 s asks the shell over IPC with a 5 s timeout; three misses kill it with SIGKILL through systemd, so the unit fails and restarts (the lock kept by the compositor), counted by the loop detector: a hang that repeats ends in safe mode (recommended)** | the only observer that is not the shell; no daemon (a timer); 100 s worst case before a frozen desktop comes back | a false restart if the shell is busy for 15 s (a huge Overview under load): the restart is harmless while unlocked, and a red screen while locked (IQ-T5); one more unit |
| B. The compositor extension pings the shell and restarts it | no timer | nested-only by rule (R13), must degrade: no detection without the extension; a restart from inside the compositor is the wrong place for a security decision |
| C. None | nothing to build | a frozen shell stays frozen until the user logs out from a TTY |

**SQ-6. The compositor extension at the login after a compositor crash** (step 6b). A crash inside Hyprland ends the
session whatever its cause; the question is the next login.
| Option | For | Against |
|---|---|---|
| **A. When the latest Hyprland crash report, newer than the last login, names `grassfield-compositor`, the next login loads no extension and says so once, with "Turn On Again" in Settings (recommended)** | the macOS model for a faulty extension; a repeated compositor crash never repeats; the user keeps a working desktop (degraded mode, C2) | a crash the plugin only witnessed (its frames in a stack it did not cause) also turns it off for one login; reading the report's shape depends on Hyprland (data, re-verified per version) |
| B. Always load it (today) | nothing changes; the C1-C3 gates are the defence | a plugin crash that repeats at every login ends every session until the user finds the setting |
| C. Turn it off after any compositor crash, named or not | simplest rule | most compositor crashes are not the plugin's (`docs/audits/final-1.0/09-reliability-audit.md:36`: 7 Hyprland dumps since 2026-10-20, all from nested sessions, 0 in a real session, none attributed); the user loses titlebars and minimize for no reason |

## Decisions taken under the owner's rule (2026-10-28: the closest to macOS 27, no technical step for the end user)
- **SD-1.** Crash reports stay on the machine; nothing is ever sent, with or without SQ-4. The watcher keeps
  `PrivateNetwork=yes`.
- **SD-2.** A process that restarts says nothing (macOS: the Dock relaunches silently); a process that cannot says so
  once, in the session's words, with one action. The shell and the services stay out of the "quit unexpectedly" notices
  (`packaging/bin/grassfield-crash-watch:9`); safe mode's bar and the journal carry the shell's case.
- **SD-3.** The hold, whatever SQ-3 decides, never constrains `hyprland` (ADR-0009: degraded mode and the rebuild).
- **SD-4.** Safe mode never unlocks by itself, never approves, never sleeps unlocked; its menu offers Try Again, Log Out,
  Restart and Shut Down and nothing else; its sentence is "Grassfield is running in safe mode: its desktop stopped
  working and was turned off." (French in the same pull request). Under SQ-1 B its bar is drawn by the security process
  (step 1, S5), with `Grassfield.Ui` only.
- **SD-5.** The chaos and endurance tests run in nested sessions only; the owner's real session gets a read-only check
  list per step (`docs/audits/stability-2026-10-29/owner-checks.sh` from step 7 on), never a driven test. The owner's own
  checks listed per step (step 1's kill of the shell, run by the owner's hand on the owner's machine) are owner-run
  checks, not driven tests (review of 2c0bd74).
- **SD-6.** Nothing of this ADR runs as root on its own after the package is installed, as ADR-0009's amendment says
  ("Nothing in the amended design runs as root after the package is installed",
  `docs/decisions/ADR-0009-plugin-distribution.md:112`): the toolkit change is detected as the user (2b) and every repair
  runs as the user at the next login or at the user's click. The only root code is what the user starts behind a polkit
  dialog: the existing helpers, which step 2a extends by two verbs (`hold`, `unhold`) and one reading of pacman's refusal,
  each under the opus security review (qualified after the review of 5a20d19).
- **SD-7.** The plan's order is the user's exposure: the loop and the lock first, the update second, the proofs third.
  A step's pull request may land before an earlier step's when it waits on an owner answer.
- **SD-8.** Every step adds its regression test to `tests/inventory.json` under its layer; a nested-only proof is
  marked `runner: bare` and recorded in `docs/testing/gates.md` with its date and commit (gates R1, L1, C2, P2, Q3).

## Consequences
- The session gains a second Quickshell process and its unit (the owner's SQ-1 B), one small oneshot unit and one timer,
  and two split packages once the repository is published, all listed above; no alpm hook, no new dependency, no new
  language.
- `grassfield-shell.service`'s start limit, `OnFailure=` list and the sleep-lock gate change under the security review;
  `tests/security/sleep_lock_units.sh` and `unit_restart_limits.sh` grow with them.
- ADR-0010's direction (a separate security process) becomes the decision: step 1 carries its S1-S5; ADR-0010 is amended
  on 2026-10-29 to say so.
- ADR-0033 gains, if SQ-3 chooses A, an amendment that records the hold next to s3.4 and extends f's watch job.
- Known limits written into the specs: a Quickshell bug that takes the security process down in a loop (SQ-1 B); a compositor crash
  ends the session (P-1); while a hold lags, updates wait (SQ-3 A); a Store install may need a system update first (I-5).

## Evidence (this session, main b345334; read-only)
- `git log --oneline -5` → `b345334 Merge fix/hypr-upgrade-reload …`; `git branch --show-current` → `ccr-8628667e-2tyi1h`.
- The spot checks of `docs/audits/stability-2026-10-29/audit.md` section 6 (unit values, the loop arithmetic, the
  `conflicts` line, the tracked packages, the private Qt users, no fuzz harness, the sanitized builds, the inventory
  counts, the watcher's rules, the `GTK_USE_PORTAL` export, the memory slope, the Store's 404 reading, the incident record).
- No graphical session, no Quickshell, no Hyprland here: every runtime statement above is NOT VERIFIED.

## Review history
- **Integrator's opus review of 2c0bd74 (PR #50): FAIL, one MAJOR, eight MINORs, three NITs.** Holds: nothing unlocks or
  weakens the lock trio, IQ-T5 referenced only, nothing sent off the machine, the new units justified, owner-checks.sh
  read-only; its items 1, 2 and 5 run on the owner's machine (x-d-p-gtk 25.5 s, `GTK_USE_PORTAL=1` in the user manager,
  no drop-in: the evidence supports I-4's hypothesis, which stays NOT VERIFIED until the drop-in is tried, step 7;
  `hyprctl` not run, the owner's Hyprland is off-limits). Answered in the commits that
  follow 2c0bd74:
  - MAJOR 1, SQ-3's premise (a hold the desktop depends on cannot be removed with `-R`; one it does not depend on is never
    installed; a `kcoreaddons` bound refuses every monthly KF6; a hold before the repository publishes blocks every update
    with no end): SQ-3 rewritten with the hold pair (`grassfield-hold` / `grassfield-unhold`, `provides` + `conflicts`,
    swapped by the channel helper), `kcoreaddons` dropped, the hold tied to the publication, B recommended now and A after
    it, what the user sees on each path written (step 2a, audit 2.3).
  - MINOR 2, the start-limit arithmetic (the eleventh start is refused, L ≤ 2.0 s): audit 1.2 and its spot check, this
    ADR's finding 1 and SQ-2, STATE.
  - MINOR 3, a probe using `systemctl restart` never reaches safe mode: the probe kills with SIGKILL through systemd
    (step 6a, SQ-5 A).
  - MINOR 4, the Qt private-API risk (the portal links `GuiPrivate` through `files-core.cmake:48`; Quickshell imports 61
    private symbols): audit 2.2's Qt row and this ADR's finding 2.
  - MINOR 5, the bridge has systemd's default start limit (5 in 10 s): audit P-4.
  - MINOR 6, step 2b's root hook against ADR-0009:112 ("Nothing in the amended design runs as root after the package is
    installed"): the hook is gone; detection runs as the user in the shell's checker (step 2b, SD-6, the R5 table).
  - MINOR 7, "7 nested Hyprland dumps" sourced (`09-reliability-audit.md:36`) in SQ-6 C.
  - MINOR 8, the safe unit's `Restart=`, `OnFailure=` and start limit specified (then step 1b; the owner's SQ-1 B moved
    them to `grassfield-security.service`, step 1 S1 and S4).
  - MINOR 9, the extension notices name a command while `windows.rebuildExtension` is off: step 2d plans the notice's
    action; a known limit under SP-6 until then.
  - NITs: SD-5 and step 1's owner check agree (owner-run checks, not driven tests); STATE's note on #48/#49 says their
    keys (112 and 111 zeros) and that there is no collision; owner-checks.sh prints its "(none)" fallback.
  - The reviewer's opinions on the questions are recorded next to each (SQ-1 A once finding 8 is fixed, SQ-2 A, SQ-3 B now
    and A after the publication, SQ-4 A without `coredumpctl list` in the notice, SQ-5 A once finding 3 is fixed, SQ-6 A).
- **Integrator's re-review of 5a20d19: PASS, with doc MINORs and NITs to fix before the merge.** Every earlier finding
  fixed (MINOR 5 in part). Fixed in the commit that follows 5a20d19: the bridge's default limit can never be reached (at
  most 4 starts fit in 10 s with its growing delays; audit P-4); "Hold again" past the bounds is greyed with its reason
  and comes back with the next build (step 2a); the coordination row says 2d amends ADR-0009's "the notice gives the
  command"; Update Now's plan step exits 8 today, so the helper's reading of a hold refusal (exit 6, the U27 path) is
  named as a root-side change under the opus review (step 2a); M-7's "post-transaction marker" wording; SD-6 qualified
  (two root verbs behind polkit); I-4's evidence "supports" the hypothesis, which stays NOT VERIFIED. The reviewer could
  not run the hold pair's scratch-database check (the project's guard blocks package-install commands even with a
  temporary `--dbpath`): reasoned from libalpm and `vercmp`, `--ask 4` = `ALPM_QUESTION_CONFLICT_PKG`; step 2a's first
  container test decides. The integrator is asking the owner SQ-1 to SQ-6; the answers go on PR #50.
- **The owner's answers (2026-10-29, posted on PR #50 by the integrator):** SQ-1 B, SQ-2 A, SQ-3 B now and A after the
  publication, SQ-4 A, SQ-5 A, SQ-6 A, with the integrator's decisions under the owner's rule for SQ-1 B. Recorded in
  "Owner decisions"; step 1 rewritten around S1-S5 in the integrator's order (1a first, the process and its unit, then
  the lock, polkit, idle and the inhibitor one per step, safe mode last; the UI fails closed on missing or stale state;
  memory and start time measured at S1; IQ-T5 applies to the security process); the delivery table, the R5 table, SD-4
  and the consequences follow; ADR-0010 amended. Next: step 1a, then S1.
- **Integrator's re-review of f018b42 (opus): FAIL, one MAJOR in the step-1 plan (two states that could fail open), one
  NIT.** (a) A lost "locked" push with heartbeats still arriving left the UI's refusals open: the heartbeat now carries
  the state and a sequence number, and `SessionState.locked` is the pushed state OR the compositor's own lock signal
  (hyprland-lock-notify-v1, as `Clipboard.qml:28` already does) OR no state OR a stale heartbeat OR a security unit
  that is not active/running. (b) Between the lock's move and the inhibitor's, the UI's `Idle.qml:142` and
  `SleepInhibitor.qml:72, :84` (and `SystemMenu.qml:72`, `SessionState.requestLock`) still called `Lock.lock` in
  process, `OnFailure=` and the gate stayed keyed on the UI, so a sleep with the security process down went unlocked:
  idle and the inhibitor now move with the lock at S2 and every `Lock.lock` caller switches in that step; `OnFailure=`,
  the gate and the stand-in key on the security unit from S2; the invariant of every state is a table at the end of
  step 1. S-steps renumbered S1-S4 (safe mode S4); ADR-0010's amendment and STATE follow. NIT: the SQ-1 row now carries
  the whole sentence.
