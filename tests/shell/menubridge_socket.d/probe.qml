import QtQuick
import Quickshell
import qs.platform

// Probe of tests/shell/menubridge_socket.sh: the socket path of the REAL MenuBridge singleton in the environment the harness set,
// as `SOCKET <path>` (an empty path prints `SOCKET -`). Nothing connects: the runtime directory is a scratch one with no bridge.
ShellRoot {
    Timer {
        interval: 50
        running: true
        onTriggered: {
            console.log("SOCKET " + (MenuBridge.socketPath === "" ? "-" : MenuBridge.socketPath));
            Qt.exit(0);
        }
    }
}
