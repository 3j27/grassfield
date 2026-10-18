.pragma library

// The seven colour tags in palette order (src/taglogic.h: Red, Orange, Yellow, Green, Blue, Purple, Gray), from the
// design tokens: pass the Tokens singleton.
function list(tokens) {
    return [tokens.filesTagRed, tokens.filesTagOrange, tokens.filesTagYellow, tokens.filesTagGreen, tokens.filesTagBlue,
            tokens.filesTagPurple, tokens.filesTagGray];
}

// Colour of palette index `index`, "" when out of range.
function at(tokens, index) {
    const colors = list(tokens);
    return index >= 0 && index < colors.length ? colors[index] : "";
}

// Swatch row model of a selection for PopupMenu/SwatchRow: [{id: "tag:<index>", color, name, state}], `states` from
// FilesApp.colorTagStates (0 none, 1 some, 2 all), `names` from FilesApp.colorTagNames.
function swatches(tokens, names, states) {
    const colors = list(tokens);
    const out = [];
    for (let i = 0; i < colors.length; i++)
        out.push({id: "tag:" + i, color: colors[i], name: names[i] !== undefined ? names[i] : "", state: states[i] !== undefined ? states[i] : 0});
    return out;
}
