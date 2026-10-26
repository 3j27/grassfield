.pragma library

// The screen saver's pure logic (ADR-0032): when it is armed, which saver, the clock's text and where the clock alone stands.
// Saver.qml and SaverView.qml only run what this decides; tests/unit/tst_savermodel.qml.

var KINDS = ["artwork", "wallpaperClock", "slideshow", "clock"];
// The longest delay the settings allow (screensaver.idleMinutes), in seconds.
var MAX_SECONDS = 240 * 60;

// The monitor counts only while the session is unlocked, no application holds a ScreenSaver inhibitor, the delay is set
// and the monitor is not being re-armed for a new delay.
function armed(seconds, locked, busInhibited, rearming) {
    return seconds > 0 && seconds <= MAX_SECONDS && locked !== true && busInhibited !== true && rearming !== true;
}

// A stored kind the shell does not know (a newer or hand-edited file) shows the artwork.
function kindOf(kind) {
    return KINDS.indexOf(kind) >= 0 ? kind : "artwork";
}

// The slideshow's folder: the setting, or the Pictures folder when it is empty.
function folderOf(setting, picturesRoot) {
    return typeof setting === "string" && setting !== "" ? setting : picturesRoot;
}

// The clock's format from the locale's short time format: 12-hour where the locale writes AM/PM, else 24-hour (the lock
// screen's rule, LockMachine.clockFormat).
function clockFormat(localeTimeFormat) {
    return /a/i.test(String(localeTimeFormat || "")) ? "h:mm" : "H:mm";
}

// Where the clock alone stands during minute `minute` (minutes since the epoch): a place inside the screen, with `margin`
// around it, that changes every minute and repeats only after a long while. Pure: the same minute gives the same place on
// every screen of the same size.
function clockPlace(minute, width, height, boxWidth, boxHeight, margin) {
    const spanX = Math.max(0, width - boxWidth - 2 * margin);
    const spanY = Math.max(0, height - boxHeight - 2 * margin);
    // Two coprime steps walk the unit square without settling (a low-discrepancy sequence).
    const fx = ((minute * 0.6180339887) % 1 + 1) % 1;
    const fy = ((minute * 0.7548776662) % 1 + 1) % 1;
    return {x: Math.round(margin + fx * spanX), y: Math.round(margin + fy * spanY)};
}

// What the wallpaper-with-clock saver draws under its clock for one display: the picture the desktop shows there (a file the
// wallpaper helper prepared: the shell decodes only those, ADR-0016), else the wallpaper's colour, else the artwork.
// `published` is {file: WallpaperState.lockStill(name)} (the checked picture, "" when there is none) or undefined, `cfg` the
// display's resolved wallpaper settings.
function backdrop(published, cfg) {
    if (published && typeof published.file === "string" && published.file !== "")
        return {kind: "picture", file: published.file, color: ""};
    if (cfg && cfg.source === "color" && typeof cfg.color === "string")
        return {kind: "color", file: "", color: cfg.color};
    return {kind: "art", file: "", color: ""};
}
