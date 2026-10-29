pragma ComponentBehavior: Bound
import QtQuick

// grassfield-portal's permission alerts (ADR-0035 D-5; docs/specs/system-dialogs.md section 2, AC1-AC3): one AccessAlert for
// each AccessDialog of xdg-desktop-portal, one at a time as macOS shows them: the others wait in the order they came, with no
// deadline (Access::queue), and the next shows when the one on screen goes (integrator nested pass of 1745c0c, MINOR 5: two
// opened at the same spot, the second hiding the first). Loaded by apps/portal/src/main.cpp at the first request, next to
// FilePanels.qml (one engine), with the portal's Access (`host`).
QtObject {
    id: root

    // Access (apps/portal/src/access.h).
    required property var host
    // Dev plumbing (GRASSFIELD_PORTAL_TEST_ANSWER, dev sessions only): "accept" grants, "cancel" denies, each alert once it has
    // drawn (the integration test drives the real process this way).
    property string testAnswer: ""

    // The alert on screen, by request id (one at most), and the requests waiting for it to go: [{id, request}].
    property var alerts: ({})
    property var waiting: []

    property Component alertComponent: Component {
        AccessAlert {}
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

    function open(id: int, request: var): void {
        if (Object.keys(root.alerts).length > 0) {
            root.waiting = root.waiting.concat([{
                    id: id,
                    request: request
                }]);
            root.host.queue(id);
            return;
        }
        root.show(id, request);
    }

    function show(id: int, request: var): void {
        const alert = root.alertComponent.createObject(root, {
            host: root.host,
            manager: root,
            requestId: id,
            request: request
        });
        if (!alert) {
            console.warn("grassfield-portal: cannot make an alert:", root.alertComponent.errorString());
            root.host.fail(id);
            root.showNext();
            return;
        }
        const next = Object.assign({}, root.alerts);
        next[id] = alert;
        root.alerts = next;
        root.host.present(id, alert);
    }

    // The request ended (answered, closed by the application, or sent to x-d-p-gtk): its alert goes, and the next one shows; a
    // request that was waiting just leaves the line.
    function dismiss(id: int): void {
        if (root.waiting.some(w => w.id === id)) {
            root.waiting = root.waiting.filter(w => w.id !== id);
            return;
        }
        const alert = root.alerts[id];
        if (!alert)
            return;
        const next = Object.assign({}, root.alerts);
        delete next[id];
        root.alerts = next;
        alert.visible = false;
        alert.destroy();
        root.showNext();
    }

    function showNext(): void {
        if (Object.keys(root.alerts).length > 0 || root.waiting.length === 0)
            return;
        const first = root.waiting[0];
        root.waiting = root.waiting.slice(1);
        root.show(first.id, first.request);
    }
}
