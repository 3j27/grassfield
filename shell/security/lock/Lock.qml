pragma ComponentBehavior: Bound
pragma Singleton
// Portions adapted from Omarchy shell/plugins/lock/Service.qml (omacom/omarchy, branch quattro),
// Copyright (c) David Heinemeier Hansson, MIT License (upstream LICENSE, basecamp/omarchy v4.0.4; notice shipped as
// packaging/licenses/omarchy-MIT.txt): the PamContext prompt/response wiring and the
// WlSessionLock secure-state handling; the stranded-lock signal (LOCK in solitaryBlockedBy) comes
// from Omarchy's omarchy-hyprland-session-locked. Upstream base reviewed against Omarchy v4.0.6
// (basecamp/omarchy@237f1b4071a0bff2296c6d740ba2b9fd695ebfa0, shell/plugins/lock/Service.qml): its
// currentlyLocked() fix (a binding that missed a change notification made a lock before suspend look done) is
// ported as currentlyLocked()/currentlySecure() below; its v4.0.5 stranded-lock change (no takeover while another
// locker process runs, basecamp/omarchy@94a8fbc2d67eec5673c7f16b8c5e8a9c8452ffdc) is not: see checkStranded() and
// docs/specs/security.md "Upstream base".
import QtQuick
import Quickshell
import Quickshell.Hyprland // layering-exception: ADR-0021 security
import Quickshell.Io
import Quickshell.Services.Pam
import Quickshell.Wayland
import Grassfield.Ui
import qs.security
import qs.services
import "../LockMachine.js" as Machine
import "../../lib/RunMode.js" as RunMode

