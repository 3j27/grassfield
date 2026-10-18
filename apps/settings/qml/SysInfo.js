.pragma library

// Pure parsers for the About page (read-only system information).

// Value of KEY in os-release text, without quotes; "" when absent.
function osReleaseValue(text, key) {
    for (const line of String(text).split("\n")) {
        const eq = line.indexOf("=");
        if (eq > 0 && line.slice(0, eq) === key)
            return line.slice(eq + 1).trim().replace(/^"(.*)"$/, "$1");
    }
    return "";
}

// "Omarchy 4.0.4" from os-release (NAME + VERSION_ID), "" when neither is present.
function osLabel(text) {
    return (osReleaseValue(text, "NAME") + " " + osReleaseValue(text, "VERSION_ID")).trim();
}

// First "model name" of /proc/cpuinfo and the logical CPU count: {model, threads} ("" and 0 when absent). The page
// words it in the UI language.
function cpu(text) {
    let model = "";
    let threads = 0;
    for (const line of String(text).split("\n")) {
        if (/^processor\s*:/.test(line))
            threads++;
        else if (model === "" && /^model name\s*:/.test(line))
            model = line.slice(line.indexOf(":") + 1).trim().replace(/\s+/g, " ");
    }
    return {model: model, threads: model === "" ? 0 : threads};
}

// MemTotal of /proc/meminfo in bytes; 0 when absent. The page formats it with the UI locale (Qt.locale()).
function memoryBytes(text) {
    const m = /^MemTotal:\s*(\d+)\s*kB/m.exec(String(text));
    return m ? Number(m[1]) * 1024 : 0;
}

// Graphics adapters of `lspci` output (VGA / 3D / Display controller lines), joined with "; ".
function gpus(text) {
    const out = [];
    for (const line of String(text).split("\n")) {
        const m = /^\S+\s+(?:VGA compatible controller|3D controller|Display controller)[^:]*:\s*(.+)$/.exec(line);
        if (m)
            out.push(m[1].replace(/\s*\(rev [0-9a-f]+\)\s*$/, "").trim());
    }
    return out.join("; ");
}

// Version of `pacman -Q <pkg>` output ("hyprland 0.56.2-1" -> "0.56.2-1"); "" when not installed.
function pacmanVersion(text) {
    const parts = String(text).trim().split(/\s+/);
    return parts.length === 2 ? parts[1] : "";
}
