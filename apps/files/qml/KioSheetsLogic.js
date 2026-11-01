.pragma library

// What a sheet says and offers for one of KIO's questions in Files (ADR-0035 D-12 a; docs/specs/system-dialogs.md
// section 9): `request` is FilesApp.prompts.current ({id, kind, ...}, src/kioprompts.cpp). Returns the sheet's texts and
// buttons, each button with the id the reply carries ({button: id}, KioPromptLogic maps it to KIO's answer):
// {title, message, confirmText, confirmId, destructive, showCancel, cancelText, cancelId, returnCancels, extras: [{id, text}],
// applyToAll}. Pure: tests/unit/tst_fileskiosheets.qml.

// "An older item named “X” already exists" (Finder): the destination older or newer than the item moved or copied.
function age(request) {
    const src = request.srcModified ? new Date(request.srcModified).getTime() : NaN;
    const dest = request.destModified ? new Date(request.destModified).getTime() : NaN;
    if (isNaN(src) || isNaN(dest) || src === dest)
        return "";
    return dest < src ? "older" : "newer";
}

function conflict(request) {
    const name = request.name;
    if (request.resume)
        return resumable(request);
    const merge = request.merge === true;
    const older = age(request);
    let title;
    if (merge)
        title = qsTr("A folder named “%1” already exists in this location.").arg(name);
    else if (older === "older")
        title = qsTr("An older item named “%1” already exists in this location.").arg(name);
    else if (older === "newer")
        title = qsTr("A newer item named “%1” already exists in this location.").arg(name);
    else
        title = qsTr("An item named “%1” already exists in this location.").arg(name);

    let message = "";
    if (!request.replace)
        message = qsTr("Do you want to keep both items?");
    else if (merge)
        message = request.mode === "move" ? qsTr("Do you want to merge it with the one you’re moving? Items with the same name are asked about one by one.") : qsTr("Do you want to merge it with the one you’re copying? Items with the same name are asked about one by one.");
    else if (request.mode === "move")
        message = older === "older" ? qsTr("Do you want to replace it with the newer one you’re moving?") : older === "newer" ? qsTr("Do you want to replace it with the older one you’re moving?") : qsTr("Do you want to replace it with the one you’re moving?");
    else if (request.mode === "copy")
        message = older === "older" ? qsTr("Do you want to replace it with the newer one you’re copying?") : older === "newer" ? qsTr("Do you want to replace it with the older one you’re copying?") : qsTr("Do you want to replace it with the one you’re copying?");
    else
        message = qsTr("Do you want to replace it?");

    // The default button: Replace (Merge), else Keep Both, else Skip; the others at the leading edge (Finder: Keep Both).
    const extras = [];
    let confirmText;
    let confirmId;
    if (request.replace) {
        confirmText = merge ? qsTr("Merge") : qsTr("Replace");
        confirmId = "replace";
        if (request.keepBoth)
            extras.push({id: "keepBoth", text: qsTr("Keep Both")});
    } else if (request.keepBoth) {
        confirmText = qsTr("Keep Both");
        confirmId = "keepBoth";
    } else {
        confirmText = qsTr("Skip");
        confirmId = "skip";
    }
    if (request.skip && confirmId !== "skip")
        extras.push({id: "skip", text: qsTr("Skip")});
    return {
        title: title,
        message: message,
        confirmText: confirmText,
        confirmId: confirmId,
        destructive: false,
        showCancel: true,
        cancelText: qsTr("Stop"),
        cancelId: "stop",
        returnCancels: false,
        extras: extras,
        applyToAll: request.applyToAll === true
    };
}

// Part of the item is already there: a copy that stopped part way (KIO's FileCopyJob asks Resume / Overwrite / Cancel).
function resumable(request) {
    const extras = [];
    if (request.replace)
        extras.push({id: "replace", text: qsTr("Start Over")});
    return {
        title: qsTr("Part of “%1” is already in this location.").arg(request.name),
        message: qsTr("An earlier copy of it stopped before the end. Do you want to resume it where it stopped?"),
        confirmText: qsTr("Resume"),
        confirmId: "resume",
        destructive: false,
        showCancel: true,
        cancelText: qsTr("Stop"),
        cancelId: "stop",
        returnCancels: false,
        extras: extras,
        applyToAll: request.applyToAll === true
    };
}

