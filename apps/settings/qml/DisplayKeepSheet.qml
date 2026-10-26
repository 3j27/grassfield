import QtQuick
import Grassfield.Ui

// Displays: after a change, "Keep these display settings?" with the seconds left before the previous settings come back
// (macOS's 15). Keep and Revert go back to the page; the countdown is only shown here: the shell owns the real one (ADR-0027),
// so the previous settings come back even when this window is gone. Closes itself at zero.
Sheet {
    id: root

    // The trial's deadline in Unix seconds.
    property int until: 0
    property int secondsLeft: 0

    signal keep
    signal revert

    title: qsTr("Keep these display settings?")
    message: qsTr("The previous settings come back in %1 s.").arg(root.secondsLeft)
    confirmText: qsTr("Keep")
    cancelText: qsTr("Revert")

    function openFor(deadline: int): void {
        root.until = deadline;
        root.tick();
        countdown.start();
        root.open();
    }

    function tick(): void {
        root.secondsLeft = Math.max(0, root.until - Math.floor(Date.now() / 1000));
        if (root.secondsLeft === 0 && root.visible) {
            countdown.stop();
            root.close();
        }
    }

    onAccepted: {
        countdown.stop();
        root.keep();
    }
    onCanceled: {
        countdown.stop();
        root.revert();
    }

    Timer {
        id: countdown
        interval: Tokens.settingsDisplayTickMs
        repeat: true
        onTriggered: root.tick()
    }
}
