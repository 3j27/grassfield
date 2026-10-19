pragma ComponentBehavior: Bound
import QtQuick
import QtQml
import Quickshell
import Quickshell.Io
import qs.store

// pointer.size read from grassfield.json by the real SettingsStore (scripts/dev/test.sh: `qs -p tests/shell/pointer_store`).
// A valid integer snaps to the slider step; a non-integer, a string, a boolean or a number out of range is the default
// 24 (an `int` property would have turned 51.5 into 52 and "64" into 64). Prints "pointer-store: PASS" or the failures.
ShellRoot {
    id: root

    readonly property string base: (Quickshell.env("GRASSFIELD_TEST_TMP") || "/tmp") + "/gf-pointer-" + Date.now() + "-" + Math.floor(Math.random() * 1e6)
    // name, file text, expected pointerSize
    readonly property var cases: [
        {"name": "on step", "text": '{"version":1,"pointer":{"size":48}}', "want": 48},
        {"name": "off step integer snaps", "text": '{"version":1,"pointer":{"size":51}}', "want": 52},
        {"name": "fraction is the default", "text": '{"version":1,"pointer":{"size":51.5}}', "want": 24},
        {"name": "string is the default", "text": '{"version":1,"pointer":{"size":"64"}}', "want": 24},
        {"name": "boolean is the default", "text": '{"version":1,"pointer":{"size":true}}', "want": 24},
        {"name": "above range is the default", "text": '{"version":1,"pointer":{"size":200}}', "want": 24},
        {"name": "below range is the default", "text": '{"version":1,"pointer":{"size":7}}', "want": 24},
        {"name": "missing is the default", "text": '{"version":1}', "want": 24}
    ]
    property var failures: []
    property int loaded: 0

    function dir(i: int): string {
        return base + "/c" + i;
    }

    function check(name: string, ok: bool): void {
        if (!ok)
            failures.push(name);
    }

    Process {
        id: setup
        command: {
            let script = "";
            for (let i = 0; i < root.cases.length; i++)
                script += 'mkdir -p "$1/c' + i + '" && printf "%s" \'' + root.cases[i].text + '\' > "$1/c' + i + '/grassfield.json" && ';
            return ["sh", "-c", script + "true", "sh", root.base];
        }
        running: true
        onRunningChanged: {
            if (!running)
                repeater.model = root.cases.length;
        }
    }

    Instantiator {
        id: repeater
        model: 0

        delegate: QtObject {
            id: item
            required property int index
            property var store: SettingsStore {
                saveDelay: 10
                configDir: root.dir(item.index)
                onLoadedFile: {
                    const c = root.cases[item.index];
                    root.check(c.name + ": got " + pointerSize, pointerSize === c.want);
                    root.loaded++;
                    if (root.loaded === root.cases.length)
                        cleanup.running = true;
                }
            }
        }
    }

    Process {
        id: cleanup
        command: ["rm", "-rf", root.base]
        onRunningChanged: {
            if (running)
                return;
            if (root.failures.length === 0) {
                console.log("pointer-store: PASS");
                Qt.exit(0);
            } else {
                console.log("pointer-store: FAIL " + root.failures.join(", "));
                Qt.exit(1);
            }
        }
    }

    Timer {
        interval: 15000
        running: true
        onTriggered: {
            console.log("pointer-store: FAIL timeout, loaded " + root.loaded);
            Qt.exit(1);
        }
    }
}
