.pragma library

// Pure logic of the Control Center (no QML types, unit-tested in tests/unit/tst_ccmodel.qml).

// Wi-Fi rows: {name, strength 0..1, secured, enterprise, connected, known, connecting, net}.
// Hidden (empty) names are dropped, duplicates (same SSID on several access points) keep the
// strongest one, the connected network comes first, then by strength, then by name.
function sortNetworks(rows) {
    const best = {};
    for (let i = 0; i < rows.length; i++) {
        const r = rows[i];
        if (!r || r.name === "")
            continue;
        const prev = best[r.name];
        if (!prev || (r.connected && !prev.connected) || (r.connected === prev.connected && r.strength > prev.strength))
            best[r.name] = r;
    }
    return Object.keys(best).map(k => best[k]).sort((a, b) => {
        if (a.connected !== b.connected)
            return a.connected ? -1 : 1;
        if (a.strength !== b.strength)
            return b.strength - a.strength;
        return a.name.localeCompare(b.name);
    });
}

// What clicking a Wi-Fi row does: "disconnect" | "connect" | "password" | "editor".
// Enterprise networks (802.1X) cannot be set up inline: they go to nm-connection-editor.
function networkAction(row) {
    if (row.connected)
        return "disconnect";
    if (row.known || !row.secured)
        return "connect";
    return row.enterprise ? "editor" : "password";
}

// Paired Bluetooth devices: {name, paired, connected, battery (0..1 or -1), dev}; connected first, then by name.
function sortDevices(rows) {
    return rows.filter(r => r.paired).sort((a, b) => {
        if (a.connected !== b.connected)
            return a.connected ? -1 : 1;
        return a.name.localeCompare(b.name);
    });
}

function batteryText(battery) {
    return battery >= 0 ? Math.round(battery * 100) + "%" : "";
}

// Audio rows: nodes → {label, isDefault, node}, alphabetical.
function audioRows(nodes, defaultNode, describe) {
    return nodes.map(n => ({label: describe(n), isDefault: n === defaultNode, node: n}))
        .sort((a, b) => a.label.localeCompare(b.label));
}

// Airplane mode is derived: on when every present radio is off. With no radio at all it is off.
function airplaneOn(wifiPresent, wifiOn, btPresent, btOn) {
    if (!wifiPresent && !btPresent)
        return false;
    return (!wifiPresent || !wifiOn) && (!btPresent || !btOn);
}

// Radios to switch when airplane mode is turned on/off: {wifi: bool|null, bluetooth: bool|null}
// (null = not present, leave alone). Turning it off re-enables every present radio.
function airplaneTargets(wifiPresent, btPresent, turnOn) {
    return {wifi: wifiPresent ? !turnOn : null, bluetooth: btPresent ? !turnOn : null};
}

// Next index for arrow navigation over `count` items (no wrap).
function stepIndex(current, count, delta) {
    if (count <= 0)
        return -1;
    if (current < 0)
        return delta > 0 ? 0 : count - 1;
    return Math.max(0, Math.min(count - 1, current + delta));
}

// Quickshell ConnectionFailReason (enum order: Unknown, NoSecrets, WifiClientDisconnected,
// WifiClientFailed, WifiAuthTimeout, WifiNetworkLost) -> a stable key the UI translates.
function failReasonKey(reason) {
    switch (reason) {
    case 1: return "noSecrets";
    case 2: return "disconnected";
    case 3: return "failed";
    case 4: return "timeout";
    case 5: return "lost";
    default: return "unknown";
    }
}
