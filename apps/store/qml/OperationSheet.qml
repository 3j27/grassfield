pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "Store.js" as Store

// The confirmation sheet of Get and Uninstall… (spec SR14, SR15, SR17, SR22; ADR-0037 e.1): nothing runs without its
// default button. While the plan is checked (the backend's plan(), a few pacman queries as the user) the button waits;
// then the sheet lists the source, the licence, the sizes and every package the operation adds or removes (pacman's plan),
// or, for a web app, the launcher it adds or removes; for an Omarchy setup, first what it changes (our catalog's text), the
// recipe Omarchy's terminal runs and, for a removal, the files it deletes (ADR-0037 e.1, b.2). A plan that cannot run says
// why instead, and offers Software Update when the system must be updated first; Esc or Cancel close it and nothing runs.
Sheet {
    id: root

    required property var backend
    property var app: ({})
    property string kind: "install"
    // null while it is checked; then {refusal, packages, download, installed, unfinished, upgrades, dependents, protected,
    // detail} (StoreBackend::plan).
    property var plan: null
    readonly property bool removing: root.kind === "remove"
    readonly property bool webApp: root.app.kind === "webapp"
    readonly property bool setup: root.app.kind === "setup"
    readonly property var setupInfo: root.app.setup || ({})
    readonly property string refusal: root.plan ? (root.plan.refusal || "") : ""
    readonly property bool updateFirst: root.refusal === "unfinished" || root.refusal === "outdated"
    readonly property var packages: root.plan ? (root.plan.packages || []) : []
    readonly property string appName: root.app.name || ""

    function show(app: var, kind: string): void {
        root.app = app;
        root.kind = kind;
        root.plan = null;
        root.open();
        root.backend.plan(app.id, kind);
    }

    Connections {
        target: root.backend
        function onPlanReady(app: string, kind: string, plan: var): void {
            if (root.visible && app === root.app.id && kind === root.kind)
                root.plan = plan;
        }
    }

    title: {
        if (root.refusal === "")
            return root.removing ? qsTr("Uninstall “%1”?").arg(root.appName) : qsTr("Install “%1”?").arg(root.appName);
        switch (root.refusal) {
        case "unfinished":
            return qsTr("Finish the system update first");
        case "outdated":
            return qsTr("Update your system first");
        case "busy":
            return qsTr("Another installation or an update is running");
        case "offline":
            return qsTr("You're offline");
        case "dependency":
            return qsTr("“%1” can't be uninstalled").arg(root.appName);
        case "protected":
            return qsTr("Uninstalling it would also remove part of the system");
        }
        return root.removing ? qsTr("“%1” can't be uninstalled now").arg(root.appName) : qsTr("“%1” can't be installed now").arg(root.appName);
    }
    message: {
        if (!root.plan)
            return qsTr("Checking what this changes…");
        switch (root.refusal) {
        case "":
            if (root.webApp)
                return root.removing ? qsTr("The launcher and its icon are removed from Apps.")
                                     : qsTr("A launcher that opens %1 in your browser is added to Apps, with its icon.").arg(Store.hostOf(root.app.webUrl || ""));
            if (root.setup) {
                // Omarchy's recipe, in its terminal: it asks for the password there (sudo), as Omarchy's own menu does.
                const recipe = root.removing ? (root.setupInfo.remove || "") : (root.setupInfo.install || "");
                const parts = root.removing ? [] : [root.setupInfo.changes || ""];
                parts.push(qsTr("Omarchy's “%1” runs in a Terminal window, which asks for your password.").arg(recipe));
                // The user data the removal recipe deletes, as our catalog says (nothing said when it says nothing).
                if (root.removing && root.setupInfo.removes)
                    parts.push(qsTr("It also deletes: %1").arg(root.setupInfo.removes));
                parts.push(root.removing ? qsTr("These packages will be removed:") : qsTr("These packages will be installed:"));
                return parts.filter(t => t !== "").join("\n\n");
            }
            return root.removing ? qsTr("These packages will be removed. Your files and settings stay.") : qsTr("These packages will be installed:");
        case "unfinished":
            return qsTr("The last system update did not finish: some packages are newer in the repositories than on this computer. Finish the update in Software Update, then try again.");
        case "outdated":
            return qsTr("This app needs newer packages than this computer has. Update your system in Software Update, then try again.");
        case "busy":
            return qsTr("Try again when it has finished.");
        case "offline":
            return qsTr("Installing an app needs a connection to the internet.");
        case "dependency":
            return qsTr("Other apps need it: %1.").arg((root.plan.dependents || []).join(", "));
        case "protected":
            return qsTr("Uninstalling “%1” would also remove %2, which the system, Omarchy or Grassfield needs. It stays installed.").arg(root.appName).arg(root.plan.protected || "");
        case "omarchyChanged":
            return Store.omarchyChangedText();
        case "unavailable":
            return Store.getBlockText(root.plan.detail || "") || Store.uninstallReasonText(root.plan.detail || "");
        }
        return qsTr("The Store could not read what this would change.");
    }
    confirmText: {
        if (root.refusal === "")
            return root.removing ? qsTr("Uninstall") : qsTr("Install");
        return root.updateFirst ? qsTr("Open Software Update") : qsTr("OK");
    }
    destructive: root.removing && root.refusal === ""
    showCancel: root.refusal === "" || root.updateFirst
    confirmEnabled: root.plan !== null

    onAccepted: {
        if (root.refusal === "") {
            if (root.removing)
                root.backend.uninstall(root.app.id);
            else
                root.backend.install(root.app.id);
        } else if (root.updateFirst) {
            root.backend.openSoftwareUpdate();
        }
    }

    ProgressBar {
        width: parent.width
        visible: root.plan === null
        indeterminate: true
        accessibleName: qsTr("Checking")
    }

    // Source, licence and sizes.
    Column {
        width: parent.width
        visible: root.plan !== null && root.refusal === ""
        spacing: Tokens.storeInfoLineGap

        Repeater {
            model: [
                [qsTr("Source"), Store.sourceLabel(root.app.kind, root.app.repo)],
                [qsTr("Licence"), root.app.license || qsTr("Licence not stated")],
                [qsTr("Download"), root.plan && !root.removing ? (root.plan.download || "") : ""],
                [qsTr("Installed size"), root.plan && !root.removing ? (root.plan.installed || "") : ""]
            ].filter(row => row[1] !== "")

            delegate: Row {
                id: infoRow
                required property var modelData
                width: parent.width
                spacing: Tokens.spacingSm

                Text {
                    width: Math.round(infoRow.width / 3)
                    textFormat: Text.PlainText
                    text: infoRow.modelData[0]
                    color: Appearance.colors.textSecondary
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyBodySize
                }

                Text {
                    width: infoRow.width - Math.round(infoRow.width / 3) - infoRow.spacing
                    textFormat: Text.PlainText
                    text: infoRow.modelData[1]
                    elide: Text.ElideRight
                    color: Appearance.colors.text
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyBodySize
                }
            }
        }
    }

    // Every package the plan adds or removes (pacman -S --print, -Rs --print), the app's own first.
    ListView {
        id: list
        width: parent.width
        visible: root.plan !== null && root.refusal === "" && root.packages.length > 0
        height: Math.min(root.packages.length, Tokens.storeSheetListMaxRows) * Tokens.storeSheetRowHeight
        clip: true
        interactive: contentHeight > height
        boundsBehavior: Flickable.StopAtBounds
        model: root.packages
        Accessible.role: Accessible.List
        Accessible.name: root.removing ? qsTr("Packages to remove") : qsTr("Packages to install")

        ScrollBar.vertical: ScrollBar {}

        delegate: Item {
            id: row
            required property var modelData
            width: list.width
            height: Tokens.storeSheetRowHeight
            Accessible.role: Accessible.ListItem
            Accessible.name: [row.modelData.name, row.modelData.version, row.modelData.size].filter(t => t).join(", ")

            Text {
                anchors.left: parent.left
                anchors.right: size.left
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: row.modelData.name + "  " + row.modelData.version
                elide: Text.ElideRight
                color: Appearance.colors.text
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
            }

            Text {
                id: size
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: row.modelData.size || ""
                color: Appearance.colors.textSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
            }
        }
    }

    // pacman's own words, when it gave some (an unresolved plan, the last update's packages).
    Text {
        width: parent.width
        visible: text !== ""
        textFormat: Text.PlainText
        text: root.plan && root.refusal !== "" && root.refusal !== "unavailable"
              ? (root.refusal === "unfinished" ? (root.plan.unfinished || []).slice(0, 6).join("\n") : (root.plan.detail || "")) : ""
        wrapMode: Text.WrapAnywhere
        maximumLineCount: 6
        elide: Text.ElideRight
        color: Appearance.colors.textSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyCaptionSize
    }
}
