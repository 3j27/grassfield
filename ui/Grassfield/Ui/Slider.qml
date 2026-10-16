import QtQuick

// Horizontal slider with a pill track and a round knob. value is within [from, to].
Item {
    id: root

    property real from: 0
    property real to: 1
    property real value: 0
    property real stepSize: 0.05
    property string accessibleName: ""
    property color fillColor: Appearance.colors.accent

    // Emitted when the user changes the value (not when it is set from outside).
    signal moved(real value)

    readonly property real position: to > from ? Math.max(0, Math.min(1, (value - from) / (to - from))) : 0
    readonly property real travel: Math.max(0, width - Tokens.controlSliderKnob)

    implicitWidth: 200
    implicitHeight: Tokens.controlSliderHeight
    activeFocusOnTab: true
    Accessible.role: Accessible.Slider
    Accessible.name: root.accessibleName
    Accessible.focusable: true
    Accessible.onIncreaseAction: root.nudge(1)
    Accessible.onDecreaseAction: root.nudge(-1)

    function clampValue(v: real): real {
        return Math.max(from, Math.min(to, v));
    }

    function commit(v: real): void {
        const next = clampValue(v);
        if (next === value)
            return;
        value = next;
        moved(next);
    }

    function nudge(direction: int): void {
        commit(value + direction * stepSize * (to - from));
    }

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Left || event.key === Qt.Key_Down) {
            nudge(-1);
            event.accepted = true;
        } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Up) {
            nudge(1);
            event.accepted = true;
        } else if (event.key === Qt.Key_Home) {
            commit(from);
            event.accepted = true;
        } else if (event.key === Qt.Key_End) {
            commit(to);
            event.accepted = true;
        }
    }

    Rectangle {
        id: track
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width
        height: Tokens.controlSliderTrack
        radius: height / 2
        color: Appearance.withAlpha(Appearance.colors.fill, Tokens.materialFillOpacity)

        Rectangle {
            width: Tokens.controlSliderKnob / 2 + root.position * root.travel
            height: parent.height
            radius: height / 2
            color: root.fillColor
        }
    }

    Rectangle {
        id: knob
        width: Tokens.controlSliderKnob
        height: Tokens.controlSliderKnob
        radius: width / 2
        x: root.position * root.travel
        anchors.verticalCenter: parent.verticalCenter
        color: Appearance.dark ? Appearance.colors.text : "#FFFFFF"
        border.width: root.activeFocus ? Tokens.controlFocusRing : 1
        border.color: root.activeFocus ? Appearance.colors.accent : Appearance.withAlpha(Appearance.colors.shadow, Tokens.materialBorderOpacity)
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        function at(mouseX: real): void {
            root.forceActiveFocus();
            const t = root.travel > 0 ? (mouseX - Tokens.controlSliderKnob / 2) / root.travel : 0;
            root.commit(root.from + Math.max(0, Math.min(1, t)) * (root.to - root.from));
        }
        onPressed: mouse => at(mouse.x)
        onPositionChanged: mouse => {
            if (pressed)
                at(mouse.x);
        }
    }
}
