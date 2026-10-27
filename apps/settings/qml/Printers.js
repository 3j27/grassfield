.pragma library

// Settings > Printers (ADR-0030): CUPS read through `lpstat` and `lpoptions` (run in the C locale, apps/settings/src/backend.cpp),
// the user's defaults through `lpoptions` (actions), a new or removed queue through cups-pk-helper (busAct ops). Pure functions,
// unit-tested (tests/unit/tst_settingsprinters.qml); the C++ side checks every argument again (src/systemguard.cpp).

// The reads, exactly as src/systemguard.cpp allows them. `-l` comes first: lpstat applies it to the options after it only.
var QUERY = {
    printers: ["lpstat", "-l", "-p"],
    defaultPrinter: ["lpstat", "-d"],
    devices: ["lpstat", "-v"],
    accepting: ["lpstat", "-a"],
    found: ["lpstat", "-l", "-e"]
};

// The paper sizes the pop-up offers when the default printer has them (PPD PageSize keywords), in this order.
var COMMON_PAPER = ["Letter", "Legal", "Tabloid", "Executive", "A3", "A4", "A5", "B5"];

// The keys of `lpstat -l -p`'s long listing (anything else indented right under a printer's line is its state message).
var LONG_KEYS = ["Form mounted:", "Content types:", "Printer types:", "Description:", "Alerts:", "Location:", "Connection:", "Interface:",
    "On fault:", "After fault:", "Users allowed:", "Users denied:", "Forms allowed:", "Banner required", "Charset sets:", "Default pitch:",
    "Default page size:", "Default port settings:"];

function validName(name) {
    return typeof name === "string" && /^[A-Za-z0-9_.+@][A-Za-z0-9_.+@-]{0,126}$/.test(name);
}

// A PPD PageSize keyword; "Custom.WIDTHxHEIGHT" (CUPS's custom size placeholder) is not a size to choose.
function validPaper(keyword) {
    return typeof keyword === "string" && /^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$/.test(keyword) && !keyword.startsWith("Custom.");
}

