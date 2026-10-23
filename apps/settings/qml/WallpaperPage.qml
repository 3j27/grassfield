pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Dialogs
import Grassfield.Ui

// Settings > Wallpaper (ADR-0016): a preview of the current wallpaper with its name and status, the options that apply to
// it, then grids of thumbnails (the Grassfield artwork, colours, the pictures folder, folders and pictures added), and the
// buttons that add a folder or a picture. Changes apply at once: the page writes the `wallpaper` keys of grassfield.json
// in one write and the shell follows the file; the shell reports what happened in wallpaper-state.json (read here).
// Pictures are parsed by grassfield-wallpaper only (thumbnails, listing): this page never decodes a file of the user's.
// Online (ADR-0016 step 2): one tile, the Wikimedia Commons Picture of the Day. Choosing it shows what is contacted and asks
// before anything is turned on; then the picture shows with its attribution (Title, Author, Source, Licence, Last updated).
// This page never touches the network: the shell fetches, and reports the state in wallpaper-state.json.
SettingsPage {
    id: root

    required property var store
    required property var backend

    title: qsTr("Wallpaper")

    // ---- which display the options are for (ADR-0016 section 8: "Display", shown with more than one output) ----
    // "all" = All Displays (the top-level keys), else a display key (WallpaperConfig.displayKey): its entry of `wallpaper.outputs`
    // overrides the top level for that display only. Every row below reads and writes through `eff` and `setFields`.
    property string displayId: "all"
    // The connected displays: [{key, name, model, serial, label}], read when the page opens and when the file changes.
    property var displays: []
    readonly property var currentDisplay: root.displayId === "all" ? null : (root.displays.find(d => d.key === root.displayId) || null)
    // The whole stored object, as WallpaperConfig reads it.
    readonly property var stored: ({
            source: root.store.value("wallpaper.source"),
            path: root.store.value("wallpaper.path"),
            color: root.store.value("wallpaper.color"),
            fit: root.store.value("wallpaper.fit"),
            interval: root.store.value("wallpaper.interval"),
            shuffle: root.store.value("wallpaper.shuffle"),
            videoOnBattery: root.store.value("wallpaper.videoOnBattery"),
            online: {provider: root.store.value("wallpaper.online.provider")},
            outputs: root.store.value("wallpaper.outputs")
        })
    // The settings that apply to the chosen display (the top level for All Displays).
    readonly property var eff: root.currentDisplay ? WallpaperConfig.resolve(root.stored, root.currentDisplay) : WallpaperConfig.resolve(root.stored, {name: "", model: "", serial: ""})
    // The chosen display has an override of its own.
    readonly property bool overridden: root.currentDisplay !== null && WallpaperConfig.normalize(root.stored).outputs.some(e => WallpaperConfig.sameDisplay(e.display, root.currentDisplay))

    readonly property string source: root.eff.source
    readonly property string path: root.eff.path
    readonly property string color: root.eff.color
    readonly property string fit: root.eff.fit
    readonly property string interval: root.eff.interval
    readonly property bool shuffle: root.eff.shuffle
    readonly property bool videoOnBattery: root.store.value("wallpaper.videoOnBattery")
    readonly property string provider: root.store.value("wallpaper.online.provider")
    // The tool's answer for the output the user looks at: {state, reason, source, path, name, files, file, video, progress}.
    property var status: ({})
    // Every output's answer, by output name.
    property var allStatus: ({})
    // The online daily picture as the shell reports it: {phase, failure, entry: {title, author, credit, caption, licenseShort,
    // licenseUrl, sourceUrl, fetchedAt, file} | null}; {} before it reports. Plain text only.
    property var online: ({})
    // The opt-in disclosure is open (the tile was chosen, the source is not on yet).
    property bool disclosing: false
    readonly property var onlineEntry: root.online.entry || null
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
        case "video-unsupported":
            return qsTr("The video \"%1\" can't be played.").arg(name);
        case "video-too-long":
            return qsTr("This video is too long for a wallpaper (10 minutes at most).");
        case "transcode-failed":
            return qsTr("The video \"%1\" couldn't be prepared.").arg(name);
        case "ffmpeg-missing":
            return qsTr("Video wallpapers can't be prepared: ffmpeg is missing.");
        case "cancelled":
            return qsTr("Preparing the video was cancelled.");
        case "video-crashed":
            return qsTr("The video wallpaper was stopped; a still is shown.");
        case "network":
            return qsTr("The picture of the day can't be downloaded right now.");
        case "skipped":
            return qsTr("Today's entry is not a picture; yesterday's picture is shown.");
        case "bad-response":
            return qsTr("The picture of the day can't be read.");
        }
        return qsTr("The wallpaper can't be shown.");
    }

    // "26/10/22 09:41" in the user's locale, "" when the date does not parse.
    function formatUpdated(iso: string): string {
        const d = new Date(iso || "");
        return isNaN(d.getTime()) ? "" : Qt.locale().toString(d, Locale.ShortFormat);
    }

    // The source page as it reads: no scheme, percent-escapes decoded (WallpaperConfig.displayUrl).
    function sourceText(url: string): string {
        return WallpaperConfig.displayUrl(url);
    }

    // The licence name and the source page are links (CC BY 4.0 section 3(a)(1)(C)): a click or Return opens a clean https
    // address with xdg-open through the backend's guarded action path (an argument vector, never a shell string; a dev
    // session suppresses it). The page itself never touches the network.
    function openLink(url: string): void {
        const u = WallpaperConfig.linkOf(url);
        if (u !== "")
            root.backend.act(qsTr("Open a link"), ["xdg-open", u], "wallpaper.link");
    }

    readonly property string headline: {
        if (root.source === "builtin")
            return qsTr("Grassfield");
        if (root.source === "color")
            return root.color;
        if (root.source === "online")
            return root.onlineEntry && root.onlineEntry.title ? root.onlineEntry.title : root.providerName(root.provider);
        if (root.source === "folder")
            return root.baseName(root.path);
        return root.baseName(root.path);
    }

    // The name of an online source as the tile and the disclosure call it.
    function providerName(id: string): string {
        return id === "apod" ? qsTr("Astronomy Picture of the Day (NASA)") : qsTr("Picture of the Day (Wikimedia Commons)");
    }

    // The hosts a provider contacts, as the disclosure names them.
    function providerHosts(id: string): string {
        return id === "apod" ? "api.nasa.gov, apod.nasa.gov" : "commons.wikimedia.org, thumb.wikimedia.org, upload.wikimedia.org";
    }

    // A video is being transcoded for the display shown (the shell reports its progress, 0..1).
    readonly property bool transcoding: root.source === "video" && typeof root.status.progress === "number" && root.status.progress >= 0

    readonly property string caption: {
        if (root.status.state === "error")
            return root.reasonText(root.status.reason, root.source === "file" ? root.baseName(root.path) : root.baseName(root.path));
        if (root.source === "video" && root.transcoding)
            return qsTr("Preparing the video… %1%").arg(Math.round(root.status.progress * 100));
        if (root.status.state === "preparing")
            return qsTr("Preparing…");
        // A video that crashed the shell is shown as its poster: said here, once the page shows it.
        if (root.source === "video" && root.status.reason === "video-crashed")
            return root.reasonText("video-crashed", "");
        if (root.source === "online") {
            // Nothing cached yet: the artwork shows, and the page says why.
            if (root.status.state === "waiting")
                return root.online.phase === "fetching" ? qsTr("Downloading today's picture…") : qsTr("Waiting for a connection");
            // Today's entry cannot be used (a video, a licence): the previous picture stays, and the page says so.
            if (root.online.failure === "skipped")
                return root.reasonText("skipped", "");
            return root.onlineEntry && root.onlineEntry.caption ? root.onlineEntry.caption : "";
        }
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
        if (!root.writeFields(entries))
            return;
        if (recentKind !== "")
            root.remember(recentKind, recentPath);
    }

    // Writes keys of grassfield.json in one write. For a chosen display the per-display keys go to that display's entry of
    // wallpaper.outputs (the top level stays); the keys that are not per display (the online provider, play on battery)
    // always go to the top level.
    function writeFields(entries: var): bool {
        if (root.currentDisplay === null)
            return root.store.setMany(entries);
        const perDisplay = ["source", "path", "color", "fit", "interval", "shuffle"];
        const fields = {};
        const next = {};
        for (const k of Object.keys(entries)) {
            const name = k.substring("wallpaper.".length);
            if (perDisplay.indexOf(name) >= 0)
                fields[name] = entries[k];
            else
                next[k] = entries[k];
        }
        if (Object.keys(fields).length > 0)
            next["wallpaper.outputs"] = WallpaperConfig.withOutput(root.stored.outputs, root.currentDisplay, fields);
        return root.store.setMany(next);
    }

    // The chosen display follows All Displays again (its override is removed).
    function useAllDisplays(): void {
        if (root.currentDisplay !== null)
            root.store.set("wallpaper.outputs", WallpaperConfig.withOutput(root.stored.outputs, root.currentDisplay, null));
    }

    function useArtwork(): void {
        root.choose({"wallpaper.source": "builtin"}, "", "");
    }

    // The online tile asks first: what is contacted is shown, and nothing is turned on until the user agrees.
    function askOnline(provider: string): void {
        if (root.source === "online" && root.provider === provider)
            return;
        root.disclosedProvider = provider;
        root.disclosing = true;
        Qt.callLater(root.revealDisclosure);
    }

    // The disclosure opens below the fold: scroll it into view (its bottom at the bottom of the pane) and give the keyboard to the
    // default button.
    function revealDisclosure(): void {
        const bottom = disclosure.mapToItem(root.contentItem, 0, disclosure.height).y;
        root.contentY = Math.max(0, Math.min(root.contentHeight - root.height, Math.max(root.contentY, bottom - root.height + Tokens.spacingLg)));
        useOnlineButton.forceActiveFocus();
    }

    // The provider whose disclosure is open ('' when none).
    property string disclosedProvider: "commons"

    function useOnline(): void {
        root.disclosing = false;
        root.choose({"wallpaper.source": "online", "wallpaper.online.provider": root.disclosedProvider}, "", "");
    }

    function useVideo(p: string): void {
        root.choose({"wallpaper.source": "video", "wallpaper.path": p}, "video", p);
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

    // A file, a folder or a video dropped on the preview: a video or a picture by its suffix, anything else is asked of the helper
    // (a folder lists, a file does not).
    function dropped(p: string): void {
        if (p === "" || !WallpaperConfig.validPath(p)) {
            root.refusal = root.reasonText("invalid-path", "");
            return;
        }
        const why = root.problem(p);
        if (why !== "") {
            root.refusal = root.reasonText(why === "outside-dev" ? "outside-dev" : "invalid-path", root.baseName(p));
            return;
        }
        const dot = p.lastIndexOf(".");
        const ext = dot > p.lastIndexOf("/") ? p.substring(dot + 1).toLowerCase() : "";
        if (WallpaperConfig.VIDEO_SUFFIXES.indexOf(ext) >= 0)
            root.useVideo(p);
        else if (root.suffixes.indexOf(ext) >= 0)
            root.usePicture(p);
        else
            root.backend.query([root.backend.wallpaperTool, "list", "--max", "1", "--", p], "wp.drop:" + p, 10000);
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
                    list = o.filter(e => e && (e.kind === "file" || e.kind === "folder" || e.kind === "video") && typeof e.path === "string" && WallpaperConfig.validPath(e.path));
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
            } else if (tag.indexOf("wp.drop:") === 0) {
                const p = tag.substring(8);
                if (ok)
                    root.useFolder(p);
                else
                    root.refusal = root.reasonText("not-regular", root.baseName(p));
            } else if (tag.indexOf("wp.thumb:") === 0) {
                const p = tag.substring(9);
                root.thumbBusy = Math.max(0, root.thumbBusy - 1);
                let file = "";
                if (ok) {
                    try {
                        const o = JSON.parse(output);
                        // The helper names the picture it really read: in a dev session it must lie inside .dev (a symlink
                        // there must not show an owner's photo), as the shell checks it. The thumbnail must be in the cache.
                        const okReal = typeof o.real === "string" && root.problem(o.real) === "";
                        const okFile = typeof o.file === "string" && WallpaperConfig.isUnder(o.file, root.backend.wallpaperCache);
                        file = okReal && okFile ? o.file : "";
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
        let outputs = {};
        let online = {};
        if (f.exists && f.ok) {
            try {
                const parsed = JSON.parse(f.text);
                online = parsed.online && typeof parsed.online === "object" ? parsed.online : {};
                outputs = parsed.outputs && typeof parsed.outputs === "object" ? parsed.outputs : {};
            } catch (e) {
                outputs = {};
            }
        }
        root.allStatus = outputs;
        root.online = online;
        root.pickStatus();
    }

    // The answer for the display the options are for; for All Displays the one worth showing (an error on any output first).
    function pickStatus(): void {
        const outputs = root.allStatus;
        if (root.currentDisplay !== null && outputs[root.currentDisplay.name]) {
            root.status = outputs[root.currentDisplay.name];
            return;
        }
        const all = Object.keys(outputs).map(k => outputs[k]);
        root.status = all.find(o => o.state === "error") || all[all.length - 1] || {};
    }

    onCurrentDisplayChanged: root.pickStatus()

    // The connected displays (QScreen: name, model, serial), the same identity the shell uses (WallpaperConfig.displayKey).
    function refreshDisplays(): void {
        const list = root.backend.screens();
        root.displays = list.map(s => {
            const d = {name: s.name, model: s.model || "", serial: s.serial || ""};
            d.key = WallpaperConfig.displayKey(d);
            d.label = d.model !== "" ? qsTr("%1 (%2)").arg(d.name).arg(d.model) : d.name;
            return d;
        });
        if (root.displayId !== "all" && !root.displays.some(d => d.key === root.displayId))
            root.displayId = "all";
    }

    Component.onCompleted: {
        root.backend.watch(root.backend.wallpaperStatusFile);
        root.refreshDisplays();
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

        // The display the options are for (its aspect ratio shapes the preview), else the primary one.
        readonly property var screen: {
            const list = root.backend.screens();
            const chosen = root.currentDisplay ? list.find(s => s.name === root.currentDisplay.name) : null;
            return chosen || (list.length > 0 ? (list.find(s => s.primary) || list[0]) : null);
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

            // Dropping a file, a folder or a video on the preview sets it (ADR-0016 section 8).
            DropArea {
                anchors.fill: parent
                keys: ["text/uri-list"]
                onDropped: drop => {
                    if (drop.urls.length > 0)
                        root.dropped(root.urlToPath(drop.urls[0]));
                }
            }

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

    // ---- display: All Displays, or one display with a wallpaper of its own (shown with more than one output) ----
    SettingsGroup {
        visible: root.displays.length > 1

        SettingsRow {
            title: qsTr("Display")
            subtitle: root.currentDisplay === null ? qsTr("The wallpaper of every display that has none of its own.") : (root.overridden ? qsTr("This display has a wallpaper of its own.") : qsTr("This display follows All Displays."))
            Picker {
                anchors.verticalCenter: parent.verticalCenter
                implicitWidth: Tokens.settingsWallpaperPickerWidth
                accessibleName: qsTr("Display")
                model: [{id: "all", text: qsTr("All Displays")}].concat(root.displays.map(d => ({id: d.key, text: d.label})))
                value: root.displayId
                onPicked: id => root.displayId = id
            }
        }

        SettingsRow {
            visible: root.overridden
            title: qsTr("Follow All Displays")
            subtitle: qsTr("Removes the wallpaper of this display.")
            Button {
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("Use the All Displays Wallpaper")
                onClicked: root.useAllDisplays()
            }
        }
    }

    // ---- options that apply to the current wallpaper ----
    SettingsGroup {
        visible: root.source !== "builtin"

        SettingsRow {
            visible: root.source === "file" || root.source === "folder" || root.source === "online" || root.source === "video"
            title: qsTr("Fit")
            Picker {
                anchors.verticalCenter: parent.verticalCenter
                implicitWidth: Tokens.settingsWallpaperPickerWidth
                accessibleName: qsTr("Fit")
                // A video is filled or fitted only; the other modes are for pictures.
                model: root.source === "video" ? root.fitModel.filter(m => m.id === "fill" || m.id === "fit") : root.fitModel
                value: root.fit
                onPicked: id => root.writeFields({"wallpaper.fit": id})
            }
        }

        SettingsRow {
            visible: root.source === "color" || ((root.source === "file" || root.source === "folder" || root.source === "online" || root.source === "video") && (root.fit === "fit" || root.fit === "center" || root.fit === "tile"))
            title: qsTr("Colour")
            subtitle: root.source === "color" ? "" : qsTr("Shown around a picture that does not fill the screen.")
            ColorWell {
                anchors.verticalCenter: parent.verticalCenter
                accessibleName: qsTr("Wallpaper colour")
                color: root.color
                presets: Tokens.iconModeTintColors.map((c, i) => ({color: c, name: root.colorNames[i]}))
                onEdited: c => root.writeFields({"wallpaper.color": c})
            }
        }

        SettingsRow {
            visible: root.source === "folder"
            title: qsTr("Change picture")
            Picker {
                anchors.verticalCenter: parent.verticalCenter
                implicitWidth: Tokens.settingsWallpaperPickerWidth
                accessibleName: qsTr("Change picture")
                model: root.intervalModel
                value: root.interval
                onPicked: id => root.writeFields({"wallpaper.interval": id})
            }
        }

        SettingsRow {
            visible: root.source === "video"
            title: qsTr("Play on battery power")
            subtitle: qsTr("A video wallpaper pauses on battery, when you are away, under a full-screen window, and with Reduce Motion.")
            Toggle {
                accessibleName: qsTr("Play on battery power")
                checked: root.videoOnBattery
                onToggled: c => root.store.set("wallpaper.videoOnBattery", c)
            }
        }

        // The shell transcodes the video once (H.264 at the display's size); its progress is reported in wallpaper-state.json.
        SettingsRow {
            visible: root.transcoding
            title: qsTr("Preparing the video")
            subtitle: qsTr("%1%").arg(root.transcoding ? Math.round(root.status.progress * 100) : 0)
            Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Tokens.spacingMd

                Rectangle {
                    id: progressTrack
                    anchors.verticalCenter: parent.verticalCenter
                    width: Tokens.settingsWallpaperPickerWidth - Tokens.spacingMd * 4
                    height: Tokens.spacingXs
                    radius: height / 2
                    color: Appearance.withAlpha(Appearance.colors.separator, Appearance.separatorOpacity)
                    Accessible.role: Accessible.ProgressBar
                    Accessible.name: qsTr("Preparing the video")
                    Accessible.description: qsTr("%1%").arg(root.transcoding ? Math.round(root.status.progress * 100) : 0)

                    Rectangle {
                        width: parent.width * (root.transcoding ? Math.max(0, Math.min(1, root.status.progress)) : 0)
                        height: parent.height
                        radius: parent.radius
                        color: Appearance.colors.accent
                    }
                }

                // Cancel: the Grassfield wallpaper again (the shell stops the job).
                Button {
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("Cancel")
                    onClicked: root.useArtwork()
                }
            }
        }

        SettingsRow {
            visible: root.source === "folder"
            title: qsTr("Shuffle")
            subtitle: qsTr("Random order, every picture once before any is repeated.")
            Toggle {
                accessibleName: qsTr("Shuffle")
                checked: root.shuffle
                onToggled: c => root.writeFields({"wallpaper.shuffle": c})
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

    // ---- online (ADR-0016 step 2) ----
    SettingsGroup {
        id: onlineGroup
        caption: qsTr("Online")
        footnote: root.disclosing ? "" : qsTr("Once a day Grassfield contacts the source you choose: commons.wikimedia.org, thumb.wikimedia.org and upload.wikimedia.org, or api.nasa.gov and apod.nasa.gov. These services see your IP address.")

        Item {
            width: parent.width
            height: onlineGrid.height + 2 * Tokens.spacingMd

            WallpaperGrid {
                id: onlineGrid
                x: Tokens.spacingMd
                y: Tokens.spacingMd
                width: parent.width - 2 * Tokens.spacingMd
                accessibleName: qsTr("Online")
                model: [{kind: "image", wrap: true, label: root.providerName("commons"), thumb: root.source === "online" && root.provider === "commons" && root.onlineEntry && root.onlineEntry.file ? root.onlineEntry.file : "", selected: root.source === "online" && root.provider === "commons"},
                    {kind: "image", wrap: true, label: root.providerName("apod"), thumb: root.source === "online" && root.provider === "apod" && root.onlineEntry && root.onlineEntry.file ? root.onlineEntry.file : "", selected: root.source === "online" && root.provider === "apod"}]
                onActivated: index => root.askOnline(index === 1 ? "apod" : "commons")
            }
        }

        // The opt-in: what is contacted, how often, who sees what. Esc or Cancel leaves everything as it was.
        Item {
            id: disclosure
            visible: root.disclosing && !(root.source === "online" && root.provider === root.disclosedProvider)
            width: parent.width
            height: visible ? disclosureColumn.height + 2 * Tokens.spacingMd : 0
            Accessible.role: Accessible.Grouping
            Accessible.name: root.providerName(root.disclosedProvider)
            Keys.onEscapePressed: root.disclosing = false

            Column {
                id: disclosureColumn
                x: Tokens.spacingMd
                y: Tokens.spacingMd
                width: parent.width - 2 * Tokens.spacingMd
                spacing: Tokens.spacingSm

                Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    wrapMode: Text.Wrap
                    text: root.disclosedProvider === "apod" ? qsTr("Grassfield will download NASA's Astronomy Picture of the Day once a day. It contacts api.nasa.gov and apod.nasa.gov, and only while you are online on a connection that is not metered. These services see your IP address and the day you ask for; the shared demonstration key is used, so no account is involved. A picture that has a copyright holder is shown with its credit. Nothing is contacted until you choose Use Picture of the Day.") : qsTr("Grassfield will download the Wikimedia Commons Picture of the Day once a day. It contacts commons.wikimedia.org, thumb.wikimedia.org and upload.wikimedia.org, and only while you are online on a connection that is not metered. These services see your IP address and the picture you ask for. Nothing is contacted until you choose Use Picture of the Day.")
                    color: Appearance.colors.text
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.typographyBodySize
                    Accessible.role: Accessible.StaticText
                    Accessible.name: text
                }

                Row {
                    anchors.right: parent.right
                    spacing: Tokens.spacingSm

                    Button {
                        text: qsTr("Cancel")
                        onClicked: root.disclosing = false
                    }

                    Button {
                        id: useOnlineButton
                        primary: true
                        text: qsTr("Use Picture of the Day")
                        onClicked: root.useOnline()
                    }
                }
            }
        }
    }

    // The attribution of the picture on screen (the same fields as the desktop menu's "About This Wallpaper").
    SettingsGroup {
        visible: root.source === "online" && root.onlineEntry !== null
        caption: qsTr("About This Wallpaper")

        SettingsRow {
            visible: !!(root.onlineEntry && root.onlineEntry.title)
            title: qsTr("Title")
            valueText: root.onlineEntry ? root.onlineEntry.title : ""
        }

        SettingsRow {
            visible: !!(root.onlineEntry && (root.onlineEntry.author || root.onlineEntry.credit))
            title: qsTr("Author")
            valueText: root.onlineEntry ? (root.onlineEntry.author || root.onlineEntry.credit) : ""
        }

        SettingsRow {
            id: sourceRow
            readonly property string link: root.onlineEntry ? WallpaperConfig.linkOf(root.onlineEntry.sourceUrl) : ""
            title: qsTr("Source")
            subtitle: sourceRow.link === "" && root.onlineEntry ? root.sourceText(root.onlineEntry.sourceUrl) : ""
            valueText: sourceRow.link === "" ? (root.provider === "apod" ? qsTr("NASA APOD") : qsTr("Wikimedia Commons")) : ""

            LinkText {
                visible: sourceRow.link !== ""
                width: Math.min(implicitWidth, sourceRow.width - Tokens.settingsGroupLabelWidth - 3 * Tokens.spacingLg)
                text: root.onlineEntry ? root.sourceText(root.onlineEntry.sourceUrl) : ""
                target: sourceRow.link
                maximumLineCount: 3
                onActivated: root.openLink(sourceRow.link)
            }
        }

        SettingsRow {
            id: licenceRow
            readonly property string link: root.onlineEntry ? WallpaperConfig.linkOf(root.onlineEntry.licenseUrl) : ""
            visible: !!(root.onlineEntry && root.onlineEntry.licenseShort)
            title: qsTr("Licence")
            valueText: licenceRow.link === "" && root.onlineEntry ? root.onlineEntry.licenseShort : ""

            LinkText {
                visible: licenceRow.link !== ""
                width: Math.min(implicitWidth, licenceRow.width - Tokens.settingsGroupLabelWidth - 3 * Tokens.spacingLg)
                text: root.onlineEntry ? root.onlineEntry.licenseShort : ""
                target: licenceRow.link
                onActivated: root.openLink(licenceRow.link)
            }
        }

        SettingsRow {
            visible: !!root.onlineEntry && root.formatUpdated(root.onlineEntry.fetchedAt) !== ""
            title: qsTr("Last updated")
            valueText: root.onlineEntry ? root.formatUpdated(root.onlineEntry.fetchedAt) : ""
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
        footnote: addedGroup.items.length === 0 ? qsTr("Add a folder to change the picture at an interval, or a single picture.") : ""

        // One tile per recent source: a picture shows its thumbnail, a folder reads "Shuffle <name>" (macOS wording).
        readonly property var items: root.recents.filter(e => e.kind !== "video")

        onItemsChanged: {
            for (const e of items) {
                if (e.kind === "file" || e.kind === "video")
                    root.requestThumb(e.path);
            }
        }

        Item {
            visible: addedGroup.items.length > 0
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

    // ---- videos (ADR-0016 W7): a video is prepared once by the shell, then plays under the pause policy ----
    SettingsGroup {
        id: videosGroup
        caption: qsTr("Videos")
        footnote: videosGroup.items.length === 0 ? qsTr("Add a video to play it as the wallpaper. It is prepared once, and pauses on battery, when you are away and under a full-screen window.") : ""

        readonly property var items: root.recents.filter(e => e.kind === "video")

        onItemsChanged: {
            for (const e of items)
                root.requestThumb(e.path);
        }

        Item {
            visible: videosGroup.items.length > 0
            width: parent.width
            height: visible ? videoGrid.height + 2 * Tokens.spacingMd : 0

            WallpaperGrid {
                id: videoGrid
                x: Tokens.spacingMd
                y: Tokens.spacingMd
                width: parent.width - 2 * Tokens.spacingMd
                accessibleName: qsTr("Videos")
                model: videosGroup.items.map(e => ({kind: "video", label: root.baseName(e.path), thumb: root.thumbs[e.path] || "", selected: root.source === "video" && root.path === e.path}))
                onActivated: index => root.useVideo(videosGroup.items[index].path)
            }
        }

        Item {
            width: parent.width
            height: addVideoButton.height + 2 * Tokens.spacingMd

            Button {
                id: addVideoButton
                anchors.right: parent.right
                anchors.rightMargin: Tokens.spacingMd
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("Add Video…")
                onClicked: videoDialog.open()
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
        id: videoDialog
        title: qsTr("Choose a video")
        nameFilters: [qsTr("Videos (%1)").arg(WallpaperConfig.VIDEO_SUFFIXES.map(s => "*." + s).join(" "))]
        onAccepted: {
            const p = root.urlToPath(selectedFile);
            if (p !== "")
                root.useVideo(p);
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
