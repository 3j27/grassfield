.pragma library

// Detects JSON text that JSON.parse + JSON.stringify cannot round-trip faithfully. Shared by the
// Settings app (refuses to edit) and the shell's SettingsStore (refuses to write). Pure, no I/O.
//
// Unsafe: integers beyond 2^53 (written plainly, with a decimal point or with an exponent),
// duplicate keys in one object (the last would win, "__proto__" included) and integer-like object
// keys (JavaScript lists them first, changing the order).

const MAX_SAFE = "9007199254740991";

// Reason an integer-valued JSON number token cannot be kept exactly, else "".
function numberReason(token) {
    const m = /^(-?)([0-9]+)(?:\.([0-9]*))?(?:[eE]([-+]?[0-9]+))?$/.exec(token);
    if (!m)
        return "";
    const frac = m[3] || "";
    let digits = (m[2] + frac).replace(/^0+/, "");
    let exp = (m[4] ? parseInt(m[4], 10) : 0) - frac.length;
    if (digits === "")
        return "";
    const trimmed = digits.replace(/0+$/, "");
    exp += digits.length - trimmed.length;
    digits = trimmed;
    if (exp < 0)
        return "";  // not an integer: a plain float, kept as well as JSON.parse can
    const len = digits.length + exp;
    // A plain integer longer than 16 digits is refused whatever its zeros (stringify would turn
    // it into an exponent form). With a point or exponent only 16+ significant digits cannot
    // round-trip (1.5e30 is a short float, kept).
    const plain = m[3] === undefined && m[4] === undefined;
    const tooBig = len > 16 ? (plain || digits.length >= 16) : (len === 16 && (digits + "0".repeat(exp)) > MAX_SAFE);
    if (tooBig)
        return "it holds the integer " + token + ", beyond 2^53, which cannot be kept exactly";
    return "";
}

// `text` is already valid JSON. Returns "" when safe, else the reason.
function unsafeReason(text) {
    const stack = [];
    const n = text.length;
    for (let i = 0; i < n; i++) {
        const c = text[i];
        if (c === "{") {
            stack.push({obj: true, keys: Object.create(null), expectKey: true});
        } else if (c === "[") {
            stack.push({obj: false});
        } else if (c === "}" || c === "]") {
            stack.pop();
        } else if (c === ",") {
            if (stack.length > 0 && stack[stack.length - 1].obj)
                stack[stack.length - 1].expectKey = true;
        } else if (c === "\"") {
            let j = i + 1;
            while (j < n && text[j] !== "\"")
                j += text[j] === "\\" ? 2 : 1;
            const top = stack.length > 0 ? stack[stack.length - 1] : null;
            if (top && top.obj && top.expectKey) {
                const key = JSON.parse(text.slice(i, j + 1));
                if (key in top.keys)
                    return "it has the key \"" + key + "\" twice in one object";
                if (/^(0|[1-9][0-9]*)$/.test(key))
                    return "it has the numeric object key \"" + key + "\", whose order cannot be kept";
                top.keys[key] = true;
                top.expectKey = false;
            }
            i = j;
        } else if (c === "-" || (c >= "0" && c <= "9")) {
            let j = i;
            while (j < n && /[-+0-9.eE]/.test(text[j]))
                j++;
            const reason = numberReason(text.slice(i, j));
            if (reason !== "")
                return reason;
            i = j - 1;
        }
    }
    return "";
}
