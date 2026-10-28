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

// The button of an app (SR13): its operation's ring while one runs or waits ("progress"), else Get, Open (installed with a
// launcher) or Installed (installed without one). `actions`: the backend's (installed, launcher), when there is one.
function buttonState(app, actions, operation) {
    if (operation)
        return "progress";
    const installed = actions ? actions.installed : app && app.installed;
    const launcher = actions ? actions.launcher : app && app.launcher;
    if (!installed)
        return "get";
    return launcher ? "open" : "installed";
}

// Why Get is not offered now (the button's tooltip, SR13, SR30).
function getBlockText(reason) {
    switch (reason) {
    case "dev":
        return qsTr("dev: not applied");
    case "offline":
        return qsTr("You're offline.");
    case "missing":
        return qsTr("This computer can't install apps from the Store: Omarchy's commands or Grassfield's installer are missing.");
    case "icon":
        return qsTr("This web app's icon hasn't been downloaded yet. Refresh the Store, then try again.");
    case "source":
        return qsTr("Installing apps from this source comes in a later version of the Store.");
    }
    return "";
}

// What an operation is doing (its ring's accessible text and the queue's rows, SR18).
function operationText(op) {
    if (!op)
        return "";
    const removing = op.kind === "remove";
    switch (op.state) {
    case "waiting":
        return op.blocked ? qsTr("Waiting for another installation or an update to finish") : qsTr("Waiting");
    case "authorizing":
        return qsTr("Waiting for permission…");
    case "checking":
        return removing ? qsTr("Finishing the uninstallation…") : qsTr("Finishing the installation…");
    }
    if (op.total > 0 && op.done > 0)
        return removing ? qsTr("Uninstalling: %1 of %2").arg(op.done).arg(op.total) : qsTr("Installing: %1 of %2").arg(op.done).arg(op.total);
    return removing ? qsTr("Uninstalling…") : qsTr("Installing…");
}

// How the last operation of an app ended, in one line (SR19, SR20); "" when there is nothing to say (done, or cancelled).
function resultText(result) {
    if (!result)
        return "";
    const removing = result.kind === "remove";
    switch (result.outcome) {
    case "interrupted":
        return removing ? qsTr("The uninstallation was interrupted: %1 of %2 packages were removed.").arg(result.present).arg(result.total)
                        : qsTr("The installation was interrupted: %1 of %2 packages were installed.").arg(result.present).arg(result.total);
    case "notFinished":
        return removing ? qsTr("The uninstallation did not finish.") : qsTr("The installation did not finish.");
    case "lostTrack":
        return qsTr("The Store stopped following this operation after a long time. Check what is installed in Installed.");
    case "timedOut":
        return qsTr("The request for permission timed out.");
    case "didNotStart":
        return removing ? qsTr("The uninstallation could not start: permission was not given.") : qsTr("The installation could not start: permission was not given.");
    case "busy":
        return qsTr("Another installation or an update is running.");
    case "unfinished":
        return qsTr("Finish the system update first.");
    case "outdated":
        return qsTr("Update your system first.");
    case "refused":
        return qsTr("This app can't be uninstalled from the Store.");
    case "notApp":
        return qsTr("This package isn't an app: the Store installs only apps.");
    case "failed":
        return removing ? qsTr("The uninstallation failed.") : qsTr("The installation failed.");
    }
    return "";
}

// A result the user can try again (the same plan; --needed completes a partial install).
function canTryAgain(result) {
    return !!result && ["interrupted", "notFinished", "timedOut", "didNotStart", "busy", "failed", "lostTrack"].indexOf(result.outcome) >= 0;
}

// Why "Uninstall…" is not offered (SR22); "" when it is, or when there is nothing to say (not installed).
function uninstallReasonText(reason) {
    switch (reason) {
    case "omarchy":
        return qsTr("Part of Omarchy");
    case "grassfield":
        return qsTr("Part of Grassfield");
    case "system":
        return qsTr("Part of the system");
    case "dependency":
        return qsTr("Installed with another app");
    case "notApp":
        return qsTr("Not an app: it has no window of its own");
    case "notFromRepository":
        return qsTr("Not from a repository: uninstalling it comes in a later version of the Store");
    case "listsMissing":
        return qsTr("Omarchy's package lists can't be read, so the Store uninstalls nothing");
    case "dev":
        return qsTr("dev: not applied");
    case "missing":
        return qsTr("This computer can't uninstall apps from the Store: Omarchy's commands or Grassfield's installer are missing.");
    }
    return "";
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
