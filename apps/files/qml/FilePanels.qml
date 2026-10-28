pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// grassfield-portal's Open and Save panels (ADR-0035 D-4; docs/specs/system-dialogs.md section 1): one FilePanel for each
// OpenFile, SaveFile or SaveFiles of xdg-desktop-portal. Loaded by apps/portal/src/main.cpp at the first request, with Files'
// backend (`app`, a FilesApp) and the portal's (`host`, FileChooser): a panel is the Files browser, its views, sidebar,
// Glance and KIO sheets.
QtObject {
    id: root

    required property var app
    required property var host
    // Dev plumbing (GRASSFIELD_PORTAL_TEST_ANSWER, dev sessions only): "accept" or "cancel" answers each panel once it has
    // drawn (the integration test drives the real process this way).
    property string testAnswer: ""

    property FilesAppearance appearance: FilesAppearance {
        app: root.app
    }

    // Open panels by request id.
    property var panels: ({})
    // The panel the user last worked in: KIO's questions are asked there (Main.qml's rule).
    property var lastActiveWindow: null
    property var promptWindow: null
    property int promptId: -1
    // Tabs a spring-loaded folder moved during a drag (BrowserTab.springStarted), told when it ends.
    property var springTabs: []

    property Component panelComponent: Component {
        FilePanel {}
    }

    property Connections requests: Connections {
        target: root.host
        function onOpened(id: int, request: var): void {
            root.open(id, request);
        }
        function onClosed(id: int): void {
            root.dismiss(id);
        }
    }

    property Connections promptPlacement: Connections {
        target: root.app.prompts ?? null
        function onCurrentChanged(): void {
            root.placePrompt();
        }
    }

    function open(id: int, request: var): void {
        const panel = root.panelComponent.createObject(root, {
            app: root.app,
            host: root.host,
            manager: root,
            requestId: id,
            request: request,
            memory: root.host.memory(request.appId),
            places: root.host.places()
        });
        if (!panel) {
            console.warn("grassfield-portal: cannot make a panel:", root.panelComponent.errorString());
            root.host.fail(id);
            return;
        }
        const next = Object.assign({}, root.panels);
        next[id] = panel;
        root.panels = next;
        root.host.present(id, panel);
    }

    // The request ended (answered, closed by the application, or sent to x-d-p-gtk): its panel goes.
    function dismiss(id: int): void {
        const panel = root.panels[id];
        if (!panel)
            return;
        const next = Object.assign({}, root.panels);
        delete next[id];
        root.panels = next;
        if (root.lastActiveWindow === panel)
            root.lastActiveWindow = null;
        if (root.promptWindow === panel) {
            root.promptWindow = null;
            root.placePrompt();
        }
        panel.visible = false;
        panel.destroy();
    }

    function placePrompt(): void {
        const current = root.app.prompts ? root.app.prompts.current : null;
        const id = current && current.id !== undefined ? current.id : -1;
        if (id < 0) {
            root.promptId = -1;
            root.promptWindow = null;
            return;
        }
        if (id === root.promptId && root.promptWindow)
            return;
        root.promptId = id;
        const open = Object.keys(root.panels).map(k => root.panels[k]);
        root.promptWindow = root.lastActiveWindow ?? (open.length > 0 ? open[open.length - 1] : null);
        if (!root.promptWindow)
            root.app.prompts.reply(id, {
                button: "stop"
            });
    }

    function springStarted(tab: var): void {
        if (root.springTabs.indexOf(tab) < 0)
            root.springTabs = root.springTabs.concat([tab]);
    }

    function dragEnded(dropped: bool): void {
        const tabs = root.springTabs;
        root.springTabs = [];
        for (let i = 0; i < tabs.length; i++) {
            if (tabs[i] && tabs[i].springEnd)
                tabs[i].springEnd(dropped);
        }
    }
}
