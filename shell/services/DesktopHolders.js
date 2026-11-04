.pragma library

// Which desktop surfaces hold the keyboard (DesktopState.holdsKeyboard), pure. Every display has its own desktop surface;
// each reports for itself under its own key, and the desktop holds the keyboard while any of them does, so a focus-out
// on one display never clears the state of another whose menu is open.

// `holders` ({key: true}) with `key` holding or not. A new object.
function updated(holders, key, on) {
    const out = Object.assign({}, holders || {});
    if (on === true)
        out[String(key)] = true;
    else
        delete out[String(key)];
    return out;
}

function any(holders) {
    return holders !== null && typeof holders === "object" && Object.keys(holders).length > 0;
}
