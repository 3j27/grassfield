import QtQuick
import Grassfield.Ui

// Lock Screen > Show message when locked > Set… (macOS: a sheet with a field for the message): one line of plain text, at
// most 200 characters (the settings contract refuses anything else, rule plainText). Done writes lock.message; Cancel and
// Esc change nothing.
Sheet {
    id: root

    required property var store

    title: qsTr("Set a message to show on the lock screen")
    withField: true
    placeholder: qsTr("Message")
    confirmText: qsTr("Done")
    confirmHandler: text => {
        const message = text.trim();
        if (SettingsContract.validate("lock.message", message) !== "")
            return qsTr("The message must be one line of at most 200 characters.");
        root.store.set("lock.message", message);
        return "";
    }

    // The sheet opens with the message as it is.
    onShownChanged: {
        if (shown)
            root.setField(root.store.value("lock.message"));
    }
}
