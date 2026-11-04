.pragma library

// Pure logic of the Battery pane: UPower's state (`power.state`, src/systembus.h powerState), the Low Power Mode choice over
// Omarchy's two remembered power profiles (one for the power adapter, one for the battery: omarchy-powerprofiles-set), the
// level chart's bars. No I/O here.

var PROFILES = ["power-saver", "balanced", "performance"];

// The `power.state` JSON, checked: {present, onBattery, percent (0-100), state, timeToEmpty, timeToFull, capacity, cycles,
// limitSupported, limitEnabled, limitEnd, history24, history10 ([[time, percent, state]])}; null when the text is not that.
function parseState(text) {
    let j;
    try {
        j = JSON.parse(String(text));
    } catch (e) {
        return null;
    }
    if (j === null || typeof j !== "object" || typeof j.present !== "boolean")
        return null;
    const num = (v, low, high, fallback) => (typeof v === "number" && isFinite(v) && v >= low && v <= high ? v : fallback);
    const history = h => (Array.isArray(h) ? h.filter(p => Array.isArray(p) && p.length === 3 && typeof p[0] === "number" && typeof p[1] === "number")
                                              .map(p => [p[0], num(p[1], 0, 100, 0), p[2] | 0]) : []);
    return {
        present: j.present, onBattery: j.onBattery === true, percent: Math.round(num(j.percent, 0, 100, 0)), state: num(j.state, 0, 6, 0) | 0,
        timeToEmpty: num(j.timeToEmpty, 0, 1e7, 0), timeToFull: num(j.timeToFull, 0, 1e7, 0), capacity: num(j.capacity, 0, 200, 0),
        cycles: num(j.cycles, -1, 1e6, -1) | 0, limitSupported: j.limitSupported === true, limitEnabled: j.limitEnabled === true,
        limitEnd: num(j.limitEnd, 0, 100, 0) | 0, history24: history(j.history24), history10: history(j.history10)
    };
}

// UPower's states (UpDeviceState): 1 charging, 2 discharging, 3 empty, 4 fully charged, 5 pending charge, 6 pending discharge.
function kind(state) {
    return state === 4 ? "full" : state === 1 || state === 5 ? "charging" : state === 2 || state === 3 || state === 6 ? "discharging" : "unknown";
}

// "1:05" for 3900 seconds; "" for none.
function duration(seconds) {
    const s = Math.round(Number(seconds));
    if (!(s > 0))
        return "";
    const m = Math.round(s / 60);
    return Math.floor(m / 60) + ":" + String(m % 60).padStart(2, "0");
}

// Battery Health as macOS words it: "normal" from 80 % of the design capacity, else "service"; "" when UPower does not know.
function health(capacity) {
    return capacity > 0 ? (capacity >= 80 ? "normal" : "service") : "";
}

// The Low Power Mode choice from the two remembered profiles: "never", "always", "battery" (only on battery), "adapter".
function lowPowerMode(acProfile, batteryProfile) {
    const ac = String(acProfile).trim() === "power-saver";
    const battery = String(batteryProfile).trim() === "power-saver";
    return ac && battery ? "always" : battery ? "battery" : ac ? "adapter" : "never";
}

// The two profiles a choice sets: power-saver where it asks for low power, else the profile remembered there unless it was
// power-saver (then Omarchy's own default: performance on the adapter when the machine has it, balanced on battery).
function profilesFor(mode, acProfile, batteryProfile, available) {
    const offers = p => available.indexOf(p) >= 0;
    const keep = (p, fallback) => (PROFILES.indexOf(String(p).trim()) >= 0 && String(p).trim() !== "power-saver" ? String(p).trim() : fallback);
    const acLow = mode === "always" || mode === "adapter";
    const batteryLow = mode === "always" || mode === "battery";
    return {
        ac: acLow ? "power-saver" : keep(acProfile, offers("performance") ? "performance" : "balanced"),
        battery: batteryLow ? "power-saver" : keep(batteryProfile, "balanced")
    };
}

