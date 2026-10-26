pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Grassfield Files: owns the browser windows (Ctrl+N opens another) and feeds the shared appearance.
// The app quits when its last window closes.
QtObject {
    id: root

    // Set by the launcher (src/main.cpp): a FilesApp.
    required property var app
    // The registrar is there (kept up to date by src/main.cpp): each window exports its menus to the global menu bar.
    required property bool globalMenu
    // --info: only the Get Info window of each location (the desktop's Get Info), no browser window.
    property bool infoOnly: false
    // --info requests still waiting for their listing, and Get Info windows opened: with none opened at the end the app
    // quits by itself (it has no window that could close).
    property int infoPending: 0
    property int infoShown: 0
    // The browser window that was active last (operation errors show there).
    property var lastActiveWindow: null

    property list<QtObject> resources: [
        Binding {
            target: Appearance
            property: "dark"
            value: root.app.dark
        },
        // App windows are opaque (master-prompt 5.5): menus drawn with the shared material too.
        Binding {
            target: Appearance
            property: "transparency"
            value: 0
        },
        // The window's own white background and secondary text (Appearance.windowSurface).
        Binding {
            target: Appearance
            property: "windowSurface"
            value: true
        },
        Binding {
            target: Appearance
            property: "reduceMotion"
            value: root.app.reduceMotion
        },
        // Accent colour (accent.color): live like the rest.
        Binding {
            target: Appearance
            property: "accentSetting"
            value: root.app.accentColor
        },
        // Icon appearance (ADR-0014): file and app icons follow the shell live.
        Binding {
            target: Appearance
            property: "iconMode"
            value: root.app.iconMode
        },
        Binding {
            target: Appearance
            property: "iconTintSetting"
            value: root.app.iconTint
        },
        Binding {
            target: Appearance
            property: "folderColorSetting"
            value: root.app.folderColor
        }
    ]

    property Component windowComponent: Component {
        BrowserWindow {}
    }

    function newWindow(url: url): void {
        const w = root.windowComponent.createObject(root, {app: root.app, manager: root, startUrl: url});
        if (!w)
            console.warn("grassfield-files: cannot create a window:", root.windowComponent.errorString());
    }

    property Component infoComponent: Component {
        InfoWindow {}
    }

    // The Get Info window of one location, with the info of its row in the parent folder's listing (the same object a
    // browser window shows); a location its parent does not list (a root) shows the folder's own info.
    property Component infoRequest: Component {
        QtObject {
            id: request

            required property url target
            readonly property url parentUrl: {
                const s = request.target.toString().replace(/\/+$/, "");
                const cut = s.lastIndexOf("/");
                return Qt.url(cut > "file://".length ? s.substring(0, cut) : s);
            }
            property var model: null
            property int waited: 0

            function show(info: var): void {
                if (info && info.name !== undefined && root.infoComponent.createObject(root, {app: root.app, info: info, browser: null})) {
                    root.infoShown++;
                    console.info("grassfield-files: Get Info of", request.target, "(" + info.name + ")");
                } else {
                    console.warn("grassfield-files: no info for", request.target);
                }
                root.infoPending--;
                if (root.infoPending === 0 && root.infoShown === 0)
                    Qt.quit();
                request.destroy();
            }

            property Timer poll: Timer {
                interval: 50
                repeat: true
                running: true
                onTriggered: {
                    if (!request.model) {
                        request.model = root.app.createFolderModel(request);
                        request.model.url = request.parentUrl;
                        return;
                    }
                    request.waited += interval;
                    if (request.model.loading && request.waited < 5000)
                        return;
                    stop();
                    const row = request.model.rowForUrl(request.target);
                    if (row >= 0) {
                        request.show(request.model.info(row));
                        return;
                    }
                    request.model.url = request.target;
                    request.waited = 0;
                    request.fallback.start();
                }
            }

            property Timer fallback: Timer {
                interval: 50
                repeat: true
                onTriggered: {
                    request.waited += interval;
                    if (request.model.loading && request.waited < 5000)
                        return;
                    stop();
                    request.show(request.model.info(-1));
                }
            }
        }
    }

    Component.onCompleted: {
        const urls = root.app.initialUrls;
        if (root.infoOnly) {
            root.infoPending = urls.length;
            for (let i = 0; i < urls.length; i++)
                root.infoRequest.createObject(root, {target: urls[i]});
            if (urls.length === 0)
                Qt.quit();
            return;
        }
        if (urls.length === 0)
            root.newWindow(Qt.url("file://" + root.app.homePath));
        for (let i = 0; i < urls.length; i++)
            root.newWindow(urls[i]);
    }
}