// An item the operation can't handle (KIO's SkipDialog): Try Again (or Rename, for characters the destination refuses),
// Stop, and Skip when there are other items; one item that can't be retried has OK only (it stops).
function skip(request) {
    const extras = [];
    let confirmText;
    let confirmId;
    let showCancel = true;
    let message = request.text || "";
    if (request.rename) {
        confirmText = qsTr("Rename");
        confirmId = "rename";
        message = (message !== "" ? message + "\n\n" : "") + qsTr("Rename replaces the characters the destination doesn’t allow with “_”.");
    } else if (request.retry) {
        confirmText = qsTr("Try Again");
        confirmId = "retry";
    } else if (request.skip) {
        confirmText = qsTr("Skip");
        confirmId = "skip";
    } else {
        confirmText = qsTr("OK");
        confirmId = "stop";
        showCancel = false;
    }
    if (request.skip && confirmId !== "skip")
        extras.push({id: "skip", text: qsTr("Skip")});
    return {
        title: qsTr("The operation can’t be completed."),
        message: message,
        confirmText: confirmText,
        confirmId: confirmId,
        destructive: false,
        showCancel: showCancel,
        cancelText: qsTr("Stop"),
        cancelId: "stop",
        returnCancels: false,
        extras: extras,
        applyToAll: request.applyToAll === true
    };
}

// A permanent deletion KIO asks about (Files asks for its own before it starts them).
function deletion(request) {
    const one = request.count === 1;
    const name = request.name;
    let title;
    let message = qsTr("You can’t undo this action.");
    let confirmText = qsTr("Delete");
    let destructive = true;
    switch (request.type) {
    case "emptyTrash":
        title = qsTr("Are you sure you want to permanently erase the items in the Trash?");
        confirmText = qsTr("Empty Trash");
        break;
    case "trash":
        title = one ? qsTr("Do you want to move “%1” to the Trash?").arg(name) : qsTr("Do you want to move these %1 items to the Trash?").arg(request.count);
        message = "";
        confirmText = qsTr("Move to Trash");
        destructive = false;
        break;
    case "trashFull":
        title = one ? qsTr("“%1” can’t be moved to the Trash because the Trash is full.").arg(name) : qsTr("These %1 items can’t be moved to the Trash because the Trash is full.").arg(request.count);
        message = one ? qsTr("Do you want to delete it immediately? You can’t undo this action.") : qsTr("Do you want to delete them immediately? You can’t undo this action.");
        break;
    case "noTrash":
        title = one ? qsTr("“%1” can’t be moved to the Trash.").arg(name) : qsTr("These %1 items can’t be moved to the Trash.").arg(request.count);
        message = one ? qsTr("Do you want to delete it immediately? You can’t undo this action.") : qsTr("Do you want to delete them immediately? You can’t undo this action.");
        break;
    default:
        title = one ? qsTr("Are you sure you want to delete “%1”?").arg(name) : qsTr("Are you sure you want to delete these %1 items?").arg(request.count);
        break;
    }
    return {
        title: title,
        message: message,
        confirmText: confirmText,
        confirmId: "delete",
        destructive: destructive,
        showCancel: true,
        cancelText: qsTr("Cancel"),
        cancelId: "cancel",
        // A deletion is never the default (common rule 3): Return cancels.
        returnCancels: destructive,
        extras: [],
        applyToAll: false
    };
}

// A message box of a KIO worker: its text, its buttons. Esc gives Cancel, or the secondary action where there is no
// Cancel (KMessageBox's two-action questions).
function message(request) {
    const extras = [];
    let cancelText = qsTr("Cancel");
    let cancelId = "cancel";
    let showCancel = true;
    if (request.okOnly) {
        showCancel = false;
    } else if (request.cancel) {
        if (request.secondary)
            extras.push({id: "secondary", text: request.secondary});
    } else if (request.secondary) {
        cancelText = request.secondary;
        cancelId = "secondary";
    } else {
        showCancel = false;
    }
    if (request.details)
        extras.push({id: "details", text: qsTr("Show Details")});
    return {
        title: request.title || request.text,
        message: request.title ? request.text : "",
        confirmText: request.okOnly ? qsTr("OK") : (request.primary || qsTr("Continue")),
        confirmId: request.okOnly ? "ok" : "primary",
        destructive: request.warning === true && !request.okOnly,
        showCancel: showCancel,
        cancelText: cancelText,
        cancelId: cancelId,
        // A warning's action is never the default (common rule 3; KDE's own box defaults to Cancel): Return gives Cancel,
        // or the secondary action where there is no Cancel (an sftp host key that changed: "Connect Anyway" is not Return).
        returnCancels: request.warning === true && !request.okOnly && showCancel,
        extras: extras,
        applyToAll: false
    };
}

