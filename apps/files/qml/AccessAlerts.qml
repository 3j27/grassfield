pragma ComponentBehavior: Bound
import QtQuick

// grassfield-portal's permission alerts (ADR-0035 D-5; docs/specs/system-dialogs.md section 2, AC1-AC3): one AccessAlert for
// each AccessDialog of xdg-desktop-portal. Loaded by apps/portal/src/main.cpp at the first request, next to FilePanels.qml (one
// engine), with the portal's Access (`host`).
QtObject {
    id: root

    // Access (apps/portal/src/access.h).
    required property var host
    // Dev plumbing (GRASSFIELD_PORTAL_TEST_ANSWER, dev sessions only): "accept" grants, "cancel" denies, each alert once it has
    // drawn (the integration test drives the real process this way).
    property string testAnswer: ""

    // Open alerts by request id.
    property var alerts: ({})

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
        const alert = root.alertComponent.createObject(root, {
            host: root.host,
            manager: root,
            requestId: id,
            request: request
        });
        if (!alert) {
            console.warn("grassfield-portal: cannot make an alert:", root.alertComponent.errorString());
            root.host.fail(id);
            return;
        }
        const next = Object.assign({}, root.alerts);
        next[id] = alert;
        root.alerts = next;
        root.host.present(id, alert);
    }

    // The request ended (answered, closed by the application, or sent to x-d-p-gtk): its alert goes.
    function dismiss(id: int): void {
        const alert = root.alerts[id];
        if (!alert)
            return;
        const next = Object.assign({}, root.alerts);
        delete next[id];
        root.alerts = next;
        alert.visible = false;
        alert.destroy();
    }
}
