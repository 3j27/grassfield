import QtQuick
import "General.js" as General
import "Privacy.js" as Privacy

// The portal permission store as Privacy & Security shows it (ADR-0030; Privacy.js): the state, read when a pane opens and
// again after each change; why it could not be read; each application's name and icon from its desktop entry; and the two
// actions, through SystemService (so never in a dev session).
QtObject {
    id: root

    required property var backend
    required property var system

    property var state: Privacy.parse("")
    property bool loaded: false
    // Why the store could not be read, "" when it was.
    property string error: ""
    // app id -> {name, icon}, from the first applications folder that has its desktop entry; its id when none has.
    property var apps: ({})
    // An action is under way: the switches and − wait for it.
    property bool busy: false
    // The saved selections of one application still to forget (one action each): [{key, token}].
    property var forgetting: []

    function reload(): void {
        root.system.queryBus("privacy.state", "privacy.state");
    }

    function describe(app: string): var {
        let found = {name: app, icon: ""};
        const file = Privacy.entryFile(app);
        for (const dir of file !== "" ? root.backend.applicationDirs : []) {
            const r = root.backend.readText(dir + "/" + file);
            if (!r.ok)
                continue;
            const e = General.parseDesktopEntry(r.text, Qt.locale().name);
            found = {name: e.name !== "" ? e.name : app, icon: e.icon};
            break;
        }
        return found;
    }

    // One category's applications by name: [{app, allowed} or {app, tokens}, with name and icon].
    function list(key: string): var {
        return (root.state[key] || []).map(e => Object.assign({}, e, root.apps[e.app] || {name: e.app, icon: ""}))
            .sort((a, b) => a.name.localeCompare(b.name));
    }

    function setAllowed(key: string, app: string, on: bool): void {
        if (!root.busy && root.system.act("privacy permission", Privacy.allow(key, app, on), "privacy.act"))
            root.busy = true;
    }

    function forget(key: string, entry: var): void {
        if (root.busy || !entry || !Array.isArray(entry.tokens) || entry.tokens.length === 0)
            return;
        root.forgetting = entry.tokens.slice(1).map(t => ({key: key, token: t}));
        if (root.system.act("saved screen selection", Privacy.forget(key, entry.tokens[0]), "privacy.act"))
            root.busy = true;
        else
            root.forgetting = [];
    }

    Component.onCompleted: root.reload()

    readonly property Connections results: Connections {
        target: root.backend

        function onFailed(tag: string, reason: string): void {
            if (tag === "privacy.state")
                root.error = reason !== "" ? reason : "-";
            else if (tag === "privacy.act")
                root.forgetting = [];
        }

        function onFinished(tag: string, ok: bool, output: string): void {
            if (tag === "privacy.state") {
                root.loaded = true;
                if (!ok)
                    return;
                root.error = "";
                root.state = Privacy.parse(output);
                const names = Object.assign({}, root.apps);
                for (const key of Privacy.SWITCHES.concat(Privacy.SAVED)) {
                    for (const e of root.state[key]) {
                        if (names[e.app] === undefined)
                            names[e.app] = root.describe(e.app);
                    }
                }
                root.apps = names;
            } else if (tag === "privacy.act") {
                const next = root.forgetting[0];
                root.forgetting = root.forgetting.slice(1);
                if (ok && next !== undefined && root.system.act("saved screen selection", Privacy.forget(next.key, next.token), "privacy.act"))
                    return;
                root.forgetting = [];
                root.busy = false;
                root.reload();
            }
        }
    }
}
