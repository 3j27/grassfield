.pragma library

// Select Text in Images (ADR-0045 OC-2, docs/specs/preview.md P13): the pure part, unit tested in
// tests/unit/tst_previewtextinimages.qml. What tesseract and zbarimg answered (PreviewApp.recognize) becomes a page of words
// in reading order, a selection between two points at word granularity (macOS Live Text), the text a copy puts on the
// clipboard, and the chips of the QR codes. Everything here is data from an untrusted image: nothing is ever run or opened
// from it but the http(s) link of a chip, which the backend checks again (PreviewApp.openLink).
//
// Coordinates are the pixels of the picture the tools read: the image as Preview shows it (EXIF orientation applied),
// scaled down when it was larger than the tools' limit. `page.width` and `page.height` give that size; a view scales it to
// what it draws.

// A word below this confidence (tesseract's 0 to 100) is noise, and a line whose words average below `lineConfidence`
// is dropped whole: tesseract reads letters into the grain of a photograph with low confidence.
const wordConfidence = 30;
const lineConfidence = 50;
// The longest link a chip opens (a longer one is copied as text), and the most chips one image shows.
const maxLinkLength = 2048;
const maxCodes = 4;
// A press within this fraction of a line's height above or below it is still on the line (the I-beam does not flicker
// between the ascenders and the descenders of two lines).
const lineSlop = 0.2;

// Tesseract's language codes (ISO 639-2/T, its traineddata names) for the language of a locale name ("fr_FR" -> "fra").
// Chinese is read in its script: Traditional for Taiwan, Hong Kong and Macao, Simplified otherwise.
const languageCodes = {
    af: "afr", am: "amh", ar: "ara", az: "aze", be: "bel", bg: "bul", bn: "ben", bs: "bos", ca: "cat", cs: "ces", cy: "cym",
    da: "dan", de: "deu", el: "ell", en: "eng", eo: "epo", es: "spa", et: "est", eu: "eus", fa: "fas", fi: "fin", fr: "fra",
    ga: "gle", gl: "glg", gu: "guj", he: "heb", hi: "hin", hr: "hrv", hu: "hun", hy: "hye", id: "ind", is: "isl", it: "ita",
    ja: "jpn", ka: "kat", kk: "kaz", km: "khm", kn: "kan", ko: "kor", ky: "kir", lo: "lao", lt: "lit", lv: "lav", mk: "mkd",
    ml: "mal", mn: "mon", mr: "mar", ms: "msa", mt: "mlt", my: "mya", nb: "nor", ne: "nep", nl: "nld", nn: "nor", no: "nor",
    pa: "pan", pl: "pol", ps: "pus", pt: "por", ro: "ron", ru: "rus", si: "sin", sk: "slk", sl: "slv", sq: "sqi", sr: "srp",
    sv: "swe", sw: "swa", ta: "tam", te: "tel", tg: "tgk", th: "tha", tl: "tgl", tr: "tur", uk: "ukr", ur: "urd", uz: "uzb",
    vi: "vie", yi: "yid"
};

function emptyPage() {
    return {width: 0, height: 0, words: [], lines: []};
}

// Tesseract's code for a locale name ("fr_FR", "zh_TW", "pt-BR"), "" when it has none.
function languageCode(localeName) {
    const parts = String(localeName || "").split(/[_.@-]/);
    const language = parts[0].toLowerCase();
    if (language === "zh")
        return parts.slice(1).some(p => p === "TW" || p === "HK" || p === "MO" || p === "Hant") ? "chi_tra" : "chi_sim";
    return languageCodes[language] || "";
}

// The languages of `tesseract --list-langs` ("List of available languages in "/usr/share/tessdata/" (3):", then one per line).
// Only plain names: a script model ("script/Latin") is not a language of the session.
function parseLanguages(output) {
    const out = [];
    for (const raw of String(output || "").split("\n")) {
        const line = raw.trim();
        if (/^[A-Za-z0-9_]{1,32}$/.test(line) && out.indexOf(line) < 0)
            out.push(line);
    }
    return out;
}

// tesseract's -l value: the session's language, then English, among the installed ones ("fra+eng"); "" when neither is.
function chooseLanguages(installed, localeName) {
    const wanted = [languageCode(localeName), "eng"];
    const out = [];
    for (const code of wanted) {
        if (code !== "" && installed.indexOf(code) >= 0 && out.indexOf(code) < 0)
            out.push(code);
    }
    return out.join("+");
}