// A server whose certificate KIO's worker can't verify: Cancel is the default (Return and Esc); Continue accepts it for
// 30 minutes (KIO's "Current Session only"), or for good when "Always trust" (shown with the certificate) is ticked.
function certificate(request) {
    return {
        title: qsTr("Files can’t verify the identity of the server “%1”.").arg(request.host),
        message: qsTr("Its certificate isn’t valid: someone could be pretending to be “%1” to read what you send. Do you want to connect anyway?").arg(request.host),
        confirmText: qsTr("Continue"),
        confirmId: "continue",
        destructive: false,
        showCancel: true,
        cancelText: qsTr("Cancel"),
        cancelId: "cancel",
        returnCancels: true,
        extras: [{id: "certificate", text: qsTr("Show Certificate")}],
        applyToAll: false
    };
}

function notice(request) {
    return {
        title: request.title,
        message: request.text,
        confirmText: qsTr("OK"),
        confirmId: "ok",
        destructive: false,
        showCancel: false,
        cancelText: qsTr("Cancel"),
        cancelId: "ok",
        returnCancels: false,
        extras: [],
        applyToAll: false
    };
}

// A document whose type has no application (KIO's Open With question; ADR-0035 5c-3): Finder's alert. Choose Application…
// (the default) opens the Choose Application panel; Search the Store (Finder's App Store button, offered when Grassfield
// Store is there: request.store) opens the Store on the apps that open this type; Cancel and Esc open nothing.
function noApplication(request) {
    return {
        title: qsTr("There is no application set to open the document “%1”.").arg(request.name),
        message: request.store ? qsTr("Search Grassfield Store for an app that opens it, or choose an application on this computer.")
                               : qsTr("Choose an application on this computer to open it."),
        confirmText: qsTr("Choose Application…"),
        confirmId: "choose",
        destructive: false,
        showCancel: true,
        cancelText: qsTr("Cancel"),
        cancelId: "cancel",
        returnCancels: false,
        extras: request.store ? [{id: "store", text: qsTr("Search the Store")}] : [],
        applyToAll: false
    };
}

// The sheet for `request`, or null for none (no question, or a kind this version doesn't know: it stops the operation).
function sheet(request) {
    if (!request || request.id === undefined)
        return null;
    switch (request.kind) {
    case "conflict":
        return conflict(request);
    case "skip":
        return skip(request);
    case "delete":
        return deletion(request);
    case "message":
        return message(request);
    case "certificate":
        return certificate(request);
    case "notice":
        return notice(request);
    case "noApplication":
        return noApplication(request);
    }
    return null;
}

// The certificate chain's lines for the sheet's details: per certificate, who it names, who issued it, its validity, its
// fingerprint and the problems found. `formatDate` formats a date for the user (FilesApp's locale).
function chainLines(chain, formatDate) {
    const lines = [];
    for (let i = 0; i < (chain || []).length; ++i) {
        const c = chain[i];
        if (i > 0)
            lines.push("");
        if (c.readable) {
            lines.push(c.subject !== "" ? c.subject : qsTr("Unnamed certificate"));
            lines.push(qsTr("Issued by: %1").arg(c.issuer));
            lines.push(qsTr("Valid from %1 to %2").arg(formatDate(c.validFrom)).arg(formatDate(c.validUntil)));
            lines.push(qsTr("SHA-256: %1").arg(c.sha256));
        } else {
            lines.push(qsTr("A certificate that can’t be read"));
        }
        for (const p of c.problems || [])
            lines.push("• " + p);
    }
    return lines;
}
