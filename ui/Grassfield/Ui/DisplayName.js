.pragma library

// A file name as shown in a label (GF-105, like Finder): the one helper every view of Files and Preview, and every message that
// names a file, goes through. Line breaks become a return symbol, and the bidirectional override, embedding and isolate controls
// (U+202A-U+202E, U+2066-U+2069) are written out as "<U+202E>" so a name cannot reorder the text around it ("evil‮fdp.exe"
// does not read "evilexe.pdf"). The marks LRM and RLM stay. The C++ twin is FileLogic::displayName (apps/files/src/filelogic.cpp).
// tests/shell/display_names.sh fails when a view shows a raw name.
function text(name) {
    return String(name === undefined || name === null ? "" : name).replace(/[\r\n]+/g, "⏎").replace(/[‪-‮⁦-⁩]/g,
        c => "<U+" + c.charCodeAt(0).toString(16).toUpperCase() + ">");
}
