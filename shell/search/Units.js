.pragma library
.import "Numbers.js" as Numbers

// Unit conversion (pure, unit-tested): length, mass, temperature, data sizes. No currency.
// Query forms: "10 km in mi", "100f to c", "2 GiB in MB" (separators: in, to, as, ->; in French also en, vers).
// The number is read and the answer written in the session's language (a `locale`: Qt.locale()): "25,5 km en mi" is read
// as 25.5 and answered with a decimal comma and grouping, rounded like Spotlight (4 decimals from 1 up, 4 significant
// digits below 1).

// factor = size of the unit in the category's base unit (m, kg, B). Temperature is special.
const TABLE = [
    {cat: "length", units: [
        ["mm", 0.001, ["millimeter", "millimeters", "millimetre", "millimetres", "millimètre", "millimètres"]],
        ["cm", 0.01, ["centimeter", "centimeters", "centimetre", "centimetres", "centimètre", "centimètres"]],
        ["m", 1, ["meter", "meters", "metre", "metres", "mètre", "mètres"]],
        ["km", 1000, ["kilometer", "kilometers", "kilometre", "kilometres", "kilomètre", "kilomètres"]],
        ["in", 0.0254, ["inch", "inches", "pouce", "pouces"]],
        ["ft", 0.3048, ["foot", "feet", "pied", "pieds"]],
        ["yd", 0.9144, ["yard", "yards"]],
        ["mi", 1609.344, ["mile", "miles"]]
    ]},
    {cat: "mass", units: [
        ["mg", 0.000001, ["milligram", "milligrams", "milligramme", "milligrammes"]],
        ["g", 0.001, ["gram", "grams", "gramme", "grammes"]],
        ["kg", 1, ["kilogram", "kilograms", "kilo", "kilos", "kilogramme", "kilogrammes"]],
        ["t", 1000, ["tonne", "tonnes"]],
        ["oz", 0.028349523125, ["ounce", "ounces", "once", "onces"]],
        ["lb", 0.45359237, ["lbs", "pound", "pounds", "livre", "livres"]]
    ]},
    {cat: "data", units: [
        ["B", 1, ["byte", "bytes", "o", "octet", "octets"]],
        ["KB", 1000, ["kilobyte", "kilobytes", "ko", "kilooctet", "kilooctets"]],
        ["MB", 1e6, ["megabyte", "megabytes", "mo", "megaoctet", "megaoctets", "mégaoctet", "mégaoctets"]],
        ["GB", 1e9, ["gigabyte", "gigabytes", "go", "gigaoctet", "gigaoctets"]],
        ["TB", 1e12, ["terabyte", "terabytes", "teraoctet", "teraoctets", "téraoctet", "téraoctets"]],
        ["KiB", 1024, ["kibibyte", "kibibytes", "kio"]],
        ["MiB", 1048576, ["mebibyte", "mebibytes", "mio"]],
        ["GiB", 1073741824, ["gibibyte", "gibibytes", "gio"]],
        ["TiB", 1099511627776, ["tebibyte", "tebibytes", "tio"]]
    ]},
    {cat: "temperature", units: [
        ["C", 0, ["celsius", "°c"]],
        ["F", 0, ["fahrenheit", "°f"]],
        ["K", 0, ["kelvin"]]
    ]}
];

// Lowercased alias -> {cat, unit, factor}. Null prototype: arbitrary query text can never hit
// inherited properties.
const ALIASES = (function () {
    const map = Object.create(null);
    for (const group of TABLE) {
        for (const u of group.units) {
            const names = [u[0].toLowerCase()].concat(u[2]);
            for (const n of names) {
                if (!(n in map))
                    map[n] = {cat: group.cat, unit: u[0], factor: u[1]};
            }
        }
    }
    return map;
})();

function lookup(name) {
    const key = name.trim().toLowerCase();
    return key in ALIASES ? ALIASES[key] : null;
}

function toCelsius(v, unit) {
    switch (unit) {
    case "F":
        return (v - 32) * 5 / 9;
    case "K":
        return v - 273.15;
    }
    return v;
}

function fromCelsius(v, unit) {
    switch (unit) {
    case "F":
        return v * 9 / 5 + 32;
    case "K":
        return v + 273.15;
    }
    return v;
}

function convert(value, from, to) {
    if (from.cat === "temperature")
        return fromCelsius(toCelsius(value, from.unit), to.unit);
    return value * from.factor / to.factor;
}

// The answer's number in the locale: 4 decimals from 1 up (the integer part is never rounded), 4 significant digits below 1,
// the exponent form beyond 1e15 and under 1e-6; trailing zeros dropped.
function formatNumber(v, locale) {
    if (v === 0)
        return "0";
    const abs = Math.abs(v);
    if (abs >= 1e15 || abs < 1e-6)
        return Numbers.localize(v.toExponential(4).replace(/\.?0+e/, "e"), locale);
    const decimals = abs >= 1 ? 4 : Math.min(10, 3 - Math.floor(Math.log10(abs)));
    return Numbers.localize(Numbers.trimmed(v, decimals), locale);
}

// The words that join the two units: in, to, as and -> everywhere, en and vers in French.
function connectors(locale) {
    return Numbers.languageOf(locale) === "fr" ? "in|to|as|->|en|vers" : "in|to|as|->";
}

// Returns {value, text, from, to} or null. `locale` (optional): what Qt.locale() is.
function answer(input, locale) {
    if (typeof input !== "string" || input.length > 100)
        return null;
    const text = Numbers.normalizeInput(input, locale);
    const m = new RegExp("^\\s*(-?(?:\\d+\\.?\\d*|\\.\\d+)(?:e[+-]?\\d+)?)\\s*([^\\s\\d]\\S*)\\s+(?:" + connectors(locale) + ")\\s+(\\S+)\\s*$", "i").exec(text);
    if (!m)
        return null;
    const from = lookup(m[2]);
    const to = lookup(m[3]);
    if (!from || !to || from.cat !== to.cat)
        return null;
    const n = Number(m[1]);
    if (!isFinite(n))
        return null;
    const result = convert(n, from, to);
    if (!isFinite(result))
        return null;
    return {value: result, from: from.unit, to: to.unit, text: formatNumber(result, locale) + " " + to.unit};
}
