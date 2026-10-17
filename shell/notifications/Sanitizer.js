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

// Longest tag (name and attributes) recognised; anything longer is plain text. Bounds the scan
// per "<" so tag-like input stays linear.
const MAX_TAG = 512;

function isAlpha(c) {
    return (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
}

function isAlnum(c) {
    return isAlpha(c) || (c >= 48 && c <= 57);
}

// Scans a tag at input[start] === "<": {end, closing, name, attrs} or null when it is not one.
// Quoted attribute values may contain ">".
function scanTag(input, start) {
    let i = start + 1;
    const closing = input[i] === "/";
    if (closing)
        i++;
    if (!isAlpha(input.charCodeAt(i)))
        return null;
    const nameStart = i;
    while (isAlnum(input.charCodeAt(i)))
        i++;
    const nameEnd = i;
    const limit = Math.min(input.length, start + MAX_TAG);
    for (;;) {
        // Native searches only, no per-character JS loop. No ">" in reach means no tag here.
        const gt = input.indexOf(">", i);
        if (gt < 0 || gt >= limit)
            return null;
        const dq = input.indexOf("\"", i);
        const sq = input.indexOf("'", i);
        let quote = -1;
        if (dq >= 0 && dq < gt)
            quote = dq;
        if (sq >= 0 && sq < gt && (quote < 0 || sq < quote))
            quote = sq;
        if (quote < 0)
            return {end: gt + 1, closing: closing, name: input.slice(nameStart, nameEnd), attrs: input.slice(nameEnd, gt)};
        const close = input.indexOf(input[quote], quote + 1);
        if (close < 0 || close >= limit)
            return null;
        i = close + 1;
    }
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

    let last = 0;
    let pos = 0;
    let lt;
    while ((lt = input.indexOf("<", pos)) >= 0) {
        const tag = scanTag(input, lt);
        if (tag === null) {
            pos = lt + 1;
            continue;
        }
        text(input.slice(last, lt));
        last = tag.end;
        pos = tag.end;
        const closing = tag.closing;
        const name = tag.name.toLowerCase();
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
                linkHref = attribute(tag.attrs, "href");
                linkText = "";
            } else if (inLink) {
                inLink = false;
                if (linkHref !== "" && linkHref !== linkText.trim())
                    out += escapeText(" (" + decode(linkHref) + ")");
                linkHref = "";
            }
        } else if (name === "img" && !closing) {
            const alt = attribute(tag.attrs, "alt");
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
