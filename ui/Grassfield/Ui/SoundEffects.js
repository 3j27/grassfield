.pragma library

// Grassfield's sound effects (ADR-0047 part B): which file an event plays, how loud, through which output, and the argument
// vector of `pw-play` that plays it. Shared by the shell (shell/services/Sounds.qml) and Settings > Sound (its previews,
// held to the same form by apps/settings/src/systemguard.cpp). Pure functions; nothing here starts a process.
//
// Events and what gates them:
//   alert            the alert sound (an application's error bell): sound.alert at sound.alertVolume (0 silences it), through
//                    sound.effectsOutput
//   screen-capture, trash-empty, dock-remove, power-plug
//                    interface sounds: only with sound.uiEffects, at sound.alertVolume, through sound.effectsOutput
//   volume-change    volume feedback: only with sound.volumeFeedback, at full stream volume through the default output (the
//                    output whose volume changed)
// Volumes are cubic, as wpctl and the volume keys: the stream volume is the level cubed.

var ALERTS = ["meadow", "dewdrop", "reed", "lantern", "ember", "thistle"];
var DEFAULT_ALERT = "meadow";
// The installed theme's files (packaging/arch/PKGBUILD installs branding/sounds/grassfield there).
var THEME_DIR = "/usr/share/sounds/grassfield/stereo";
// Volume feedback plays once the volume keys have rested this long (macOS plays it when the key is released; Grassfield's
// keys repeat after 250 ms, config/hypr/grassfield/omarchy.lua, so a held key plays once at its end).
var FEEDBACK_QUIET_MS = 350;
// The same sound is not started again within this (a burst of bells from a terminal).
var REPEAT_GAP_MS = 120;

var EVENTS = {
    "alert": {kind: "alert", file: ""},
    "screen-capture": {kind: "ui", file: "screen-capture.wav"},
    "trash-empty": {kind: "ui", file: "trash-empty.wav"},
    "dock-remove": {kind: "ui", file: "grassfield-dock-remove.wav"},
    "power-plug": {kind: "ui", file: "power-plug.wav"},
    "volume-change": {kind: "feedback", file: "audio-volume-change.wav"}
};

// The schema's rule of sound.effectsOutput (config/schema/grassfield.schema.json, rule nodeName).
var NODE_NAME = /^[A-Za-z0-9_][A-Za-z0-9_.:@+-]{0,254}$/;

function alertId(id) {
    return ALERTS.indexOf(id) >= 0 ? id : DEFAULT_ALERT;
}

function alertFile(id) {
    return "grassfield-alert-" + alertId(id) + ".wav";
}

// The file name of an event ("" for an unknown event).
function fileFor(event, alert) {
    const e = EVENTS[event];
    if (!e)
        return "";
    return e.kind === "alert" ? alertFile(alert) : e.file;
}

function clamp01(v) {
    return typeof v === "number" && isFinite(v) ? Math.max(0, Math.min(1, v)) : 0;
}

// pw-play's --volume (linear stream volume) for a level on the cubic scale, three decimals.
function streamVolume(level) {
    const l = clamp01(level);
    return (l * l * l).toFixed(3);
}

// The output to name with --target: the chosen output while it is connected (`sinks`: the node names of the outputs now),
// "" for the selected (default) device.
function target(output, sinks) {
    return typeof output === "string" && NODE_NAME.test(output) && Array.isArray(sinks) && sinks.indexOf(output) >= 0 ? output : "";
}

// The argument vector that plays `file` (a name of the theme directory) at `level` through `node` ("" = the default output).
function playArgv(themeDir, file, level, node) {
    if (typeof file !== "string" || !/^[a-z0-9-]{1,64}\.wav$/.test(file))
        return null;
    const argv = ["pw-play", "--media-role", "Notification", "--volume", streamVolume(level)];
    if (typeof node === "string" && node !== "" && NODE_NAME.test(node))
        argv.push("--target", node);
    argv.push("--", themeDir + "/" + file);
    return argv;
}

// What the shell plays for `event`, or null when nothing plays (unknown event, switched off, an alert volume of 0).
// settings: {alert, alertVolume, effectsOutput, uiEffects, volumeFeedback}; sinks: the node names of the outputs now.
function argvFor(event, settings, sinks, themeDir) {
    const e = EVENTS[event];
    if (!e || !settings)
        return null;
    const dir = themeDir || THEME_DIR;
    switch (e.kind) {
    case "alert":
        if (clamp01(settings.alertVolume) <= 0)
            return null;
        return playArgv(dir, alertFile(settings.alert), settings.alertVolume, target(settings.effectsOutput, sinks));
    case "ui":
        if (settings.uiEffects !== true || clamp01(settings.alertVolume) <= 0)
            return null;
        return playArgv(dir, e.file, settings.alertVolume, target(settings.effectsOutput, sinks));
    case "feedback":
        return settings.volumeFeedback === true ? playArgv(dir, e.file, 1, "") : null;
    }
    return null;
}

// Settings > Sound's preview of an alert sound at a level through an output ("" = the default): always plays, even at 0
// (a preview at 0 is silent anyway, and the person asked for it).
function previewArgv(alert, level, output) {
    return playArgv(THEME_DIR, alertFile(alert), level, typeof output === "string" ? output : "");
}

// ---- GNOME's keys (applications that play theme sounds: libcanberra, GSound) ------------------------------------------------

// org.gnome.desktop.sound event-sounds: such applications play theme sounds (their error bell included) only while it is on,
// so it is on only while Grassfield plays its own: interface sounds on and an alert volume above 0. GNOME has one switch for
// both; the stricter reading wins. input-feedback-sounds (clicks on buttons and keys) stays off: macOS plays none.
function gnomeEventSounds(settings) {
    return !!settings && settings.uiEffects === true && clamp01(settings.alertVolume) > 0;
}

// What the shell runs to keep them in step (Sounds.qml; never in a dev session).
function gnomeArgvs(settings) {
    return [
        ["gsettings", "set", "org.gnome.desktop.sound", "event-sounds", gnomeEventSounds(settings) ? "true" : "false"],
        ["gsettings", "set", "org.gnome.desktop.sound", "input-feedback-sounds", "false"]
    ];
}

// ---- Rate and debounce (state objects owned by the caller) ------------------------------------------------------------------

// Whether `event` may start now: not the same sound within REPEAT_GAP_MS. Records the start when it may.
function allowed(last, event, now) {
    const t = last[event];
    if (t !== undefined && now - t < REPEAT_GAP_MS && now >= t)
        return false;
    last[event] = now;
    return true;
}

// Volume feedback: a step of the volume keys. Up and down (re)arm the feedback; mute cancels it. Returns the time it is due,
// or null.
function feedbackStep(st, direction, now) {
    if (direction === "up" || direction === "down")
        st.due = now + FEEDBACK_QUIET_MS;
    else
        st.due = null;
    return st.due;
}

// Whether the feedback is due at `now` (it is then consumed).
function feedbackDue(st, now) {
    if (st.due === null || st.due === undefined || now < st.due)
        return false;
    st.due = null;
    return true;
}