// A whole non-negative number of a TSV column, NaN otherwise.
function count(text) {
    return /^\d{1,9}$/.test(text) ? Number(text) : NaN;
}

// The page of `tesseract … tsv`: its size (the level-1 row) and its words (level 5) in tesseract's reading order (blocks,
// paragraphs, lines, words), grouped into lines. A word: {text, x, y, w, h, line}; a line: {first, last, x, y, w, h,
// paragraph} with `first` and `last` indices into `words` and its box the union of its words'. Words without text or below
// `wordConfidence`, lines below `lineConfidence`, rows that are not 12 columns of numbers then text, and boxes outside the
// page are left out. An answer without a page row is an empty page.
function parseTsv(output) {
    const page = emptyPage();
    let pending = null;
    const kept = [];
    const flush = () => {
        if (pending && pending.words.length > 0 && pending.total / pending.words.length >= lineConfidence)
            kept.push(pending);
        pending = null;
    };
    for (const raw of String(output || "").split("\n")) {
        const fields = raw.replace(/\r$/, "").split("\t");
        if (fields.length < 12)
            continue;
        const level = count(fields[0]);
        const numbers = fields.slice(1, 10).map(count);
        if (isNaN(level) || numbers.some(isNaN))
            continue;
        const [pageNumber, block, paragraph, line, , x, y, w, h] = numbers;
        if (level === 1 && pageNumber === 1 && page.width === 0) {
            page.width = w;
            page.height = h;
            continue;
        }
        if (level !== 5 || pageNumber !== 1 || page.width === 0)
            continue;
        const confidence = Number(fields[10]);
        const text = fields.slice(11).join("\t").trim();
        if (text === "" || !(confidence >= wordConfidence) || w <= 0 || h <= 0 || x + w > page.width || y + h > page.height)
            continue;
        const key = block + "/" + paragraph + "/" + line;
        if (!pending || pending.key !== key) {
            flush();
            pending = {key: key, paragraph: block + "/" + paragraph, words: [], total: 0};
        }
        pending.words.push({text: text, x: x, y: y, w: w, h: h});
        pending.total += confidence;
    }
    flush();
    for (const l of kept) {
        const first = page.words.length;
        let left = Infinity, top = Infinity, right = 0, bottom = 0;
        for (const word of l.words) {
            word.line = page.lines.length;
            page.words.push(word);
            left = Math.min(left, word.x);
            top = Math.min(top, word.y);
            right = Math.max(right, word.x + word.w);
            bottom = Math.max(bottom, word.y + word.h);
        }
        page.lines.push({first: first, last: page.words.length - 1, x: left, y: top, w: right - left, h: bottom - top, paragraph: l.paragraph});
    }
    if (page.words.length === 0 && page.width === 0)
        return emptyPage();
    return page;
}

// The line under the point (page pixels), its box grown by `lineSlop` of its height above and below; -1 when the point is
// on no line. Of two lines that both hold it, the one whose middle is nearer.
function lineAt(page, x, y) {
    let best = -1;
    let bestDistance = Infinity;
    for (let i = 0; i < page.lines.length; i++) {
        const l = page.lines[i];
        const slop = l.h * lineSlop;
        if (x < l.x || x > l.x + l.w || y < l.y - slop || y > l.y + l.h + slop)
            continue;
        const distance = Math.abs(y - (l.y + l.h / 2));
        if (distance < bestDistance) {
            best = i;
            bestDistance = distance;
        }
    }
    return best;
}

// The word of line `index` nearest to x: the one under it, else the closer of its neighbours (the first before the line,
// the last after it).
function wordInLine(page, index, x) {
    const l = page.lines[index];
    let best = l.first;
    let bestDistance = Infinity;
    for (let i = l.first; i <= l.last; i++) {
        const word = page.words[i];
        const distance = x < word.x ? word.x - x : (x > word.x + word.w ? x - word.x - word.w : 0);
        if (distance < bestDistance) {
            best = i;
            bestDistance = distance;
        }
    }
    return best;
}

// The word a press at the point starts a selection on: -1 when it is not over text (the press then pans the image).
function wordAt(page, x, y) {
    const l = lineAt(page, x, y);
    return l < 0 ? -1 : wordInLine(page, l, x);
}