// The two commands, the current power source last: omarchy-powerprofiles-set applies what it remembers at once, so the source
// in use must win. null when a profile is not one of power-profiles-daemon's.
function commands(profiles, onBattery) {
    if (PROFILES.indexOf(profiles.ac) < 0 || PROFILES.indexOf(profiles.battery) < 0)
        return null;
    const ac = ["omarchy-powerprofiles-set", "ac", profiles.ac];
    const battery = ["omarchy-powerprofiles-set", "battery", profiles.battery];
    return onBattery ? [ac, battery] : [battery, ac];
}

// ---- Energy (a computer without a battery: macOS 27 shows Energy in place of Battery) ----

// macOS 27's Energy Mode over power-profiles-daemon's profiles, in macOS's order: Automatic is balanced, Low Power is
// power-saver, High Power is performance.
var ENERGY_MODES = [{id: "automatic", profile: "balanced"}, {id: "low", profile: "power-saver"}, {id: "high", profile: "performance"}];

// The modes this computer offers (`available`: the profiles power-profiles-daemon lists), in macOS's order; none without the
// daemon.
function energyModes(available) {
    const list = Array.isArray(available) ? available : [];
    return ENERGY_MODES.filter(m => list.indexOf(m.profile) >= 0).map(m => m.id);
}

// The profile Omarchy applies on the power adapter (a computer without a battery is always on it): the one it remembers when
// the daemon offers it, else its own default (performance where offered, else balanced), as omarchy-powerprofiles-set does.
function adapterProfile(acProfile, available) {
    const list = Array.isArray(available) ? available : [];
    const remembered = String(acProfile === undefined || acProfile === null ? "" : acProfile).trim();
    if (PROFILES.indexOf(remembered) >= 0 && list.indexOf(remembered) >= 0)
        return remembered;
    return list.indexOf("performance") >= 0 ? "performance" : "balanced";
}

// The Energy Mode shown: the one of the profile Omarchy applies; "" when the daemon offers nothing (the row is disabled).
function energyMode(acProfile, available) {
    if (energyModes(available).length === 0)
        return "";
    const profile = adapterProfile(acProfile, available);
    for (const m of ENERGY_MODES) {
        if (m.profile === profile)
            return m.id;
    }
    return "";
}

// The command that sets a mode: Omarchy's, for the power adapter (it applies it at once and remembers it, as Battery's Low
// Power Mode does). null for a mode this computer does not offer.
function energyCommand(mode, available) {
    for (const m of ENERGY_MODES) {
        if (m.id === mode)
            return energyModes(available).indexOf(mode) >= 0 ? ["omarchy-powerprofiles-set", "ac", m.profile] : null;
    }
    return null;
}

// The pane Settings shows for a section id (Main.qml), as macOS does: Battery on a computer with a battery, Energy without
// one; asked for the other, this one. Any other id as it is.
function paneFor(id, hasBattery) {
    if (id === "battery" && hasBattery !== true)
        return "energy";
    if (id === "energy" && hasBattery === true)
        return "battery";
    return id;
}

// `omarchy-powerprofiles-list`: one profile name per line.
function parseProfiles(text) {
    return String(text).split("\n").map(s => s.trim()).filter(s => PROFILES.indexOf(s) >= 0);
}

// The chart's bars: `count` buckets of `span / count` seconds ending at `end` (seconds since the epoch). Each bar is the level
// UPower recorded last at or before the bucket's end (its history keeps changes only), -1 before the first record or after now;
// `charging` when that record is a charging one.
function bars(history, end, span, count, now) {
    const out = [];
    const step = span / count;
    let i = 0;
    let last = null;
    for (let k = 0; k < count; k++) {
        const until = end - span + (k + 1) * step;
        while (i < history.length && history[i][0] <= until) {
            last = history[i];
            i++;
        }
        const future = end - span + k * step > now;
        out.push(last === null || future ? {level: -1, charging: false} : {level: last[1], charging: last[2] === 1 || last[2] === 4});
    }
    return out;
}

// The end of a chart's window: the next whole 3-hour mark after `now` (24 hours) or the next midnight (10 days), local time.
function windowEnd(now, days) {
    const d = new Date(now * 1000);
    if (days > 1) {
        d.setHours(24, 0, 0, 0);
    } else {
        d.setMinutes(0, 0, 0);
        d.setHours(d.getHours() + 3 - d.getHours() % 3);
    }
    return Math.round(d.getTime() / 1000);
}
