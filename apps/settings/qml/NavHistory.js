.pragma library

// Back / forward through the panes of Settings (macOS: the back and forward capsule of the toolbar). Pure: a state is
// {back: [ids], forward: [ids], current: id}; every function returns a new state.

function start(current) {
    return {back: [], forward: [], current: current};
}

// The user chose another pane: the old one goes on the back list, the forward list is forgotten. The same pane changes nothing.
function visit(state, id) {
    if (id === state.current)
        return state;
    return {back: state.back.concat([state.current]), forward: [], current: id};
}

function canBack(state) {
    return state.back.length > 0;
}

function canForward(state) {
    return state.forward.length > 0;
}

function back(state) {
    if (!canBack(state))
        return state;
    return {back: state.back.slice(0, -1), forward: [state.current].concat(state.forward), current: state.back[state.back.length - 1]};
}

function forward(state) {
    if (!canForward(state))
        return state;
    return {back: state.back.concat([state.current]), forward: state.forward.slice(1), current: state.forward[0]};
}
