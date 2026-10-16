.pragma library

// Notification body sanitizer (spec N9, pure, unit-tested).
//
// Input is the untrusted body of org.freedesktop.Notifications (a small HTML subset). Output is
// safe for a QtQuick Text with textFormat Text.StyledText: only <b>, <i>, <u> and <br> survive,
// always balanced. Links are never made clickable: <a href="URL">label</a> becomes
// "label (URL)" as plain text. Images are dropped (alt text kept); every other tag is
// stripped and its text kept. Text is entity-normalised then re-escaped.

const MAX_LENGTH = 4000;
const ALLOWED = {b: true, i: true, u: true};
const ENTITIES = {amp: "&", lt: "<", gt: ">", quot: "\"", apos: "'", nbsp: " "};

function decode(text) {
    return text.replace(/&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);/g, (whole, name) => {
        if (name[0] === "#") {
            const code = name[1] === "x" || name[1] === "X" ? parseInt(name.slice(2), 16) : parseInt(name.slice(1), 10);
            if (!isFinite(code) || (code < 32 && code !== 10) || code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF))
                return "";
            return String.fromCodePoint(code);
        }
        return ENTITIES[name] !== undefined ? ENTITIES[name] : whole;
    });
}

function escapeText(text) {
    return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function attribute(tag, name) {
    const match = new RegExp("\\b" + name + "\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))", "i").exec(tag);
    if (!match)
        return "";
    return match[1] !== undefined ? match[1] : (match[2] !== undefined ? match[2] : match[3]);
}

// Markup subset to StyledText.
function sanitize(body) {
    let input = typeof body === "string" ? body : "";
    if (input.length > MAX_LENGTH)
        input = input.slice(0, MAX_LENGTH);
    const open = [];
    let out = "";
    let linkHref = "";
    let linkText = "";
    let inLink = false;

    const text = raw => {
        const plainText = decode(raw);
        if (inLink)
            linkText += plainText;
        out += escapeText(plainText).replace(/\r?\n/g, "<br>");
    };

    const re = /<(\/?)([a-zA-Z][a-zA-Z0-9]*)((?:"[^"]*"|'[^']*'|[^>"'])*)>/g;
    let last = 0;
    let match;
    while ((match = re.exec(input)) !== null) {
        text(input.slice(last, match.index));
        last = re.lastIndex;
        const closing = match[1] === "/";
        const name = match[2].toLowerCase();
        if (ALLOWED[name]) {
            if (!closing) {
                open.push(name);
                out += "<" + name + ">";
            } else {
                const at = open.lastIndexOf(name);
                if (at >= 0) {
                    while (open.length > at)
                        out += "</" + open.pop() + ">";
                }
            }
        } else if (name === "br") {
            out += "<br>";
        } else if (name === "a") {
            if (!closing) {
                inLink = true;
                linkHref = attribute(match[3], "href");
                linkText = "";
            } else if (inLink) {
                inLink = false;
                if (linkHref !== "" && linkHref !== linkText.trim())
                    out += escapeText(" (" + decode(linkHref) + ")");
                linkHref = "";
            }
        } else if (name === "img" && !closing) {
            const alt = attribute(match[3], "alt");
            if (alt !== "")
                text(alt);
        }
    }
    text(input.slice(last));
    while (open.length > 0)
        out += "</" + open.pop() + ">";
    return out;
}

// Plain text (no markup) for accessibility names and logs.
function plain(body) {
    return sanitize(body).replace(/<br>/g, "\n").replace(/<\/?[biu]>/g, "").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");
}
