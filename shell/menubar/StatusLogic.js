.pragma library

// Pure decisions of the menu bar's status area (no Quickshell types, tested by tests/unit/tst_statuslogic.qml).

// StatusNotifierItem Status as Quickshell numbers it (Passive, Active, NeedsAttention).
var PASSIVE = 0;
var NEEDS_ATTENTION = 2;

// A tray item gets a slot while it is alive and not Passive (the SNI spec: a Passive item "should be hidden or moved to
// an overflow"). `item` is the Quickshell SystemTrayItem; anything that is not an object (a dead handle) has no slot.
function trayShown(item) {
    if (!item || typeof item !== "object")
        return false;
    // No icon: nothing to draw yet (before the first GetAll) or never (a broken item); a slot would be a phantom.
    if (typeof item.icon !== "string" || item.icon === "")
        return false;
    return item.status !== PASSIVE;
}

function needsAttention(item) {
    return !!item && item.status === NEEDS_ATTENTION;
}

// What a press does, per the SNI semantics: ItemIsMenu (onlyMenu) means the primary click is the menu; otherwise the
// primary click is Activate, and the menu is the context menu (right click). The middle button is SecondaryActivate.
// button: "left" | "right" | "middle". Returns "menu" | "activate" | "secondary" | "none".
function clickAction(item, button) {
    if (!item)
        return "none";
    var menu = !!item.hasMenu;
    if (button === "middle")
        return "secondary";
    if (button === "right")
        return menu ? "menu" : "none";
    if (item.onlyMenu)
        return menu ? "menu" : "activate";
    return "activate";
}

// A hovering pointer may switch to this item's menu while another bar menu is open.
function opensMenu(item) {
    return !!item && !!item.hasMenu;
}

// Accessible name: the app's title, else the tooltip, else its id.
function accessibleName(item) {
    if (!item)
        return "";
    var parts = [item.title, item.tooltipTitle, item.id];
    for (var i = 0; i < parts.length; i++) {
        if (typeof parts[i] === "string" && parts[i].trim() !== "")
            return parts[i].trim();
    }
    return "";
}

// Now Playing item (macOS: shown while the app has a session, i.e. playing or paused with a track loaded).
function nowPlayingShown(enabled, available, playing, title) {
    return !!enabled && !!available && (!!playing || (typeof title === "string" && title !== ""));
}

// Crowding (macOS: status items that would collide with the menus are hidden). items are in bar order, left to right:
// [{key, width, optional}]. `available` is the width the status area may use (the space between the application
// menus' right edge and the screen's right inset). Optional items are dropped leftmost first until the rest fits;
// mandatory ones stay. Returns {key: true} for every hidden item. `gap` is the margin kept per item.
function hiddenItems(available, items, gap) {
    var hidden = {};
    var total = 0;
    for (var i = 0; i < items.length; i++)
        total += items[i].width + (gap || 0);
    for (var at = 0; at < items.length && total > available; at++) {
        if (items[at].optional) {
            hidden[items[at].key] = true;
            total -= items[at].width + (gap || 0);
        }
    }
    return hidden;
}
