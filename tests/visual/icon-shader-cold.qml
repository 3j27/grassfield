pragma ComponentBehavior: Bound
// Cold compile of the icon shader: frames before and after an effect first draws (tests/visual/icon-shader-cold.sh).
import QtQuick

Window {
    id: win
    property double last: Date.now()
    property int frames: 0
    property bool armed: false
    width: 200
    height: 200
    visible: true
    color: "#202024"
    Rectangle {
        y: 150
        width: 10
        height: 10
        color: "red"
        NumberAnimation on x { from: 0; to: 180; duration: 1000; loops: Animation.Infinite }
    }
    Image { id: img; visible: false; width: 192; height: 192; sourceSize: Qt.size(192, 192); source: "file:///usr/share/icons/hicolor/256x256/apps/hey.png" }
    Loader {
        id: ld
        active: false
        sourceComponent: ShaderEffect {
            width: 96
            height: 96
            property var iconTexture: img
            property real modeIndex: 2
            property real dark: 1
            property real sysPlateInset: 0.04
            property real sysPlateRadius: 0.225
            property real sysGlyphScale: 0.72
            property real rimUv: 0.03
            property real rimGain: 1
            fragmentShader: Qt.resolvedUrl("../../ui/Grassfield/Ui/shaders/icon.frag.qsb")
            onStatusChanged: console.log("status", status, log)
        }
    }
    onFrameSwapped: {
        const now = Date.now();
        console.log("COLD frame", frames, (now - last), "ms", armed ? "(after effect)" : "(before)");
        last = now;
        frames++;
        if (frames === 8 && !armed) { armed = true; ld.active = true; }
        if (frames === 16) Qt.quit();
    }
}
