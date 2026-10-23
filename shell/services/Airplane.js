.pragma library

// Airplane Mode as its own state (macOS model, REQ-QS-CC3): turning it on remembers which radios were on and switches
// them all off; turning it off restores exactly those and leaves the others as they were. Wi-Fi switched off alone is not
// Airplane Mode. Pure functions; Connectivity.qml owns the persisted state {on, restore: [radio types]}.
// Radio types are the rfkill names: wlan, bluetooth, wwan.

const TYPES = ["wlan", "bluetooth", "wwan"];

// {type: bool} for the radios that exist: on = not blocked (a type with several devices is on while any is). `devices` as
// parsed by Rfkill.js parseList: [{type, soft, hard}].
function radiosFromRfkill(devices) {
    const out = {};
    for (const d of devices) {
        if (TYPES.indexOf(d.type) < 0)
            continue;
        const on = !d.soft && !d.hard;
        out[d.type] = out[d.type] === true || on;
    }
    return out;
}

// The same from the service switches (the fallback without rfkill): null = no such radio.
function radiosFromServices(wifiOn, bluetoothOn) {
    const out = {};
    if (wifiOn !== null)
        out.wlan = wifiOn;
    if (bluetoothOn !== null)
        out.bluetooth = bluetoothOn;
    return out;
}

function anyRadio(radios) {
    return Object.keys(radios).length > 0;
}

// State after turning Airplane Mode on: the radios that are on now are the ones to bring back.
function begin(radios) {
    return {on: true, restore: Object.keys(radios).filter(t => radios[t] === true)};
}

// State after turning it off.
function end() {
    return {on: false, restore: []};
}

// The state as the user should see it: Airplane Mode stays on until it is turned off, except that when every radio is
// on again (switched on by hand, or restored by another tool) there is nothing left of it.
function reconcile(state, radios) {
    if (!state || state.on !== true || !anyRadio(radios))
        return {on: false, restore: []};
    const allOn = Object.keys(radios).every(t => radios[t] === true);
    return allOn ? {on: false, restore: []} : state;
}

// Radio types to switch back on when Airplane Mode ends: those remembered that still exist.
function typesToRestore(state, radios) {
    if (!state || !Array.isArray(state.restore))
        return [];
    return state.restore.filter(t => TYPES.indexOf(t) >= 0 && t in radios);
}

// Parse the persisted text; anything unreadable is "off".
function parse(text) {
    try {
        const o = JSON.parse(text);
        if (o && o.on === true && Array.isArray(o.restore))
            return {on: true, restore: o.restore.filter(t => TYPES.indexOf(t) >= 0)};
    } catch (e) {
        // fall through
    }
    return end();
}

function serialize(state) {
    return JSON.stringify({on: state.on === true, restore: state.restore}) + "\n";
}
