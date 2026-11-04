import QtQuick
import QtTest
import "../../apps/files/qml"

// A mouse's side buttons and the XF86Back / XF86Forward keys move a Files window's history like Cmd-[ and Cmd-]
// (HistoryButtons.qml), over a view that takes every button as well as over the sidebar.
Item {
    id: stage

    width: 300
    height: 200

    property int backs: 0
    property int forwards: 0
    property int clicks: 0

    QtObject {
        id: fakeTab

        property bool canBack: true
        property bool canForward: true

        function back() {
            ++stage.backs;
        }
        function forward() {
            ++stage.forwards;
        }
    }

    // Something under the buttons that accepts every button, as a view does.
    MouseArea {
        id: greedy

        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        onClicked: ++stage.clicks
    }

    HistoryButtons {
        id: buttons

        tab: fakeTab
    }

    TestCase {
        name: "FilesHistoryButtons"
        when: windowShown
        visible: true

        function init() {
            stage.backs = 0;
            stage.forwards = 0;
            stage.clicks = 0;
            fakeTab.canBack = true;
            fakeTab.canForward = true;
            buttons.live = true;
        }

        function test_backAndForwardButtons() {
            mouseClick(stage, 100, 100, Qt.BackButton);
            compare(stage.backs, 1);
            compare(stage.forwards, 0);
            mouseClick(stage, 100, 100, Qt.ForwardButton);
            compare(stage.forwards, 1);
            compare(stage.backs, 1);
        }

        function test_otherButtonsPassThrough() {
            mouseClick(stage, 50, 50, Qt.LeftButton);
            mouseClick(stage, 50, 50, Qt.RightButton);
            compare(stage.clicks, 2, "the view under the item still gets its clicks");
            compare(stage.backs + stage.forwards, 0);
        }

        function test_theKeys() {
            keyClick(Qt.Key_Back);
            compare(stage.backs, 1);
            keyClick(Qt.Key_Forward);
            compare(stage.forwards, 1);
        }

        function test_nothingToGoTo() {
            fakeTab.canBack = false;
            fakeTab.canForward = false;
            mouseClick(stage, 100, 100, Qt.BackButton);
            mouseClick(stage, 100, 100, Qt.ForwardButton);
            keyClick(Qt.Key_Back);
            compare(stage.backs + stage.forwards, 0);
        }

        function test_keysBelongToTheKeyWindow() {
            buttons.live = false;
            mouseClick(stage, 100, 100, Qt.BackButton);
            keyClick(Qt.Key_Forward);
            compare(stage.backs + stage.forwards, 0);
        }

        function test_noTab() {
            buttons.tab = null;
            mouseClick(stage, 100, 100, Qt.BackButton);
            keyClick(Qt.Key_Forward);
            compare(stage.backs + stage.forwards, 0);
            buttons.tab = fakeTab;
        }
    }
}
