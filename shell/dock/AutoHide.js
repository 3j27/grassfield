.pragma library

// Dock auto-hide state machine (pure, unit-tested). Time in ms; `visible` runs 1 (shown) to 0 (hidden).
//
//   shown     --no inhibitor for hideGrace-->             hiding
//   hiding    --inhibitor (pointer included)-->           revealing   (from the current position, no jump)
//   hiding    --visible reaches 0-->                      hidden
//   hidden    --drag, popup, hold, keyboard-->            revealing   (never waits)
//   hidden    --pointer at the edge for revealDwell-->    revealing
//   revealing --visible reaches 1-->                      shown
//
// Inhibitors keep the Dock shown: pointer over it, a drag, a Dock popup or menu, a press and hold, keyboard mode, and
// `attention` (an app asked for attention: the Dock comes out for a moment, a token duration set by the Dock).
// While hidden the pointer can only be at the edge strip (the input mask is the strip), so `pointer` means "at the edge".

function create() {
    return {
        state: "shown",
        visible: 1,
        timer: 0
    };
}

// True when the Dock must not leave (or must come back to) the shown state.
function inhibited(inh) {
    return !!(inh.pointer || inh.drag || inh.popup || inh.hold || inh.keyboard || inh.forced || inh.attention);
}

// Inhibitors other than the pointer (they reveal a hidden Dock at once, the pointer waits for its dwell).
function forcing(inh) {
    return !!(inh.drag || inh.popup || inh.hold || inh.keyboard || inh.forced || inh.attention);
}

// Next machine after `dt` ms. `timing` is {hideGrace, hideDuration, revealDwell, revealDuration}; with `enabled` false
// the Dock is simply shown.
function step(m, inh, enabled, timing, dt) {
    const out = {
        state: m.state,
        visible: m.visible,
        timer: m.timer
    };
    if (!enabled) {
        out.state = "shown";
        out.visible = 1;
        out.timer = 0;
        return out;
    }
    const busy = inhibited(inh);
    switch (m.state) {
    case "shown":
        out.visible = 1;
        if (busy) {
            out.timer = 0;
        } else {
            out.timer = m.timer + dt;
            if (out.timer >= timing.hideGrace) {
                out.state = "hiding";
                out.timer = 0;
            }
        }
        break;
    case "hiding":
        if (busy) {
            out.state = "revealing";
            out.timer = 0;
        } else {
            out.visible = Math.max(0, m.visible - dt / Math.max(1, timing.hideDuration));
            if (out.visible <= 0) {
                out.state = "hidden";
                out.timer = 0;
            }
        }
        break;
    case "hidden":
        out.visible = 0;
        if (forcing(inh)) {
            out.state = "revealing";
            out.timer = 0;
        } else if (inh.pointer) {
            out.timer = m.timer + dt;
            if (out.timer >= timing.revealDwell) {
                out.state = "revealing";
                out.timer = 0;
            }
        } else {
            out.timer = 0;
        }
        break;
    case "revealing":
        out.visible = Math.min(1, m.visible + dt / Math.max(1, timing.revealDuration));
        if (out.visible >= 1) {
            out.state = "shown";
            out.timer = 0;
        }
        break;
    }
    return out;
}

// Whether the machine still needs time to advance (the Dock stops its frame clock otherwise).
function active(m, inh, enabled) {
    if (!enabled)
        return m.state !== "shown";
    if (m.state === "hidden")
        return inhibited(inh);
    if (m.state === "shown")
        return !inhibited(inh);
    return true;
}

// Easing of the slide: smooth at both ends (the position, not the time, is what is eased).
function ease(visible) {
    const x = Math.min(1, Math.max(0, visible));
    return x * x * (3 - 2 * x);
}
