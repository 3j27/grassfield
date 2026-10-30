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
    property Item focusBack: null
    // prepare()'s answer for the open sheet.
    property var info: ({})
    // AM52: Quit could not be done safely; the quit sheet's one action is Force Quit.
    property bool forceOnly: false
    // The signal chosen in the pop-up (Terminate by default).
    property string signalChoice: "15"
    // The tests read them.
    readonly property alias quitSheet: quitSheet
    readonly property alias sessionSheet: sessionSheet
    readonly property alias signalSheet: signalSheet
    readonly property alias signalPicker: signalPicker
    readonly property bool shown: quitSheet.shown || sessionSheet.shown || signalSheet.shown

    anchors.fill: parent

    // The Stop button, View > Quit Process and the context menu (AM50).
    function openQuit(): void {
        root.open("quit");
    }

    // View > Send Signal to Process… and the action menu (AM55).
    function openSignal(): void {
        root.open("signal");
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
            sessionSheet.action = action;
            sessionSheet.open();
        } else {
            root.show(action);
        }
    }

    function show(action: string): void {
        if (action === "signal") {
            const choices = root.info.signals || [];
            root.signalChoice = choices.some(c => c.number === 15) ? "15" : choices.length > 0 ? String(choices[0].number) : "";
            signalSheet.open();
            if (root.info.self)
                signalSheet.errorText = qsTr("This app can't force quit itself.");
        } else {
            quitSheet.open();
        }
    }

    function release(): void {
        root.actions.release();
        root.info = ({});
        root.forceOnly = false;
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
        id: sessionSheet
        objectName: "sessionSheet"
        property string action: "quit"
        title: sessionSheet.action === "signal"
            ? qsTr("Sending a signal to “%1” may end your session or stop part of it.").arg(root.info.session || "")
            : qsTr("Quitting “%1” may end your session or stop part of it.").arg(root.info.session || "")
        confirmText: qsTr("Continue")
        destructive: true
        returnCancels: true
        focusBack: root.focusBack
        onAccepted: root.show(sessionSheet.action)
        onCanceled: root.release()
    }

    Sheet {
        id: quitSheet
        objectName: "quitSheet"
        title: (root.info.count || 1) === 1 ? qsTr("Are you sure you want to quit this process?")
            : qsTr("Are you sure you want to quit these %n processes?", "", root.info.count)
        message: (root.info.count || 1) === 1 ? qsTr("“%1” (PID %2)").arg(root.info.name || "").arg(root.info.pid || 0) : ""
        // AM50: Cancel, Force Quit and Quit (the default); AM52: Force Quit alone once Quit could not be done safely, and
        // then Return does not force it.
        extraButtons: root.forceOnly ? [] : [{id: "force", text: qsTr("Force Quit")}]
        confirmText: root.forceOnly ? qsTr("Force Quit") : qsTr("Quit")
        destructive: root.forceOnly
        returnCancels: root.forceOnly
        focusBack: root.focusBack
        confirmHandler: () => root.outcome(root.forceOnly ? root.actions.forceQuit() : root.actions.quit())
        onExtra: id => {
            const error = root.outcome(root.actions.forceQuit());
            if (error === "")
                quitSheet.close();
            else
                quitSheet.errorText = error;
        }
        onCanceled: root.release()
    }

    // AM55: one process, a signal from the pop-up.
    Sheet {
        id: signalSheet
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
