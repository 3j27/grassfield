# ADR-0038: Activity Monitor: a native app that shows and stops the user's own processes, on macOS 27's model with the best of Windows 11's Task Manager
Status: Proposed (cloud session, owner brief 2026-10-28, step 0; docs only, no code before the opus PASS). The owner's answers
to AQ1 to AQ7 are recorded in "Owner decisions". Every other choice follows the owner's rule of 2026-10-28 ("the closest to
macOS 27, with no technical step for the end user") and is recorded in "Decisions taken under the owner's rule" (AD1 to
AD24). · Date: 2026-10-28 · Decider: owner (AQ1 to AQ7), integrator (merge after the opus review) · Number: 0038 (0033 to
0037 are merged; 0038 is free on main be7eb7c and on the open pull requests #33 and #35)

The app's visible name is the owner's answer to AQ1 (a legal question). Internal identifiers are neutral whatever the
answer (master-prompt §14): the folder `apps/activity`, the binary `grassfield-activity`, the app id and desktop file
`org.grassfield.Activity`, the QML module and the code say "activity". In this ADR "the app" means it.

Parity with macOS 27 and Windows 11, row by row: `docs/audits/activity-2026-10-28/parity.md`. Behaviour, keyboard,
accessibility, refusals and limits: `docs/specs/activity.md`. Evidence: the probes A0 to A8 of
`docs/audits/activity-2026-10-28/activity-probes.sh`, run in a throwaway `archlinux:base` container, output in
`probes-output.txt` next to it. Legal points are marked "needs legal review" (master-prompt §14); none is a conclusion.

## Context

### The owner's brief (2026-10-28)
- A native app in `apps/` that takes the best of Windows 11's Task Manager with the design and model of macOS 27's Activity
  Monitor.
- From macOS: the window with the CPU, Memory, Energy, Disk and Network tabs; the summary at the bottom of the window,
  memory pressure included; Quit and Force Quit; Inspect a process; the Dock icon that can show a graph.
- From Windows 11: processes grouped (Apps, Background processes); the Performance graphs (CPU per core, GPU, memory, disk,
  network); the app history; efficiency mode; End task from an app's menu in the Dock (Windows: the taskbar); a choice of
  columns; search.
- Constraints:
  - no root code: the app sees and stops only the user's own processes; no new polkit action without the owner's decision;
  - `/proc` and `/sys` read directly, no new dependency;
  - the data of Force Quit and of "Not Responding" (`shell/services/NotResponding*`) reused, never duplicated;
  - the apps that open at login stay in Settings > General > Login Items: a link, not a copy;
  - tokens only, plain text, French translations;
  - the app's own CPU and memory cost measured: a monitor must not be noticed.
- Step 0 (this pull request): this ADR, the spec, the parity matrix and the owner's questions. Then one pull request per step;
  the integrator reviews (opus), runs the nested passes and merges.

### What Grassfield has today
- **Force Quit** (`shell/overlay/ForceQuitPanel.qml`, SUPER+ALT+ESCAPE, `config/hypr/grassfield/bindings.lua:151`): the
  windows by app, "(Not Responding)" in `colors.danger`, a confirmation, then `kill -9` of the window's client pid through
  `Power.run("forcequit")` (`shell/services/Power.qml`), which refuses a pid that no longer owns a window of the chosen class.
- **"Not Responding"** (ADR-0035 D-3): Hyprland runs `hyprland-dialog` when an app misses its pings; Grassfield's stand-in
  reports the pid to `NotResponding.qml` (IPC `anr report`), which keeps one mark per stand-in while it lives. The marks
  are shell state; `anr status` is a dev hook (it returns window titles).
- **The Dock menu** (`shell/overlay/DockMenu.qml`): "Application Not Responding" first for a hung app, then Force Quit in
  place of Quit for its hung processes; Option turns Quit into Force Quit for all its processes (ADR-0035 decision 3-5).
  The Dock already draws an app's progress bar and badge on its tile (ADR-0018, `shell/dock/Dock.qml` `tile.progress`).
- **App launches** (`shell/services/AppLaunch.js:45`, `Apps.scoped`): every app the shell starts runs in its own systemd
  scope through `uwsm-app --`, in `app-graphical.slice` (A7: `app-<first XDG_CURRENT_DESKTOP>-<command basename>-<8 hex>.scope`,
  so `app-Hyprland-firefox-1a2b3c4d.scope` in the Grassfield session, ADR-0001).
- **Login Items** (`apps/settings/qml/LoginItemsPage.qml`, General > Login Items): the XDG autostart entries with switches
  and the user's own systemd services ("Allow in the Background"). Settings opens on a pane with `--section=login`
  (`shell/services/SettingsApp.qml:21`).
- **App to shell**: an app calls the running shell with `qs ipc -p <shell dir> call …` (`apps/runmode.h` `shellIpcArgs`);
  the IPC surface is the table of `docs/specs/security.md` "IPC surface", checked by `tests/security/ipc_inventory.sh`.
- **Omarchy 4.0.4** (data): its "Activity" is btop in a terminal (SUPER+CTRL+T, `default/hypr/bindings/utilities.lua:103`);
  the Grassfield session does not load Omarchy's bindings. Omarchy swaps to zram (`zram-size = ram`, zstd,
  `default/systemd/zram-generator.conf.d/90-omarchy.conf`) and turns zswap off (`etc/tmpfiles.d/omarchy-zswap.conf`).

