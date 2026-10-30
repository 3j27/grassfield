pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// grassfield-portal's Open and Save panels (ADR-0035 D-4; docs/specs/system-dialogs.md section 1): one FilePanel for each
// OpenFile, SaveFile or SaveFiles of xdg-desktop-portal, and for each ChooseApplication (D-5, step 5b: Choose Application is an
// Open panel in the Applications location). Loaded by apps/portal/src/main.cpp at the first request of either, with Files'
// backend (`app`, a FilesApp) and the portal's (`host`, FileChooser; `appHost`, AppChooser): a panel is the Files browser,
// its views, sidebar, Glance and KIO sheets.
QtObject {
    id: root

    required property var app
    required property var host
    // AppChooser (apps/portal/src/appchooser.h): its panels are kept in `panels` under "app:<id>" (its request ids are its own).
    property var appHost: null
    // Dev plumbing (GRASSFIELD_PORTAL_TEST_ANSWER, dev sessions only): "accept" or "cancel" answers each panel once it has
    // drawn (the integration test drives the real process this way).
    property string testAnswer: ""

    property FilesAppearance appearance: FilesAppearance {
        app: root.app
    }

    // Open panels by request id (key()).
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
            root.open(id, request, false);
        }
        function onClosed(id: int): void {
            root.dismiss(id, false);
        }
    }

    property Connections appRequests: Connections {
        target: root.appHost
        function onOpened(id: int, request: var): void {
            root.open(id, request, true);
        }
        function onClosed(id: int): void {
            root.dismiss(id, true);
        }
        // UpdateChoices: the frontend's new candidates for the document.
        function onApplicationsChanged(id: int, applications: var): void {
            const panel = root.panels[root.key(id, true)];
            if (panel)
                panel.recommended = applications;
        }
    }

    property Connections promptPlacement: Connections {
        target: root.app.prompts ?? null
        function onCurrentChanged(): void {
            root.placePrompt();
        }
    }

    // The panel for request `id` of FileChooser, or of AppChooser (`application`).
    function open(id: int, request: var, application: bool): void {
        const owner = application ? root.appHost : root.host;
        const panel = root.panelComponent.createObject(root, {
            app: root.app,
            host: root.host,
            appHost: root.appHost,
            manager: root,
            requestId: id,
            request: request,
            memory: application ? {} : root.host.memory(request.appId),
            places: request.places || {}
        });
        if (!panel) {
            console.warn("grassfield-portal: cannot make a panel:", root.panelComponent.errorString());
            owner.fail(id);
            return;
        }
        const next = Object.assign({}, root.panels);
        next[root.key(id, application)] = panel;
        root.panels = next;
        owner.present(id, panel);
    }

    function key(id: int, application: bool): string {
        return application ? "app:" + id : String(id);
    }

    // The request ended (answered, closed by the application, or sent to x-d-p-gtk): its panel goes.
    function dismiss(id: int, application: bool): void {
        const panel = root.panels[root.key(id, application)];
        if (!panel)
            return;
        const next = Object.assign({}, root.panels);
        delete next[root.key(id, application)];
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