// The word a drag that reached the point selects to, anywhere in or outside the text: the nearest line (by the distance from
// the point to its box, so that a point beside a column picks that column's line), then its nearest word. -1 on a page
// without words.
function wordNear(page, x, y) {
    let best = -1;
    let bestDistance = Infinity;
    for (let i = 0; i < page.lines.length; i++) {
        const l = page.lines[i];
        const dx = x < l.x ? l.x - x : (x > l.x + l.w ? x - l.x - l.w : 0);
        const dy = y < l.y ? l.y - y : (y > l.y + l.h ? y - l.y - l.h : 0);
        const distance = dx * dx + dy * dy;
        if (distance < bestDistance) {
            best = i;
            bestDistance = distance;
        }
    }
    return best < 0 ? -1 : wordInLine(page, best, x);
}

// The selected words between the anchor and the focus, in reading order whichever way the drag went: {from, to}, or null
// when either end is not a word of the page.
function range(page, anchor, focus) {
    const n = page.words.length;
    if (!(anchor >= 0 && anchor < n && focus >= 0 && focus < n))
        return null;
    return {from: Math.min(anchor, focus), to: Math.max(anchor, focus)};
}

// What Copy puts on the clipboard: the words of the selection, a space between two words of a line and a line break
// between two lines (also between paragraphs: a screenshot's labels are each a paragraph of their own).
function selectionText(page, anchor, focus) {
    const r = range(page, anchor, focus);
    if (!r)
        return "";
    let out = "";
    for (let i = r.from; i <= r.to; i++) {
        const word = page.words[i];
        if (i > r.from)
            out += word.line === page.words[i - 1].line ? " " : "\n";
        out += word.text;
    }
    return out;
}

// The highlight of the selection: one box per line it covers, from its first to its last selected word, as tall as the
// line ({x, y, w, h}, page pixels), the way macOS draws a selection of Live Text.
function selectionBoxes(page, anchor, focus) {
    const r = range(page, anchor, focus);
    const out = [];
    if (!r)
        return out;
    for (let index = page.words[r.from].line; index <= page.words[r.to].line; index++) {
        const l = page.lines[index];
        const first = page.words[Math.max(l.first, r.from)];
        const last = page.words[Math.min(l.last, r.to)];
        out.push({x: first.x, y: l.y, w: last.x + last.w - first.x, h: l.h});
    }
    return out;
}

// No control or format characters (bidirectional overrides, zero-width marks): what a link shows is what it opens.
function clean(text) {
    return !/[\u0000-\u001f\u007f-\u009f­؜​-‏‪-‮⁠-⁤⁦-⁯﻿]/.test(text);
}

// An http or https link a chip may open: the whole code is one URL (no space, control or format character), with a host
// and without user information ("https://bank.example@other.example" shows one host and opens another: it is text), at
// most `maxLinkLength` characters. The backend applies the same rule before xdg-open (PreviewApp.openLink).
function isLink(text) {
    const s = String(text || "");
    if (s.length > maxLinkLength || !clean(s) || /\s/.test(s))
        return false;
    const m = /^https?:\/\/([^\/?#]*)/i.exec(s);
    return m !== null && m[1] !== "" && m[1].indexOf("@") < 0 && /^[^:]+(:\d{1,5})?$/.test(m[1]);
}

// The host a link chip names ("https://Example.org:8443/a?b" -> "example.org"), "" for anything that is not a link.
function linkHost(text) {
    if (!isLink(text))
        return "";
    return /^https?:\/\/([^\/?#:]*)/i.exec(String(text))[1].toLowerCase();
}

// The codes zbarimg found (`zbarimg -q -Sdisable -Sqrcode.enable`, exit 0; 4 is "none found"): each starts a line with
// "QR-Code:"; a line without it continues the code before (a vCard, a Wi-Fi network: codes may hold line breaks). Duplicates
// are dropped, at most `maxCodes` kept. Each: {text, link, host}.
function parseCodes(exitCode, output) {
    if (exitCode !== 0)
        return [];
    const texts = [];
    for (const line of String(output || "").replace(/\n$/, "").split("\n")) {
        if (line.startsWith("QR-Code:"))
            texts.push(line.substring(8));
        else if (texts.length > 0)
            texts[texts.length - 1] += "\n" + line;
    }
    const out = [];
    for (const text of texts) {
        if (text === "" || out.some(code => code.text === text))
            continue;
        out.push({text: text, link: isLink(text), host: linkHost(text)});
        if (out.length === maxCodes)
            break;
    }
    return out;
}
