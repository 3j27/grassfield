"""The secret agent as an offscreen test component (tests/security/secret_sheets.sh): the real
shell/security/secret/SecretAgent.qml with its Quickshell types replaced by plain QML, its logic untouched.

    make_harness.py [--quickshell] <SecretAgent.qml> <out.qml>

PrompterClient becomes FakeClient (the same properties, signals and answer(); the tests drive it), Scope an Item, and
PanelWindow an Item of the window's size; the layer-shell, blur and IPC parts go, and the dev gate reads true (the
dev hook is checked in the real Quickshell run, tests/security/secret_bridge.sh). With --quickshell (that run: offscreen
Quickshell has no PanelWindow backend) only the window becomes an Item and loses its layer-shell and blur lines; the real
PrompterClient, the dev gate, the socket path rule and the IPC handler stay. Each replacement must find exactly what it
expects: when SecretAgent.qml changes shape, the script fails (exit 1) rather than test something else.
"""
import re
import sys


def block_end(text, start):
    i = text.index("{", start)
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return j + 1
    raise ValueError("unbalanced block at %d" % start)


def replace_block(text, head, replacement):
    m = re.search(head, text)
    if not m:
        raise ValueError("not found: " + head)
    return text[:m.start()] + replacement + text[block_end(text, m.start()):]


def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError("not found once: " + old.strip())
    return text.replace(old, new, 1)


def main():
    args = sys.argv[1:]
    quickshell = args[:1] == ["--quickshell"]
    if quickshell:
        args = args[1:]
    if len(args) != 2:
        raise ValueError("usage: make_harness.py [--quickshell] <SecretAgent.qml> <out.qml>")
    src, out = args
    s = open(src).read()
    if quickshell:
        s = once(s, "import Quickshell.Wayland\n", "")
    else:
        for imp in ("import Quickshell\n", "import Quickshell.Io\n", "import Quickshell.Wayland\n", 'import "../../lib/RunMode.js" as RunMode\n'):
            s = once(s, imp, "")
        s = once(s, "\nScope {\n", "\nItem {\n")
        s = once(s, "\n    PrompterClient {\n", "\n    FakeClient {\n")
        s = once(s, '    readonly property bool dev: RunMode.dev(Quickshell.env("GRASSFIELD_DEV"), Quickshell.env("GRASSFIELD_SESSION"))\n',
                 "    readonly property bool dev: true\n")
        s = once(s, '    readonly property string socketPath: Prompter.socketPath(root.dev, Quickshell.env("XDG_RUNTIME_DIR"), root.devSocket)\n',
                 '    readonly property string socketPath: ""\n')
        s = once(s, "return RunMode.REFUSED;", 'return "refused";')
        s = replace_block(s, r"\n    IpcHandler \{", "\n")
    s = replace_block(s, r"\n        anchors \{\n            top: true", "\n        width: 800\n        height: 600")
    s = replace_block(s, r"\n        Region \{", "\n")
    s = once(s, "\n    PanelWindow {\n", "\n    Item {\n")
    dropped = r"\s*(WlrLayershell\.|BackgroundEffect\.|exclusionMode:|color: win\.shown \? Appearance\.withAlpha)"
    lines = s.split("\n")
    kept = [line for line in lines if not re.match(dropped, line)]
    if len(lines) - len(kept) != 6:
        raise ValueError("expected 6 window property lines, found %d" % (len(lines) - len(kept)))
    s = "\n".join(kept)
    if not quickshell:
        aliases = ("    property alias clientMock: client\n    property alias model: sheetModel\n    property alias sheet: win\n"
                   "    property alias holderItem: holder\n    property alias sink: keySink\n    property alias notice: endedNotice\n")
        s = once(s, "    id: root\n", "    id: root\n" + aliases)
    open(out, "w").write(s)


if __name__ == "__main__":
    try:
        main()
    except ValueError as e:
        sys.exit("make_harness: SecretAgent.qml changed shape: %s" % e)
