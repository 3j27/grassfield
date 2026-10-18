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

// True when `data` claims to be a capabilities event of this protocol but cannot be parsed as one (features missing or
// not a list). Events of other types (overview, ...) and foreign payloads are not malformed capabilities events.
function isMalformedCapabilities(data, protocol) {
    let msg = null;
    try {
        msg = JSON.parse(data);
    } catch (e) {
        return false;
    }
    return !!msg && msg.v === protocol && msg.type === "capabilities" && !Array.isArray(msg.features);
}

// The protocol version of a capabilities event of another protocol ("gfc/2", "?" when it names none), "" for anything
// else (this protocol, other event types, foreign payloads). parse() returns null for such an event, so the shell treats
// a plugin it cannot speak to as no plugin; the caller only logs it.
function otherProtocolCapabilities(data, protocol) {
    let msg = null;
    try {
        msg = JSON.parse(data);
    } catch (e) {
        return "";
    }
    if (!msg || msg.type !== "capabilities" || msg.v === protocol)
        return "";
    return typeof msg.v === "string" && msg.v !== "" ? msg.v : "?";
}
