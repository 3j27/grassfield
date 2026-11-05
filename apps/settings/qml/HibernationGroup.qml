pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "Setups.js" as Setups

// Hibernation (ADR-0045 OC-9), shared by Battery and Energy (a desktop hibernates too): shown where the kernel can hibernate
// (/sys/power/image_size) and Omarchy's setup is there; on when Omarchy's omarchy-hibernation-available says so. Set Up… and
// Remove… run Omarchy's commands in its terminal behind a sheet that says why (a swap file, the start-up settings, the
// start-up files rebuilt; the page's setupRequested, Main.qml's TerminalSetupSheet). macOS has no Hibernate item in its
// menu, nor does Grassfield: the session hibernates when Omarchy's power settings say so. The state is read when the pane
// starts and again when Settings is active again (the terminal closed).
SettingsGroup {
    id: root

    required property var backend

    signal setupRequested(string id)

    // Setups.hibernationState: "unsupported" (the group is hidden), "off", "on" or "incomplete".
    property string status: "unsupported"
    property bool setUp: false

    function read(): void {
        const supported = root.backend.readText(Setups.FILES.imageSize).exists === true;
        const installed = root.backend.hasCommand("omarchy-hibernation-setup");
        const conf = root.backend.readText(Setups.FILES.resumeConf).text;
        root.status = Setups.hibernationState(supported, installed, conf, root.setUp);
        if (supported && root.backend.hasCommand("omarchy-hibernation-available"))
            root.backend.readOnlyQuery(Setups.QUERY.hibernation, "power.hibernation");
    }

    visible: root.status !== "unsupported"

    Connections {
        target: root.backend

        function onFinished(tag: string, ok: bool, output: string): void {
            if (tag !== "power.hibernation")
                return;
            root.setUp = ok;
            root.status = Setups.hibernationState(root.backend.readText(Setups.FILES.imageSize).exists === true,
                root.backend.hasCommand("omarchy-hibernation-setup"), root.backend.readText(Setups.FILES.resumeConf).text, ok);
        }
    }

    // The terminal closed: Settings is active again.
    ActiveAgain {
        onReturned: root.read()
    }

    Component.onCompleted: root.read()

    SettingsRow {
        title: qsTr("Hibernation")
        subtitle: root.status === "on" ? qsTr("On. When the computer hibernates, the session is saved to the start-up disk and the computer turns off.")
            : root.status === "incomplete" ? qsTr("Set up, but not available: the swap file is missing or smaller than the memory. Set it up again or remove it.")
            : qsTr("Off. Hibernation saves the session to the start-up disk and turns the computer off; it needs a swap file as large as the memory.")

        Button {
            push: true
            text: root.status === "off" ? qsTr("Set Up…") : qsTr("Remove…")
            Accessible.name: root.status === "off" ? qsTr("Set up hibernation") : qsTr("Remove hibernation")
            onClicked: root.setupRequested(root.status === "off" ? "hibernation-setup" : "hibernation-remove")
        }
    }
}
