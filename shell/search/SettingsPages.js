.pragma library
.import "Ranking.js" as Ranking

// Search provider for the pages of Grassfield Settings (REQ-SRCH-PRV-d1; macOS: Spotlight lists System Settings panes,
// a click opens that pane). Pure: Search.qml passes the translated pages and opens the page with
// `SettingsApp.openSection(id)` (grassfield-settings --section=<id>).

// Page ids are the section ids of apps/settings/qml/Main.qml; `icon` is a glyph of branding/icons/symbolic.
const PAGES = [
    {id: "wifi", icon: "wifi-3"},
    {id: "bluetooth", icon: "bluetooth"},
    {id: "sound", icon: "volume-3"},
    {id: "displays", icon: "display"},
    {id: "appearance", icon: "sun"},
    {id: "wallpaper", icon: "wallpaper"},
    {id: "accessibility", icon: "person"},
    {id: "desktop", icon: "overview"},
    {id: "menubar", icon: "control-center"},
    {id: "notifications", icon: "bell"},
    {id: "lock", icon: "lock"},
    {id: "mouse", icon: "mouse"},
    {id: "keyboard", icon: "keyboard"},
    {id: "about", icon: "grassfield-logo"}
];

// Below this a page does not match (the same floor as the commands: a substring or better).
const MIN_SCORE = 50;
// Keywords score a little under the title, as the command words do.
const KEYWORD_FACTOR = 0.8;

// `pages`: [{id, title, icon, keywords: [string]}]; `query` trimmed. Returns [{page, score}] best first, ties by title.
function match(pages, query) {
    const q = Ranking.norm(query).trim();
    if (q === "")
        return [];
    const out = [];
    for (const p of pages) {
        let s = Ranking.textScore(Ranking.norm(p.title), q);
        for (const w of p.keywords)
            s = Math.max(s, Ranking.textScore(Ranking.norm(w), q) * KEYWORD_FACTOR);
        if (s >= MIN_SCORE)
            out.push({page: p, score: s});
    }
    out.sort((a, b) => b.score - a.score || a.page.title.localeCompare(b.page.title));
    return out;
}

// Whether `id` is a page Settings has (a stale or foreign id is never opened).
function known(id) {
    return PAGES.some(p => p.id === id);
}
