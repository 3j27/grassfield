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

// Why Get is not offered now (the button's tooltip, SR13, SR30). `kind`: the app's source (the AUR's words differ).
function getBlockText(reason, kind) {
    switch (reason) {
    case "dev":
        return qsTr("dev: not applied");
    case "offline":
        return qsTr("You're offline.");
    case "missing":
        return qsTr("This computer can't install apps from the Store: Omarchy's commands or Grassfield's installer are missing.");
    case "icon":
        return qsTr("This web app's icon hasn't been downloaded yet. Refresh the Store, then try again.");
    case "omarchyChanged":
        return omarchyChangedText(kind);
    case "aurUnchecked":
        return omarchyChangedText("aur");
    case "aurOff":
        return qsTr("Turn on the AUR in the Store's settings to install from it.");
    case "aurProtected":
        return qsTr("The system, Omarchy or Grassfield uses this name, so the Store doesn't build it from the AUR.");
    case "listsMissing":
        return qsTr("Omarchy's package lists can't be read, so the Store installs nothing from the AUR.");
    case "repository":
        return qsTr("A repository has this package: the Store installs it from there, from its own page.");
    case "flathubOff":
        return qsTr("Turn on Flathub in the Store's settings to install from it.");
    case "noFlatpak":
        return qsTr("Flathub needs the flatpak package.");
    case "source":
        return qsTr("Installing apps from this source comes in a later version of the Store.");
    }
    return "";
}

// A setup, or an AUR app, while the installed Omarchy differs from the release the catalog checked (ADR-0037 b.2, g).
function omarchyChangedText(kind) {
    if (kind === "aur")
        return qsTr("Installing from the AUR hasn't been checked with your version of Omarchy yet. The Store offers it again once its catalog has been.");
    return qsTr("This setup hasn't been checked with your version of Omarchy yet. The Store offers it again once its catalog has been.");
}

// An AUR result's line (SR7): its votes, and the out-of-date flag; "" for any other app.
function aurLine(app) {
    if (!app || app.votes === undefined)
        return "";
    const votes = app.votes === 1 ? qsTr("1 vote") : qsTr("%1 votes").arg(app.votes);
    return app.outOfDate ? qsTr("%1 · Flagged out of date").arg(votes) : votes;
}

// The AUR's warning, on the sheet of every AUR install (spec SR16, ADR-0037 e.7).
function aurWarning() {
    return qsTr("AUR packages are made by users and reviewed by no one, neither Arch Linux nor Grassfield. Their build script runs on this computer and the package is then installed with administrator rights. Install only what you trust.");
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
    case "opening":
        return qsTr("Opening Terminal…");
    case "checking":
        return removing ? qsTr("Finishing the uninstallation…") : qsTr("Finishing the installation…");
    }
    if (op.total > 0 && op.done > 0)
        return removing ? qsTr("Uninstalling: %1 of %2").arg(op.done).arg(op.total) : qsTr("Installing: %1 of %2").arg(op.done).arg(op.total);
    if (op.path === "terminal")
        return removing ? qsTr("Uninstalling in Terminal…") : qsTr("Installing in Terminal…");
    return removing ? qsTr("Uninstalling…") : qsTr("Installing…");
}

// How the last operation of an app ended, in one line (SR19, SR20); "" when there is nothing to say (done, cancelled, or a
// Flatpak install the user stopped: "stopped").
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
        // The databases are older than the mirror (a plan refused before anything downloaded, or a file the mirror no
        // longer had): the system is updated first (the integrator's note on PR #36).
        return qsTr("Your system needs to be updated before you can install apps.");
    case "refused":
        // The AUR's plan checked again in the terminal (a repository has the package now, or it is protected or needed).
        return removing ? qsTr("This app can't be uninstalled from the Store.")
                        : qsTr("The installation was refused: the system changed since the Store checked it. Try again from its page.");
    case "notApp":
        return qsTr("This package isn't an app: the Store installs only apps.");
    case "failed":
        return removing ? qsTr("The uninstallation failed.") : qsTr("The installation failed.");
    case "omarchyChanged":
        return omarchyChangedText(result.source || "");
    case "terminalDidNotOpen":
        return qsTr("The terminal did not open.");
    }
    return "";
}