### What the kernel lets a user read and do (probes, kernel 6.18.44; `probes-output.txt`)
| What | Own process | Another user's process, or an own non-dumpable one | Cost (A8) |
|---|---|---|---|
| `/proc/<pid>/stat`, `statm`, `status`, `cmdline`, `comm`, `cgroup`, `sched`, `limits`, `task/` | read (A1) | read (A1) | 6 to 10 µs per file |
| `/proc/<pid>/io` (bytes read and written by the storage layer) | read | refused (EACCES) | 6 to 8 µs |
| `/proc/<pid>/smaps_rollup` (proportional and private memory) | read | refused | **3.6 ms** for a 1 GiB process |
| `/proc/<pid>/fd/`, `fdinfo/` (open files, sockets, GPU clients), `exe`, `cwd`, `maps`, `environ` | read | refused | a readlink per descriptor |
| signal (`kill`, `pidfd_send_signal`) | allowed (A2) | refused (EPERM) | — |
| a pidfd on a process that ended | `pidfd_send_signal` fails with ESRCH: a pid reused since cannot be hit (A2) | — | — |
| raise the nice value | allowed; **lowering it back is refused** (EACCES) under RLIMIT_NICE 0 (A3) | — | — |
| `SCHED_IDLE` | allowed; **back to `SCHED_OTHER` refused** (A3) | — | — |
| I/O class idle (`ioprio_set`) | allowed, and back to best-effort allowed (A3) | — | — |
| `/proc/stat`, `meminfo`, `vmstat`, `loadavg`, `uptime`, `diskstats`, `net/dev`, `net/tcp`, `net/udp`, `swaps`, `cpuinfo`, `pressure/{cpu,memory,io}`, `/sys/block/*/stat`, `/sys/block/zram0/mm_stat` | read (A4) | (system-wide files) | — |
| TCP bytes and segments per socket (`NETLINK_SOCK_DIAG` with `tcp_info`, what `ss -ti` reads) | read, with the owning process found through the own `/proc/<pid>/fd` (A5) | the socket's counters are visible, its process is not | one netlink dump |
| UDP bytes per socket | the kernel's answer has no byte counters (A5) | — | — |

### What the session gives (A6, A7; not product code)
- systemd 262 delegates `pids memory cpu` to the user manager (`user@.service`: `Delegate=pids memory cpu`), not `io`.
- When a unit stops, systemd 262 logs "Consumed %s CPU time" with `MESSAGE_ID=ae8f7b866b0347b9af31fe1c80b127c0` and
  structured fields (`CPU_USAGE_NSEC=`, `IO_METRIC_*`, `IP_METRIC_*`; the I/O and IP fields need accounting the user manager
  does not have).
- uwsm 0.27.1 names an app's scope as above; `UWSM_APP_UNIT_TYPE` may make it a service instead.

### Not verified here (read-only checks on the owner's machine at the step that needs them; listed in the spec)
- GPU per process from `/proc/<pid>/fdinfo` (`drm-engine-*`, `drm-memory-*`) on the owner's i915 (this cloud machine has no
  GPU).
- RLIMIT_NICE in the owner's session; the `cpu` controller in `app-graphical.slice`; the user journal holding the resource
  records of app scopes; Hyprland's client list carrying `inhibitingIdle`; UPower's history on the laptop.

## Decision

### Overview
One Qt 6 / QML app on Grassfield.Ui, `apps/activity`, packaged in `grassfield-desktop` (like Settings, Files and Preview:
it has no root part). No daemon, no service, no root code, no polkit action, no new dependency (Qt Core, Gui, Qml, Quick
and DBus, which Settings and the Store already use; `journalctl` and `systemd` are part of the base system). A C++ sampler
reads `/proc` and `/sys` on a thread of its own; QML draws the window with tokens only. The shell gains two small links:
it publishes its windows and "Not Responding" marks for the app (a projection, not a copy of the logic), and it draws the
app's Dock tile graph from numbers the app writes.

