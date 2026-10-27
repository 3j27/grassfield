.pragma library

// Pure tab helpers of Grassfield Files (unit tested in tests/unit/tst_filestabs.qml): the tab bar's visibility, slots
// for a dragged tab, list moves and the stack of closed tabs (docs/specs/files.md FP-2 to FP-11).

// The MIME type of a dragged tab: "<process id>:<tab id>". A drop from another process is refused.
const tabMimeType = "application/x-grassfield-files-tab";

// Closed tabs kept for File > Reopen Closed Tab (newest first).
const maxClosedTabs = 10;

// The bar shows from the second tab, or with one tab when View > Show Tab Bar is on (Finder).
function barVisible(shown, count) {
    return shown === true || count > 1;
}

// The current index after closing tab `closed` of `count` tabs (the left neighbour takes over, as before).
function indexAfterClose(current, closed, count) {
    const remaining = count - 1;
    if (remaining <= 0)
        return 0;
    const next = current >= closed && current > 0 ? current - 1 : current;
    return Math.min(next, remaining - 1);
}

// Width of one tab when `slots` equal tabs share `trackWidth`.
function tabWidth(trackWidth, slots) {
    return slots > 0 ? Math.max(0, trackWidth / slots) : trackWidth;
}

// The slot (0 .. slots - 1) under `x` in a track of `slots` equal tabs of `width`.
function slotAt(x, width, slots) {
    if (slots <= 0 || width <= 0)
        return 0;
    return Math.max(0, Math.min(slots - 1, Math.floor(x / width)));
}

// The slot tab `index` is drawn in while a tab is dragged. `from`: the dragged tab of this bar (-1: none); `to`: the slot
// a dragged tab hovers in this bar (-1: none). The tabs between the two slide over by one and the dragged tab takes `to`;
// a tab of another window (`from` < 0) opens slot `to`; a tab dragged out of the bar (`to` < 0) leaves no gap.
function visualSlot(index, from, to) {
    if (to < 0)
        return from >= 0 && index > from ? index - 1 : index;
    if (from < 0)
        return index >= to ? index + 1 : index;
    if (index === from)
        return to;
    if (from < to && index > from && index <= to)
        return index - 1;
    if (to < from && index >= to && index < from)
        return index + 1;
    return index;
}

// `list` with the item at `from` moved to `to` (indices of the result).
function moved(list, from, to) {
    const out = list.slice();
    if (from < 0 || from >= out.length)
        return out;
    const item = out.splice(from, 1)[0];
    out.splice(Math.max(0, Math.min(to, out.length)), 0, item);
    return out;
}

// The closed-tab stack with `entry` on top, at most maxClosedTabs entries.
function pushClosed(stack, entry) {
    return [entry].concat(stack).slice(0, maxClosedTabs);
}

// "<pid>:<id>" -> the tab id, or -1 when the text is not a tab of process `pid`.
function tabIdFrom(text, pid) {
    const m = /^(\d+):(\d+)$/.exec(String(text));
    if (!m || Number(m[1]) !== pid)
        return -1;
    return Number(m[2]);
}
