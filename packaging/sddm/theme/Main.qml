import QtQuick
import Grassfield.Ui
import "Strings.js" as Strings

// Grassfield's login theme for SDDM's own greeter (ADR-0042, ADR-0040 IQ-L1 C): the lock screen's layout on the default
// Grassfield artwork. A theme, not a greeter: SDDM authenticates (its own PAM service, `sddm.login`); this file only draws and
// hands the typed password to `sddm.login` once per Return, clearing the field at once and again on a failure. It runs no
// process, opens no file or URL and logs nothing of the password. The greeter runs it as the `sddm` user, which cannot read
// the user's wallpaper: the default artwork is drawn (Grassfield.Ui, the system-wide module of grassfield-desktop). Values
// are Grassfield's tokens (the lock screen's). If this file cannot load, SDDM uses its embedded theme (ADR-0042 section 2).
//
// SDDM's context: `sddm` (login, reboot, powerOff, canReboot, canPowerOff, loginFailed), `userModel` (name, realName, icon;
// lastIndex), `sessionModel` (name; lastIndex), `keyboard` (capsLock).
Rectangle {
    id: root

    // No size of its own: the greeter sizes the root to each screen.
    color: Tokens.sessionGround

    readonly property var colors: Tokens.colorDark
    readonly property string locale: Qt.locale().name
    function t(key: string): string {
        return Strings.text(key, root.locale);
    }

    // ---- the users and the sessions, read through their models' roles ----
    property int userIndex: userModel.lastIndex >= 0 ? userModel.lastIndex : 0
    readonly property var user: userList.count > 0 && root.userIndex < userList.count ? userList.itemAt(root.userIndex) : null
    readonly property string userName: root.user ? root.user.userName : ""
    readonly property string shownName: root.user ? (root.user.realName !== "" ? root.user.realName : root.user.userName) : ""
    property int sessionIndex: -1
    readonly property string sessionName: sessionIndex >= 0 && sessionIndex < sessionList.count ? sessionList.itemAt(sessionIndex).sessionName : ""

    Repeater {
        id: userList
        model: userModel
        delegate: Item {
            required property string name
            required property string realName
            required property string icon
            readonly property string userName: name
            readonly property string iconPath: icon
        }
    }

    Repeater {
        id: sessionList
        model: sessionModel
        delegate: Item {
            required property string name
            readonly property string sessionName: name
        }
        onCountChanged: root.pickSession()
    }

    function pickSession(): void {
        const names = [];
        for (let i = 0; i < sessionList.count; i++)
            names.push(sessionList.itemAt(i).sessionName);
        root.sessionIndex = Strings.pickSession(names, sessionModel.lastIndex);
    }

    // ---- the login: the password goes to SDDM once, and the field is emptied at once ----
    property string message: ""
    property bool busy: false

    function submit(): void {
        if (root.busy || field.text.length === 0 || root.userName === "")
            return;
        const secret = field.text;
        field.text = "";
        root.message = "";
        root.busy = true;
        sddm.login(root.userName, secret, root.sessionIndex);
    }

    Connections {
        target: sddm

        function onLoginFailed(): void {
            field.text = "";
            root.busy = false;
            root.message = root.t("incorrect");
            shake.restart();
            field.forceActiveFocus();
        }
    }

    Component.onCompleted: {
        field.forceActiveFocus();
        root.pickSession();
    }

    // ---- what is drawn ----
    GrassfieldArtwork {
        anchors.fill: parent
    }

    // The clock refreshes every second (the greeter has no wall clock service).
    property date now: new Date()
    Timer {
        interval: 1000
        repeat: true
        running: true
        onTriggered: root.now = new Date()
    }

    // The banded scrim of the lock screen (ADR-0040 IQ-W4 A): dark under the two text bands, light between them.
    Rectangle {
        id: scrim
        anchors.fill: parent
        readonly property color dim: Qt.alpha(root.colors.shadow, Tokens.lockDimOpacity)
        readonly property color clear: Qt.alpha(root.colors.shadow, Tokens.lockScrimClearOpacity)
        readonly property real upperEdge: (dateClock.y + dateClock.height) / Math.max(1, height)
        readonly property real lowerEdge: account.y / Math.max(1, height)
        readonly property real feather: Tokens.lockScrimFeather / Math.max(1, height)
        readonly property bool banded: lowerEdge - upperEdge > 2 * feather
        gradient: Gradient {
            GradientStop {
                position: 0
                color: scrim.dim
            }
            GradientStop {
                position: scrim.banded ? scrim.upperEdge : 0
                color: scrim.dim
            }
            GradientStop {
                position: scrim.banded ? scrim.upperEdge + scrim.feather : 0
                color: scrim.banded ? scrim.clear : scrim.dim
            }
            GradientStop {
                position: scrim.banded ? scrim.lowerEdge - scrim.feather : 1
                color: scrim.banded ? scrim.clear : scrim.dim
            }
            GradientStop {
                position: scrim.banded ? scrim.lowerEdge : 1
                color: scrim.dim
            }
            GradientStop {
                position: 1
                color: scrim.dim
            }
        }
    }

    Column {
        id: dateClock
        anchors.horizontalCenter: parent.horizontalCenter
        y: Tokens.lockTopMargin

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            text: Qt.locale().toString(root.now, "dddd d MMMM")
            color: root.colors.text
            font.family: Tokens.typographyFamily
            font.pixelSize: Tokens.lockDateSize
            font.weight: Tokens.lockDateWeight
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            text: Qt.locale().toString(root.now, Qt.locale().timeFormat(Locale.ShortFormat).replace(/:ss|\.ss|\s*t$/g, ""))
            color: root.colors.text
            font.family: Tokens.typographyFamily
            font.pixelSize: Tokens.lockClockSize
            font.weight: Tokens.lockClockWeight
        }
    }

    Column {
        id: account
        anchors {
            horizontalCenter: parent.horizontalCenter
            bottom: parent.bottom
            bottomMargin: Tokens.lockBottomMargin
        }
        spacing: Tokens.spacingSm

        // The account's picture (SDDM's icon of the user), else the initials on a disc.
        Item {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Tokens.lockAvatarSize
            height: Tokens.lockAvatarSize

            Rectangle {
                anchors.fill: parent
                radius: width / 2
                color: Qt.alpha(root.colors.fill, Tokens.lockAvatarFillOpacity)
                visible: picture.status !== Image.Ready

                Text {
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: Strings.initials(root.shownName)
                    color: root.colors.text
                    font.family: Tokens.typographyFamily
                    font.pixelSize: Tokens.lockInitialsSize
                    font.weight: Tokens.lockNameWeight
                }
            }

            Image {
                id: picture
                anchors.fill: parent
                source: root.user && root.user.iconPath !== "" ? "file://" + root.user.iconPath : ""
                sourceSize: Qt.size(width * 2, height * 2)
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                visible: false
            }

            // The picture in its circle, without an effect module: a rounded clip of a rounded rectangle.
            Rectangle {
                anchors.fill: parent
                radius: width / 2
                clip: true
                color: "transparent"
                visible: picture.status === Image.Ready

                Image {
                    anchors.fill: parent
                    source: picture.source
                    sourceSize: picture.sourceSize
                    fillMode: Image.PreserveAspectCrop
                }
            }
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            text: root.shownName
            color: root.colors.text
            font.family: Tokens.typographyFamily
            font.pixelSize: Tokens.typographyTitleSize
            font.weight: Tokens.lockNameWeight
        }

        // More than one user: the others by name, to switch.
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Tokens.spacingMd
            visible: userList.count > 1

            Repeater {
                model: userList.count > 1 ? userList.count : 0

                Text {
                    required property int index
                    textFormat: Text.PlainText
                    text: userList.itemAt(index) ? (userList.itemAt(index).realName !== "" ? userList.itemAt(index).realName : userList.itemAt(index).userName) : ""
                    color: index === root.userIndex ? root.colors.text : root.colors.textSecondary
                    font.family: Tokens.typographyFamily
                    font.pixelSize: Tokens.typographyCaptionSize

                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            root.userIndex = parent.index;
                            field.text = "";
                            root.message = "";
                            field.forceActiveFocus();
                        }
                    }
                }
            }
        }

        // The password field: the lock screen's dark frosted inset.
        Item {
            id: fieldBox
            anchors.horizontalCenter: parent.horizontalCenter
            width: Tokens.lockFieldWidth
            height: Tokens.lockFieldHeight

            Rectangle {
                id: fieldFrame
                width: parent.width
                height: parent.height
                radius: height / 2
                color: Qt.alpha(root.colors.shadow, Tokens.lockFieldFillOpacity)
                border.width: field.activeFocus ? 1 : 0
                border.color: Qt.alpha(root.colors.text, Tokens.lockFocusRingOpacity)

                TextInput {
                    id: field
                    anchors {
                        fill: parent
                        leftMargin: Tokens.spacingMd
                        rightMargin: Tokens.spacingMd
                    }
                    verticalAlignment: TextInput.AlignVCenter
                    echoMode: TextInput.Password
                    passwordCharacter: "•"
                    inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText | Qt.ImhNoAutoUppercase | Qt.ImhHiddenText
                    enabled: !root.busy
                    color: root.colors.text
                    selectionColor: root.colors.accent
                    selectedTextColor: root.colors.accentText
                    font.family: Tokens.typographyFamily
                    font.pixelSize: Tokens.typographyBodySize
                    clip: true
                    onAccepted: root.submit()
                    onTextChanged: {
                        if (text.length > 0)
                            root.message = "";
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: field.text.length === 0
                        textFormat: Text.PlainText
                        text: root.t("password")
                        color: root.colors.textSecondary
                        font: field.font
                    }
                }
            }

            SequentialAnimation {
                id: shake
                NumberAnimation {
                    target: fieldFrame
                    property: "x"
                    to: -Tokens.lockShakeDistance
                    duration: Tokens.lockShakeDuration / 2
                }
                NumberAnimation {
                    target: fieldFrame
                    property: "x"
                    to: Tokens.lockShakeDistance
                    duration: Tokens.lockShakeDuration
                }
                NumberAnimation {
                    target: fieldFrame
                    property: "x"
                    to: 0
                    duration: Tokens.lockShakeDuration / 2
                }
            }
        }

        // One line under the field: the last error, else the Caps Lock hint.
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            text: root.message !== "" ? root.message : (typeof keyboard !== "undefined" && keyboard.capsLock ? root.t("capsLock") : " ")
            color: root.colors.text
            font.family: Tokens.typographyFamily
            font.pixelSize: Tokens.typographyCaptionSize
        }
    }

    // ---- the session and the power buttons, at the bottom (macOS's login window) ----
    Row {
        anchors {
            horizontalCenter: parent.horizontalCenter
            bottom: parent.bottom
            bottomMargin: Tokens.spacingLg
        }
        spacing: Tokens.spacingLg

        Text {
            visible: sessionList.count > 1
            textFormat: Text.PlainText
            text: root.t("session").arg(root.sessionName)
            color: root.colors.textSecondary
            font.family: Tokens.typographyFamily
            font.pixelSize: Tokens.typographyCaptionSize

            // A click goes to the next session.
            MouseArea {
                anchors.fill: parent
                onClicked: root.sessionIndex = (root.sessionIndex + 1) % sessionList.count
            }
        }

        Text {
            visible: sddm.canReboot
            textFormat: Text.PlainText
            text: root.t("restart")
            color: root.colors.text
            font.family: Tokens.typographyFamily
            font.pixelSize: Tokens.typographyCaptionSize

            MouseArea {
                anchors.fill: parent
                onClicked: sddm.reboot()
            }
        }

        Text {
            visible: sddm.canPowerOff
            textFormat: Text.PlainText
            text: root.t("shutDown")
            color: root.colors.text
            font.family: Tokens.typographyFamily
            font.pixelSize: Tokens.typographyCaptionSize

            MouseArea {
                anchors.fill: parent
                onClicked: sddm.powerOff()
            }
        }
    }
}
