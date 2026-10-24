.pragma library

// The keys that activate a control (press a button, toggle a box, open a pop-up). One list for every control, so that a hidden
// or disabled control that still holds the focus swallows exactly the keys the Qt templates would act on: a key missing
// from one control's own list (Qt.Key_Select was) lets the template click it.
// `activation(key)` is true for Space, Return, Enter and Select; `navigation(key)` for the arrows a group or a list moves by.

var ACTIVATION = [0x20, 0x01000004, 0x01000005, 0x01010000]; // Space, Return, Enter, Select (Qt.Key_*)
var ARROWS = [0x01000012, 0x01000013, 0x01000014, 0x01000015]; // Left, Up, Right, Down

function activation(key) {
    return ACTIVATION.indexOf(key) >= 0;
}

function navigation(key) {
    return ARROWS.indexOf(key) >= 0;
}
