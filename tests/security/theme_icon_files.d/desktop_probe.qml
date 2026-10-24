pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.desktop
import qs.launchpad
import qs.overlay
import qs.services
import "security/LockMachine.js" as Machine
import "widgets/ArtUrl.js" as ArtUrl

// Probe of tests/security/theme_icon_files.sh, part 3 (reviews of eee45cc and 100692f): icons named by applications
// and files, one real surface per class, with FIFOs where their files should be:
//  - Launchpad cells (AppsCell) and the Apps prewarm list, for four entries in a scratch applications directory: a FIFO
//    Icon= path, an Icon= theme name whose file is a FIFO, a regular path, a regular name;
//  - desktop icons (DesktopIcon) for launchers in a scratch Desktop folder with the same two FIFO Icon= values, and a
//    picture file that is a FIFO (its thumbnail);
//  - the About panel (AppAboutPanel: the class of surfaces that look an application up by id, with the Overview and
//    Force Quit) for both FIFO applications;
//  - review of 423766f: a flatpak user export (a symlink into the user's flatpak tree) is shown as a copy; a user icon
//    that is a symlink to an image outside the allowed roots is refused; media art (the player's file: URL through
//    ThemeIcons.artSource, as both Now Playing views show Media.artShown) naming a FIFO is refused and naming an SVG that
//    references a FIFO becomes a PNG; the lock screen's account picture
//    (LockMachine.avatarSource over ThemeIcons, as Lock.qml binds it) likewise.
// Then a control icon is loaded: its Image only becomes Ready when the one image loader never stalled, and the probe
// exits only when the GUI thread never blocked. Prints "probe:" lines and "probe: done", then exits.
ShellRoot {
    id: root

    readonly property string desktop: Quickshell.env("PROBE_DESKTOP")
    readonly property var ids: ["gf-fifo-path", "gf-fifo-name", "gf-ok-path", "gf-ok-name", "gf-flatpak", "gf-outside"]
    readonly property string artFifo: ArtUrl.localPath("file://" + Quickshell.env("PROBE_ART_FIFO"))
    readonly property string artSvg: ArtUrl.localPath("file://" + Quickshell.env("PROBE_ART_SVG"))
    readonly property string artSvgUrl: "file://" + Quickshell.env("PROBE_ART_SVG")
    readonly property string faceSvg: Quickshell.env("PROBE_FACE_SVG")
    readonly property string faceFifo: Quickshell.env("PROBE_FACE_FIFO")

    function avatar(face: string): string {
        return Machine.avatarSource(face, "", path => ThemeIcons.fileSource(path), path => ThemeIcons.fileState(path));
    }

    function cls(source: string): string {
        return source === "" ? "" : (source.indexOf("/grassfield-icons-") > 0 && source.endsWith(".png") ? "copy" : source);
    }
    property var entries: ({})
    property int waited: 0
    property string phase: "entries"

    function entryFor(id: string): var {
        for (const e of DesktopEntries.applications.values) {
            if (e.id === id || e.id === id + ".desktop")
                return e;
        }
        return null;
    }

    // ThemeIcons' copy key of an Icon= value (none of these names exists in the system theme).
    function keyOf(icon: string): string {
        return icon.startsWith("/") ? "icon:" + icon : "name:" + icon;
    }

    function stateOf(key: string): string {
        const e = ThemeIcons.copies[key];
        return e === undefined ? "" : e.state;
    }

    function settled(keys: var): bool {
        return keys.every(k => stateOf(k) === "ok" || stateOf(k) === "no");
    }

    function prewarmed(id: string): bool {
        return Apps.listedIconSources.indexOf(ThemeIcons.appIcon(entries[id].icon, "application-x-executable")) >= 0;
    }

    // The Apps singleton (prewarm list) starts now, as in the shell (the menu bar hosts the prewarm).
    Component.onCompleted: console.info("desktop probe: apps revision " + Apps.revision)

    Component {
        id: cellComponent
        AppsCell {}
    }

    Component {
        id: desktopIconComponent
        DesktopIcon {}
    }

    Component {
        id: aboutComponent
        AppAboutPanel {}
    }

    FloatingWindow {
        id: win
        visible: true
        implicitWidth: 900
        implicitHeight: 400

        Row {
            id: row
        }

        Row {
            id: desktopRow
            y: 130
        }

        Item {
            id: aboutHost
            y: 230
            width: 400
            height: 160
        }

        Row {
            id: pictures
            y: 200
            x: 500

            Image {
                id: artFifoImage
                width: 16
                height: 16
                asynchronous: true
                source: ThemeIcons.artSource("file://" + root.artFifo)
            }

            Image {
                id: artSvgImage
                width: 16
                height: 16
                asynchronous: true
                source: ThemeIcons.artSource(root.artSvgUrl)
            }

            Image {
                id: faceSvgImage
                width: 16
                height: 16
                asynchronous: true
                source: root.avatar(root.faceSvg)
            }

            Image {
                id: faceFifoImage
                width: 16
                height: 16
                asynchronous: true
                source: root.avatar(root.faceFifo)
            }
        }

        Image {
            id: control
            x: 860
            y: 360
            width: 32
            height: 32
            asynchronous: true
            sourceSize: Qt.size(64, 64)
        }
    }

    Timer {
        id: poll
        interval: 100
        repeat: true
        running: true
        onTriggered: {
            root.waited += interval;
            if (root.phase === "entries") {
                const found = {};
                for (const id of root.ids) {
                    const e = root.entryFor(id);
                    if (e)
                        found[id] = e;
                }
                if (Object.keys(found).length < root.ids.length && root.waited < 10000)
                    return;
                root.entries = found;
                if (Object.keys(found).length < root.ids.length) {
                    console.log("probe: entries missing: " + root.ids.filter(id => !found[id]).join(","));
                    Qt.exit(1);
                    return;
                }
                for (const id of root.ids)
                    cellComponent.createObject(row, {info: {key: id, id: id, name: id, rec: {icon: found[id].icon}}});
                for (const name of ["gf-fifo-path.desktop", "gf-fifo-name.desktop", "photo.png"])
                    desktopIconComponent.createObject(desktopRow, {name: name, isDir: false, filePath: root.desktop + "/" + name});
                Popups.open("appabout", "", 0, 0, "center", {appId: "gf-fifo-path"});
                aboutComponent.createObject(aboutHost, {});
                root.phase = "verdicts";
                root.waited = 0;
            } else if (root.phase === "verdicts") {
                // The surfaces' bindings asked; wait for every verdict, then a second for any stalled read to begin.
                const keys = root.ids.map(id => root.keyOf(root.entries[id].icon)).concat(["picture:" + root.desktop + "/photo.png"])
                    .concat([root.artFifo, root.artSvg, root.faceSvg, root.faceFifo].map(p => "picture:" + p));
                const ready = root.settled(keys) && root.prewarmed("gf-ok-path") && root.prewarmed("gf-ok-name");
                if ((!ready || root.waited < 1000) && root.waited < 15000)
                    return;
                for (const id of root.ids) {
                    const icon = root.entries[id].icon;
                    const src = ThemeIcons.appIcon(icon, "");
                    console.log("probe: " + id + " verdict=" + root.stateOf(root.keyOf(icon)) + " source=" + (src.indexOf("/grassfield-icons-") > 0 ? "copy" : src)
                        + " prewarmed=" + root.prewarmed(id));
                }
                console.log("probe: thumbnail verdict=" + root.stateOf("picture:" + root.desktop + "/photo.png") + " source=" + ThemeIcons.fileSource(root.desktop + "/photo.png"));
                console.log("probe: art-fifo verdict=" + root.stateOf("picture:" + root.artFifo) + " source=" + root.cls(artFifoImage.source.toString()));
                console.log("probe: art-svgref verdict=" + root.stateOf("picture:" + root.artSvg) + " source=" + root.cls(artSvgImage.source.toString()));
                console.log("probe: face-svgref verdict=" + root.stateOf("picture:" + root.faceSvg) + " source=" + root.cls(faceSvgImage.source.toString()));
                console.log("probe: face-fifo verdict=" + root.stateOf("picture:" + root.faceFifo) + " source=" + root.cls(faceFifoImage.source.toString()));
                // The About panel shows the second FIFO application too.
                Popups.open("appabout", "", 0, 0, "center", {appId: "gf-fifo-name"});
                root.phase = "about";
                root.waited = 0;
            } else if (root.phase === "about") {
                if (root.waited < 1000)
                    return;
                ThemeIcons.source("ctl");
                root.phase = "control";
                root.waited = 0;
            } else if (root.phase === "control") {
                const c = ThemeIcons.source("ctl");
                if (c === "" && root.waited < 10000)
                    return;
                control.source = c;
                root.phase = "loaded";
                root.waited = 0;
            } else if (root.phase === "loaded") {
                if (control.status !== Image.Ready && root.waited < 5000)
                    return;
                stop();
                console.log("probe: pictures loaded art-svgref=" + artSvgImage.status + " face-svgref=" + faceSvgImage.status);
                console.log("probe: done ctl=" + control.status);
                Qt.exit(0);
            }
        }
    }
}
