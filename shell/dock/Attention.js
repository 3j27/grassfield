.pragma library

// Attention requests of the Dock (pure, tested in tests/unit/tst_dockattention.qml). macOS: an app that needs attention
// bounces its Dock icon until the app is activated.
//
// State: an object whose keys are normalised window addresses that asked for attention (Hyprland's `urgent` event), value true.
// A tile bounces while one of its windows is in the state. Functions return a new state and never change their argument.
// `groups` is [{key, addresses: [..]}]: one entry per app tile, its windows' addresses (any hex spelling).

// Hyprland address as the shell compares them: lower-case hex without 0x; "" when it is not an address.
function normalize(address) {
    const m = /^(?:0x)?([0-9a-fA-F]{1,16})$/.exec(String(address));
    return m ? m[1].toLowerCase() : "";
}

// A window asked for attention. A window that already has the focus never does (nothing to ask for).
function request(state, address, focusedAddress) {
    const a = normalize(address);
    if (a === "" || a === normalize(focusedAddress))
        return state;
    const next = Object.assign({}, state);
    next[a] = true;
    return next;
}

// Windows that went away leave the state, and an app that is activated (any of its windows has the focus) is satisfied:
// every window of that tile leaves. No focused window ("" or a menu holding the keyboard) changes nothing but the closed windows.
function settle(state, groups, focusedAddress, liveAddresses) {
    const live = {};
    for (const l of liveAddresses || [])
        live[normalize(l)] = true;
    const focus = normalize(focusedAddress);
    const satisfied = {};
    if (focus !== "") {
        for (const g of groups || []) {
            if (g.addresses.some(a => normalize(a) === focus)) {
                for (const a of g.addresses)
                    satisfied[normalize(a)] = true;
            }
        }
    }
    const next = {};
    for (const a of Object.keys(state)) {
        if (live[a] && !satisfied[a])
            next[a] = true;
    }
    return Object.keys(next).length === Object.keys(state).length ? state : next;
}

// Keys of the tiles that bounce, in the order of `groups`.
function tileKeys(state, groups) {
    return (groups || []).filter(g => g.addresses.some(a => state[normalize(a)] === true)).map(g => g.key);
}
