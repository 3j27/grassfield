.pragma library

// Filter for cover art URLs that come from an MPRIS player (untrusted: a player can name any URL,
// and an Image given an http(s) URL would download it). Only local files and size-capped inline
// images are accepted; everything else shows the placeholder.

const MAX_DATA_CHARS = 1048576;

// The URL itself when it is safe to hand to an Image, else "".
function safe(url, maxDataChars) {
    if (typeof url !== "string")
        return "";
    const text = url.trim();
    if (/[\u0000-\u001f]/.test(text))
        return "";
    const limit = maxDataChars > 0 ? maxDataChars : MAX_DATA_CHARS;
    if (/^data:image\//i.test(text))
        return text.length <= limit ? text : "";
    // file:///path or file://localhost/path; no other host, no query or fragment.
    const m = /^file:\/\/(localhost)?(\/(?!\/)[^?#]*)$/i.exec(text);
    if (m === null || m[2].length < 2)
        return "";
    return text;
}
