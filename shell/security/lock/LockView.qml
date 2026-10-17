pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import Quickshell
import Grassfield.Ui
import qs.desktop
import qs.security
import qs.services
import "../LockMachine.js" as Machine

// Content of one lock surface (one per screen): blurred and dimmed wallpaper, date and clock at
// the top centre, avatar, user name and password field near the bottom centre. Nothing else is
// rendered here on purpose: no notifications, no window thumbnails, no media (gate L4).
// Text on the wallpaper always uses the dark-appearance roles (light text on a dimmed image).
Item {
    id: root

    property bool authenticating: false
    property bool inputEnabled: true
    property string message: ""
    // Persistent warning under the error line (e.g. crash recovery unavailable); never replaced.
    property string notice: ""
    property string userName: ""
    // file:// URL of the account picture, or "" for the initials disc.
    property string avatarSource: ""

    signal submitted(string password)
    // Typing started after an error: the error line gives way (e.g. to the Caps Lock hint).
    signal edited

    readonly property var colors: Tokens.colorDark

    function clear(): void {
        field.clear();
    }

    function shake(): void {
        shakeAnimation.restart();
    }

    function focusField(): void {
        field.forceActiveFocus();
    }

    Component.onCompleted: focusField()

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }

    WallpaperArt {
        id: wallpaper
        anchors.fill: parent
        visible: false
    }

    MultiEffect {
        anchors.fill: parent
        source: wallpaper
        autoPaddingEnabled: false
        blurEnabled: true
        blur: 1.0
        blurMax: Tokens.lockBlurMax
    }

    Rectangle {
        anchors.fill: parent
        color: root.colors.shadow
        opacity: Tokens.lockDimOpacity
    }

    // Any click focuses the password field.
    MouseArea {
        anchors.fill: parent
        onPressed: root.focusField()
    }

    Column {
        anchors.horizontalCenter: parent.horizontalCenter
        y: Tokens.lockTopMargin

        Text {
            textFormat: Text.PlainText
            anchors.horizontalCenter: parent.horizontalCenter
            text: Qt.locale().toString(FixedTime.date(clock.date), qsTr("dddd d MMMM"))
            color: root.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.lockDateSize
            font.weight: Tokens.lockDateWeight
            Accessible.role: Accessible.StaticText
            Accessible.name: text
        }

        Text {
            textFormat: Text.PlainText
            anchors.horizontalCenter: parent.horizontalCenter
            text: Qt.formatTime(FixedTime.date(clock.date), Machine.clockFormat(Qt.locale().timeFormat(Locale.ShortFormat)))
            color: root.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.lockClockSize
            font.weight: Tokens.lockClockWeight
            Accessible.role: Accessible.StaticText
            Accessible.name: qsTr("Time: %1").arg(text)
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

        // Avatar: the account picture (resolved by Lock), else the initials on a disc.
        Item {
            id: avatar

            anchors.horizontalCenter: parent.horizontalCenter
            width: Tokens.lockAvatarSize
            height: Tokens.lockAvatarSize
            Accessible.role: Accessible.Graphic
            Accessible.name: qsTr("Picture of %1").arg(root.userName)

            Rectangle {
                id: disc
                anchors.fill: parent
                radius: width / 2
                color: Appearance.withAlpha(root.colors.fill, Tokens.lockAvatarFillOpacity)
                visible: picture.status !== Image.Ready

                Text {
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    text: Machine.initials(root.userName)
                    color: root.colors.text
                    font.family: Appearance.fontFamily
                    font.pixelSize: Tokens.lockInitialsSize
                    font.weight: Tokens.lockNameWeight
                }
            }

            Image {
                id: picture
                anchors.fill: parent
                visible: false
                source: root.avatarSource
                sourceSize: Qt.size(width * 2, height * 2)
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                cache: false
            }

            Rectangle {
                id: circleMask
                anchors.fill: parent
                radius: width / 2
                visible: false
                layer.enabled: true
            }

            MultiEffect {
                anchors.fill: parent
                source: picture
                visible: picture.status === Image.Ready
                maskEnabled: true
                maskSource: circleMask
                autoPaddingEnabled: false
            }
        }

        Text {
            textFormat: Text.PlainText
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.userName
            color: root.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyTitleSize
            font.weight: Tokens.lockNameWeight
            Accessible.role: Accessible.StaticText
            Accessible.name: text
        }

        Item {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Tokens.lockFieldWidth
            height: Tokens.lockFieldHeight

            PasswordField {
                id: field
                x: 0
                width: parent.width
                height: parent.height
                enabled: root.inputEnabled
                busy: root.authenticating
                showSubmit: true
                radius: height / 2
                fontSize: Tokens.typographyBodySize
                textColor: root.colors.text
                placeholderColor: Appearance.withAlpha(root.colors.text, 1 - Tokens.lockFieldFillOpacity)
                fillColor: Appearance.withAlpha(root.colors.fill, Tokens.lockFieldFillOpacity)
                focusColor: Appearance.withAlpha(root.colors.text, Tokens.materialHighlightOpacity * 2)
                onSubmitted: password => root.submitted(password)
                onEdited: root.edited()
            }

            SequentialAnimation {
                id: shakeAnimation

                readonly property int leg: Appearance.reduceMotion ? 0 : Tokens.lockShakeDuration

                NumberAnimation {
                    target: field
                    property: "x"
                    to: -Tokens.lockShakeDistance
                    duration: shakeAnimation.leg / 2
                    easing.type: Easing.OutQuad
                }
                NumberAnimation {
                    target: field
                    property: "x"
                    to: Tokens.lockShakeDistance
                    duration: shakeAnimation.leg
                    easing.type: Easing.InOutQuad
                }
                NumberAnimation {
                    target: field
                    property: "x"
                    to: -Tokens.lockShakeDistance / 2
                    duration: shakeAnimation.leg
                    easing.type: Easing.InOutQuad
                }
                NumberAnimation {
                    target: field
                    property: "x"
                    to: 0
                    duration: shakeAnimation.leg / 2
                    easing.type: Easing.OutQuad
                }
            }
        }

        // One line under the field: the last error, else the Caps Lock hint.
        Text {
            textFormat: Text.PlainText
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.max(Tokens.lockFieldWidth, implicitWidth)
            horizontalAlignment: Text.AlignHCenter
            text: root.message !== "" ? root.message : (field.capsLock ? qsTr("Caps Lock is on") : " ")
            color: root.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyCaptionSize
            font.weight: Tokens.typographyMenuWeight
            Accessible.role: Accessible.AlertMessage
            Accessible.name: text
        }

        Text {
            textFormat: Text.PlainText
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.max(Tokens.lockFieldWidth, implicitWidth)
            horizontalAlignment: Text.AlignHCenter
            visible: root.notice !== ""
            text: root.notice
            color: root.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyCaptionSize
            font.weight: Tokens.typographyMenuWeight
            Accessible.role: Accessible.AlertMessage
            Accessible.name: text
        }
    }
}
