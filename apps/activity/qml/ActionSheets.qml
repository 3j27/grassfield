pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Quit, Force Quit and Send Signal (spec AM50 to AM56; ADR-0038 e): the sheets over the window. The backend fixes the
// sheet's processes when it opens (AM51) and acts on them alone. A session process first gets the warning sheet (AM54);
// Quit that cannot be done safely leaves Force Quit only (AM52); the app's own row refuses Force Quit and every signal.
// Declare it over the window's content; it fills it.
Item {
    id: root

    required property var actions
    // AM68: the backend's Efficiency Mode and its "Don't ask again".
    property var backend: null
    property Item focusBack: null
    // prepare()'s answer for the open sheet.
    property var info: ({})
    // AM52: Quit could not be done safely; the quit sheet's one action is Force Quit.
    property bool forceOnly: false
    // The signal chosen in the pop-up (Terminate by default).
    property string signalChoice: "15"
    // AM52: Quit waits for the shell to close the process's windows (at most a second): the sheet takes no click or key.
    property bool waiting: false
    // The tests read them.
    readonly property alias quitSheet: quitSheetItem
    readonly property alias sessionSheet: sessionSheetItem
    readonly property alias signalSheet: signalSheetItem
    readonly property alias signalPicker: signalPicker
    readonly property alias efficiencySheet: efficiencySheetItem
    readonly property alias efficiencyError: efficiencyErrorItem
    readonly property bool shown: quitSheetItem.shown || sessionSheetItem.shown || signalSheetItem.shown || efficiencySheetItem.shown || efficiencyErrorItem.shown

    anchors.fill: parent

    // The Stop button, View > Quit Process and the context menu (AM50).
    function openQuit(): void {
        root.open("quit");
    }

    // View > Send Signal to Process… and the action menu (AM55).
    function openSignal(): void {
        root.open("signal");
    }

    // AM68: the first time Efficiency Mode is turned on.
    function openEfficiency(): void {
        if (root.shown || !root.backend)
            return;
        dontAsk.checked = false;
        efficiencySheetItem.open();
    }

    function open(action: string): void {
        if (root.shown || !(action === "signal" ? root.actions.canSignal : root.actions.canQuit))
            return;
        const info = root.actions.prepare(action);
        if (!info.ok)
            return; // AM51: every selected process ended or changed meanwhile
        root.info = info;
        root.forceOnly = false;
        if (info.session !== "") {
            sessionSheetItem.action = action;
            sessionSheetItem.open();
        } else {
            root.show(action);
        }
    }

    function show(action: string): void {
        if (action === "signal") {
            const choices = root.info.signals || [];
            root.signalChoice = choices.some(c => c.number === 15) ? "15" : choices.length > 0 ? String(choices[0].number) : "";
            signalSheetItem.open();
            if (root.info.self)
                signalSheetItem.errorText = qsTr("This app can't send a signal to itself.");
        } else {
            quitSheetItem.open();
        }
    }

    function release(): void {
        root.actions.release();
        root.info = ({});
        root.forceOnly = false;
    }

    // Quit's answer: false while the shell closes windows (quitFinished follows), else as outcome().
    function answerQuit(result: var): var {
        if (result.pending) {
            root.waiting = true;
            return false;
        }
        return root.outcome(result);
    }

    // An answer of the backend: "" when it was done (the sheet closes), else the sheet's message.
    function outcome(result: var): string {
        if (result.done) {
            root.release();
            return "";
        }
        if (result.unsafe)
            root.forceOnly = true;
        return result.error || "";
    }

    // AM54: before acting on a session process.
    Sheet {
        id: sessionSheetItem
        objectName: "sessionSheet"
        property string action: "quit"
        title: sessionSheetItem.action === "signal"
            ? qsTr("Sending a signal to “%1” may end your session or stop part of it.").arg(root.info.session || "")
            : qsTr("Quitting “%1” may end your session or stop part of it.").arg(root.info.session || "")
        confirmText: qsTr("Continue")
        destructive: true
        returnCancels: true
        focusBack: root.focusBack
        onAccepted: root.show(sessionSheetItem.action)
        onCanceled: root.release()
    }

    Sheet {
        id: quitSheetItem
        objectName: "quitSheet"
        title: (root.info.count || 1) === 1 ? qsTr("Are you sure you want to quit this process?")
            : qsTr("Are you sure you want to quit these %1 processes?").arg(root.info.count) // two or more: plural in English and French
        message: (root.info.count || 1) === 1 ? qsTr("“%1” (PID %2)").arg(root.info.name || "").arg(root.info.pid || 0) : ""
        // AM50: Cancel, Force Quit and Quit (the default); AM52: Force Quit alone once Quit could not be done safely, and
        // then Return does not force it.
        extraButtons: root.forceOnly ? [] : [{id: "force", text: qsTr("Force Quit")}]
        confirmText: root.forceOnly ? qsTr("Force Quit") : qsTr("Quit")
        destructive: root.forceOnly
        returnCancels: root.forceOnly
        focusBack: root.focusBack
        holdInput: root.waiting
        confirmEnabled: !root.waiting
        confirmHandler: () => root.answerQuit(root.forceOnly ? root.actions.forceQuit() : root.actions.quit())
        onExtra: id => {
            const error = root.outcome(root.actions.forceQuit());
            if (error === "")
                quitSheetItem.close();
            else
                quitSheetItem.errorText = error;
        }
        onCanceled: root.release()
    }

    Connections {
        target: root.actions

        function onQuitFinished(result: var): void {
            root.waiting = false;
            const error = root.outcome(result);
            if (error === "")
                quitSheetItem.close();
            else
                quitSheetItem.errorText = error;
        }
    }

    // AM68: what Efficiency Mode does, before the first time; "Don't ask again" is remembered (AM74).
    Sheet {
        id: efficiencySheetItem
        objectName: "efficiencySheet"
        title: qsTr("Turn on Efficiency Mode for “%1”?").arg(root.backend ? root.backend.efficiency.appName : "")
        message: qsTr("The whole app runs at the lowest priority whenever the computer is busy, so other apps stay responsive. It may run more slowly until you turn Efficiency Mode off or quit it.")
        confirmText: qsTr("Turn On")
        focusBack: root.focusBack
        confirmHandler: () => {
            if (dontAsk.checked)
                root.backend.askEfficiency = false;
            root.backend.efficiency.set(true);
            return "";
        }

        CheckBox {
            id: dontAsk
            objectName: "dontAskEfficiency"
            text: qsTr("Don't ask again")
        }
    }

    // AM68: the user manager refused the weight (or the process ended, or is not an app's any more).
    Sheet {
        id: efficiencyErrorItem
        objectName: "efficiencyError"
        showCancel: false
        focusBack: root.focusBack
    }

    Connections {
        target: root.backend ? root.backend.efficiency : null

        // An answer can come from inside Turn On's handler, before its sheet has closed: shown once the sheets settle.
        function onFinished(error: string): void {
            if (error === "")
                return;
            Qt.callLater(() => {
                if (root.shown)
                    return;
                efficiencyErrorItem.title = error;
                efficiencyErrorItem.open();
            });
        }
    }

    // AM55: one process, a signal from the pop-up.
    Sheet {
        id: signalSheetItem
        objectName: "signalSheet"
        title: qsTr("Choose a signal to send to “%1” (PID %2).").arg(root.info.name || "").arg(root.info.pid || 0)
        confirmText: qsTr("Send")
        confirmEnabled: !root.info.self
        focusBack: root.focusBack
        confirmHandler: () => root.outcome(root.actions.send(Number(root.signalChoice)))
        onCanceled: root.release()

        ComboBox {
            id: signalPicker
            objectName: "signalPicker"
            accessibleName: qsTr("Signal")
            model: (root.info.signals || []).map(c => ({id: String(c.number), text: c.title}))
            value: root.signalChoice
            onPicked: id => root.signalChoice = id
        }
    }
}
