.pragma library

// Back and forward through the Store's pages (the toolbar's capsule, Ctrl+[ and Ctrl+], Alt+Left and Alt+Right; spec SR3).
// A page is {page, id, query, tab}: page is section, categories, category, app, search, installed or updates; tab the
// sidebar row it belongs to. Each page left keeps its scroll position (`scroll`), restored when it comes back. Pure: every
// function returns a new state.

function start(entry) {
    return {back: [], forward: [], current: entry};
}

function same(a, b) {
    return a.page === b.page && (a.id || "") === (b.id || "") && (a.query || "") === (b.query || "");
}

function leaving(state, scroll) {
    return Object.assign({}, state.current, {scroll: scroll || 0});
}

// Another page: the one left goes on the back list with its scroll, the forward list is forgotten. The same page changes nothing.
function visit(state, entry, scroll) {
    if (same(entry, state.current))
        return state;
    return {back: state.back.concat([leaving(state, scroll)]), forward: [], current: Object.assign({scroll: 0}, entry)};
}

// The search's query as it is typed: the current page changes in place (no page per key).
function replace(state, entry) {
    return {back: state.back, forward: state.forward, current: Object.assign({scroll: 0}, entry)};
}

function canBack(state) {
    return state.back.length > 0;
}

function canForward(state) {
    return state.forward.length > 0;
}

function back(state, scroll) {
    if (!canBack(state))
        return state;
    return {back: state.back.slice(0, -1), forward: [leaving(state, scroll)].concat(state.forward), current: state.back[state.back.length - 1]};
}

function forward(state, scroll) {
    if (!canForward(state))
        return state;
    return {back: state.back.concat([leaving(state, scroll)]), forward: state.forward.slice(1), current: state.forward[0]};
}