// Session lock (ADR-0010, master-prompt R12): ext-session-lock through WlSessionLock, password
// checked by PAM service "omarchy-lock-password" (no PAM file of ours). Only a PAM success
// unlocks; every error, timeout or lost lock keeps the session locked.
//
// Lock survival, fail closed (docs/specs/security.md "Lock survival"):
// - Crash: Hyprland keeps the session locked when this process dies (ext-session-lock; its
//   "lockscreen app died" screen, no input reaches clients). The restarted shell re-takes the lock
//   (misc.allow_session_lock_restore = true) when the marker in $XDG_RUNTIME_DIR (one per
//   compositor instance) says anything but "unlocked", when the machine slept since that "unlocked"
//   was written (the marker records the kernel's count of completed suspends: no shell could lock for
//   that sleep, Machine.sleptSince), when XDG_RUNTIME_DIR is unset
//   (nothing can prove the session unlocked), or when Hyprland reports a lock this instance did
//   not take (forged or missing marker): see strandedProbe.
// - Soft reload (Quickshell.reload(false)): the new WlSessionLock inherits the old instance's lock
//   in WlSessionLock::onReload and RELEASES it if its `locked` is false at that moment. The lock
//   intent is therefore carried over in `persist` (PersistentProperties), which Quickshell restores
//   before sessionLock reloads, and the marker is also checked in Component.onCompleted, which runs
//   before the reload pass. File watching is off (shell.qml), so only an explicit reload can happen.
// A fresh session (no marker, no carried intent) starts unlocked: if a marker was removed while
// locked, the compositor still holds the dead client's lock and strandedProbe re-acquires it.
//
// Lock ownership (docs/specs/security.md "Lock ownership and foreign lockers"): Hyprland 0.56 with
// misc.allow_session_lock_restore hands a LIVE session lock to the next client that asks and tells
// the previous holder nothing; when either client releases its lock, the session is unlocked
// although the other one's WlSessionLock still reports locked and secure. While this shell holds a
// confirmed lock, ownershipProbe therefore asks Hyprland for the real session lock state (no
// Hyprland event exists for it) and takes a fresh lock as soon as the session is found unlocked.
// A foreign locker that takes the lock over is left alone (the session stays locked); its release
// is followed by a fresh Grassfield lock.
//
// Every Hyprland query of the lock goes through requestMonitors(), which sends none while Quickshell's monitor model is
// empty (a QML query creates no monitor object and, sent too early, keeps that model empty: see there).
Singleton {
    id: root

    // "unlocked" | "locking" | "locked" | "authenticating"
    readonly property string lockState: controller.lockState
    readonly property bool locked: controller.locked
    // This shell holds a lock the compositor confirmed (its `locked` event: every output shows a
    // lock surface). On Hyprland the lock may since have been taken over: see `secure`.
    readonly property bool holding: (controller.lockState === Machine.LOCKED || controller.lockState === Machine.AUTHENTICATING) && sessionLock.secure
    // Holding, and Hyprland reported the session locked since the last verify() (or the lock was
    // just acquired). SleepInhibitor releases the sleep delay only on this.
    readonly property bool secure: holding && verified
    property bool verified: false
    readonly property bool pamAvailable: controller.pamAvailable
    readonly property bool fingerprintAvailable: fingerprintFile.available
    // Dev session (RunMode.dev: GRASSFIELD_DEV=1 and no GRASSFIELD_SESSION=1, read through the relative import of
    // shell/lib/RunMode.js, which no QML import path can replace): the test hooks below answer, and PAM is
    // suppressed unless GRASSFIELD_DEV_ALLOW_PAM=1. In a real session (GRASSFIELD_SESSION=1) both are off even when
    // GRASSFIELD_DEV=1 leaks into its environment (GF-AUDIT-001 SEC-03).
    readonly property bool devHooks: RunMode.dev(Quickshell.env("GRASSFIELD_DEV"), Quickshell.env("GRASSFIELD_SESSION"))
    readonly property bool pamSuppressed: controller.pamSuppressed
    // Lock fields (one per screen) that hold typed text: only ever read by the dev hook devLockView (L2 test: the
    // field is emptied after every attempt). Never the text, never its length.
    property int filledFields: 0

    readonly property string loginName: Quickshell.env("USER")
    property string userName: loginName
    // Account picture: ~/.face, else the AccountsService icon, else "" (initials). Never loaded where it lies: shown only
    // as a PNG the shell made from it (ThemeIcons.fileSource, services/image-copy.py; review of 423766f: a ~/.face that is
    // a FIFO, or an SVG naming one, stalled the image loader). Cosmetic only: until the PNG exists, and when it is refused,
    // the initials show; nothing here can unlock or keep the lock from engaging.
    readonly property string facePath: Quickshell.env("HOME") ? Quickshell.env("HOME") + "/.face" : ""
    readonly property string avatarSource: Machine.avatarSource(facePath, Machine.accountsIconPath(loginName), path => ThemeIcons.fileSource(path), path => ThemeIcons.fileState(path))

    // ---- ready before it is needed (ADR-0040 step 4a, ID-7; display only) ----
    // LockStills.qml, created at run time at the end of Component.onCompleted (never a declared child: if it cannot be
    // loaded, the lock is unaffected and the surfaces show the artwork and the initials): one backdrop per output and the
    // account picture, decoded while the session is unlocked (Qt's pixmap cache; LockView asks for the same urls with the
    // same options and gets them at once). A surface takes them once. Nothing here can unlock or keep the lock from engaging.
    property var stills: null
    readonly property string avatarReady: root.stills ? root.stills.avatarReady : ""
    readonly property int backdrops: root.stills ? root.stills.revision : 0
    function backdropOf(output: string): var {
        return root.stills ? root.stills.backdropOf(output) : null;
    }
    function prepareStills(): void {
        try {
            const c = Qt.createComponent(Qt.resolvedUrl("LockStills.qml"));
            if (c.status !== Component.Ready) {
                console.warn("grassfield-lock: the lock's display data cannot be prepared (" + c.errorString() + "); the lock shows the artwork and the initials");
                return;
            }
            const o = c.createObject(root);
            if (o === null) {
                console.warn("grassfield-lock: the lock's display data cannot be created; the lock shows the artwork and the initials");
                return;
            }
            o.avatarSource = Qt.binding(() => root.avatarSource);
            root.stills = o;
        } catch (e) {
            console.warn("grassfield-lock: the lock's display data failed (" + e + "); the lock shows the artwork and the initials");
        }
    }
    // Counts the resumes from sleep (SleepInhibitor.afterResume): each lock surface refreshes its clock (ID-7, T-14).
    property int resumes: 0
    function resumed(): void {
        root.resumes += 1;
    }

    readonly property string markerPath: {
        const dir = Quickshell.env("XDG_RUNTIME_DIR");
        return dir ? dir + "/" + Machine.markerName(Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE"), Quickshell.env("WAYLAND_DISPLAY")) : "";
    }
    // The last marker write failed (or could not be read back).
    property bool markerFailed: false
    // Crash recovery cannot record the lock state; shown on the lock surface (the lock itself is
    // unaffected: a crash still leaves the compositor locked).
    readonly property bool recoveryDegraded: markerPath === "" || markerFailed

    // Hyprland IPC is available for the lock ownership checks (Quickshell.Hyprland, no hyprctl).
    readonly property bool hyprland: Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") !== ""
    // Consecutive Hyprland answers reporting the session unlocked while holding (see checkOwnership).
    property int unlockedAnswers: 0
    // Quickshell's monitor model was found empty when the lock wanted to ask Hyprland (requestMonitors): logged once, cleared
    // when a monitor object appears (monitorsAdded).
    property bool emptyModelLogged: false
    // The start-up stranded-lock check has not decided yet: it is running, or it ran out of ticks on an unknown state (the
    // monitor model still empty, outputs still coming up). Cleared once Hyprland reported the session locked (taken over)
    // or unlocked, or this shell locked; while set, monitors appearing run the check again at once (monitorsAdded).
    property bool strandedUndecided: false
    // The lock surface (one per screen) whose window has the keyboard, else null: none of this shell's lock
    // surfaces has it (another client's lock surface took it, or a window did after the session was unlocked
    // under this lock). Only ever speeds the ownership check up.
    property var focusedSurface: null
    // The lock this shell holds was requested by restore() or checkStranded() (reason "restore"): it may be a lock
    // taken over from a live foreign locker, whose release unlocks the session without any event. Cleared by
    // relock() (the session was found unlocked: that release happened) and release().
    property bool inheritedLock: false
    // Another client may hold or have held the session lock (Machine.takeoverSuspected): the ownership check then
    // runs every Machine.PROBE_SUSPECTED_MS instead of every second (R12 review #3: the session stayed unlocked up
    // to ~1.1 s after a foreign locker released a lock it had taken over).
    readonly property bool takeoverSuspected: holding && hyprland && Machine.takeoverSuspected(focusedSurface !== null, inheritedLock)

    onTakeoverSuspectedChanged: {
        if (takeoverSuspected)
            console.info("grassfield-lock: takeover suspected (" + (focusedSurface === null ? "no lock surface has the keyboard" : "lock inherited at start") + "); ownership check every " + Machine.PROBE_SUSPECTED_MS + " ms");
        else if (holding)
            console.info("grassfield-lock: no takeover suspected; ownership check every " + Machine.PROBE_INTERVAL_MS + " ms");
    }

    // Decisions read the lock state afresh (port of Omarchy v4.0.6 currentlyLocked(), basecamp/omarchy@237f1b4: "A
    // property binding that missed a change notification once reported locked after an unlock, and a lock request
    // before suspend then took that for done and never locked the session"). The bindings above (locked, holding,
    // secure) drive the UI and the timers; lock(), restore(), checkStranded() and the sleep delay
    // (SleepInhibitor) decide on these instead: the state machine's storage, WlSessionLock's own getter and the
    // verified flag, read at the moment of the decision.
    function currentlyLocked(): bool {
        return Machine.isLocked(controller.currentState());
    }

    function currentlySecure(): bool {
        return Machine.isHolding(controller.currentState()) && sessionLock.secure && verified;
    }

    // Engage the lock. reason: "ipc" | "menu" | "idle" | "sleep" | "lid" | "restore". Returns "ok",
    // "already-locked" or "refused: missing-pam". When this shell already holds a lock, the
    // compositor is asked again (verify()): a session found unlocked under it gets a fresh lock once
    // a fresh answer confirms it (checkOwnership), never here on an earlier answer alone: relock()
    // releases the lock object first, and releasing the lock the compositor still uses unlocks the
    // session until the new lock arrives (R12 review #3: keys reached a window in forced runs).
    function lock(reason: string): string {
        if (currentlyLocked()) {
            console.info("grassfield-lock: lock requested (" + reason + ") while " + controller.lockState + "; verifying the session lock");
            engage();
            verify();
            return "already-locked";
        }
        controller.pamAvailable = pamServiceInstalled();
        // A lock nobody could open is refused, except when restoring one (never fail open).
        if (!controller.pamAvailable && reason !== "restore") {
            console.warn("grassfield-lock: refused (" + reason + "): /etc/pam.d/omarchy-lock-password is missing");
            return "refused: missing-pam";
        }
        strandedProbe.stop();
        // Never again after this shell locked: the cached answers would then show its own lock (a stale LOCK after the
        // unlock would re-lock the session on the next monitor plugged in).
        strandedUndecided = false;
        console.info("grassfield-lock: lock requested (" + reason + ")");
        inheritedLock = reason === "restore";
        Popups.close();
        writeMarker("locked");
        controller.requestLock();
        engage();
        return "ok";
    }

    // The lid was closed (Hyprland binding `switch:on:Lid Switch`, D-4): lock at once, whether or not logind suspends
    // (HandleLidSwitchExternalPower=ignore, a delay inhibitor, a failed suspend), as macOS does, except in clamshell
    // mode: a physical external display is active and still in use (Machine.lidShouldLock). When logind does suspend,
    // the lock is then already on its way before PrepareForSleep. Returns lock()'s answer or "docked".
    function lockOnLid(): string {
        const names = Quickshell.screens.map(s => s.name);
        if (!Machine.lidShouldLock(names)) {
            console.info("grassfield-lock: lid closed with an external display active (clamshell); not locking");
            return "docked";
        }
        return lock("lid");
    }

    // Ask the compositor for the lock; retried by retryTimer until it is confirmed.
    function engage(): void {
        if (controller.lockState !== Machine.LOCKING)
            return;
        if (Quickshell.screens.length > 0 && !sessionLock.locked)
            sessionLock.locked = true;
        if (sessionLock.locked && sessionLock.secure)
            controller.lockAcquired();
        else
            retryTimer.start();
    }

    // Ask Hyprland again whether the session is locked (repeated lock request, before sleep, lock
    // surface lost keyboard focus). `secure` is false until the answer; checkOwnership() takes a
    // fresh lock if the session is found unlocked. A lock confirmed less than verifyGraceMs ago
    // needs no answer: the compositor's own `locked` event is the proof. While Quickshell's monitor
    // model is empty no query is sent (requestMonitors): `secure` then stays false until the model
    // fills and an answer confirms the lock (monitorsAdded asks at once).
    function verify(): void {
        if (!holding || !hyprland || secureGrace.running)
            return;
        verified = false;
        requestMonitors();
    }

    // The session is unlocked under a lock object that still reports secure (another client took
    // the lock over and released it): drop that stale object and request a new lock in the same
    // event-loop turn. Never unlocks anything that is not already unlocked; the carried intent and
    // the marker stay "locked". Not atomic (the release can reach Hyprland before the new request):
    // called ONLY from checkOwnership() on a confirmed "unlocked" answer (Machine.ownershipAction),
    // never on a single answer, which may be stale (tests/security/reload_order checks the callers).
    function relock(why: string): void {
        console.warn("grassfield-lock: the session is unlocked although this shell holds a lock (taken over and released by another client; " + why + "); taking a fresh lock");
        unlockedAnswers = 0;
        verified = false;
        inheritedLock = false;
        controller.lockLost();
        sessionLock.locked = false;
        engage();
    }

    // Runs after every Hyprland monitor answer (whoever asked). While holding, a session reported
    // unlocked twice in a row (Machine.ownershipAction) is re-locked. Answers in the first
    // verifyGraceMs after the lock was confirmed are skipped: they may answer a request sent before.
    function checkOwnership(): void {
        if (!holding || secureGrace.running) {
            unlockedAnswers = 0;
            return;
        }
        // Lazy: each lastIpcObject read converts a whole monitor map to JS; while locked only the first one is read.
        const monitors = Hyprland.monitors.values;
        const state = Machine.compositorLockStateLazy(monitors.length, i => monitors[i].lastIpcObject);
        const action = Machine.ownershipAction(state, unlockedAnswers);
        unlockedAnswers = state === "unlocked" ? unlockedAnswers + 1 : 0;
        if (action === "confirm")
            requestMonitors();
        else if (action === "relock")
            relock("confirmed by Hyprland");
        else
            verified = true; // "ok": the session is locked; "unknown": WlSessionLock's word is all there is
    }

    // The lock's only Hyprland monitor query (verify, checkOwnership's confirmation, checkStranded, ownershipProbe,
    // monitorsAdded); the answer reaches checkOwnership through monitorAnswers. Never sent while Quickshell's monitor model is
    // empty (Machine.monitorQueryAllowed): Quickshell 0.3.1's QML query creates no monitor object, and one sent before
    // Hyprland answered Quickshell's own first query makes Quickshell drop that query, so the model would stay empty until a
    // monitor event and no check here would ever get an answer. Until Quickshell's own answer fills the model, the lock state
    // is unknown: nothing is verified, relocked or taken over, and WlSessionLock keeps the session locked (fail closed).
    // Returns whether the query was sent.
    function requestMonitors(): bool {
        if (!Machine.monitorQueryAllowed(Hyprland.monitors.values.length)) {
            if (!emptyModelLogged)
                console.warn("grassfield-lock: Hyprland's monitor model is empty (Quickshell has no monitor object yet): no monitor query sent; the session lock state is unknown until Quickshell's own query fills it");
            emptyModelLogged = true;
            return false;
        }
        Hyprland.refreshMonitors();
        return true;
    }

    // Quickshell created a monitor object: the model filled once Hyprland answered Quickshell's own query, or an output
    // appeared. monitorAnswers watches it from now on, but the answer that created it came before (Quickshell fills a new
    // monitor, then adds it to the model), so while holding a fresh answer is asked for at once rather than at the next
    // ownershipProbe tick; it reaches checkOwnership through the new delegate. Before this shell locked, a start-up
    // stranded check that has not decided (still running, or out of ticks because Quickshell's first answer came after
    // them) runs again on that answer, so a dead client's stranded lock is taken over as soon as the model fills. That
    // check only ever locks.
    function monitorsAdded(): void {
        if (emptyModelLogged) {
            emptyModelLogged = false;
            console.info("grassfield-lock: Hyprland's monitor model has " + Hyprland.monitors.values.length + " monitor(s); lock state queries resume");
        }
        if (holding)
            requestMonitors();
        else if (strandedUndecided)
            checkStranded();
    }

    // Called by the controller after a PAM success only: the only path that clears the carried
    // intent and writes "unlocked".
    function release(): void {
        retryTimer.stop();
        fingerprintRetry.stop();
        if (fingerprintPam.active)
            fingerprintPam.abort();
        verified = false;
        unlockedAnswers = 0;
        inheritedLock = false;
        persist.intent = false;
        sessionLock.locked = false;
        writeMarker("unlocked");
        console.info("grassfield-lock: unlocked");
    }

    // Atomic, blocking write, then read back. Returns false (and sets markerFailed, logged and
    // shown on the lock surface) when the marker cannot hold the value.
    function writeMarker(value: string): bool {
        if (markerPath === "") {
            console.warn("grassfield-lock: XDG_RUNTIME_DIR unset: no crash recovery marker (" + value + "); a restart will lock");
            return false;
        }
        // The line also records the count of completed suspends, so that a restarted shell can tell that the
        // machine slept while no shell could lock for it (Machine.sleptSince).
        const line = Machine.markerLine(value, sleepCount());
        // FileView skips a write equal to its cached text, which is stale if the file was changed
        // or removed behind its back: re-read first.
        marker.reload();
        marker.waitForJob();
        marker.setText(line + "\n");
        marker.reload();
        marker.waitForJob();
        const ok = String(marker.text()).trim() === line;
        if (!ok)
            console.warn("grassfield-lock: crash recovery marker could not be written:", root.markerPath, "(wanted " + value + ")");
        markerFailed = !ok;
        return ok;
    }

    // null when the marker does not exist; "" when it exists but cannot be read (locks); else its
    // text (Machine.markerRead).
    function readMarker(): var {
        if (markerPath === "")
            return null;
        marker.reload();
        marker.waitForJob();
        return Machine.markerRead(marker.loadError === FileViewError.FileNotFound, marker.loadError !== FileViewError.Success, marker.text());
    }

    // Count of completed suspends of the machine (/sys/power/suspend_stats/success), or -1 when unreadable.
    function sleepCount(): int {
        suspendStats.reload();
        suspendStats.waitForJob();
        return suspendStats.readable ? Machine.parseSleepCount(suspendStats.text()) : -1;
    }

    // Restore the lock if the previous instance held or wanted it (see the header), or if the machine slept
    // since the marker said unlocked (a crash or restart right before or during a sleep: no shell could lock for
    // it). Only ever locks; never unlocks.
    function restore(intent: bool, when: string): void {
        if (currentlyLocked())
            return;
        const text = readMarker();
        const sleeps = sleepCount();
        if (!Machine.restoreAtStart(intent, markerPath !== "", text, sleeps))
            return;
        const slept = Machine.sleptSince(text, sleeps);
        console.info("grassfield-lock: restoring the lock (" + when + (intent ? ", carried intent" : "") + (markerPath === "" ? ", no XDG_RUNTIME_DIR" : "") + (slept ? ", the machine slept while no shell could lock" : "") + ")");
        lock("restore");
    }

    // Stranded lock: Hyprland holds a session lock although this instance never locked, i.e. a
    // crashed instance whose marker was missing or wrong, or a live foreign locker (Hyprland cannot
    // tell them apart). Take it over (fail closed: a dead client's lock could never be unlocked
    // otherwise). If it was a live locker, its later release unlocks the session under this lock
    // and ownershipProbe takes a fresh one. Omarchy v4.0.5 (basecamp/omarchy@94a8fbc) instead leaves the lock alone
    // while another locker process runs, because its shell, once it has taken a live lock over, strands the session
    // behind Hyprland's failsafe when it exits. Not ported: here the takeover only ever keeps the session locked, the
    // ownership check re-locks after the foreign release (reload_locked.sh `foreign-restart`), and a Grassfield exit
    // is followed by a restart that restores the lock from the marker; skipping the takeover would instead leave a
    // dead client's lock (marker missing or forged) unlockable whenever any other Quickshell process of the user runs.
    function checkStranded(): void {
        if (currentlyLocked()) {
            strandedProbe.stop();
            strandedUndecided = false;
            return;
        }
        const monitors = Hyprland.monitors.values.map(m => m.lastIpcObject);
        const state = Machine.compositorLockState(monitors);
        if (state === "locked") {
            strandedProbe.stop();
            strandedUndecided = false;
            console.warn("grassfield-lock: the compositor holds a session lock this shell did not take (a crash with a missing or wrong marker, or a foreign locker); taking it over");
            lock("restore");
        } else if (state === "unlocked") {
            strandedProbe.stop();
            strandedUndecided = false;
        } else if (--strandedProbe.remaining <= 0) {
            strandedProbe.stop(); // still undecided: monitorsAdded runs the check again when monitors appear
            console.info("grassfield-lock: compositor lock state unknown; relying on the crash recovery marker");
        } else {
            requestMonitors(); // none while the monitor model is empty: Quickshell's own answer fills it
        }
    }

    function pamServiceInstalled(): bool {
        passwordFile.reload();
        return passwordFile.text().length > 0;
    }

    function pamResultName(result: int): string {
        switch (result) {
        case PamResult.Success:
            return "success";
        case PamResult.Failed:
            return "failed";
        case PamResult.MaxTries:
            return "maxtries";
        }
        return "error";
    }

    function startFingerprint(): void {
        if (!fingerprintFile.available || controller.lockState !== Machine.LOCKED || !sessionLock.secure || fingerprintPam.active)
            return;
        if (!fingerprintPam.start())
            fingerprintRetry.restart();
    }

    LockController {
        id: controller
        pam: passwordPam
        onUnlockRequested: root.release()
        onLockStateChanged: {
            // Carried over a soft reload; cleared only by release() (PAM success).
            if (controller.locked)
                persist.intent = true;
            if (lockState === Machine.LOCKED)
                root.startFingerprint();
        }
    }

    // Lock intent carried over a Quickshell soft reload. MUST stay declared before sessionLock:
    // Quickshell 0.3.1 reloads a Singleton's children in declaration order (ReloadPropagator),
    // so the old values are restored here, and sessionLock's `locked` binding re-evaluated, before
    // WlSessionLock::onReload decides whether to keep the handed-over lock. Checked offscreen by
    // tests/security/reload_order and in nested by tests/security/reload_locked.sh.
    PersistentProperties {
        id: persist
        reloadableId: "grassfield-lock-intent"

        // The previous instance was locking, locked or authenticating.
        property bool intent: false

        // Runs inside the reload pass of every instance (no old instance: intent stays false). The
        // old value just restored must not downgrade a lock taken in Component.onCompleted: only
        // release() (PAM success) ever clears the intent.
        onLoaded: {
            intent = intent || controller.locked;
            root.restore(intent, "reload");
        }
    }

    WlSessionLock {
        id: sessionLock

        // Declarative initial value (no false-to-true window): already true at WlSessionLock::onReload
        // when the previous instance held or wanted the lock (persist) or the marker restored it
        // (controller). False only when both are unlocked, i.e. after release(). engage() and
        // release() take over imperatively afterwards.
        locked: persist.intent || controller.locked

        onSecureStateChanged: {
            if (secure) {
                // A fresh `locked` event: the compositor uses this lock now.
                secureGrace.restart();
                root.unlockedAnswers = 0;
                root.verified = true;
                retryTimer.stop();
                controller.lockAcquired();
            }
        }

        onLockStateChanged: {
            if (!locked && controller.locked) {
                if (controller.lockState !== Machine.LOCKING)
                    console.warn("grassfield-lock: compositor dropped the lock; re-acquiring");
                controller.lockLost();
                retryTimer.start();
            }
        }

        WlSessionLockSurface {
            id: surface

            // The ground under the scrim (ADR-0040 ID-2, ID-15): what shows before the content and until the backdrop is
            // decided, on a hotplugged output too. Taken once, when the surface is created (the shadow colour until then).
            color: Tokens.colorDark.shadow
            Component.onCompleted: surface.color = Ground.of(surface.screen ? surface.screen.name : "")

            // Keyboard focus left this lock surface: on Hyprland that also happens when another
            // client takes the session lock over or the session is unlocked under it. Ask now
            // rather than at the next ownershipProbe tick (moving between outputs only costs a query),
            // and track whether any lock surface has the keyboard (takeoverSuspected).
            Item {
                id: keyboardProbe

                Window.onActiveChanged: {
                    if (Window.active) {
                        // Keyboard focus says nothing about a lock inherited at start: a live foreign locker that held the
                        // session lock sits UNDER this lock, and its release unlocks the session while this surface keeps
                        // the keyboard (R12 counter-review of 620f08c). inheritedLock is cleared only by relock() (that
                        // release happened) and release().
                        root.focusedSurface = keyboardProbe;
                    } else {
                        if (root.focusedSurface === keyboardProbe)
                            root.focusedSurface = null;
                        root.verify();
                    }
                }
                Component.onDestruction: {
                    if (root.focusedSurface === keyboardProbe)
                        root.focusedSurface = null;
                }
            }

            LockView {
                id: view
                anchors.fill: parent
                userName: root.userName
                avatarSource: root.avatarReady
                offeredBackdrop: root.backdrops >= 0 ? root.backdropOf(surface.screen ? surface.screen.name : "") : null
                resumes: root.resumes
                showUser: Settings.lockShowUser
                lockMessage: Settings.lockShowMessage ? Settings.lockMessage : ""
                authenticating: controller.authenticating
                inputEnabled: controller.pamAvailable
                message: controller.pamAvailable ? controller.message : qsTr("Authentication service unavailable. The session stays locked.")
                // In dev, a visible hint that password checks are off (PAM suppressed), so a GRASSFIELD_DEV value that
                // leaked into a real session is obvious; the lock still fails closed.
                notice: {
                    const recovery = root.recoveryDegraded ? qsTr("Crash recovery unavailable: the lock state could not be saved.") : "";
                    const dev = controller.pamSuppressed ? qsTr("dev: password checks disabled") : "";
                    return recovery !== "" && dev !== "" ? qsTr("%1 · %2").arg(dev).arg(recovery) : recovery + dev;
                }
                onSubmitted: password => controller.submit(password)
                onEdited: controller.clearMessage()
                onFieldEmptyChanged: root.filledFields = Math.max(0, root.filledFields + (fieldEmpty ? -1 : 1))
                Component.onDestruction: {
                    if (!fieldEmpty)
                        root.filledFields = Math.max(0, root.filledFields - 1);
                }
            }

            Connections {
                target: controller

                function onFailed(): void {
                    view.shake();
                }

                function onClearRequested(): void {
                    view.clear();
                }
            }
        }
    }

    PamContext {
        id: passwordPam
        config: "omarchy-lock-password"
        // user unset: PAM authenticates the uid running the shell, not $USER.

        onPamMessage: controller.pamMessage(message, messageIsError, responseRequired)
        onCompleted: result => controller.pamCompleted(root.pamResultName(result))
        onError: controller.pamError()
    }

    // Started only when /etc/pam.d/omarchy-lock-fingerprint exists (SEC8).
    PamContext {
        id: fingerprintPam
        config: "omarchy-lock-fingerprint"

        onCompleted: result => {
            if (result === PamResult.Success)
                controller.fingerprintSucceeded();
            else if (result !== PamResult.MaxTries)
                fingerprintRetry.restart();
        }
        onError: fingerprintRetry.restart()
    }

    Timer {
        id: fingerprintRetry
        interval: 1000
        onTriggered: root.startFingerprint()
    }

    Timer {
        id: retryTimer
        interval: 500
        repeat: true
        onTriggered: {
            if (controller.lockState !== Machine.LOCKING)
                stop();
            else
                root.engage();
        }
    }

    // Bounded startup check (at most 20 Hyprland monitor queries in 10 s, only until this instance
    // first locks); outputs may still be coming up, so an unknown answer is asked again. While
    // Quickshell's monitor model is still empty nothing is asked (requestMonitors) and the state stays
    // unknown; if it is still unknown after the 20 ticks, the crash recovery marker decides until
    // monitors appear, which runs the check once more (monitorsAdded, strandedUndecided).
    Timer {
        id: strandedProbe

        property int remaining: 20

        interval: 500
        repeat: true
        onTriggered: root.checkStranded()
    }

    // Lock ownership check, only while holding a lock on Hyprland: one monitor query
    // (Quickshell.Hyprland IPC request, no hyprctl process) per second, every 100 ms while a takeover
    // is suspected (takeoverSuspected). Hyprland 0.56.2 emits no event when a session lock is taken
    // over or released (verified on its event socket), so a query is the only way to notice that the
    // session was unlocked under this lock. The answer is handled by checkOwnership() (monitorAnswers),
    // as are answers to anyone's query. A changed interval restarts the timer. A tick while Quickshell's
    // monitor model is empty sends nothing (requestMonitors); the ticks after it fills do.
    Timer {
        id: ownershipProbe

        // Answers this soon after the compositor confirmed the lock are not trusted (see checkOwnership).
        readonly property int verifyGraceMs: 500

        interval: Machine.probeInterval(root.takeoverSuspected)
        repeat: true
        running: root.holding && root.hyprland && !devPause.running
        onTriggered: root.requestMonitors()
    }

    // Runs for ownershipProbe.verifyGraceMs after the compositor confirmed a lock of this shell (its `locked` event,
    // WlSessionLock.secure): verify() and checkOwnership() skip that window. A single-shot Timer (a monotonic clock), never
    // the wall clock (review of 2dfd992: with Date.now() a clock step back turned the ownership check off for as long as
    // the step). Not running (a new instance, a soft reload, a Timer that never ran): no window, the check stays on.
    Timer {
        id: secureGrace
        interval: ownershipProbe.verifyGraceMs
    }

    // Dev-only (GRASSFIELD_DEV=1): `lock devPauseOwnershipCheck` stops the periodic check for 10 s so
    // that tests/security/reload_locked.sh can hold a desync and check the lock()/before-sleep paths.
    Timer {
        id: devPause
        interval: 10000
        onTriggered: console.warn("grassfield-lock: dev pause of the lock ownership check ended")
    }

    // Follows the live model, whether or not a lock is held: a monitor object Quickshell creates later (the model filling
    // after start, an output plugged in) gets its own Connections at once (see monitorsAdded).
    Instantiator {
        id: monitorAnswers

        active: root.hyprland
        model: Hyprland.monitors
        onObjectAdded: Qt.callLater(root.monitorsAdded)

        delegate: Connections {
            required property HyprlandMonitor modelData

            target: modelData

            // One call per answer, after every monitor of it was updated.
            function onLastIpcObjectChanged(): void {
                Qt.callLater(root.checkOwnership);
            }
        }
    }

    FileView {
        id: passwordFile
        path: "/etc/pam.d/omarchy-lock-password"
        blockLoading: true
        printErrors: false
    }

    FileView {
        id: fingerprintFile

        property bool available: false

        path: "/etc/pam.d/omarchy-lock-fingerprint"
        printErrors: false
        onLoaded: available = true
        onLoadFailed: available = false
    }

    FileView {
        id: marker

        // Result of the last read (FileViewError): tells a missing marker from an unreadable one.
        property int loadError: FileViewError.Success

        path: root.markerPath
        blockLoading: true
        blockWrites: true
        atomicWrites: true
        printErrors: false
        onLoaded: loadError = FileViewError.Success
        onLoadFailed: error => loadError = error
        onSaveFailed: error => console.warn("grassfield-lock: crash recovery marker write failed:", FileViewError.toString(error))
    }

    // Completed suspends of the machine (kernel counter, world-readable): see sleepCount().
    FileView {
        id: suspendStats

        property bool readable: false

        path: "/sys/power/suspend_stats/success"
        blockLoading: true
        printErrors: false
        onLoaded: readable = true
        onLoadFailed: readable = false
    }

    FileView {
        path: "/etc/passwd"
        printErrors: false
        onLoaded: root.userName = Machine.displayName(text(), root.loginName)
    }

    Connections {
        target: Quickshell

        function onScreensChanged(): void {
            root.engage();
        }
    }

    // Runs before the reload pass (persist.onLoaded): a marker that says locked, or no
    // XDG_RUNTIME_DIR, restores the lock even if the carried intent were lost.
    Component.onCompleted: {
        controller.pamAvailable = pamServiceInstalled();
        // Defence in depth: in a dev/test session, never hand a password to PAM unless the L2 test opts in.
        // A stray key reaching the lock field in nested then cannot count a faillock failure on the real account.
        // Never in a real session (devHooks is false there whatever GRASSFIELD_DEV says): it could never be unlocked.
        controller.pamSuppressed = root.devHooks && Quickshell.env("GRASSFIELD_DEV_ALLOW_PAM") !== "1";
        if (Quickshell.env("GRASSFIELD_DEV") === "1" && !root.devHooks)
            console.warn("grassfield-lock: GRASSFIELD_DEV=1 ignored in a real session (GRASSFIELD_SESSION=1): no dev hook, PAM not suppressed");
        if (controller.pamSuppressed)
            console.warn("grassfield-lock: dev: PAM is suppressed on the lock (no real authentication; set GRASSFIELD_DEV_ALLOW_PAM=1 for the L2 failure-path test)");
        restore(false, "start");
        if (!controller.locked && root.hyprland) {
            strandedUndecided = true;
            strandedProbe.start();
        }
        // Last, after everything the lock itself needs (ADR-0040 step 4a): the display data.
        prepareStills();
    }

    // Dev hooks (dev session only, "refused" otherwise; tests/security/dev_gate checks both ways). Functions of
    // the singleton so that the offscreen test can call them; the IPC handler below only forwards.

    // Test hook: the state machine state.
    function devStatus(): string {
        return root.devHooks ? root.lockState : RunMode.REFUSED;
    }

    // Soft-reload the configuration the way Quickshell's file watcher would (tests/security/reload_locked.sh).
    function devReload(): string {
        if (!root.devHooks)
            return RunMode.REFUSED;
        console.warn("grassfield-lock: dev soft reload requested");
        Qt.callLater(() => Quickshell.reload(false));
        return "reloading";
    }

    // Pause the periodic lock ownership check for 10 s (answers to other queries, lock() and verify() still check).
    function devPauseOwnershipCheck(): string {
        if (!root.devHooks)
            return RunMode.REFUSED;
        console.warn("grassfield-lock: dev pause of the lock ownership check (10 s)");
        devPause.restart();
        return "paused";
    }

    // Count one "unlocked" answer Hyprland never gave, as a stale answer would, while the session is really locked
    // (tests/security/reload_locked.sh `relock-confirm`). Only a relock can follow (never an unlock), and only once a
    // fresh answer confirms it.
    function devForgeUnlockedAnswer(): string {
        if (!root.devHooks)
            return RunMode.REFUSED;
        if (!root.holding)
            return "not-holding";
        console.warn("grassfield-lock: dev forged one unlocked answer");
        root.unlockedAnswers = 1;
        return "forged";
    }

    // What the L2 wrong-password test checks after each attempt (tests/security/l2_wrong_password.sh): the state, whether
    // any lock field still holds text (never the text or its length), the message shown, the failed attempts, and
    // whether PAM is suppressed. JSON.
    function devLockView(): string {
        if (!root.devHooks)
            return RunMode.REFUSED;
        return JSON.stringify({
            state: root.lockState,
            field: root.filledFields > 0 ? "filled" : "empty",
            message: controller.message,
            failedAttempts: controller.failedAttempts,
            pamSuppressed: controller.pamSuppressed
        });
    }

    IpcHandler {
        target: "lock"

        // Used by the Hyprland binding (SUPER+CTRL+Q), the screen corners and the Grassfield menu. Only ever locks.
        function lock(): string {
            return root.lock("ipc");
        }

        // Used by /usr/lib/grassfield/grassfield-lid, run by the lid switch binding of system.lua. Only ever locks
        // ("docked": clamshell, nothing done).
        function lid(): string {
            return root.lockOnLid();
        }

        // Dev hooks (refused outside a dev session).
        function status(): string {
            return root.devStatus();
        }

        function devReload(): string {
            return root.devReload();
        }

        function devPauseOwnershipCheck(): string {
            return root.devPauseOwnershipCheck();
        }

        function devForgeUnlockedAnswer(): string {
            return root.devForgeUnlockedAnswer();
        }

        function devLockView(): string {
            return root.devLockView();
        }
    }
}
