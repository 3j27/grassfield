.pragma library

// Parses a `grassfield` raw event payload of type "capabilities" (gfc/1): {features, present} or null when the
// payload is not a capabilities event. `present` is false for an empty list: the plugin posts it when it unloads
// (docs/specs/desktop.md "Compositor focus policy" 1), every feature is gone and the shell is degraded again.
function parse(data, protocol) {
    let msg = null;
    try {
        msg = JSON.parse(data);
    } catch (e) {
        return null;
    }
    if (!msg || msg.v !== protocol || msg.type !== "capabilities" || !Array.isArray(msg.features))
        return null;
    const features = msg.features.filter(f => typeof f === "string");
    return {features: features, present: features.length > 0};
}
