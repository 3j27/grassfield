pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Dialogs
import Grassfield.Ui

// Settings > Wallpaper (ADR-0016): a preview of the current wallpaper with its name and status, the options that apply to
// it, then grids of thumbnails (the Grassfield artwork, colours, the pictures folder, folders and pictures added), and the
// buttons that add a folder or a picture. Changes apply at once: the page writes the `wallpaper` keys of grassfield.json
// in one write and the shell follows the file; the shell reports what happened in wallpaper-state.json (read here).
// Pictures are parsed by grassfield-wallpaper only (thumbnails, listing): this page never decodes a file of the user's.
SettingsPage {
    id: root

    required property var store
    required property var backend

    title: qsTr("Wallpaper")

    readonly property string source: root.store.value("wallpaper.source")
    readonly property string path: root.store.value("wallpaper.path")
    readonly property string color: root.store.value("wallpaper.color")
    readonly property string fit: root.store.value("wallpaper.fit")
    readonly property string interval: root.store.value("wallpaper.interval")
    readonly property bool shuffle: root.store.value("wallpaper.shuffle")
    // The tool's answer for the output the user looks at: {state, reason, source, path, name, files, file}.
    property var status: ({})
    // The refusal of a choice (outside the dev folder, bad path): shown under the grids.
    property string refusal: ""
    property var pictures: []
    property var thumbs: ({})
    property var recents: []
    property bool showAllPictures: false
    property var suffixes: ["jpg", "jpeg", "png", "webp", "tif", "tiff", "bmp", "gif"]
    readonly property int shownPictures: 8

    // ---- names and captions ----
    function baseName(p: string): string {
        const i = p.lastIndexOf("/");
        return i >= 0 ? p.substring(i + 1) : p;
    }

    function intervalText(id: string): string {
        switch (id) {
        case "login":
            return qsTr("When logging in");
        case "5s":
            return qsTr("Every 5 seconds");
        case "1m":
            return qsTr("Every minute");
        case "5m":
            return qsTr("Every 5 minutes");
        case "15m":
            return qsTr("Every 15 minutes");
        case "30m":
            return qsTr("Every 30 minutes");
        case "1h":
            return qsTr("Every hour");
        case "1d":
            return qsTr("Every day");
        }
        return id;
    }

    readonly property var intervalModel: WallpaperConfig.INTERVAL_NAMES.map(id => ({id: id, text: root.intervalText(id)}))
    readonly property var fitModel: [{id: "fill", text: qsTr("Fill Screen")}, {id: "fit", text: qsTr("Fit to Screen")}, {id: "stretch", text: qsTr("Stretch to Fill Screen")}, {id: "center", text: qsTr("Center")}, {id: "tile", text: qsTr("Tile")}]
    readonly property var colorNames: [qsTr("Blue"), qsTr("Purple"), qsTr("Pink"), qsTr("Red"), qsTr("Orange"), qsTr("Yellow"), qsTr("Green"), qsTr("Graphite")]

    // The sentence for a failure id of the shell or the helper. The name is the user's, shown as plain text.
    function reasonText(id: string, name: string): string {
        switch (id) {
        case "not-found":
            return qsTr("The picture \"%1\" can't be found.").arg(name);
        case "unreadable":
            return qsTr("The picture \"%1\" can't be read.").arg(name);
        case "unsupported":
            return qsTr("This picture format isn't supported.");
        case "too-large":
            return qsTr("This picture is too large.");
        case "not-regular":
            return qsTr("This item can't be used as a wallpaper.");
        case "folder-unavailable":
            return qsTr("The folder \"%1\" isn't available.").arg(name);
        case "folder-empty":
            return qsTr("No pictures in this folder.");
        case "all-failed":
            return qsTr("None of the pictures in this folder can be shown.");
        case "helper-missing":
            return qsTr("Wallpapers can't be prepared: the helper is missing.");
        case "timeout":
            return qsTr("Preparing the picture took too long.");
        case "outside-dev":
            return qsTr("In a development session only pictures inside the project's .dev folder can be used.");
        case "invalid-path":
            return qsTr("This path can't be used.");
        case "video-unavailable":
            return qsTr("Video wallpapers aren't available yet.");
        }
        return qsTr("The wallpaper can't be shown.");
    }

    readonly property string headline: {
        if (root.source === "builtin")
            return qsTr("Grassfield");
        if (root.source === "color")
            return root.color;
        if (root.source === "folder")
            return root.baseName(root.path);
        return root.baseName(root.path);
    }

    readonly property string caption: {
        if (root.status.state === "error")
            return root.reasonText(root.status.reason, root.source === "file" ? root.baseName(root.path) : root.baseName(root.path));
        if (root.status.state === "preparing")
            return qsTr("Preparing…");
        if (root.source === "folder") {
            const every = root.shuffle ? qsTr("%1, shuffled").arg(root.intervalText(root.interval)) : root.intervalText(root.interval);
            return root.status.files > 0 ? qsTr("%1 · Pictures in the folder: %2").arg(every).arg(root.status.files) : every;
        }
        return "";
    }

    // ---- dev guard and choosing ----
    function problem(p: string): string {
        return WallpaperConfig.sourceProblem(p, root.backend.devSession, root.backend.devRoot);
    }

    function choose(entries: var, recentKind: string, recentPath: string): void {
        if (recentKind !== "") {
            const why = root.problem(recentPath);
            if (why !== "") {
                root.refusal = root.reasonText(why === "outside-dev" ? "outside-dev" : "invalid-path", root.baseName(recentPath));
                return;
            }
        }
        root.refusal = "";
        if (!root.store.setMany(entries))
            return;
        if (recentKind !== "")
            root.remember(recentKind, recentPath);
    }

    function useArtwork(): void {
        root.choose({"wallpaper.source": "builtin"}, "", "");
    }

    function useColor(c: string): void {
        root.choose({"wallpaper.source": "color", "wallpaper.color": c}, "", "");
    }

    function usePicture(p: string): void {
        root.choose({"wallpaper.source": "file", "wallpaper.path": p}, "file", p);
    }

    function useFolder(p: string): void {
        root.choose({"wallpaper.source": "folder", "wallpaper.path": p}, "folder", p);
    }

    function urlToPath(u: url): string {
        const s = u.toString();
        return s.indexOf("file://") === 0 ? decodeURIComponent(s.substring(7)) : "";
    }

    // ---- recents (wallpaper-recent.json, written by this page) ----
    function loadRecents(): void {
        const f = root.backend.readText(root.backend.wallpaperRecentFile);
        let list = [];
        if (f.exists && f.ok) {
            try {
                const o = JSON.parse(f.text);
                if (Array.isArray(o))
                    list = o.filter(e => e && (e.kind === "file" || e.kind === "folder") && typeof e.path === "string" && WallpaperConfig.validPath(e.path));
            } catch (e) {
                list = [];
            }
        }
        root.recents = list.slice(0, 12);
    }

    function remember(kind: string, p: string): void {
        const next = [{kind: kind, path: p}].concat(root.recents.filter(e => !(e.kind === kind && e.path === p))).slice(0, 12);
        root.recents = next;
        root.backend.writeText(root.backend.wallpaperRecentFile, JSON.stringify(next, null, 2) + "\n");
    }

    // ---- the helper: listing and thumbnails, two at a time ----
    property var thumbQueue: []
    property var thumbFailed: ({})
    property int thumbBusy: 0

    function requestThumb(p: string): void {
        if (p === "" || root.thumbs[p] !== undefined || root.thumbFailed[p] || root.thumbQueue.indexOf(p) >= 0)
            return;
        root.thumbQueue = root.thumbQueue.concat([p]);
        root.pump();
    }

    function pump(): void {
        while (root.thumbBusy < 2 && root.thumbQueue.length > 0) {
            const p = root.thumbQueue[0];
            root.thumbQueue = root.thumbQueue.slice(1);
            root.thumbBusy++;
            root.backend.query([root.backend.wallpaperTool, "thumb", "--width", String(Tokens.settingsWallpaperThumbWidth), "--out", root.backend.wallpaperCache + "/thumbs", "--", p], "wp.thumb:" + p, 20000);
        }
    }

    function refreshPictures(): void {
        root.backend.query([root.backend.wallpaperTool, "list", "--max", "500", "--", root.backend.picturesDir], "wp.list", 10000);
    }

    Connections {
        target: root.backend

        function onFinished(tag: string, ok: bool, output: string): void {
            if (tag === "wp.list") {
                if (!ok)
                    return;
                try {
                    const o = JSON.parse(output);
                    root.pictures = Array.isArray(o.files) ? o.files : [];
                } catch (e) {
                    root.pictures = [];
                }
            } else if (tag === "wp.formats") {
                if (!ok)
                    return;
                try {
                    const o = JSON.parse(output);
                    if (Array.isArray(o.suffixes) && o.suffixes.length > 0)
                        root.suffixes = o.suffixes;
                } catch (e) {
                    // The built-in list stays.
                }
            } else if (tag.indexOf("wp.thumb:") === 0) {
                const p = tag.substring(9);
                root.thumbBusy = Math.max(0, root.thumbBusy - 1);
                let file = "";
                if (ok) {
                    try {
                        file = JSON.parse(output).file || "";
                    } catch (e) {
                        file = "";
                    }
                }
                if (file !== "") {
                    const t = Object.assign({}, root.thumbs);
                    t[p] = file;
                    root.thumbs = t;
                } else {
                    const f = Object.assign({}, root.thumbFailed);
                    f[p] = true;
                    root.thumbFailed = f;
                }
                root.pump();
            }
        }

        function onFileChanged(p: string): void {
            if (p === root.backend.wallpaperStatusFile)
                root.loadStatus();
        }
    }

    // ---- the shell's status ----
    function loadStatus(): void {
        const f = root.backend.readText(root.backend.wallpaperStatusFile);
        let pick = {};
        if (f.exists && f.ok) {
            try {
                const outputs = JSON.parse(f.text).outputs || {};
                const all = Object.keys(outputs).map(k => outputs[k]);
                // An error on any output is the one worth showing.
                pick = all.find(o => o.state === "error") || all[all.length - 1] || {};
            } catch (e) {
                pick = {};
            }
        }
        root.status = pick;
    }

    Component.onCompleted: {
        root.backend.watch(root.backend.wallpaperStatusFile);
        root.loadStatus();
        root.loadRecents();
        root.refreshPictures();
        root.backend.query([root.backend.wallpaperTool, "formats"], "wp.formats", 5000);
    }

    // ---- the preview ----
    Item {
        id: header
        width: parent.width
        height: Tokens.settingsWallpaperPreviewHeight + captions.height + Tokens.spacingSm

        readonly property var screen: {
            const list = root.backend.screens();
            return list.length > 0 ? (list.find(s => s.primary) || list[0]) : null;
        }
        readonly property real aspect: screen && screen.pixelHeight > 0 ? screen.pixelWidth / screen.pixelHeight : 16 / 9

        Rectangle {
            id: preview
            anchors.horizontalCenter: parent.horizontalCenter
            height: Tokens.settingsWallpaperPreviewHeight
            width: Math.min(parent.width, height * header.aspect)
            radius: Tokens.settingsDisplayRadius
            clip: true
            color: root.source === "color" ? root.color : Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)
            Accessible.role: Accessible.Graphic
            Accessible.name: qsTr("Current wallpaper: %1").arg(root.headline)

            GrassfieldArtwork {
                anchors.fill: parent
                visible: root.source === "builtin" || (root.source !== "color" && preparedImage.status !== Image.Ready)
            }

            Image {
                id: preparedImage
                anchors.fill: parent
                // The prepared picture the shell drew (the tool's own output, never the user's file).
                source: root.source !== "builtin" && root.source !== "color" && root.status.file ? "file://" + root.status.file : ""
                asynchronous: true
                cache: false
                fillMode: Image.PreserveAspectCrop
                sourceSize: Qt.size(Tokens.settingsWallpaperThumbWidth * 2, Tokens.settingsWallpaperThumbWidth * 2)
            }

            Rectangle {
                anchors.fill: parent
                radius: preview.radius
                color: "transparent"
                border.width: 1
                border.color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
            }
        }

        Column {
            id: captions
            y: Tokens.settingsWallpaperPreviewHeight + Tokens.spacingSm
            width: parent.width
            spacing: Tokens.spacingXs

            Text {
                width: parent.width
                textFormat: Text.PlainText
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideMiddle
                text: root.headline
                color: Appearance.colors.text
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
                font.weight: Tokens.typographyMenuBoldWeight
                Accessible.role: Accessible.StaticText
                Accessible.name: text
            }

            Text {
                visible: root.caption !== ""
                width: parent.width
                textFormat: Text.PlainText
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: root.caption
                color: Appearance.colors.textSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
                Accessible.role: Accessible.StaticText
                Accessible.name: text
            }

            Item {
                visible: root.status.state === "error" && root.source !== "builtin"
                width: parent.width
                height: visible ? useArtworkButton.height : 0

                Button {
                    id: useArtworkButton
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: qsTr("Use the Grassfield Wallpaper")
                    onClicked: root.useArtwork()
                }
            }
        }
    }

    // ---- options that apply to the current wallpaper ----
    SettingsGroup {
        visible: root.source !== "builtin"

        SettingsRow {
            visible: root.source === "file" || root.source === "folder"
            title: qsTr("Fit")
            Picker {
                anchors.verticalCenter: parent.verticalCenter
                accessibleName: qsTr("Fit")
                model: root.fitModel
                value: root.fit
                onPicked: id => root.store.set("wallpaper.fit", id)
            }
        }

        SettingsRow {
            visible: root.source === "color" || ((root.source === "file" || root.source === "folder") && (root.fit === "fit" || root.fit === "center" || root.fit === "tile"))
            title: qsTr("Colour")
            subtitle: root.source === "color" ? "" : qsTr("Shown around a picture that does not fill the screen.")
            ColorWell {
                anchors.verticalCenter: parent.verticalCenter
                accessibleName: qsTr("Wallpaper colour")
                color: root.color
                presets: Tokens.iconModeTintColors.map((c, i) => ({color: c, name: root.colorNames[i]}))
                onEdited: c => root.store.set("wallpaper.color", c)
            }
        }

        SettingsRow {
            visible: root.source === "folder"
            title: qsTr("Change picture")
            Picker {
                anchors.verticalCenter: parent.verticalCenter
                accessibleName: qsTr("Change picture")
                model: root.intervalModel
                value: root.interval
                onPicked: id => root.store.set("wallpaper.interval", id)
            }
        }

        SettingsRow {
            visible: root.source === "folder"
            title: qsTr("Shuffle")
            subtitle: qsTr("Random order, every picture once before any is repeated.")
            Toggle {
                accessibleName: qsTr("Shuffle")
                checked: root.shuffle
                onToggled: c => root.store.set("wallpaper.shuffle", c)
            }
        }
    }

    // ---- sections ----
    SettingsGroup {
        caption: qsTr("Grassfield")

        Item {
            width: parent.width
            height: artGrid.height + 2 * Tokens.spacingMd

            WallpaperGrid {
                id: artGrid
                x: Tokens.spacingMd
                y: Tokens.spacingMd
                width: parent.width - 2 * Tokens.spacingMd
                accessibleName: qsTr("Grassfield")
                model: [{kind: "art", label: qsTr("Grassfield"), selected: root.source === "builtin"}]
                onActivated: root.useArtwork()
            }
        }
    }

    SettingsGroup {
        id: picturesGroup
        caption: qsTr("Pictures")
        footnote: root.pictures.length === 0 ? qsTr("No pictures were found in the Pictures folder.") : ""

        readonly property var shown: root.showAllPictures ? root.pictures : root.pictures.slice(0, root.shownPictures)

        onShownChanged: {
            for (const p of shown)
                root.requestThumb(p);
        }

        Item {
            visible: root.pictures.length > 0
            width: parent.width
            height: visible ? pictureGrid.height + 2 * Tokens.spacingMd : 0

            WallpaperGrid {
                id: pictureGrid
                x: Tokens.spacingMd
                y: Tokens.spacingMd
                width: parent.width - 2 * Tokens.spacingMd
                accessibleName: qsTr("Pictures")
                model: picturesGroup.shown.map(p => ({kind: "image", label: root.baseName(p), thumb: root.thumbs[p] || "", selected: root.source === "file" && root.path === p}))
                onActivated: index => root.usePicture(picturesGroup.shown[index])
            }
        }

        Item {
            visible: root.pictures.length > root.shownPictures
            width: parent.width
            height: visible ? showAllButton.height + Tokens.spacingMd : 0

            Button {
                id: showAllButton
                anchors.right: parent.right
                anchors.rightMargin: Tokens.spacingMd
                text: root.showAllPictures ? qsTr("Show Fewer") : qsTr("Show All (%1)").arg(root.pictures.length)
                onClicked: root.showAllPictures = !root.showAllPictures
            }
        }
    }

    SettingsGroup {
        caption: qsTr("Colours")

        Item {
            width: parent.width
            height: colorGrid.height + 2 * Tokens.spacingMd

            WallpaperGrid {
                id: colorGrid
                x: Tokens.spacingMd
                y: Tokens.spacingMd
                width: parent.width - 2 * Tokens.spacingMd
                accessibleName: qsTr("Colours")
                model: Tokens.iconModeTintColors.map((c, i) => ({kind: "color", color: c, label: root.colorNames[i], selected: root.source === "color" && root.color.toLowerCase() === c.toLowerCase()}))
                onActivated: index => root.useColor(Tokens.iconModeTintColors[index])
            }
        }
    }

    SettingsGroup {
        id: addedGroup
        caption: qsTr("Folders and Pictures")
        footnote: root.recents.length === 0 ? qsTr("Add a folder to change the picture at an interval, or a single picture.") : ""

        // One tile per recent source: a picture shows its thumbnail, a folder reads "Shuffle <name>" (macOS wording).
        readonly property var items: root.recents

        onItemsChanged: {
            for (const e of items) {
                if (e.kind === "file")
                    root.requestThumb(e.path);
            }
        }

        Item {
            visible: root.recents.length > 0
            width: parent.width
            height: visible ? addedGrid.height + 2 * Tokens.spacingMd : 0

            WallpaperGrid {
                id: addedGrid
                x: Tokens.spacingMd
                y: Tokens.spacingMd
                width: parent.width - 2 * Tokens.spacingMd
                accessibleName: qsTr("Folders and Pictures")
                model: addedGroup.items.map(e => ({
                            kind: e.kind === "file" ? "image" : "folder",
                            label: e.kind === "folder" ? qsTr("Shuffle %1").arg(root.baseName(e.path)) : root.baseName(e.path),
                            thumb: e.kind === "file" ? (root.thumbs[e.path] || "") : "",
                            selected: root.source === e.kind && root.path === e.path
                        }))
                onActivated: index => {
                    const e = addedGroup.items[index];
                    if (e.kind === "file")
                        root.usePicture(e.path);
                    else
                        root.useFolder(e.path);
                }
            }
        }

        Item {
            width: parent.width
            height: addFolderButton.height + 2 * Tokens.spacingMd

            Row {
                anchors.right: parent.right
                anchors.rightMargin: Tokens.spacingMd
                anchors.verticalCenter: parent.verticalCenter
                spacing: Tokens.spacingSm

                Button {
                    id: addFolderButton
                    text: qsTr("Add Folder…")
                    onClicked: folderDialog.open()
                }

                Button {
                    text: qsTr("Add Picture…")
                    onClicked: fileDialog.open()
                }
            }
        }
    }

    Text {
        visible: root.refusal !== ""
        width: parent.width
        leftPadding: Tokens.spacingMd
        rightPadding: Tokens.spacingMd
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        text: root.refusal
        color: Appearance.colors.textSecondary
        font.family: Appearance.fontFamily
        font.pixelSize: Tokens.typographyCaptionSize
        Accessible.role: Accessible.StaticText
        Accessible.name: text
    }

    // The pickers are Qt Quick Dialogs: with the session's GTK platform theme they are the native chooser (a documented
    // limit: it does not look like a Grassfield window). Esc closes them and changes nothing.
    FolderDialog {
        id: folderDialog
        title: qsTr("Choose a folder of pictures")
        onAccepted: {
            const p = root.urlToPath(selectedFolder);
            if (p !== "")
                root.useFolder(p);
        }
    }

    FileDialog {
        id: fileDialog
        title: qsTr("Choose a picture")
        nameFilters: [qsTr("Pictures (%1)").arg(root.suffixes.map(s => "*." + s).join(" "))]
        onAccepted: {
            const p = root.urlToPath(selectedFile);
            if (p !== "")
                root.usePicture(p);
        }
    }
}
