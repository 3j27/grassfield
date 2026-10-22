.pragma library

// Filter chips of Search (macOS 26 Spotlight keeps a row of them under the field). Pure: Search.qml owns the
// state. A chip narrows the results to one kind of item; the inline answers (calculator, conversion) belong to
// no chip and are hidden while one is selected.

const CHIPS = [
    {id: "apps", kinds: ["app"]},
    {id: "commands", kinds: ["command"]},
    {id: "documents", kinds: ["file", "recent"]}
];

// The chip ids that have at least one item in `groups` ([{id, title, items}]), in the fixed chip order.
function chipsOf(groups) {
    const out = [];
    for (const c of CHIPS) {
        if (groups.some(g => g.items.some(it => c.kinds.indexOf(it.kind) >= 0)))
            out.push(c.id);
    }
    return out;
}

// `groups` narrowed to the chip `filter` (a chip id): one group with every matching item, the Top Hit included, in
// the order the groups had. An empty or unknown filter returns `groups` unchanged. `title` names the group.
function apply(groups, filter, title) {
    const chip = CHIPS.find(c => c.id === filter);
    if (!chip)
        return groups;
    const items = [];
    for (const g of groups) {
        for (const it of g.items) {
            if (chip.kinds.indexOf(it.kind) >= 0)
                items.push(it);
        }
    }
    return items.length > 0 ? [{id: chip.id, title: title, items: items}] : [];
}