### a. The window (macOS 27's structure, ADR-0024 material)
- One main window: the unified toolbar (ADR-0015) with the traffic lights, the title and the current view as subtitle
  ("All Processes"), the Stop button (Quit Process), the Info button (Inspect), the action menu (…), a segmented control
  CPU / Memory / Energy / Disk / Network, and the search field. Under it, the process table; at the bottom, the tab's summary
  (figures and a graph). The window is opaque (§5.5); the toolbar's scroll-edge glass follows ADR-0024 phase 3.
- Menus: Activity Monitor, File, Edit (Copy, Select All, Find), View (Columns, Dock Icon, Update Frequency, the process
  filters, Clear CPU History, Inspect Process, Quit Process, Send Signal to Process…, Efficiency Mode), Window (Activity
  Monitor, CPU Usage, CPU History, GPU History, Performance, App History, Login Items…), Help. Exported to the menu bar
  through the apps' T1 path (`apps/globalmenu.h`).
- Small windows of the Window menu: CPU Usage (one bar per logical processor), CPU History (one graph per logical
  processor), GPU History (one graph per GPU) as on macOS; **Performance** and **App History** come from Windows 11 (g).

### b. What is measured, and from where
Formulas and edge cases are the spec's (AM20 to AM49); the sources are:
| Tab | Columns (default first) | Source |
|---|---|---|
| CPU | % CPU, CPU Time, Threads, % GPU, GPU Time, PID; optional Wake Ups, Open Files, Status, Command, Kind | `stat` (utime + stime of the whole thread group, `num_threads`), `fdinfo` of the DRM descriptors, `task/*/status` (voluntary switches) |
| Memory | Memory, Threads, PID; optional Real Memory, Private Memory, Shared Memory, Compressed Memory, Peak Memory, Page Ins | `status` (`RssAnon`, `RssFile`, `RssShmem`, `VmSwap`, `VmHWM`), `stat` (`majflt`) |
| Energy | Energy Impact, Preventing Sleep, PID; optional Average Energy Impact, Wake Ups, % GPU | the CPU and GPU terms above, logind's inhibitors (system bus), the shell's idle-inhibit flag |
| Disk | Bytes Written, Bytes Read, PID; optional Read/s, Written/s | `io` (`read_bytes`, `write_bytes`) |
| Network | Sent Bytes, Rcvd Bytes, Sent Packets, Rcvd Packets, PID (AQ2) | `NETLINK_SOCK_DIAG` (`tcpi_bytes_acked`, `tcpi_bytes_received`, `tcpi_segs_out`, `tcpi_segs_in`) and the own `fd/` |
| Summaries | CPU: System, User, Idle, CPU Load graph, Threads, Processes. Memory: Memory Pressure graph, Physical Memory, Memory Used (App Memory, Wired Memory, Compressed), Cached Files, Swap Used. Energy: Energy Impact graph, and on a laptop Remaining charge, Time remaining or Time until full, Time on battery or on AC, Battery (Last 12 hours). Disk: Reads in, Writes out, Reads in/sec, Writes out/sec, Data read, Data written, Data read/sec, Data written/sec, graph IO or Data. Network: Packets in, Packets out, Packets in/sec, Packets out/sec, Data received, Data sent, Data received/sec, Data sent/sec, graph Packets or Data | `/proc/stat`, `loadavg`, `meminfo`, `pressure/memory`, `swaps`, `/sys/block/zram*/mm_stat`, `diskstats` (whole physical disks), `net/dev` (every interface but `lo`), UPower (system bus) |
macOS meanings are kept where Linux has them: "User" is the CPU of the user's own processes and "System" everything else
that is not idle (AD5), "Compressed" is zram's RAM and "Swap Used" the swap on disk (AD7). A figure Linux cannot give is
not invented (R11): it is absent, or "—" for a process that refuses the read.

### c. Which processes (AQ4)
The table lists the processes whose real uid is the user's (`status` `Uid:`), kernel threads excluded, as the owner's
constraint says, unless AQ4 decides otherwise. The summaries and graphs are system-wide (`/proc/stat`, `meminfo`, …), so
the totals stay true. Actions apply to the user's processes only (the kernel enforces it: A2).

