.pragma library

// The login theme's few words (ADR-0042), English and French: SDDM's greeter loads no Grassfield catalog. The French matches
// translations/grassfield_fr.ts where the shell says the same thing.
var TEXT = {
    password: {en: "Enter Password", fr: "Saisir le mot de passe"},
    incorrect: {en: "Incorrect password", fr: "Mot de passe incorrect"},
    capsLock: {en: "Caps Lock is on", fr: "Le verrouillage des majuscules est activé"},
    restart: {en: "Restart", fr: "Redémarrer"},
    shutDown: {en: "Shut Down", fr: "Éteindre"},
    session: {en: "Session: %1", fr: "Session : %1"},
    pictureOf: {en: "Picture of %1", fr: "Photo de %1"}
};

function text(key, locale) {
    var entry = TEXT[key];
    if (!entry)
        return "";
    return String(locale || "").indexOf("fr") === 0 ? entry.fr : entry.en;
}

// The session SDDM starts: "Grassfield (uwsm)" first (the entry grassfield-login routes, as Omarchy's own theme picks the first
// session whose name contains "uwsm"), else the first one with "uwsm", else SDDM's last one, else the first.
function pickSession(names, lastIndex) {
    var i;
    for (i = 0; i < names.length; i++) {
        if (/^Grassfield\b/.test(names[i]) && /uwsm/i.test(names[i]))
            return i;
    }
    for (i = 0; i < names.length; i++) {
        if (/uwsm/i.test(names[i]))
            return i;
    }
    if (typeof lastIndex === "number" && lastIndex >= 0 && lastIndex < names.length)
        return lastIndex;
    return names.length > 0 ? 0 : -1;
}

// Initials for the disc when the account has no picture (as the lock screen draws them).
function initials(name) {
    var parts = String(name || "").trim().split(/\s+/).filter(function (p) {
        return p.length > 0;
    });
    if (parts.length === 0)
        return "";
    var first = parts[0].charAt(0);
    var last = parts.length > 1 ? parts[parts.length - 1].charAt(0) : "";
    return (first + last).toUpperCase();
}
