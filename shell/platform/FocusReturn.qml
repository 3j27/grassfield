pragma Singleton
import QtQuick
import Quickshell
import Grassfield.Ui
import qs.services
import "FocusReturn.js" as FR

// Gives the keyboard back when a full-attention surface closes (macOS: Spotlight, Launchpad, a menu or the app switcher
// closing returns key focus to the window that was key before). Every Exclusive shell surface reports `opened(name)` and
// `closed(name, restore)`; when the last one is gone the window that was active when the first one opened is asked for:
//  - with the plugin capability `overview-focus`: ONE `remembered` request (the compositor waits for the last Exclusive
//    layer and focuses, FR41-FR43);
//  - without it (C2): the shell focuses after the surfaces' hold time and checks the result, retrying until it holds, the
//    bound runs out, the user acted (another window or Desktop became active) or another Exclusive surface opened.
// Nothing is requested while the session lock is up, when no window was active, or when another window is active at the
// time of the decision (someone chose it: a menu item that raised a window). The Overview is a holder too (`closed(name,
// false)`: it sends its own request) so that a hand-over between surfaces never fights over the focus.
Singleton {
    id: root

    // The session lock owns the screen and the keyboard (set from shell.qml): nothing is focused by the shell.
    property bool locked: false
    // Surfaces holding the keyboard now: {name: true}.
    property var holders: ({})
    // {address, workspaceId} of the window active when the first surface opened (null: none, or the desktop had the keyboard).
    property var previous: null
    property bool restoreWanted: false

    function anyOpen(): bool {
        return Object.keys(holders).length > 0;
    }

    // A full-attention surface just opened (`name`). The Dock's drag listens: such a surface takes the pointer from it.
    signal surfaceOpened(string name)

    // A full-attention surface was released (it hands the pointer back).
    signal surfaceClosed(string name)

    function opened(name: string): void {
        surfaceOpened(name);
        cancelFallback();
        if (!anyOpen())
            previous = DesktopState.holdsKeyboard ? null : Compositor.activeWindow();
        const next = Object.assign({}, holders);
        next[name] = true;
        holders = next;
    }

    // `restore` false: the surface took care of the focus itself (the Overview, a switcher commit, a menu item that raised a
    // window). The decision is taken one event-loop turn later, so surfaces handing the keyboard over (ExclusiveSurfaces) see
    // each other: only the last one to close restores.
    function closed(name: string, restore: bool): void {
        if (!holders[name])
            return;
        surfaceClosed(name);
        const next = Object.assign({}, holders);
        delete next[name];
        holders = next;
        if (restore)
            restoreWanted = true;
        Qt.callLater(decide);
    }

    // A choice of focus made by the caller (a menu item raising a window): the close that follows requests nothing.
    function skip(): void {
        restoreWanted = false;
        previous = null;
    }

    function decide(): void {
        if (anyOpen()) {
            // Another surface took over: its own close decides (the remembered window stays).
            restoreWanted = false;
            return;
        }
        const prev = previous;
        const wanted = restoreWanted;
        previous = null;
        restoreWanted = false;
        if (!wanted || locked)
            return;
        const target = FR.restoreTarget(prev, Compositor.activeWindow());
        if (target)
            request(target);
    }

    // Plugin: one request now. C2: the shell's own focus once the surfaces are unmapped (their hold time).
    function request(target: var): void {
        if (Capabilities.has("overview-focus") && Compositor.overviewFocus(target))
            return;
        startFallback(target, Tokens.focusReturnReleaseHoldMs);
    }

    // ---- Without the plugin capability: focus, check, retry ----

    // {kind: "window", address} | {kind: "space", id} (FR.fallbackPlan), the goal of the current attempt, what was active
    // just before it ({address, workspace}), the attempt number and when the first one started.
    property var focusPlan: null
    property var focusGoal: null
    property var focusBefore: null
    property int focusAttempt: 0
    property real focusStarted: 0
    // What was active when the fallback was decided ({address, workspace}): a change before the first attempt is the
    // user's choice (a click on another window while the surfaces were releasing the keyboard).
    property var focusOrigin: null

    function startFallback(target: var, delayMs: int): void {
        const plan = FR.fallbackPlan(target, Compositor.windowAddresses(), Compositor.minimizedAddresses());
        if (plan.kind === "none" || locked)
            return;
        const active = Compositor.activeWindow();
        focusOrigin = {
            address: active ? active.address : "",
            workspace: Compositor.focusedWorkspace ? Compositor.focusedWorkspace.id : -1
        };
        focusPlan = plan;
        focusAttempt = 0;
        focusStarted = Date.now();
        if (delayMs > 0) {
            focusTimer.interval = delayMs;
            focusTimer.restart();
            focusStarted += delayMs;
            focusDelayed = true;
        } else {
            attempt();
        }
    }

    // The first attempt waits for the surfaces' hold time (the timer then runs `attempt`, not a check).
    property bool focusDelayed: false

    function cancelFallback(): void {
        focusTimer.stop();
        focusPlan = null;
        focusDelayed = false;
    }

    // The Lua focus dispatch (Compositor.focusWindow: the protocol `activate` does nothing for the window Hyprland still
    // counts as focused). For a Desktop the window focused last on it, else the Desktop itself.
    function attempt(): void {
        const plan = focusPlan;
        if (!plan || locked) {
            focusPlan = null;
            return;
        }
        const active = Compositor.activeWindow();
        focusBefore = {
            address: active ? active.address : "",
            workspace: Compositor.focusedWorkspace ? Compositor.focusedWorkspace.id : -1
        };
        let address = plan.address;
        if (plan.kind === "space")
            address = Compositor.frontWindowOn(plan.id);
        if (address) {
            focusGoal = {
                address: address
            };
            Compositor.focusWindow(address);
        } else {
            focusGoal = {
                workspace: plan.id
            };
            Compositor.focusSpace(plan.id);
        }
        focusTimer.interval = FR.retryDelay(focusAttempt, Tokens.overviewFocusRetryMs);
        focusTimer.restart();
    }

    // Whether the focus holds: done, else try again with a longer wait until the bound runs out (Hyprland's own choice then
    // stands), the user acted or an Exclusive surface opened (its keyboard stands).
    Timer {
        id: focusTimer
        onTriggered: {
            if (root.focusDelayed) {
                root.focusDelayed = false;
                if (root.anyOpen()) {
                    root.focusPlan = null;
                    return;
                }
                // The hold time can be stretched by a busy GUI thread: a window or Desktop the user chose in the meantime
                // (a click) stands; the late first attempt would take the keyboard back from it.
                const ws = Compositor.focusedWorkspace ? Compositor.focusedWorkspace.id : -1;
                if (FR.userActed(FR.planGoal(root.focusPlan), root.focusOrigin, Compositor.activeWindow(), ws)) {
                    console.info("grassfield-focus: return focus (shell fallback) user before the first attempt");
                    root.focusPlan = null;
                    return;
                }
                root.attempt();
                return;
            }
            if (!root.focusPlan)
                return;
            const ws = Compositor.focusedWorkspace ? Compositor.focusedWorkspace.id : -1;
            const outcome = FR.checkOutcome(root.focusGoal, root.focusBefore, Compositor.activeWindow(), ws, Date.now() - root.focusStarted, Tokens.overviewFocusBoundMs, root.anyOpen());
            if (outcome === "retry") {
                root.focusAttempt++;
                root.attempt();
                return;
            }
            console.info("grassfield-focus: return focus (shell fallback)", outcome, "after", root.focusAttempt + 1, "attempt(s)");
            root.focusPlan = null;
        }
    }
}
