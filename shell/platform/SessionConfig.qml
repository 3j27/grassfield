pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Grassfield.Ui
import qs.lib

// The session configuration read again (ADR-0031 and its amendment). Hyprland reads the files Settings writes for the session
// (displays.conf and a display trial through config/hypr/grassfield/displays.lua; mouse-trackpad.lua and keyboard.lua through
// grassfield/input.lua and bindings.lua) only when it parses its configuration, so a choice made in Settings applies when the
// shell asks it to read the configuration again: the request `reload` on the request socket, one connection per request (as
// the blur push), never a `hyprctl` process. Displays.qml asks for it during a trial; the two input files are watched here and
// a change is applied once the writes settle. In a dev session the files are the dev configuration directory's and the socket
// is the nested Hyprland's.
Singleton {
    id: root

    property int reloads: 0

    // Hyprland's answer to a request reload() made: its ticket (what reload() returned) and whether it said "ok" (it answers
    // once it has read its configuration again; a late answer counts as no).
    signal answered(int ticket, bool ok)

    readonly property string mouseTrackpadPath: Mode.configDir + "/mouse-trackpad.lua"
    readonly property string keyboardPath: Mode.configDir + "/keyboard.lua"

    // The request's ticket (answered() names it), or 0 when there is no Hyprland to ask.
    function reload(why: string): int {
        const path = Hyprland.requestSocketPath || "";
        if (path === "") {
            console.info("grassfield-shell: session config: no Hyprland request socket, not read again (" + why + ")");
            return 0;
        }
        root.reloads++;
        console.info("grassfield-shell: session config read again (" + why + ")");
        reloadSocket.createObject(root, {"path": path, "ticket": root.reloads});
        return root.reloads;
    }

    // Settings writes a file on every step of a slider: one reload once the writes settle.
    Timer {
        id: inputSettle
        interval: Tokens.settingsInputReloadMs
        onTriggered: root.reload("input settings")
    }

    FileView {
        path: root.mouseTrackpadPath
        printErrors: false
        watchChanges: true
        onFileChanged: inputSettle.restart()
    }

    FileView {
        path: root.keyboardPath
        printErrors: false
        watchChanges: true
        onFileChanged: inputSettle.restart()
    }

    // One connection per request: it sends `reload` and collects the answer until Hyprland closes the connection (or the
    // answer is late), then it is judged once and destroyed later (a Socket cannot be destroyed from its own error signal).
    Component {
        id: reloadSocket

        Socket {
            id: sock
            property int ticket: 0
            property string reply: ""
            property bool judged: false

            function finish(): void {
                if (sock.judged)
                    return;
                sock.judged = true;
                sock.answerTimeout.stop();
                if (sock.reply.trim() !== "ok")
                    console.info("grassfield-shell: session config: Hyprland answered the reload with \"" + sock.reply.trim() + "\"");
                sock.connected = false;
                root.answered(sock.ticket, sock.reply.trim() === "ok");
                Qt.callLater(() => sock.destroy());
            }

            parser: SplitParser {
                // No separator: Hyprland's answer has no newline, take what arrives and add it up.
                splitMarker: ""
                onRead: data => sock.reply += data
            }
            onConnectedChanged: {
                if (connected) {
                    write("reload");
                    flush();
                    sock.answerTimeout.start();
                } else {
                    sock.finish();
                }
            }

            readonly property Timer answerTimeout: Timer {
                interval: Tokens.materialBlurAnswerMs
                onTriggered: sock.finish()
            }

            Component.onCompleted: {
                sock.error.connect(() => sock.finish());
                sock.connected = true;
            }
        }
    }
}
