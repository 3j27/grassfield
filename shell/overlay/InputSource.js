.pragma library

// Which input device moved the focus last: the keyboard focus ring is kept for the keyboard (macOS). The ring of a keyboard-focused control
// stays whatever the pointer does over it; only a pointer PRESS hands the focus to the mouse. Hover (including the hover updates a
// redraw sends without the mouse moving) never changes it.
function start() {
    return {keyboard: false};
}

// The focus moved to a control; `visualFocus` is true when Qt moved it with a keyboard reason (Tab, the arrows).
function focusMoved(state, visualFocus) {
    return visualFocus === true ? {keyboard: true} : state;
}

// A pointer button went down anywhere on the panel.
function pressed(state) {
    return {keyboard: false};
}

// A pointer moved or hovered: no change.
function hovered(state) {
    return state;
}

// The focus is a visible keyboard focus now.
function ringShown(state, visualFocus) {
    return state.keyboard && visualFocus === true;
}
