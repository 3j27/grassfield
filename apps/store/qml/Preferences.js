.pragma library
.import Grassfield.Ui 1.0 as Ui
// The tree's own Grassfield.Ui, unversioned (as the Settings app's Store.js imports it).
.import Grassfield.Ui as Tree

// The Store's own keys of grassfield.json (ADR-0037 c, SD20): set as the Settings app sets its keys (its Store.js setValue),
// until the shell is the file's single writer (ADR-0020 decision 4). Pure: the caller reads the file's text, passes it in
// and writes the text returned. Every other key of the file is kept, in its order; a file that is not a JSON object, that
// JsonSafety refuses or whose version is not 1 is never written; a missing or empty file starts at version 1.

// {ok, text, error}: `text` is the whole new file when ok.
function setValue(text, path, value) {
    const bad = Tree.SettingsContract.validate(path, value);
    if (bad !== "")
        return {ok: false, text: "", error: bad};
    let data = {};
    const fresh = text === null || text === undefined || String(text).trim() === "";
    if (!fresh) {
        try {
            data = JSON.parse(text);
        } catch (e) {
            return {ok: false, text: "", error: "not valid JSON"};
        }
        if (data === null || typeof data !== "object" || Array.isArray(data))
            return {ok: false, text: "", error: "not a JSON object"};
        const unsafe = Ui.JsonSafety.unsafeReason(String(text));
        if (unsafe !== "")
            return {ok: false, text: "", error: unsafe};
        if (data.version !== 1)
            return {ok: false, text: "", error: "contract version " + JSON.stringify(data.version)};
    } else {
        data.version = 1;
    }
    const parts = path.split(".");
    let node = data;
    for (let i = 0; i < parts.length - 1; i++) {
        const next = node[parts[i]];
        if (next === null || typeof next !== "object" || Array.isArray(next))
            node[parts[i]] = {};
        node = node[parts[i]];
    }
    node[parts[parts.length - 1]] = value;
    return {ok: true, text: JSON.stringify(data, null, 2) + "\n", error: ""};
}

// Read the file, set `path`, write it back: "" when written, else why not (the switch then shows the file's value again).
function set(backend, path, value) {
    const file = backend.readConfig();
    if (file.exists && !file.ok)
        return "unreadable";
    const result = setValue(file.exists ? file.text : "", path, value);
    if (!result.ok)
        return result.error;
    return backend.writeConfig(result.text);
}
