.pragma library

// Unit conversion (pure, unit-tested): length, mass, temperature, data sizes. No currency.
// Query forms: "10 km in mi", "100f to c", "2 GiB in MB" (separators: in, to, as, ->).

// factor = size of the unit in the category's base unit (m, kg, B). Temperature is special.
const TABLE = [
    {cat: "length", units: [
        ["mm", 0.001, ["millimeter", "millimeters", "millimetre", "millimetres"]],
        ["cm", 0.01, ["centimeter", "centimeters", "centimetre", "centimetres"]],
        ["m", 1, ["meter", "meters", "metre", "metres"]],
        ["km", 1000, ["kilometer", "kilometers", "kilometre", "kilometres"]],
        ["in", 0.0254, ["inch", "inches"]],
        ["ft", 0.3048, ["foot", "feet"]],
        ["yd", 0.9144, ["yard", "yards"]],
        ["mi", 1609.344, ["mile", "miles"]]
    ]},
    {cat: "mass", units: [
        ["mg", 0.000001, ["milligram", "milligrams"]],
        ["g", 0.001, ["gram", "grams"]],
        ["kg", 1, ["kilogram", "kilograms", "kilo", "kilos"]],
        ["t", 1000, ["tonne", "tonnes"]],
        ["oz", 0.028349523125, ["ounce", "ounces"]],
        ["lb", 0.45359237, ["lbs", "pound", "pounds"]]
    ]},
    {cat: "data", units: [
        ["B", 1, ["byte", "bytes"]],
        ["KB", 1000, ["kilobyte", "kilobytes"]],
        ["MB", 1e6, ["megabyte", "megabytes"]],
        ["GB", 1e9, ["gigabyte", "gigabytes"]],
        ["TB", 1e12, ["terabyte", "terabytes"]],
        ["KiB", 1024, ["kibibyte", "kibibytes"]],
        ["MiB", 1048576, ["mebibyte", "mebibytes"]],
        ["GiB", 1073741824, ["gibibyte", "gibibytes"]],
        ["TiB", 1099511627776, ["tebibyte", "tebibytes"]]
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

function formatNumber(v) {
    if (v === 0)
        return "0";
    const abs = Math.abs(v);
    if (abs >= 1e15 || abs < 1e-6)
        return v.toExponential(6).replace(/\.?0+e/, "e");
    return Number(v.toPrecision(8)).toString();
}

// Returns {value, text, from, to} or null.
function answer(input) {
    if (typeof input !== "string" || input.length > 100)
        return null;
    const m = /^\s*(-?(?:\d+\.?\d*|\.\d+)(?:e[+-]?\d+)?)\s*([^\s\d]\S*)\s+(?:in|to|as|->)\s+(\S+)\s*$/i.exec(input);
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
    return {value: result, from: from.unit, to: to.unit, text: formatNumber(result) + " " + to.unit};
}
