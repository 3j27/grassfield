.pragma library

// Pure helpers for the Documents/Files and Recent providers: parsing of `localsearch search`
// and `plocate` output, and of recently-used.xbel. All input is untrusted text.

function baseName(path) {
    const i = path.lastIndexOf("/");
    return i >= 0 ? path.slice(i + 1) : path;
}

function dirName(path) {
    const i = path.lastIndexOf("/");
    return i > 0 ? path.slice(0, i) : "/";
}

function fileUrlToPath(url) {
    if (!url.startsWith("file://"))
        return "";
    try {
        const p = decodeURIComponent(url.slice(7));
        return p.startsWith("/") && p.indexOf("\0") < 0 ? p : "";
    } catch (e) {
        return "";
    }
}

// Lexical canonical form: collapses "//", "." and ".." (".." never climbs above "/"). Symlinks are
// not resolved (no filesystem access here).
function canonical(path) {
    const out = [];
    for (const seg of path.split("/")) {
        if (seg === "" || seg === ".")
            continue;
        if (seg === "..")
            out.pop();
        else
            out.push(seg);
    }
    return "/" + out.join("/");
}

// Canonical path when it lies strictly under home and has no hidden segment, else "".
function homePath(path, home) {
    if (!home || !path.startsWith("/"))
        return "";
    const c = canonical(path);
    const h = canonical(home);
    if (!c.startsWith(h + "/") || hasHiddenSegment(c, h))
        return "";
    return c;
}

// Shows "~/x" for paths under home.
function tildePath(path, home) {
    if (home && (path === home || path.startsWith(home + "/")))
        return "~" + path.slice(home.length);
    return path;
}

function hasHiddenSegment(path, home) {
    const rel = home && path.startsWith(home + "/") ? path.slice(home.length + 1) : path;
    return rel.split("/").some(seg => seg.startsWith("."));
}

// `localsearch search` prints one `file://` URI per line (possibly indented / colored).
function parseLocalsearch(text, home, limit) {
    const out = [];
    const clean = text.replace(/\x1b\[[0-9;]*m/g, "");
    for (const line of clean.split("\n")) {
        const m = /(file:\/\/\S+)/.exec(line);
        if (!m)
            continue;
        const path = homePath(fileUrlToPath(m[1]), home);
        if (path !== "")
            out.push(path);
        if (out.length >= limit)
            break;
    }
    return out;
}

// plocate prints one absolute path per line: keep paths under home without hidden segments.
// Basename prefix matches first.
function parsePlocate(text, query, home, limit) {
    const q = query.toLowerCase();
    const hits = [];
    for (const line of text.split("\n")) {
        const path = homePath(line, home);
        if (path === "")
            continue;
        const name = baseName(path).toLowerCase();
        hits.push({path: path, rank: name.startsWith(q) ? 0 : (name.indexOf(q) >= 0 ? 1 : 2)});
    }
    hits.sort((a, b) => a.rank - b.rank || a.path.length - b.path.length);
    return hits.slice(0, limit).map(h => h.path);
}

function unescapeXml(s) {
    return s.replace(/&(lt|gt|quot|apos|amp);/g, (m, n) => ({lt: "<", gt: ">", quot: "\"", apos: "'", amp: "&"})[n]);
}

// The applications that registered a bookmark (`<bookmark:application name="Text Editor" exec="&apos;gedit %U&apos;" .../>`):
// [{name, cmd}] with cmd the program of the exec line without its directory ("gedit").
function xbelApps(body) {
    const out = [];
    const re = /<bookmark:application\s+([^>]*?)\/?>/g;
    let m;
    while ((m = re.exec(body)) !== null) {
        const name = /\sname="([^"]*)"/.exec(" " + m[1]);
        const exec = /\sexec="([^"]*)"/.exec(" " + m[1]);
        let cmd = "";
        if (exec) {
            const first = /^\s*(?:'([^']*)'|"([^"]*)"|(\S+))/.exec(unescapeXml(exec[1]));
            const line = first ? (first[1] !== undefined ? first[1] : (first[2] !== undefined ? first[2] : first[3])) : "";
            cmd = line.trim().split(/\s+/)[0].replace(/^.*\//, "");
        }
        out.push({name: name ? unescapeXml(name[1]) : "", cmd: cmd});
    }
    return out;
}

// recently-used.xbel -> [{path, mime, modified (ms), apps: [{name, cmd}]}], newest first.
// With home set, entries outside it (or hidden) are dropped; non-file:// URIs always are.
function parseXbel(text, home) {
    const out = [];
    const re = /<bookmark\s([^>]*)>([\s\S]*?)<\/bookmark>/g;
    let m;
    while ((m = re.exec(text)) !== null) {
        const href = /\shref="([^"]*)"/.exec(" " + m[1]);
        const mod = /\smodified="([^"]*)"/.exec(" " + m[1]);
        const mime = /<mime:mime-type\s+type="([^"]*)"/.exec(m[2]);
        if (!href)
            continue;
        let path = fileUrlToPath(unescapeXml(href[1]));
        if (home !== undefined)
            path = homePath(path, home);
        if (path === "")
            continue;
        const t = mod ? Date.parse(mod[1]) : 0;
        out.push({path: path, mime: mime ? mime[1] : "", modified: isNaN(t) ? 0 : t, apps: xbelApps(m[2])});
    }
    out.sort((a, b) => b.modified - a.modified);
    return out;
}