// A result that Software Update answers (the last system update did not finish, or the system is older than the mirror):
// "Update Now…" opens it, and nothing of pacman's output is shown.
function needsUpdate(result) {
    return !!result && (result.outcome === "outdated" || result.outcome === "unfinished");
}

// A result the user can try again (the same plan; --needed completes a partial install).
function canTryAgain(result) {
    return !!result && ["interrupted", "notFinished", "timedOut", "didNotStart", "busy", "failed", "lostTrack", "terminalDidNotOpen"].indexOf(result.outcome) >= 0;
}

// Why "Uninstall…" is not offered (SR22); "" when it is, or when there is nothing to say (not installed).
function uninstallReasonText(reason, kind) {
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
    case "omarchyChanged":
        return omarchyChangedText(kind);
    case "aurUnchecked":
        return omarchyChangedText("aur");
    case "aurOff":
        return qsTr("Turn on the AUR in the Store's settings to uninstall it from the Store.");
    case "flathubOff":
        return qsTr("Turn on Flathub in the Store's settings to uninstall it from the Store.");
    case "noFlatpak":
        return qsTr("Flathub needs the flatpak package.");
    }
    return "";
}

// What a Flatpak can reach beyond its own window and folder (SR11, SD25), from its metadata (flatpak.h flatpakAccess),
// each in plain words: a class, "sessionService:<name>", "systemService:<name>", "other:<flatpak's words>",
// "more:<count>". A key this window does not know is said as it is, never left out. [] when it reaches nothing more.
function accessWords(keys) {
    const words = {
        "network": qsTr("The internet"),
        "allFiles": qsTr("All your files"),
        "home": qsTr("Your home folder"),
        "folders": qsTr("Some of your folders"),
        "devices": qsTr("Devices such as cameras, USB drives and game controllers"),
        "input": qsTr("Game controllers and other input devices"),
        "usb": qsTr("USB devices"),
        "kvm": qsTr("Virtual machines, through KVM"),
        "audio": qsTr("Your speakers and microphone"),
        "x11": qsTr("The X11 display, where it can see what other X11 apps show and what you type in them"),
        "sharedMemory": qsTr("Memory your other programs share"),
        "printers": qsTr("Your printers"),
        "ssh": qsTr("Your SSH keys, through the SSH agent"),
        "gpg": qsTr("Your GnuPG keys, through the GnuPG agent"),
        "smartCards": qsTr("Smart cards"),
        "bus": qsTr("Every service of your session"),
        "systemBus": qsTr("Every service of the system"),
        "bluetooth": qsTr("Bluetooth"),
        "canbus": qsTr("CAN bus devices"),
        "devel": qsTr("Developer features that can trace programs"),
        "multiarch": qsTr("32-bit programs"),
        "outside": qsTr("Programs outside its sandbox")
    };
    return Array.from(keys || [], k => {
        const key = String(k);
        if (words[key] !== undefined)
            return words[key];
        const colon = key.indexOf(":");
        const kind = colon < 0 ? "" : key.slice(0, colon), value = key.slice(colon + 1);
        if (kind === "sessionService")
            return qsTr("The session service “%1”").arg(value);
        if (kind === "systemService")
            return qsTr("The system service “%1”").arg(value);
        if (kind === "more")
            return qsTr("%1 more").arg(value);
        return qsTr("A permission the Store can't describe: %1").arg(kind === "other" ? value : key);
    });
}

// The same in one line: "Can access" (SR11); "Only its own window and files" when it reaches nothing more; "" when
// what it can reach could not be read (nothing said rather than too little).
function accessText(keys) {
    if (keys === undefined || keys === null)
        return "";
    const words = accessWords(keys);
    return words.length === 0 ? qsTr("Only its own window and files") : words.join(", ");
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
    case "aur":
        return qsTr("AUR");
    case "flatpak":
        return qsTr("Flathub");
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
    if (appData && appData.problem === "download")
        parts.push(qsTr("Arch's app data couldn't be downloaded. Check for updates, then try again."));
    else if (appData && appData.problem === "unverified")
        parts.push(qsTr("Arch's app data could not be verified."));
    else if (!appData || appData.origin === "none")
        parts.push(qsTr("Arch's app data isn't installed and could not be fetched."));
    return parts.join(" ");
}
