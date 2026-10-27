.pragma library

// The words of the Store's data (spec SR5, SR11, SR13, SR23, SR24): the backend gives kinds, repositories, levels and
// states; the text is made here, translated. Pure, so that tests/unit/tst_storetext.qml reaches every case.

// A source badge (SR5): the repository for Arch Linux's, "Omarchy" for [omarchy], and the other sources by name.
function sourceLabel(kind, repo) {
    switch (kind) {
    case "repo":
        return repo === "omarchy" ? qsTr("Omarchy") : qsTr("Arch Linux · %1").arg(repo);
    case "setup":
        return qsTr("Omarchy setup");
    case "webapp":
        return qsTr("Web app");
    case "aur":
        return qsTr("AUR");
    case "flatpak":
        return qsTr("Flathub");
    case "foreign":
        return qsTr("Not from a repository");
    }
    return "";
}

// The glyph of a catalog symbol (sections and categories); an unknown symbol gets the generic one.
var SYMBOLS = {
    "discover": "sparkle",
    "create": "paintbrush",
    "work": "paperplane",
    "play": "gamecontroller",
    "develop": "hammer",
    "category-productivity": "paperplane",
    "category-graphics": "paintbrush",
    "category-photo-video": "film",
    "category-music-audio": "music-note",
    "category-developer-tools": "hammer",
    "category-games": "gamecontroller",
    "category-internet": "globe",
    "category-education": "book",
    "category-utilities": "wrench"
};

function symbolIcon(symbol) {
    return SYMBOLS[symbol] || "apps";
}

// The button of an app (SR13): Get, Open (installed with a launcher) or Installed (installed without one).
function buttonState(app) {
    if (!app || !app.installed)
        return "get";
    return app.launcher ? "open" : "installed";
}

function buttonText(state) {
    return state === "open" ? qsTr("Open") : state === "installed" ? qsTr("Installed") : qsTr("Get");
}

// The content rating (SR11): "Not rated" without OARS data, "None" when it lists nothing, else each group at its level.
function ratingText(rated, rating) {
    if (!rated)
        return qsTr("Not rated");
    const groups = [["violence", qsTr("Violence")], ["drugs", qsTr("Drugs, alcohol or tobacco")], ["sex", qsTr("Sexual content")],
                    ["language", qsTr("Strong language")], ["social", qsTr("Online interaction")], ["money", qsTr("Purchases or gambling")]];
    const levels = ["", qsTr("mild"), qsTr("moderate"), qsTr("intense")];
    const parts = [];
    for (const g of groups) {
        const level = rating ? rating[g[0]] : 0;
        if (level >= 1 && level <= 3)
            parts.push(qsTr("%1: %2").arg(g[1]).arg(levels[level]));
    }
    return parts.length === 0 ? qsTr("None") : parts.join(" · ");
}

// The languages (SR11): up to three by name, else two and how many more.
function languagesText(languages) {
    if (!languages || languages.length === 0)
        return "";
    if (languages.length <= 3)
        return languages.join(", ");
    return qsTr("%1, %2 and %3 more").arg(languages[0]).arg(languages[1]).arg(languages.length - 2);
}

// The sources present in a list, in the Store's order: the category page's filter (SR8).
function kindsIn(apps) {
    const order = ["repo", "setup", "webapp", "aur", "flatpak"];
    const seen = {};
    for (const a of apps || [])
        seen[a.kind] = true;
    return order.filter(k => seen[k]);
}

function kindTitle(kind) {
    switch (kind) {
    case "repo":
        return qsTr("Repositories");
    case "setup":
        return qsTr("Omarchy Setups");
    case "webapp":
        return qsTr("Web Apps");
    case "aur":
        return qsTr("AUR");
    case "flatpak":
        return qsTr("Flathub");
    }
    return "";
}

// A group of Installed (SR23).
function groupTitle(group) {
    switch (group) {
    case "arch":
        return qsTr("Arch Linux");
    case "omarchy":
        return qsTr("Omarchy");
    case "setup":
        return qsTr("Omarchy Setups");
    case "webapp":
        return qsTr("Web Apps");
    case "foreign":
        return qsTr("Not from a Repository");
    }
    return "";
}

// The state line of Updates (SR24, read only until step 4).
function updatesStatus(u) {
    switch (u ? u.state : "unknown") {
    case "up-to-date":
        return u.checkedAt !== "" ? qsTr("Your apps are up to date. Last checked %1.").arg(u.checkedAt) : qsTr("Your apps are up to date.");
    case "available":
        return u.checkedAt !== "" ? qsTr("Last checked %1.").arg(u.checkedAt) : "";
    case "update-running":
    case "busy":
        return qsTr("Update in progress");
    case "failed":
        return u.error === "offline" ? qsTr("Updates could not be checked: you're offline.") : qsTr("Updates could not be checked.");
    case "blocking":
        return qsTr("System updates are blocked. Software Update in Settings says why.");
    case "not-set-up":
    case "repair":
        return qsTr("Software Update is not set up. Settings can set it up.");
    }
    return qsTr("Software Update has not checked for updates yet.");
}

// The address a link shows: its host.
function hostOf(url) {
    const m = /^https:\/\/([^/?#]+)/.exec(url || "");
    return m ? m[1] : "";
}

// Why the Store has nothing to show (no catalog in use and no app data from Arch), in plain words: what is missing first,
// then what would bring it.
function unavailableReason(catalog, appData, online) {
    if (!online)
        return qsTr("You're offline, and this computer has no saved catalog or app data yet.");
    const parts = [];
    switch (catalog ? catalog.problem : "") {
    case "unconfigured":
        parts.push(qsTr("This version of Grassfield has no catalog host yet."));
        break;
    case "untrusted":
        parts.push(qsTr("The Grassfield catalog can't be verified: no trusted Grassfield key is installed yet."));
        break;
    case "refused":
        parts.push(qsTr("The Grassfield catalog could not be verified."));
        break;
    case "unavailable":
        parts.push(qsTr("The Grassfield catalog could not be fetched."));
        break;
    }
    if (appData && appData.problem === "unverified")
        parts.push(qsTr("Arch's app data could not be verified."));
    else if (!appData || appData.origin === "none")
        parts.push(qsTr("Arch's app data isn't installed and could not be fetched."));
    return parts.join(" ");
}
