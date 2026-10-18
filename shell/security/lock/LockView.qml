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
// Display only: authentication, lock state and crash recovery live in Lock.qml and LockController.
//
// Contrast (gate A2, both appearances, any wallpaper): as on macOS, white text with a soft shadow over the blurred
// wallpaper darkened by a shadow-colour scrim (lock.dimOpacity), and a dark frosted password field
// (lock.fieldFillOpacity). The scrim alone carries the contrast (the shadow is decoration): every role is computed
// in tests/visual/test_contrast_tokens.py ("lock ..." roles) and measured by tests/visual/contrast.sh (surface lock).
// A missing colour, scrim or shadow token, or a failed colour binding, only loses that colour or the shadow: the
// password field's geometry, focus and input never depend on them; the field and the error/notice lines have no layer or
// effect (a failed effect would hide them).
Item {
    id: root

    property bool authenticating: false
    property bool inputEnabled: true
    property string message: ""
    // Persistent warning under the error line (e.g. crash recovery unavailable); never replaced.
    property string notice: ""
    property string userName: ""
    // What is drawn for the account name (display only; authentication never reads it). Fixed fake name in the
    // visual-test fixture (GRASSFIELD_DEV and GRASSFIELD_VISUAL_FIXTURES), else the account's own.
    readonly property string shownName: VisualFixtures.active ? VisualFixtures.user : userName
    // file:// URL of the account picture, or "" for the initials disc.
    property string avatarSource: ""

    signal submitted(string password)
    // Typing started after an error: the error line gives way (e.g. to the Caps Lock hint).
    signal edited

    // Always the dark palette (white text on the dimmed image, both appearances). Read through Appearance so that the
    // dev-only glyph mask of the contrast run recolours the lock text too; outside dev it is Tokens.colorDark.
    readonly property var colors: Appearance.darkColors

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

    // Soft drop shadow under the white text (decoration only, see the header).
    component TextShadow: MultiEffect {
        shadowEnabled: true
        shadowColor: Appearance.darkColors.shadow
        shadowOpacity: Tokens.lockTextShadowOpacity
        shadowBlur: Tokens.lockTextShadowBlur
        shadowVerticalOffset: Tokens.lockTextShadowOffsetY
    }

    WallpaperArt {
        id: wallpaper
        anchors.fill: parent
        visible: false

        // Dev-only: the wallpaper override of the contrast run (VisualFixtures.wallpaperFile, always "" outside dev),
        // so that the lock is measured over the same worst-case wallpapers as the desktop. No `visible` binding: under
        // an invisible effect source, a child turned visible later is never redrawn (Qt only dirties it when its
        // effective visibility changes); an empty source draws nothing.
        Image {
            anchors.fill: parent
            source: VisualFixtures.wallpaperFile !== "" ? "file://" + VisualFixtures.wallpaperFile : ""
            fillMode: Image.Stretch
            sourceSize: Qt.size(width, height)
            asynchronous: true
            cache: false
            smooth: false
        }
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
        layer.enabled: true
        layer.effect: TextShadow {}

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
            Accessible.name: qsTr("Picture of %1").arg(root.shownName)

            Rectangle {
                id: disc
                anchors.fill: parent
                radius: width / 2
                color: Appearance.withAlpha(root.colors.fill, Tokens.lockAvatarFillOpacity)
                visible: picture.status !== Image.Ready

                Text {
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    text: Machine.initials(root.shownName)
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
                source: VisualFixtures.active ? "" : root.avatarSource
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
            text: root.shownName
            color: root.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyTitleSize
            font.weight: Tokens.lockNameWeight
            layer.enabled: true
            layer.effect: TextShadow {}
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
                // Dark frosted inset: white dots and caret, secondary placeholder, white focus ring (no layer or
                // effect on the field: it renders and takes input whatever happens to the decoration).
                textColor: root.colors.text
                placeholderColor: root.colors.textSecondary
                fillColor: Appearance.withAlpha(root.colors.shadow, Tokens.lockFieldFillOpacity)
                focusColor: Appearance.withAlpha(root.colors.text, Tokens.lockFocusRingOpacity)
                // Selection: the dark palette's accent behind dark accent-text dots (was the focus ring colour behind
                // white dots, 1.7-2.1:1).
                selectionColor: root.colors.accent
                selectedTextColor: root.colors.accentText
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
            // No layer/effect: a failed shadow effect must never hide an error (R12 review); the scrim carries A2.
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
            // No layer/effect: a failed shadow effect must never hide a notice such as "Crash recovery unavailable".
            Accessible.role: Accessible.AlertMessage
            Accessible.name: text
        }
    }
}
