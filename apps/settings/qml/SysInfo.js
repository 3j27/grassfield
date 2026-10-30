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

// The processor's name as About This Computer shows it, on one line (integrator nested pass of 85c2c10: the full name
// wrapped to three lines in French): the model name without the marks "(R)" and "(TM)", the word "CPU", the clock
// ("@ 2.80GHz"), the generation prefix ("11th Gen"), the integrated graphics ("with Radeon Graphics", "w/ Radeon 780M
// Graphics") and a trailing "Processor" ("8-Core Processor"). "11th Gen Intel(R) Core(TM) i7-1165G7 @ 2.80GHz" -> "Intel
// Core i7-1165G7". The model name itself when nothing would be left.
function cpuShortName(model) {
    const full = String(model).trim().replace(/\s+/g, " ");
    const short = full
        .replace(/\((?:R|TM)\)/gi, "")
        .replace(/^\d+(?:st|nd|rd|th) Gen\s+/i, "")
        .replace(/\s*@\s*[\d.]+\s*[GM]Hz\b/i, "")
        .replace(/\s+(?:with|w\/)\s.*\bGraphics\b.*$/i, "")
        .replace(/\s+(?:\d+-Core\s+)?Processor$/i, "")
        .replace(/\bCPU\b/g, "")
        .replace(/\s+/g, " ")
        .trim();
    return short !== "" ? short : full;
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
            out.push(gpuName(m[1].replace(/\s*\(rev [0-9a-f]+\)\s*$/, "").trim()));
    }
    return out.join("; ");
}

// Version of `pacman -Q <pkg>` output ("hyprland 0.56.2-1" -> "0.56.2-1"); "" when not installed.
function pacmanVersion(text) {
    const parts = String(text).trim().split(/\s+/);
    return parts.length === 2 ? parts[1] : "";
}

// A graphics adapter's marketing name from an lspci description: the vendor's short name, then the name in the last brackets
// when there is one ("Intel Corporation Raptor Lake-P [Iris Xe Graphics]" -> "Intel Iris Xe Graphics", "NVIDIA Corporation AD107M
// [GeForce RTX 4060 Max-Q / Mobile]" -> "NVIDIA GeForce RTX 4060 Max-Q / Mobile"); the description itself otherwise.
var GPU_VENDORS = [
    ["Advanced Micro Devices, Inc. [AMD/ATI]", "AMD"], ["Advanced Micro Devices, Inc.", "AMD"], ["Intel Corporation", "Intel"],
    ["NVIDIA Corporation", "NVIDIA"], ["Red Hat, Inc.", "Red Hat"], ["VMware", "VMware"]
];

function gpuName(description) {
    let rest = String(description).trim();
    let vendor = "";
    for (const pair of GPU_VENDORS) {
        if (rest.indexOf(pair[0]) === 0) {
            vendor = pair[1];
            rest = rest.slice(pair[0].length).trim();
            break;
        }
    }
    const m = /\[([^\]]+)\]\s*$/.exec(rest);
    const model = m ? m[1].trim() : rest;
    if (vendor === "")
        return model;
    return model.indexOf(vendor) === 0 ? model : vendor + " " + model;
}

// The installed memory as a computer is sold with it, from MemTotal (which leaves out what the firmware keeps): the nearest
// usual size at or above it, in GiB (31.0 -> 32, 15.4 -> 16, 7.6 -> 8, 11.6 -> 12).
var MEMORY_SIZES = [1, 2, 3, 4, 6, 8, 12, 16, 18, 24, 32, 36, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024, 1536, 2048];

function installedGiB(bytes) {
    const gib = Number(bytes) / 1073741824;
    if (!(gib > 0))
        return 0;
    for (const size of MEMORY_SIZES) {
        if (gib <= size)
            return size;
    }
    return Math.ceil(gib);
}
