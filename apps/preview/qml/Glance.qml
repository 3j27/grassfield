pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui

// Glance: a quick look at the given files in a floating window sized to the content (a normal
// toplevel with app_id org.grassfield.Preview.Glance, floated and centered by a Hyprland window
// rule). Space or Esc closes it, Left/Right move between files, "Open with Preview" starts the
// full viewer. Read only, like the viewer.
Window {
    id: win

    // Set by the launcher (src/main.cpp).
    required property var backend

    property int current: 0
    readonly property int fileCount: win.backend.files.length
    readonly property var view: content.view
    readonly property real maxWidth: Screen.width * Tokens.previewGlanceScreenFraction
    readonly property real maxHeight: Screen.height * Tokens.previewGlanceScreenFraction
    // The window is sized once, for the first file: a compositor does not follow later size changes of a
    // floating toplevel reliably, so the other files of a multi-file Glance are fitted into this size.
    readonly property var firstInfo: win.backend.inspect(0)
    // Content size (without the header) by kind.
    readonly property size wanted: {
        const info = win.firstInfo;
        if (info.ok !== true)
            return Qt.size(Tokens.previewGlanceMediaWidth, Tokens.previewGlanceMediaHeight);
        switch (info.kind) {
        case "image": {
            const w = info.width ?? 1;
            const h = info.height ?? 1;
            const room = Math.min(1, win.maxWidth / w, (win.maxHeight - Tokens.previewGlanceHeaderHeight) / h);
            return Qt.size(w * room, h * room);
        }
        case "pdf":
            return Qt.size(Tokens.previewGlancePdfWidth, Tokens.previewGlancePdfHeight);
        case "text":
            return Qt.size(Tokens.previewGlanceTextWidth, Tokens.previewGlanceTextHeight);
        case "video":
            return Qt.size(Tokens.previewGlanceVideoWidth, Tokens.previewGlanceVideoHeight);
        }
        return Qt.size(Tokens.previewGlanceMediaWidth, Tokens.previewGlanceMediaHeight);
    }

    title: content.info.name ?? qsTr("Glance")
    width: Math.max(Tokens.previewGlanceMinWidth, Math.min(win.maxWidth, win.wanted.width))
    height: Math.max(Tokens.previewGlanceMinHeight, Math.min(win.maxHeight, win.wanted.height + Tokens.previewGlanceHeaderHeight))
    visible: true
    color: Appearance.colors.materialTint

    Theme {
        backend: win.backend
    }

    function go(delta: int): void {
        if (win.fileCount > 1)
            win.current = (win.current + delta + win.fileCount) % win.fileCount;
    }

    Shortcut {
        sequence: "Space"
        onActivated: Qt.quit()
    }
    Shortcut {
        sequence: "Esc"
        onActivated: Qt.quit()
    }
    Shortcut {
        sequence: "Ctrl+W"
        onActivated: Qt.quit()
    }
    Shortcut {
        sequence: "Ctrl+O"
        onActivated: win.openInPreview()
    }
    Shortcut {
        sequence: "Left"
        enabled: win.fileCount > 1
        onActivated: win.go(-1)
    }
    Shortcut {
        sequence: "Right"
        enabled: win.fileCount > 1
        onActivated: win.go(1)
    }
    Shortcut {
        sequences: ["+", "="]
        enabled: win.view?.canZoom ?? false
        onActivated: win.view.zoomIn()
    }
    Shortcut {
        sequence: "-"
        enabled: win.view?.canZoom ?? false
        onActivated: win.view.zoomOut()
    }
    Shortcut {
        sequence: "0"
        enabled: win.view?.canZoom ?? false
        onActivated: win.view.fit()
    }

    function openInPreview(): void {
        win.backend.openInPreview();
        Qt.quit();
    }

    Item {
        id: header
        width: parent.width
        height: Tokens.previewGlanceHeaderHeight

        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: 1
            color: Appearance.withAlpha(Appearance.colors.separator, Tokens.materialSeparatorOpacity)
        }

        Text {
            anchors {
                left: parent.left
                leftMargin: Tokens.spacingMd
                right: counter.left
                rightMargin: Tokens.spacingMd
                verticalCenter: parent.verticalCenter
            }
            elide: Text.ElideMiddle
            textFormat: Text.PlainText
            text: content.info.name ?? ""
            color: Appearance.colors.text
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyMenuSize
            font.weight: Tokens.typographyMenuBoldWeight
            Accessible.role: Accessible.Heading
            Accessible.name: text
        }

        Text {
            id: counter
            anchors {
                right: openButton.left
                rightMargin: Tokens.spacingMd
                verticalCenter: parent.verticalCenter
            }
            visible: win.fileCount > 1
            textFormat: Text.PlainText
            text: qsTr("%1 of %2").arg(win.current + 1).arg(win.fileCount)
            color: Appearance.colors.textSecondary
            font.family: Appearance.fontFamily
            font.pixelSize: Tokens.typographyCaptionSize
            Accessible.role: Accessible.StaticText
            Accessible.name: text
        }

        Button {
            id: openButton
            anchors {
                right: parent.right
                rightMargin: Tokens.spacingMd
                verticalCenter: parent.verticalCenter
            }
            height: Tokens.previewToolbarButtonSize
            visible: win.fileCount > 0
            text: qsTr("Open with Preview")
            // Space closes the Glance, never presses this button.
            activeFocusOnTab: false
            onClicked: win.openInPreview()
        }
    }

    Content {
        id: content
        anchors {
            top: header.bottom
            bottom: parent.bottom
            left: parent.left
            right: parent.right
        }
        backend: win.backend
        fileIndex: win.current
        autoplay: true
    }
}
