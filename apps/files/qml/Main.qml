pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Grassfield Files: owns the browser windows (Ctrl+N opens another) and feeds the shared appearance.
// The app quits when its last window closes.
QtObject {
    id: root

    // Set by the launcher (src/main.cpp): a FilesApp.
    required property var app
    // The registrar is there: each window exports its menus to the global menu bar (GlobalMenu.qml).
    required property bool globalMenu
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
        Binding {
            target: Appearance
            property: "reduceMotion"
            value: root.app.reduceMotion
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

    Component.onCompleted: {
        const urls = root.app.initialUrls;
        if (urls.length === 0)
            root.newWindow(Qt.url("file://" + root.app.homePath));
        for (let i = 0; i < urls.length; i++)
            root.newWindow(urls[i]);
    }
}
