import QtQuick

// The Store window's backend for the QML tests (apps/store/src/storebackend.h's API): made-up apps, sections and
// categories, nothing read from a system, a network or a file. Calls are recorded for the tests to read.
QtObject {
    id: root

    property string language: "en"
    property bool devSession: true
    property bool dark: false
    property bool reduceMotion: false
    property bool increaseContrast: false
    property real textScale: 1
    property string accentColor: "multicolor"
    property string accentHighlight: "automatic"
    property string shortcutStyle: "pc"
    property string titlebarDoubleClick: "zoom"
    property bool canMinimize: true
    property int revision: 1
    property bool loading: false
    property bool refreshing: false
    property bool online: true
    property bool metered: false
    property var catalog: ({inUse: true, problem: "", channel: "stable", date: "October 27", old: false})
    property var appData: ({origin: "installed", problem: ""})
    property var user: ({name: "Ada Lovelace", initials: "AL", picture: ""})
    property var sources: ({aur: false, flathub: false, flatpak: false, screenshots: true})

    property var calls: []
    property var links: []

    signal appearanceChanged
    signal dataChanged
    signal networkChanged
    signal packageInfo(string name, var facts)

    function app_(id, name, kind, installed, launcher) {
        return {id: id, name: name, summary: name + " does one thing well", icon: "", kind: kind, repo: kind === "repo" ? "extra" : "",
            installed: installed, launcher: launcher};
    }

    readonly property var apps: [
        app_("org.example.Paint", "Paint", "repo", false, true),
        app_("org.example.Photo", "Photo Lab", "repo", true, true),
        app_("org.example.Games", "Game Hub", "setup", false, true),
        app_("org.example.Mail", "Mail Web", "webapp", false, true),
        app_("org.example.Tool", "Pack Tool", "repo", true, false)
    ]

    function find(id) {
        return root.apps.find(a => a.id === id);
    }

    property var sectionList: [
        {id: "discover", title: "Discover", symbol: "discover", blocks: [
            {kind: "hero", items: [{app: find("org.example.Paint"), eyebrow: "Drawing", title: "Paint anything", text: "Brushes for everyone", tint: "#22446A"},
                                   {app: find("org.example.Photo"), eyebrow: "Photos", title: "Develop your photos", text: "Light and colour", tint: ""}]},
            {kind: "cards", items: [{app: find("org.example.Games"), eyebrow: "Games", title: "Your library", text: "All your games", tint: ""},
                                    {app: find("org.example.Mail"), eyebrow: "Mail", title: "Mail in a window", text: "A web app", tint: ""}]},
            {kind: "row", title: "Make something", apps: [find("org.example.Paint"), find("org.example.Photo")]}
        ]},
        {id: "play", title: "Play", symbol: "play", blocks: [{kind: "row", title: "Games", apps: [find("org.example.Games")]}]}
    ]

    function sections() {
        calls.push("sections");
        return root.sectionList;
    }

    function categories() {
        return [{id: "graphics", title: "Graphics", symbol: "category-graphics", count: 2},
                {id: "games", title: "Games", symbol: "category-games", count: 1}];
    }

    function categoryApps(id, kind) {
        calls.push("categoryApps:" + id);
        const list = id === "graphics" ? [find("org.example.Paint"), find("org.example.Photo")] : id === "games" ? [find("org.example.Games")] : [];
        return kind ? list.filter(a => a.kind === kind) : list;
    }

    function search(query) {
        calls.push("search:" + query);
        const q = query.trim().toLowerCase();
        return q === "" ? [] : root.apps.filter(a => a.name.toLowerCase().indexOf(q) >= 0);
    }

    function app(id) {
        calls.push("app:" + id);
        const a = find(id);
        if (!a)
            return {};
        return Object.assign({}, a, {description: "A description.\n• A point", developer: "Example Developers", license: "GPL-3.0-or-later",
            homepage: "https://example.org/" + id, bugtracker: "", package: "paint", packages: ["paint"], desktopId: "paint.desktop",
            inCatalog: true, screenshots: ["https://example.org/1.png"], captions: ["The main window"], categories: ["Graphics"],
            releases: [{version: "2.0", date: "October 1, 2026", notes: "Faster."}], languages: ["Deutsch", "français"],
            rated: true, rating: {social: 3}, setup: ({}), webUrl: "", flatpakId: ""});
    }

    function requestPackageInfo(name) {
        calls.push("info:" + name);
    }

    function installed() {
        return [{group: "arch", apps: [Object.assign({page: true}, find("org.example.Photo")), Object.assign({page: true}, find("org.example.Tool"))]},
                {group: "webapp", apps: [{id: "webapp:Notes", name: "Notes", summary: "notes.example.org", icon: "", kind: "webapp",
                    installed: true, launcher: true, page: false}]}];
    }

    function updates() {
        return {state: "available", checkedAt: "10/27/26 9:12 AM", grassfield: {installed: "1.0.0-1", available: "1.0.1-1"},
            omarchy: {installed: "", available: ""}, others: 3, listed: true, truncated: false,
            apps: [Object.assign({from: "1.0-1", to: "1.1-1"}, find("org.example.Photo"))], otherCount: 2};
    }

    function refresh() {
        calls.push("refresh");
    }

    function openLink(url) {
        links.push(url);
        return false;
    }

    function screenshotSource(url) {
        return "";
    }
}
