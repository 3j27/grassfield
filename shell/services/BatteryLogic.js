.pragma library

// Pure logic of the Quick Settings Battery module (macOS Battery menu: percentage, time remaining, power source,
// Low Power Mode). Unit-tested in tests/unit/tst_battery.qml. Enum values are Quickshell's UPowerDeviceState
// (Unknown 0, Charging 1, Discharging 2, Empty 3, FullyCharged 4, PendingCharge 5, PendingDischarge 6) and PowerProfile
// (PowerSaver 0, Balanced 1, Performance 2).

const CHARGING = 1;
const DISCHARGING = 2;
const EMPTY = 3;
const FULL = 4;
const PENDING_CHARGE = 5;
const PENDING_DISCHARGE = 6;
const POWER_SAVER = 0;
const BALANCED = 1;

// Whole percent 0..100 from UPower's fraction 0..1.
function percent(fraction) {
    if (typeof fraction !== "number" || isNaN(fraction))
        return 0;
    return Math.max(0, Math.min(100, Math.round(fraction * 100)));
}

// "H:MM" for a number of seconds (rounded to whole minutes); "" for no estimate (zero, negative or not a number).
function duration(seconds) {
    if (typeof seconds !== "number" || !(seconds > 0))
        return "";
    const minutes = Math.round(seconds / 60);
    return Math.floor(minutes / 60) + ":" + String(minutes % 60).padStart(2, "0");
}

// Where the power comes from: "adapter" while charging, full or waiting to charge, or when UPower says the system is
// not on battery; "battery" otherwise.
function source(state, onBattery) {
    if (state === CHARGING || state === FULL || state === PENDING_CHARGE)
        return "adapter";
    if (onBattery === false && state !== DISCHARGING && state !== EMPTY)
        return "adapter";
    return "battery";
}

// What the second line says: {kind: "full" | "charging" | "discharging" | "idle", time: "H:MM" or ""}.
function status(state, timeToEmpty, timeToFull) {
    if (state === FULL)
        return {kind: "full", time: ""};
    if (state === CHARGING)
        return {kind: "charging", time: duration(timeToFull)};
    if (state === DISCHARGING || state === EMPTY)
        return {kind: "discharging", time: duration(timeToEmpty)};
    return {kind: "idle", time: ""};
}

// Low Power Mode is the power-saver profile of power-profiles-daemon.
function lowPower(profile) {
    return profile === POWER_SAVER;
}

// The profile that Low Power Mode on or off selects (off returns to Balanced).
function profileFor(on) {
    return on ? POWER_SAVER : BALANCED;
}

// Icon of the module: the charging glyph while charging, else the battery.
function iconName(state) {
    return state === CHARGING ? "battery-charging" : "battery";
}
