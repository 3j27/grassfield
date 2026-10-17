pragma Singleton
import QtQuick
import Quickshell

// Mirrors the shape of shell/security/lock/Lock.qml: a non-reloadable child first, the persisted
// lock intent, then the object whose reload decides whether the previous lock is kept (there a
// WlSessionLock, here a PersistentProperties whose `loaded` signal fires inside its own reload).
Singleton {
    id: root

    property var events: []
    // Values of the stand-in `locked` bindings at the moment the WlSessionLock stand-in reloaded.
    property bool seenEarly: false
    property bool seenLate: false

    readonly property alias earlyIntent: early.intent
    readonly property alias lateIntent: late.intent

    function log(event: string): void {
        events = events.concat([event]);
    }

    function setIntents(value: bool): void {
        early.intent = value;
        late.intent = value;
    }

    // Like LockController: not a Reloadable.
    QtObject {
        id: target

        // Like `WlSessionLock { locked: persist.intent }`.
        property bool locked: early.intent
        property bool lateLocked: late.intent
    }

    // Like Lock.qml's `persist`: declared before the WlSessionLock stand-in.
    PersistentProperties {
        id: early
        reloadableId: "early"

        property bool intent: false

        onLoaded: root.log("early-loaded:" + intent)
    }

    // Stand-in for WlSessionLock: WlSessionLock::onReload runs at this position.
    PersistentProperties {
        id: standIn
        reloadableId: "standIn"

        onLoaded: {
            root.seenEarly = target.locked;
            root.seenLate = target.lateLocked;
            root.log("standin-loaded:" + target.locked);
        }
    }

    // Negative control: declared after the stand-in, so restored too late for it.
    PersistentProperties {
        id: late
        reloadableId: "late"

        property bool intent: false
    }

    Component.onCompleted: log("completed")
}
