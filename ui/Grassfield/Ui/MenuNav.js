.pragma library

// Keyboard navigation model of a popup menu (pure functions, unit-tested).
// An item is {text, enabled?, separator?, submenu?}; enabled defaults to true.

function selectable(item) {
    return item !== undefined && item !== null && !item.separator && item.enabled !== false;
}

// Next selectable index from `index` in direction dir (+1/-1), wrapping; -1 if none.
function step(items, index, dir) {
    const n = items.length;
    if (n === 0)
        return -1;
    let i = index;
    for (let k = 0; k < n; k++) {
        i = i < 0 ? (dir > 0 ? 0 : n - 1) : (i + dir + n) % n;
        if (selectable(items[i]))
            return i;
    }
    return -1;
}

function first(items) {
    return step(items, -1, 1);
}

function last(items) {
    return step(items, -1, -1);
}

function hasSubmenu(item) {
    return item !== undefined && item !== null && item.submenu !== undefined && item.submenu.length > 0;
}

// A row of colour swatches ({swatches: [{id, color, name, state}], caption?, enabled?}): one menu row whose swatches
// are chosen with Left/Right (wrapping) and Return/Space.
function hasSwatches(item) {
    return item !== undefined && item !== null && item.swatches !== undefined && item.swatches.length > 0;
}

// Next swatch of a swatch row from `swatchIndex` in direction dir (+1/-1), wrapping.
function stepSwatch(item, swatchIndex, dir) {
    const n = hasSwatches(item) ? item.swatches.length : 0;
    if (n === 0)
        return -1;
    if (swatchIndex < 0)
        return dir > 0 ? 0 : n - 1;
    return (swatchIndex + dir + n) % n;
}

// Result of a key press: {index, action} with action one of
// "", "activate", "close", "openSubmenu", "closeSubmenu", "swatchPrevious", "swatchNext", "nextMenu", "previousMenu".
// nextMenu / previousMenu (macOS): Right on a row without a submenu, or Left in a top-level menu, moves to the
// neighbouring title of a menu bar; a host without one ignores them.
// On a swatch row "activate" means: choose the swatch under the row's cursor.
function handleKey(items, index, key, isSubmenu) {
    const onSwatches = selectable(items[index]) && hasSwatches(items[index]);
    if (onSwatches && (key === "left" || key === "right"))
        return {index: index, action: key === "left" ? "swatchPrevious" : "swatchNext"};
    switch (key) {
    case "down":
        return {index: step(items, index, 1), action: ""};
    case "up":
        return {index: step(items, index, -1), action: ""};
    case "home":
        return {index: first(items), action: ""};
    case "end":
        return {index: last(items), action: ""};
    case "return":
    case "space":
        if (!selectable(items[index]))
            return {index: index, action: ""};
        return {index: index, action: hasSubmenu(items[index]) ? "openSubmenu" : "activate"};
    case "right":
        return {index: index, action: selectable(items[index]) && hasSubmenu(items[index]) ? "openSubmenu" : "nextMenu"};
    case "left":
        return {index: index, action: isSubmenu ? "closeSubmenu" : "previousMenu"};
    case "escape":
        return {index: index, action: isSubmenu ? "closeSubmenu" : "close"};
    }
    return {index: index, action: ""};
}

// Which rows reserve the leading icon / check slot (macOS: the text starts at the plain inset, and a section whose rows
// have an icon or a check pushes the text of that whole section, separators bound sections). Returns one boolean per
// item; separators and swatch rows get false.
function leadSlots(items) {
    const out = [];
    let start = 0;
    const flush = end => {
        let any = false;
        for (let i = start; i < end; i++) {
            const it = items[i];
            if (it && !it.separator && ((typeof it.iconName === "string" && it.iconName !== "") || it.checked === true))
                any = true;
        }
        for (let i = start; i < end; i++)
            out.push(any && !!items[i] && !items[i].separator);
    };
    for (let i = 0; i < items.length; i++) {
        if (items[i] && items[i].separator) {
            flush(i);
            out.push(false);
            start = i + 1;
        }
    }
    flush(items.length);
    return out;
}
