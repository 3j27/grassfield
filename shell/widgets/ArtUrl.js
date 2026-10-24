.pragma library

// Cover art URLs come from an MPRIS player (untrusted: a player can name any URL). Only a local file is shown, and never
// as such: its path goes to ThemeIcons.fileSource, which shows a PNG the shell made from it (review of 423766f: a file:
// URL naming an SVG that references a FIFO, or the FIFO itself, stalled the image loader). Any other URL, http(s) and
// data: included, shows the placeholder: nothing is downloaded and nothing the player wrote is decoded by Qt.

// The absolute path a file:///path or file://localhost/path URL names (percent-decoded; no other host, no query or
// fragment, no control character), else "".
function localPath(url) {
    if (typeof url !== "string")
        return "";
    const text = url.trim();
    const m = /^file:\/\/(localhost)?(\/(?!\/)[^?#]*)$/i.exec(text);
    if (m === null || m[2].length < 2)
        return "";
    let path = "";
    try {
        path = decodeURIComponent(m[2]);
    } catch (e) {
        return "";
    }
    return path.length <= 4096 && !/[\u0000-\u001f\u007f]/.test(path) ? path : "";
}
