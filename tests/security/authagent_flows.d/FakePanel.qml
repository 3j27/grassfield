import QtQuick
import QtQuick.Window

// Quickshell 0.3.1's PanelWindow as far as the keyboard goes, for the agent harness's window cases (authagent_flows.sh, the
// check of c1ca44f): its WlrLayershell deletes the window when it is hidden (deleteOnInvisible), so `visible` false then true
// is a NEW window and a new layer surface (ProxyWindowBase::setVisibleDirect, completeWindow); and a compositor's keyboard:
// the panel gets it only once its new surface is mapped (mapDelayMs: the configure round trip and the first frame) and while
// it asks for it (wantsKeyboard: make_harness.py --panel binds it where the agent sets WlrLayershell.keyboardFocus),
// otherwise the window underneath (`underneath`) does.
Item {
    id: fp

    default property alias panelData: content.data
    // The agent's WlrLayershell.keyboardFocus: Exclusive (true) or None (false).
    property bool wantsKeyboard: false
    property int mapDelayMs: 40
    // The window that has the keyboard when the panel does not (the test's own window).
    property var underneath: null
    property var backing: null
    property bool mapped: false
    // How many times a window was made for the panel, and what happened: "create", "mapped", "destroy", "kbd:panel",
    // "kbd:underneath".
    property int recreations: 0
    property var events: []

    width: 800
    height: 600

    Item {
        id: content
        width: 800
        height: 600
    }

    Component {
        id: windowComponent
        Window {
            width: 800
            height: 600
            flags: Qt.ToolTip
            color: "transparent"
        }
    }

    Timer {
        id: mapTimer
        interval: fp.mapDelayMs
        onTriggered: {
            fp.mapped = true;
            fp.events.push("mapped");
            fp.arbitrate();
        }
    }

    function arbitrate(): void {
        if (fp.backing && fp.mapped && fp.wantsKeyboard) {
            fp.backing.requestActivate();
            fp.events.push("kbd:panel");
        } else if (fp.underneath) {
            fp.underneath.requestActivate();
            fp.events.push("kbd:underneath");
        }
    }

    function showPanel(): void {
        fp.recreations++;
        fp.events.push("create");
        fp.backing = windowComponent.createObject(fp);
        fp.backing.visible = true;
        content.parent = fp.backing.contentItem;
        fp.mapped = false;
        mapTimer.restart();
        Qt.callLater(fp.arbitrate);
    }

    function hidePanel(): void {
        if (!fp.backing)
            return;
        fp.events.push("destroy");
        const w = fp.backing;
        w.visible = false;
        content.parent = null;
        fp.backing = null;
        fp.mapped = false;
        mapTimer.stop();
        w.destroy();
        Qt.callLater(fp.arbitrate);
    }

    onVisibleChanged: visible ? showPanel() : hidePanel()

    // The panel asks for the keyboard, or lets it go (applied at polish: deferred).
    onWantsKeyboardChanged: Qt.callLater(fp.arbitrate)

    Component.onCompleted: {
        content.parent = null;
        if (visible)
            showPanel();
    }
}
