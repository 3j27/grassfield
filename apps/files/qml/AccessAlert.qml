pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "IconSource.js" as IconSource

// A permission alert of grassfield-portal (ADR-0035 D-5; docs/specs/system-dialogs.md section 2, AC1-AC3): the macOS 26 alert
// shape of the shell's alerts (shell/overlay/Dialog.qml, the same tokens): the application's icon in a 64-pt frame at the top
// left, the frontend's title in bold and its question and note left-aligned under it, then two capsule buttons of one width
// filling the row, "Don't Allow" and "Allow" (or the frontend's labels). A window of its own, centred on the screen, or over
// the application's window when the frontend names one.
// - Neither button is the default for the camera and screen capture (AC2): Return does nothing until a
//   button has the keyboard. Otherwise Return grants; Space acts only on a button the user reached with Tab (the keyboard
//   starts on the alert, never on a button: a space typed for another window never grants, ADR-0035 5a-5).
// - Esc, or the window closed by the compositor, is "Don't Allow".
// - Each time the alert becomes the active window, no click, key or close answers it for panelAlertArmMs, and a key pressed
//   meanwhile starts that time again (a click or a key meant for what was there before never answers it); an alert that gets
//   the keyboard late, the first time (it opened behind the lock, AC3, or under another window) or after a long time away
//   (the lock, the screen saver or another window came in front of it), takes keys only after a click in it, and that click
//   only ends the hold.
Window {
    id: alert

    // Access (apps/portal/src/access.h).
    required property var host
    // AccessAlerts.qml.
    required property var manager
    required property int requestId
    // Access::toQml, with appIcon.
    required property var request

    readonly property bool hasDefault: alert.request.noDefault !== true
    readonly property string denyText: alert.request.denyLabel ? String(alert.request.denyLabel) : qsTr("Don't Allow")
    readonly property string grantText: alert.request.grantLabel ? String(alert.request.grantLabel) : qsTr("Allow")
    // The choices' values by id.
    property var choiceValues: {
        const values = {};
        const choices = alert.request.choices || [];
        for (let i = 0; i < choices.length; i++)
            values[choices[i].id] = choices[i].initial;
        return values;
    }
    property bool answered: false
    // False until armMs after the alert became the active window (again), or after the last key pressed meanwhile: clicks,
    // keys and a close answer nothing yet.
    property bool armed: false
    property int armMs: Tokens.panelAlertArmMs
    property bool keysHeld: false
    property real shownAt: 0
    property bool everActive: false
    // When the alert last stopped being the active window.
    property real inactiveSince: 0
    property bool testAnswered: false
    readonly property real pad: Tokens.spacingLg
    readonly property real textInset: Tokens.panelAlertTextInset

    // ADR-0015: the alert draws its own frame; the compositor plugin draws no titlebar on it (config/hypr/grassfield/
    // windows.lua, gf-client-chrome-alert).
    property string gfChromeRole: "access-alert"

    title: String(alert.request.title)
    color: Appearance.colors.windowBackground
    modality: alert.request.modal && alert.request.parented ? Qt.WindowModal : Qt.NonModal
    // One size, the content's: the alert is not resized.
    readonly property real contentHeight: alert.pad + column.implicitHeight + Tokens.spacingLg + buttonRow.height + alert.pad
    width: Tokens.panelAlertWidth
    height: alert.contentHeight
    minimumWidth: Tokens.panelAlertWidth
    maximumWidth: Tokens.panelAlertWidth
    minimumHeight: alert.contentHeight
    maximumHeight: alert.contentHeight

    function answer(grant: bool): void {
        if (alert.answered)
            return;
        alert.answered = true;
        const choices = [];
        const given = alert.request.choices || [];
        for (let i = 0; i < given.length; i++)
            choices.push({
                id: given[i].id,
                value: alert.choiceValues[given[i].id]
            });
        alert.host.answer(alert.requestId, grant, choices);
    }

    // The keyboard at the start: the alert, none of its buttons (Return grants where Allow is the default; Tab reaches them).
    // The alert's own item, not the scope: a scope gives the keyboard back to the button it had.
    function focusStart(): void {
        home.forceActiveFocus();
    }

    onVisibleChanged: {
        if (alert.visible && alert.shownAt === 0)
            alert.shownAt = Date.now();
    }

    onActiveChanged: {
        if (alert.active)
            alert.becameActive();
        else
            alert.inactiveSince = Date.now();
    }

    function becameActive(): void {
        // A click or a key that made it the active window is not an answer, and the keyboard starts on the alert again (a
        // button that had it before would take a Space).
        alert.armed = false;
        arm.restart();
        // Away long enough (since it opened, or since it was last active) and keys wait for a click: a Return meant for the
        // lock or for another window does not answer it once it is back (integrator review of e24ea5c, MINOR 1).
        const away = Date.now() - (alert.everActive ? alert.inactiveSince : alert.shownAt);
        alert.everActive = true;
        if (away > Tokens.filesPanelLateFocusMs)
            alert.keysHeld = true;
        if (!alert.keysHeld)
            alert.focusStart();
    }

    // Closed by the compositor (no answer yet): "Don't Allow"; not yet armed, the close is refused (one meant for the window
    // before it).
    onClosing: close => {
        if (!alert.armed) {
            close.accepted = false;
            return;
        }
        alert.answer(false);
    }

    onFrameSwapped: {
        if (alert.manager.testAnswer === "" || alert.testAnswered)
            return;
        alert.testAnswered = true;
        Qt.callLater(() => alert.answer(alert.manager.testAnswer === "accept"));
    }

    Timer {
        id: arm
        interval: alert.armMs
        onTriggered: alert.armed = true
    }

    FocusScope {
        id: keys
        anchors.fill: parent
        focus: true
        Accessible.role: Accessible.Dialog
        Accessible.name: alert.title
        Accessible.description: [String(alert.request.subtitle), String(alert.request.body)].filter(t => t !== "").join(" ")

        // Not armed: any key starts the time again, so keys typed on for another window never arm it.
        function unarmedKey(): bool {
            if (alert.armed)
                return false;
            arm.restart();
            return true;
        }
        Keys.onEscapePressed: {
            if (!keys.unarmedKey())
                alert.answer(false);
        }
        Keys.onReturnPressed: {
            if (!keys.unarmedKey() && alert.hasDefault)
                alert.answer(true);
        }
        Keys.onEnterPressed: {
            if (!keys.unarmedKey() && alert.hasDefault)
                alert.answer(true);
        }
        Keys.onPressed: event => {
            if (keys.unarmedKey())
                event.accepted = true;
        }

        // Where the keyboard starts: it acts on nothing, so its keys go on to the alert's (above).
        Item {
            id: home
            focus: true
        }

        Column {
            id: column
            x: alert.textInset
            y: alert.pad
            width: alert.width - 2 * alert.textInset
            spacing: Tokens.spacingMd

            Item {
                width: Tokens.panelAlertIconFrame
                height: Tokens.panelAlertIconFrame

                Image {
                    anchors.centerIn: parent
                    width: Tokens.panelAlertIconGlyph
                    height: Tokens.panelAlertIconGlyph
                    sourceSize: Qt.size(2 * Tokens.panelAlertIconGlyph, 2 * Tokens.panelAlertIconGlyph)
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    // The application's icon; for an application the frontend could not name, the question's own symbol.
                    source: alert.request.appIcon ? IconSource.url(String(alert.request.appIcon)) : IconSource.url(alert.request.icon ? String(alert.request.icon) : "application-x-executable")
                }
            }

            Text {
                width: parent.width
                textFormat: Text.PlainText
                text: String(alert.request.title)
                visible: text !== ""
                color: Appearance.colors.text
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
                font.weight: Tokens.typographyMenuBoldWeight
                wrapMode: Text.WordWrap
            }

            Text {
                width: parent.width
                textFormat: Text.PlainText
                text: String(alert.request.subtitle)
                visible: text !== ""
                color: Appearance.colors.text
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyBodySize
                font.weight: Tokens.typographySmallWeight
                wrapMode: Text.WordWrap
            }

            Text {
                width: parent.width
                textFormat: Text.PlainText
                text: String(alert.request.body)
                visible: text !== ""
                color: Appearance.colors.textSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
                wrapMode: Text.WordWrap
            }

            // The frontend's choices: a pop-up with its label, or a check box.
            Repeater {
                model: alert.request.choices || []

                Column {
                    id: choice
                    required property var modelData
                    width: column.width
                    spacing: Tokens.spacingXs

                    Text {
                        visible: choice.modelData.options.length > 0
                        width: parent.width
                        textFormat: Text.PlainText
                        text: choice.modelData.label
                        color: Appearance.colors.text
                        font.family: Appearance.fontFamily
                        font.pixelSize: Tokens.typographyBodySize
                        wrapMode: Text.WordWrap
                    }

                    ComboBox {
                        visible: choice.modelData.options.length > 0
                        width: parent.width
                        accessibleName: choice.modelData.label
                        model: choice.modelData.options.map(o => ({
                                    id: o.id,
                                    text: o.label
                                }))
                        value: alert.choiceValues[choice.modelData.id] ?? ""
                        onPicked: id => {
                            const next = Object.assign({}, alert.choiceValues);
                            next[choice.modelData.id] = id;
                            alert.choiceValues = next;
                        }
                    }

                    CheckBox {
                        visible: choice.modelData.options.length === 0
                        width: parent.width
                        text: choice.modelData.label
                        checked: alert.choiceValues[choice.modelData.id] === "true"
                        onToggled: {
                            const next = Object.assign({}, alert.choiceValues);
                            next[choice.modelData.id] = checked ? "true" : "false";
                            alert.choiceValues = next;
                        }
                    }
                }
            }

            Text {
                visible: alert.keysHeld
                width: parent.width
                textFormat: Text.PlainText
                text: qsTr("Click the alert before you answer it.")
                color: Appearance.colors.textSecondary
                font.family: Appearance.fontFamily
                font.pixelSize: Tokens.typographyCaptionSize
                wrapMode: Text.WordWrap
            }
        }

        // Two capsules of one width filling the row (the shell's alert), never narrower than the wider label.
        Row {
            id: buttonRow
            x: alert.pad
            y: alert.pad + column.implicitHeight + Tokens.spacingLg
            spacing: Tokens.controlAlertButtonGap
            readonly property real fill: (alert.width - 2 * alert.pad - spacing) / 2
            readonly property real wanted: Math.max(fill, denyButton.implicitWidth, grantButton.implicitWidth)
            height: grantButton.implicitHeight

            Button {
                id: denyButton
                capsule: true
                width: buttonRow.wanted
                text: alert.denyText
                onClicked: {
                    if (alert.armed)
                        alert.answer(false);
                    else
                        arm.restart();
                }
            }

            Button {
                id: grantButton
                capsule: true
                primary: alert.hasDefault
                width: buttonRow.wanted
                text: alert.grantText
                onClicked: {
                    if (alert.armed)
                        alert.answer(true);
                    else
                        arm.restart();
                }
            }
        }
    }

    // Clicks wait until the alert is armed; while the keys are held, this takes them, and the first press in the alert ends the
    // hold, and only that (review of step 5a, M1: it once went on to the button under it).
    Item {
        id: guard
        anchors.fill: parent
        z: 10
        visible: !alert.armed || alert.keysHeld
        focus: alert.keysHeld
        Keys.onPressed: event => {
            event.accepted = true;
        }

        // Taken, never passed on: a click that ends the hold or comes before the alert is armed is not an answer.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onPressed: {
                if (!alert.armed)
                    return;
                alert.keysHeld = false;
                alert.focusStart();
            }
        }
    }
}