function validUri(uri) {
    return typeof uri === "string" && uri.length <= 1024 && /^(dnssd|ipp|ipps|ippusb):\/\/[^/?#][^#]*$/.test(uri)
        && !/[\s\x00-\x1f\x7f\u200e\u200f\u202a-\u202e\u2066-\u2069]/.test(uri);
}

// `lpstat -l -p`: [{name, state ("idle" | "printing" | "holding" | "stopped"), message, description, location}] in CUPS's order.
function parsePrinters(text) {
    const out = [];
    let current = null;
    let first = false;
    for (const line of String(text || "").split("\n")) {
        const m = /^printer (\S+) (is idle\.|now printing |is holding new jobs\.|disabled since )/.exec(line);
        if (m) {
            const name = m[1].split("/")[0];
            const state = m[2] === "is idle." ? "idle" : m[2] === "now printing " ? "printing" : m[2] === "is holding new jobs." ? "holding" : "stopped";
            current = {name: name, state: state, message: "", description: "", location: ""};
            // An instance (name/instance) is the same queue: listed once.
            if (!out.some(p => p.name === name))
                out.push(current);
            first = true;
            continue;
        }
        if (current === null || !/^\t/.test(line)) {
            first = false;
            continue;
        }
        const body = line.replace(/^\t+/, "");
        const description = /^Description: ?(.*)$/.exec(body);
        const location = /^Location: ?(.*)$/.exec(body);
        if (description)
            current.description = description[1].trim();
        else if (location)
            current.location = location[1].trim();
        else if (first && !LONG_KEYS.some(k => body.startsWith(k)) && body !== "reason unknown")
            current.message = body.trim();
        first = false;
    }
    return out;
}

// `lpstat -d`: the default queue's name (the user's own first), "" for none.
function parseDefault(text) {
    const m = /^system default destination: ([^\s/]+)/m.exec(String(text || ""));
    return m ? m[1] : "";
}

// `lpstat -v`: {queue: device URI}.
function parseDevices(text) {
    const out = {};
    for (const line of String(text || "").split("\n")) {
        const m = /^device for ([^\s:/]+): (\S+)$/.exec(line);
        if (m)
            out[m[1]] = m[2];
    }
    return out;
}

// `lpstat -a`: {queue: whether it accepts jobs} ("<queue> accepting requests since …", "<queue> not accepting requests since …").
function parseAccepting(text) {
    const out = {};
    for (const line of String(text || "").split("\n")) {
        const m = /^(\S+) (not )?accepting requests/.exec(line);
        if (m)
            out[m[1].split("/")[0]] = m[2] === undefined;
    }
    return out;
}

// `lpstat -l -e`: the printers cupsd and DNS-SD found that are not queues yet ("<name> network none <device-uri>") and that
// cupsd can make a driverless queue of: [{name, uri}], without the names in `queues`.
function parseFound(text, queues) {
    const out = [];
    const taken = (queues || []).map(q => q.name);
    for (const line of String(text || "").split("\n")) {
        const f = line.trim().split(/\s+/);
        if (f.length !== 4 || f[1] !== "network" || !validName(f[0]) || !validUri(f[3]) || taken.indexOf(f[0]) >= 0)
            continue;
        if (!out.some(p => p.name === f[0]))
            out.push({name: f[0], uri: f[3]});
    }
    return out;
}

// `lpoptions -p <queue> -l`: the PageSize choices {choices: [keywords], current: keyword ("" when none is marked)}.
function parsePaper(text) {
    const m = /^PageSize\/[^:]*:(.*)$/m.exec(String(text || ""));
    const out = {choices: [], current: ""};
    if (!m)
        return out;
    for (const word of m[1].trim().split(/\s+/)) {
        const marked = word.startsWith("*");
        const keyword = marked ? word.slice(1) : word;
        if (!validPaper(keyword))
            continue;
        out.choices.push(keyword);
        if (marked)
            out.current = keyword;
    }
    return out;
}

// The pop-up's sizes: the common ones the printer has, and the one in effect when it is another.
function paperChoices(paper) {
    const list = COMMON_PAPER.filter(k => paper.choices.indexOf(k) >= 0);
    if (paper.current !== "" && list.indexOf(paper.current) < 0)
        list.push(paper.current);
    return list;
}

// What a queue's device URI says it is: "network", "usb", "driverless" (IPP Everywhere, AirPrint), "other".
function kindOf(uri) {
    const scheme = String(uri || "").split(":")[0];
    if (scheme === "dnssd" || scheme === "ipp" || scheme === "ipps" || scheme === "ippusb" || scheme === "implicitclass")
        return "driverless";
    if (scheme === "usb")
        return "usb";
    if (scheme === "socket" || scheme === "lpd" || scheme === "http" || scheme === "https" || scheme === "smb")
        return "network";
    return "other";
}

// A queue's description for a new queue: the DNS-SD name with its underscores as spaces, at most 127 characters.
function infoOf(name) {
    return String(name).replace(/_+/g, " ").trim().slice(0, 127);
}

// The ops and commands (null when a value is not one Settings may send).
function addOp(printer) {
    if (!printer || !validName(printer.name) || !validUri(printer.uri))
        return null;
    return {op: "printer.add", name: printer.name, uri: printer.uri, info: infoOf(printer.name)};
}

function deleteOp(name) {
    return validName(name) ? {op: "printer.delete", name: name} : null;
}

// A queue that is stopped or refuses jobs (an add whose second dialog was refused) made to print again.
function resumeOp(name) {
    return validName(name) ? {op: "printer.resume", name: name} : null;
}

function setDefault(name) {
    return validName(name) ? ["lpoptions", "-d", name] : null;
}

function paperQuery(name) {
    return validName(name) ? ["lpoptions", "-p", name, "-l"] : null;
}

function setPaper(name, keyword) {
    return validName(name) && validPaper(keyword) ? ["lpoptions", "-p", name, "-o", "PageSize=" + keyword] : null;
}
