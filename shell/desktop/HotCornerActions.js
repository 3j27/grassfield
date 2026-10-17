.pragma library

// Hot corner actions (pure, unit-tested). Each action is a call into another shell surface
// through `qs ipc`, so the surfaces stay decoupled from the desktop layer.

const ACTIONS = ["none", "overview", "notifications", "apps", "lock"];

// IPC target and function of each action.
const IPC = {
    overview: ["overview", "toggle"],
    notifications: ["notifications", "toggleCenter"],
    apps: ["apps", "toggle"],
    lock: ["lock", "lock"]
};

// Action name clamped to the enum; unknown values mean "none".
function normalize(action) {
    return ACTIONS.indexOf(action) >= 0 ? action : "none";
}

// argv of the IPC call for an action against the shell process `pid`, or null for none.
function command(action, pid) {
    const target = IPC[normalize(action)];
    return target ? ["qs", "ipc", "--pid", String(pid), "call", target[0], target[1]] : null;
}

// True when `qs ipc show` output lists the target (the Apps surface may not exist yet).
function hasTarget(showOutput, target) {
    const re = new RegExp("^\\s*target " + target.replace(/[^\w.-]/g, "") + "\\s*$", "m");
    return re.test(String(showOutput));
}
