.pragma library

// Numbers of the Search answers (pure, unit-tested by tst_searchunits and tst_searchcalc): reading what a person types
// in the language of the session ("25,5 km en mi", "1 000 + 5") and writing the answer the way the language does
// (Spotlight: "15,5343 mi", "19 560"). A `locale` is anything with `decimalPoint` and `groupSeparator` (and `name`),
// which is what Qt.locale() is; without one the answer is plain: "." and no grouping.

function decimalPointOf(locale) {
    return locale && typeof locale.decimalPoint === "string" && locale.decimalPoint !== "" ? locale.decimalPoint : ".";
}

function groupSeparatorOf(locale) {
    return locale && typeof locale.groupSeparator === "string" ? locale.groupSeparator : "";
}

// The language of a locale ("fr" for fr_FR), "en" without one.
function languageOf(locale) {
    const name = locale && typeof locale.name === "string" ? locale.name : "";
    const m = /^([A-Za-z]{2,3})/.exec(name);
    return m ? m[1].toLowerCase() : "en";
}

// What a person typed, with the numbers in one plain form ("1000.5"): the grouping separators gone (spaces, no-break and
// narrow no-break spaces between groups of three digits; commas between groups of three where the comma is not the decimal
// point), a decimal comma read as the point. Text without digits is returned unchanged.
function normalizeInput(text, locale) {
    let s = String(text);
    if (!/\d/.test(s))
        return s;
    s = s.replace(/(\d)[   ](?=\d{3}(?!\d))/g, "$1");
    if (decimalPointOf(locale) !== ",")
        s = s.replace(/\d{1,3}(?:,\d{3})+(?!\d)/g, group => group.replace(/,/g, ""));
    return s.replace(/(\d),(\d)/g, "$1.$2");
}

// "12345.678" -> "12 345,678" in the locale: the grouping inserted every three digits of the integer part, the point
// replaced. An exponent form ("1e-7") only has its point replaced.
function localize(plain, locale) {
    const s = String(plain);
    const point = decimalPointOf(locale);
    if (/e/i.test(s))
        return s.replace(".", point);
    const m = /^(-?)(\d+)(?:\.(\d+))?$/.exec(s);
    if (!m)
        return s;
    const sep = groupSeparatorOf(locale);
    const int = sep === "" ? m[2] : m[2].replace(/\B(?=(\d{3})+(?!\d))/g, sep);
    return m[1] + int + (m[3] !== undefined ? point + m[3] : "");
}

// A fixed number of decimals without the trailing zeros ("2.50" -> "2.5", "3.000" -> "3", "-0" -> "0").
function trimmed(value, decimals) {
    let s = value.toFixed(decimals);
    if (s.indexOf(".") >= 0)
        s = s.replace(/0+$/, "").replace(/\.$/, "");
    return s === "-0" ? "0" : s;
}