### d. Sampling and its cost
- One sampler thread, woken by one timer at the update frequency: View > Update Frequency, Very Often (1 sec), Often (2 sec),
  Normally (5 sec), **Normally by default** (Apple's guide for macOS 27: "every 5 seconds" by default).
- Only what is shown is read (AD10): the common per-process files (`stat`, `status`) each sample; `io` only when a disk
  column or the Energy tab is shown; descriptor scans (GPU clients, sockets) only for the GPU columns, the Network tab and
  Inspect, with each process's descriptor list re-read at most every 10 s and when the process is new; `smaps_rollup` never in
  the table (3.6 ms per read, A8), only in Inspect; per-thread files only for Wake Ups, when that column is shown.
- Open `/proc` files are kept and re-read with `pread` at offset 0 while the process lives (fewer system calls); the
  step measures it against plain opens and keeps the cheaper.
- The window hidden or minimized: no per-process sampling. With a Dock graph (f), only the system file the graph needs, at
  the update frequency. Nothing else wakes the app.
- **Budget, measured by `tests/apps/activity_cost.sh` (AM-P1 to AM-P4):** with about 400 processes, the window visible on
  the CPU tab, the app's own CPU (its `utime + stime` over 10 minutes) stays ≤ 0.5 % of one core at the default 5 s and ≤ 1.5
  % at 1 s; ≤ 0.1 % minimized with a Dock graph at 5 s; one sample of the sampler costs ≤ 5 ms of CPU; the app's PSS stays ≤
  120 MB and grows by < 5 MB over one hour. The app lists itself, as macOS does, so the user sees its cost too.

### e. Quit, Force Quit and signals (no root; macOS sheet)
- The Stop button and View > Quit Process open macOS's sheet: "Are you sure you want to quit this process?", with Cancel,
  Force Quit and Quit (Quit is the default button).
- **Quit** is the safe one (macOS: "quits when it's safe to do so"): for a process with windows, the shell closes its windows
  (new IPC action `activity quit`, the same path as the Dock's Quit: the app can save or ask), never a signal; for a process
  without windows, `SIGTERM`. **Force Quit** is `SIGKILL`.
- Every signal goes through a pidfd opened when the sheet opens, after checking that the process still has the start time
  (`stat` field 22) of the row: a process that ended makes the call fail (ESRCH, A2), so a reused pid is never hit. This is a
  stronger check than the Force Quit panel's window class, and it needs no window.
- View > Send Signal to Process…: macOS's sheet with a pop-up of the usual POSIX signals, then Send; the same pidfd path.
- Grassfield's own session processes (the compositor, the shell, the menu bridge, the user manager) can be force quit
  only after a second sheet that names the consequence ("Your session will end" for the compositor); no user loses a
  session to one click.

### f. With the shell: Not Responding, windows, the Dock, Force Quit (AQ5, AQ6)
- **Projection, not duplication.** While a window with app id `org.grassfield.Activity` is open, the shell writes
  `$XDG_RUNTIME_DIR/grassfield/activity/windows.json` (0600 in the 0700 runtime folder): `{"v":1,"windows":[{"pid","app",
  "idleInhibit"}],"notResponding":[pid,…]}`, from `Compositor.knownWindows()` (Hyprland's list read again when a window
  opens or closes) and `NotResponding.marks`, coalesced over 250 ms, at most 256 windows. No title (the anr dev hook
  keeps titles private). The app watches the file (inotify through `QFileSystemWatcher`): no polling, no second
  "not responding" detector. The app shows "(Not Responding)" in red after the name (macOS) and "Not Responding" in the
  optional Status column (Windows). Without the shell (absent, crashed) the file is gone or stale (its writer pid is in it):
  no row is marked and Quit of a process in an app scope is not offered (Force Quit still is).
- **IPC action `activity quit <pid>`** (class action, caller `grassfield-activity`; security.md table): the shell closes every
  window whose client pid is that pid, as the Dock's Quit; it answers `ok`, `no-windows` or `refused` and never kills.
- **Dock tile graph** (macOS View > Dock Icon: Show Application Icon, Show Network Usage, Show Disk Activity, Show CPU
  Usage, Show CPU History): the app writes `$XDG_RUNTIME_DIR/grassfield/activity/dock-tile.json` at the update frequency
  (`{"v":1,"pid","kind","samples":[…]}`, values 0 to 1 the app has scaled, at most 32 samples, at most 2 KiB); the Dock
  draws it with tokens over the `org.grassfield.Activity` tile while that app runs (it reads no other path and no other app
  id: no app can draw on another app's tile). The image is never written by the app (no pixels to trust, no decode cost).
- **Force Quit panel and Dock menu:** AQ5. **Keyboard shortcut:** AQ6.

### g. From Windows 11 (in the Grassfield structure)
- **Processes, by Type** (View menu; Windows' "group by type"): Apps (processes in `app-graphical.slice` scopes or that own a
  window, one group per scope, named and drawn with its desktop entry), Background Processes (the user's services and
  everything else), Session Processes (the compositor, the shell and the other units of the session's slices and the
  user manager). Groups expand to their processes; a group's row sums them. macOS 27's "Processes, by GPU" groups by GPU.
- **Performance** (Window menu): a sidebar of resources with a small graph each (CPU, Memory, each physical disk, each
  network interface, each GPU) and the selected one's large graph and details (Windows' Performance page in macOS 27's
  window structure). CPU: overall or one graph per logical processor; speed, cores, logical processors, caches, up time,
  processes, threads. Memory: in use, available, committed, cached, compressed, swap, composition bar. Disk: active time,
  read and write speed, average response time, capacity, SSD or HDD. Network: send and receive throughput, interface, kind,
  addresses. GPU: one graph per engine (render, video, copy) from the user's GPU clients, memory where the driver reports it.
- **App History** (Window menu): per app, CPU time, memory peak when recorded, number of launches and last use, over the
  last 12 hours (macOS's "Applications in last 12 hours" span), 7 days or 30 days, from systemd's own record of each app scope
  that stopped (the user journal, `journalctl --user`, read when the window opens) plus the live scopes' `cpu.stat`. Delete
  Usage History stores a cut-off date in the app's state; the journal is never written. No collector runs in the background.
- **Efficiency Mode** (View menu, the action menu and the row's context menu): the lowest CPU weight on the process's own
  app scope or user service, through the systemd user manager on the session bus (`SetUnitProperties`, runtime only,
  reverted by the same call): reversible, no root, unlike `nice` and `SCHED_IDLE` (A3). It applies to the whole app (Windows
  applies it to a group too) and says so in a first-time sheet ("Don't ask again"). Unavailable, with the reason, for a
  process outside such a unit and for the session's own processes. Status column: "Efficiency Mode".
- **Columns** (View > Columns and the header's context menu), **search** (process name, app name, command, PID), **Copy**
  of the selected rows as text, and the Status column.
- **Login Items…** (Window menu): opens Settings on General > Login Items (`grassfield-settings --section=login`). Nothing
  of it is copied into the app.

### h. Not built (the parity matrix gives each reason)
Sample Process, Run Spindump, Run System Diagnostics (no unprivileged stack sampling; Yama), the Cache tab (no content
cache), App Nap and Graphics Card (no Linux counterpart), 12 hr Power (no 12-hour record without a background sampler; the
Energy tab has an average since the app opened instead), Windows' Users, Details (it is the main table), Services (Settings
has the user's services), Run new task (Search and Apps start apps), Set priority and Set affinity (one-way without root,
A3), Create dump file, Search online, heat-map cells, Paused update speed, and processes of other users beyond AQ4.

### i. Security and privacy
- Nothing runs as root; no polkit action; nothing is sent anywhere. The kernel refuses every action on another user's
  process (A2).
- Command lines are shown for the user's own processes only (what `ps` shows); environment variables are never read.
- The projection holds pids and app ids (any local process of the user reads `hyprctl -j clients` already, ADR-0035
  decision 3-14); the Dock tile file holds numbers. Both live in the 0700 runtime folder and go when their writer stops.
- Dev sessions (ADR-0019): the app runs in the owner's account and sees the owner's real processes. In a dev session every
  action (signals, Quit, Efficiency Mode) is refused for a process that does not descend from the nested compositor or a
  test fixture, with a "dev guard" journal line (as Settings' guard); efficiency mode is refused for every unit not named
  by a test.

### j. Files (rows added to ADR-0020 in the step that writes them)
- `activity.json` (state, version 1, the app only): window frames, tab, view, columns and sort per tab, update frequency,
  Dock icon, Efficiency Mode's "Don't ask again", App History's cut-off.
- `activity/windows.json` and `activity/dock-tile.json` (runtime, 0600): above; removed when their writer stops.

## Owner decisions (asked 2026-10-28 with AskUserQuestion; each option with its pros and cons)

**AQ1. The app's name (needs legal review).**
| Option | For | Against |
|---|---|---|
| A. « Moniteur d'activité » / "Activity Monitor" | the macOS name, which users look for; the same footing as "Preview" / « Aperçu », kept by the owner (L1) | Apple's app name: trade-dress risk on the list (§14, docs/legal/visual-review.md) |
| B. « Activité » / "Activity" | short, close to macOS, Omarchy already calls btop "Activity" | further from macOS; collides in words with Omarchy's btop entry if both are shown |
| C. « Moniteur système » / "System Monitor" | the generic Linux name (GNOME, KDE), lowest resemblance | not macOS; two different apps on Linux already carry it |
| D. « Gestionnaire d'activité Grassfield » / "Grassfield Activity" | own name, like "Grassfield Store" | long in the Dock and the menu bar |
Answer: _recorded below after the questions_.

**AQ2. Network use per process** (no root).
| Option | For | Against |
|---|---|---|
| A. TCP only, labelled (Sent Bytes and Rcvd Bytes headed "(TCP)", a line under the table: "UDP traffic, such as some video, is counted only in the totals") | real per-process numbers without root (A5); the culprit of a download is found | UDP (QUIC) is missing; a connection that opens and closes between two samples is missed; counts start when the app opens |
| B. No per-process network: the tab shows the system totals and graph only | nothing partial on screen | the Network tab's table is empty of network data (PID, name only) |
| C. A root helper (eBPF or packet capture) | complete numbers | contradicts the brief (no root code, no new polkit action) |

**AQ3. Energy per process** (no root).
| Option | For | Against |
|---|---|---|
| A. Energy Impact as macOS: a relative index without unit, computed from CPU, wake-ups, GPU and disk; Preventing Sleep from logind and the shell; battery figures and the 12-hour battery graph from UPower | macOS's own Energy Impact is a computed estimate too ("lower is better"); real inputs | Grassfield's weights are its own, calibrated on the owner's laptop; a desktop without battery shows the index and Preventing Sleep only |
| B. No index: the Energy tab shows CPU, wake-ups, Preventing Sleep and the battery | no model to calibrate | not the macOS tab; nothing ranks the apps by energy |
| C. Measured watts per process (RAPL, powertop) | measured | RAPL counters are root-only since 2020; a root helper is excluded |

**AQ4. Other users' processes** (root's services, other accounts).
| Option | For | Against |
|---|---|---|
| A. Hidden, as the brief says: only the user's processes; the totals stay system-wide | the brief; nothing to explain about rows the user cannot act on | the per-process CPU does not add up to "System" (the difference is root's and the kernel's work) |
| B. Shown read-only, as macOS's "All Processes" (View > My Processes, System Processes, Other User Processes): name, CPU, memory, user; actions greyed | closest to macOS; the user sees which service eats the CPU | reading other accounts' command lines; disk, network, GPU and Inspect show "—" for them (A1); contradicts the brief |
| C. One aggregated row "Other Users and System" | the totals add up; no foreign details | a row that cannot be expanded or acted on |

**AQ5. The Dock and Force Quit.**
| Option | For | Against |
|---|---|---|
| A. macOS model only: the Dock tile graph; the Dock menu unchanged (Force Quit with Option, or at once for a hung app); the Force Quit panel unchanged | macOS 27 exactly; no new item | Windows' End task is not added |
| B. A + Windows' "End Task" in every running app's Dock menu, behind a switch in Settings > Desktop & Dock, off by default | Windows' feature for those who want it, invisible otherwise | one more setting; End Task is Force Quit under another name |
| C. A + an "Activity Monitor…" button in the Force Quit panel (bottom left) | a path from the panel to the details, as Windows' "More details" | not on macOS |
| D. B and C | both additions | both costs |

**AQ6. Keyboard shortcut to open the app.**
| Option | For | Against |
|---|---|---|
| A. Ctrl+Shift+Esc (Windows) | known by every Windows user; free in Grassfield's bindings; apps rarely use it | not a macOS shortcut (macOS has none for Activity Monitor) |
| B. None (macOS): Search, Apps and the Dock open it | macOS exactly | slower to reach when something hangs |
| C. Super+Shift+Esc (next to Force Quit, Super+Alt+Esc) | the Grassfield (Command) family | nobody knows it yet |
| D. Super+Ctrl+T (Omarchy's "Activity") | Omarchy users' habit | Omarchy's key for btop; unrelated to Escape and Force Quit |

**AQ7. The order of the steps** (each one pull request, reviewed and merged before the next).
| Option | For | Against |
|---|---|---|
| A. macOS first: 1 sampler (no window) with its cost gate; 2 the window, its five tabs, Quit and Force Quit, Inspect; 3 the shell links (Not Responding, Quit through the shell, Dock graph, AQ5, AQ6); 4 Windows' additions (by Type, Performance, Efficiency Mode, App History, Login Items link); 5 the small windows and the finish (F1, A2, cost re-measured) | the cost is proven before any UI; a usable app at step 2 | the Windows features come last |
| B. Shell links early: 1 sampler; 2 the shell links and the Dock graph; 3 the window; 4 Windows; 5 finish | Not Responding and End Task reach the Dock sooner | the Dock graph before the app the user sees |
| C. Windows first: 1 sampler; 2 the window with Performance and by Type; 3 macOS's tabs; 4 shell; 5 finish | the Windows graphs early | the macOS model, the owner's rule, comes late |

### Answers
_Filled after the owner answers (2026-10-28)._

## Decisions taken under the owner's rule (2026-10-28: the closest to macOS 27, no technical step for the end user)
- **AD1. One app, no daemon.** The app samples only while it runs; App History reads systemd's records rather than a
  collector of ours (R5, §5.8).
- **AD2. Package.** `grassfield-desktop` (no root part, unlike `grassfield-store`); desktop entry `org.grassfield.Activity`,
  Categories `System;Monitor;`; a Grassfield icon of its own (branding, CC-BY-SA-4.0, L2), never Apple's art.
- **AD3. Default update frequency: Normally (5 sec)**, Apple's default; Very Often (1 sec) and Often (2 sec) offered. No
  "Paused" (Windows).
- **AD4. % CPU is a share of one core** (macOS; can exceed 100 % for a process with several busy threads), not of the whole
  machine (Windows).
- **AD5. System and User as macOS means them:** User = the CPU of the user's processes (the sum of their shares), System =
  every other non-idle CPU (`/proc/stat`), Idle = the rest. A process that ended between two samples moves its last slice to
  System (a known limitation).
- **AD6. Memory column = private footprint** (`RssAnon + VmSwap`), the nearest to macOS's "Memory" and Windows' private
  working set; Real, Private, Shared, Compressed and Peak are optional columns; PSS only in Inspect (A8).
- **AD7. Memory summary:** Physical Memory `MemTotal`; Memory Used `MemTotal − MemAvailable`; Compressed = zram's RAM
  (`mm_stat` `mem_used_total`); Wired = `SUnreclaim + KernelStack + PageTables + Unevictable`; App Memory = Memory Used −
  Wired − Compressed, so the three add up as on macOS; Cached Files = `Active(file) + Inactive(file)`; Swap Used = swap
  in use on devices that are not zram (`/proc/swaps`). The Compressed Memory column is titled "Swapped Memory" when a
  disk swap is in use too.
- **AD8. Memory Pressure:** the graph's height is the memory in use; its colour is green, yellow or red from the kernel's
  pressure stall information (`/proc/pressure/memory`) and the memory left (thresholds in the spec, AM33).
- **AD9. GPU** from `fdinfo` (`drm-engine-*`): % GPU = the busiest engine of the process, GPU Time = the sum of its engines;
  the system's GPU graphs sum the user's clients (the compositor is one of them). A driver without these keys shows no GPU
  column ("—").
- **AD10. Read only what is shown** (d). A process the kernel refuses a read for (non-dumpable) shows "—" in that column.
- **AD11. Quit through the shell for windowed processes**, `SIGTERM` otherwise; Force Quit `SIGKILL`; pidfd and start time.
- **AD12. Send Signal to Process…** kept (macOS); its list is the usual POSIX signals with plain names.
- **AD13. Inspect** (Info button, Ctrl+I): macOS's window "<name> (<pid>)": Parent Process, Process Group, User, % CPU,
  Recent hangs (marks seen since the app opened); tabs Memory, Statistics, Open Files and Ports (files, pipes, sockets with
  their addresses from `/proc/net/*`); Quit. No Sample button (h).
- **AD14. Views (View menu):** All Processes (default), All Processes, Hierarchically, Processes, by Type (g), Processes,
  by GPU, Active Processes, Inactive Processes, GPU Processes, Windowed Processes, Selected Processes; My Processes, System
  Processes and Other User Processes only if AQ4 is B.
- **AD15. Search** is a live filter, as macOS; matches the process name, the app name, the command and the PID.
- **AD16. Dock Icon** offers macOS's five items; "Show Memory Pressure" is not offered (no source confirms it on macOS).
- **AD17. The app quits when its last window closes** (the Grassfield Dock knows running apps by their windows), so the Dock
  graph shows while the window is open or minimized (macOS keeps the app running without a window: known limitation).
- **AD18. Performance and App History are windows of the Window menu**, not tabs: the five macOS tabs stay as they are.
- **AD19. Efficiency Mode** through the user manager's CPU weight (g); refused, with the reason, where it cannot apply.
- **AD20. App History's source** is the user journal's resource records of app scopes plus the live scopes; the app
  matches a scope to a desktop entry by its command (uwsm's unit name, A7).
- **AD21. Projection file and Dock tile file** (f) rather than IPC polls: no process is started per sample, no wake-up
  without a change.
- **AD22. Session processes** (compositor, shell, menu bridge, user manager): Force Quit asks twice; Efficiency Mode
  refused.
- **AD23. Keep CPU Windows on Top** (macOS Window menu) through a toplevel tag (ADR-0015's `xdg-toplevel-tag` helper) and a
  rule of the Grassfield session's Hyprland config; without the rule, the item is absent.
- **AD24. Tables and graphs** reuse Grassfield.Ui (tokens, `SegmentedControl`, `SearchField`, `PopupMenu`, `Sheet`) and the
  list header of Files (`apps/files/qml/FileList.qml`); a shared table component moves into Grassfield.Ui only if the
  step's code is the same in both apps (R5).

## Delivery order
_Per AQ7; recorded after the answers._

## macOS reference (Apple's Activity Monitor User Guide, macOS 27 in its version selector, read 2026-10-28; facts only)
Five tabs CPU, Memory, Energy, Disk, Network; the bottom of the window summarises each one (System, User and Idle for the
CPU; Physical Memory, Memory Used, App Memory, Wired Memory, Compressed, Cached Files and Swap Used with the Memory
Pressure graph; Remaining charge, Time remaining, Time on battery and Battery (Last 12 hours) on laptops; Reads in, Writes
out, Data read, Data written and their rates; Packets in, Packets out, Data received, Data sent and their rates). View
menu filters: All Processes; All Processes, Hierarchically; My Processes; System Processes; Other User Processes; Active
Processes; Inactive Processes; GPU Processes; Windowed Processes; Selected Processes; Applications in last 12 hours;
Processes, by GPU. Columns by View > Columns; search field; Info button or a double-click for a process's details; the
Stop button offers Quit ("quits when it's safe to do so") and Force Quit; a hung process is "(Not Responding)" in red;
View > Send Signal to Process; Window > CPU Usage, CPU History, GPU History; View > Dock Icon puts a live CPU, network or
disk graph in the Dock; the default update is every 5 seconds.

## Windows 11 reference (described in words; Microsoft's own pages were not found by the search, third-party descriptions used, marked in the parity matrix)
Task Manager (Ctrl+Shift+Esc): a navigation pane with Processes, Performance, App history, Startup apps, Users, Details,
Services and Settings; a search box for name, publisher or PID. Processes grouped as Apps, Background processes and
Windows processes, groups expandable; columns chosen from the header (Status, CPU, Memory, Disk, Network, GPU, Power usage,
…). Performance: CPU (overall or per logical processor), Memory, Disk, Network and GPU graphs with details. App history:
resource use per app since a date, with Delete usage history. Efficiency mode (22H2): lowers a process's priority and its
power class, toggled from the command bar, refused for core Windows processes. End task in the taskbar's menu: a switch
under Settings > System > For developers (Advanced on 25H2), off by default.

## Alternatives rejected
- **A shell surface instead of an app:** the owner asked for a native app in `apps/`; a shell surface would sample inside
  the shell process (gates P1, P2) and could not be closed.
- **Reading Hyprland from the app** (`hyprctl -j clients` each sample): only the shell's platform layer talks to Hyprland
  (§5.2, §5.4), and a poll would wake Hyprland's request socket every second.
- **A second "not responding" detector** (pinging windows from the app): the brief forbids duplicating NotResponding.
- **`nice` or `SCHED_IDLE` for Efficiency Mode:** one-way without root (A3).
- **PSS (`smaps_rollup`) as the Memory column:** 3.6 ms per read of a 1 GiB process (A8): a browser would cost tens of
  milliseconds per sample.
- **A background collector for App History and 12 hr Power:** a new service (R5, §5.8); systemd already records each app's
  CPU time when it stops.
- **The app drawing its Dock tile as an image:** arbitrary pixels on a system surface and a decode per sample; numbers drawn
  by the Dock are cheaper and cannot imitate another tile.

## Evidence
- `docs/audits/activity-2026-10-28/activity-probes.sh` and `probes-output.txt` (docker exit 0): A1 the `/proc` read matrix
  as an unprivileged user (own, another user's, own non-dumpable, root's); A2 signals and pidfds (EPERM on another user's
  process, ESRCH after the target ended); A3 nice and `SCHED_IDLE` one-way under RLIMIT_NICE 0, I/O class reversible; A4 the
  system files; A5 TCP byte counters per socket with the owner process for the user's own sockets, none for UDP; A6 systemd
  262's delegation and resource record; A7 uwsm 0.27.1's scope name; A8 the cost of each `/proc` read.
- Code read: `shell/services/NotResponding.qml` and `.js`, `shell/overlay/ForceQuitPanel.qml`, `shell/overlay/DockMenu.qml`,
  `shell/services/Power.qml`, `shell/services/AppLaunch.js`, `shell/services/SettingsApp.qml`,
  `apps/settings/qml/LoginItemsPage.qml`, `apps/runmode.h`, `config/hypr/grassfield/bindings.lua`.
- Omarchy v4.0.4 (c668141, data): the btop binding, zram and zswap files named above.

## Consequences
- New: `apps/activity/` (C++ sampler and model, QML window), `tests/unit/activity/` (gtest with fixture `/proc` trees: every
  formula, every refusal), `tests/apps/activity_cost.sh` (the budget), `tests/apps/activity_*.sh` (offscreen), a nested
  scenario (Not Responding, Quit through the shell, the Dock graph), translations, the icon, the PKGBUILD lines.
- Shell: a projection writer and the IPC action `activity quit` (security.md "IPC surface", `ipc_inventory.sh`), the Dock
  tile graph in `shell/dock/Dock.qml`, AQ5's items, AQ6's binding in `config/hypr/grassfield/bindings.lua`.
- Docs: ADR-0020 rows (j); `docs/specs/security.md` (the IPC row); `docs/legal/visual-review.md` (a new element for the
  app, its name per AQ1, "needs legal review"); `docs/specs/dock.md` (the tile graph); `docs/specs/settings.md` if AQ5 adds a
  switch.
- Gates: P1 and P2 are the shell's and unchanged except the projection writer (measured); the app's own budget is AM-P1 to
  AM-P4; A1, A2, I1, Q1 to Q3 and F1 apply as for every app.
