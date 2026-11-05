import QtQuick
import QtTest
import "../../shell/search/SettingsPages.js" as SettingsPages
import "../../shell/search/Filters.js" as Filters

// Search provider for the Settings pages (REQ-SRCH-PRV-d1): type a setting name, get the page.
TestCase {
    name: "SearchSettings"

    readonly property var pages: [
        {id: "wifi", title: "Wi-Fi", icon: "wifi-3", keywords: ["wireless", "network"]},
        {id: "sound", title: "Sound", icon: "volume-3", keywords: ["volume", "microphone"]},
        {id: "appearance", title: "Appearance", icon: "sun", keywords: ["dark", "light", "auto"]},
        {id: "lock", title: "Lock Screen", icon: "lock", keywords: ["idle", "password"]}
    ]

    function ids(q) {
        return SettingsPages.match(pages, q).map(h => h.page.id);
    }

    function test_titlePrefixAndExact() {
        compare(ids("sound"), ["sound"]);
        compare(ids("app"), ["appearance"]);
        compare(ids("SOUND "), ["sound"]);
    }

    function test_keywordFindsThePage() {
        compare(ids("dark"), ["appearance"]);
        compare(ids("wireless"), ["wifi"]);
        compare(ids("volume"), ["sound"]);
    }

    function test_titleBeatsKeyword() {
        const hits = SettingsPages.match(pages, "lock");
        compare(hits[0].page.id, "lock");
        verify(hits[0].score >= 50);
    }

    function test_noMatchAndEmpty() {
        compare(ids("zzzz"), []);
        compare(ids(""), []);
        compare(ids("   "), []);
        compare(ids("x"), []);
    }

    function test_everySettingsPageHasAGlyphAndIsKnown() {
        verify(SettingsPages.PAGES.length >= 12);
        for (const p of SettingsPages.PAGES) {
            verify(p.icon !== "");
            verify(SettingsPages.known(p.id));
        }
        // ADR-0045 panes: the fingerprint and sharing pages are offered too.
        verify(SettingsPages.known("fingerprint"));
        verify(SettingsPages.known("sharing"));
        verify(!SettingsPages.known("rm -rf"));
        verify(!SettingsPages.known(""));
    }

    function test_settingsChip() {
        const g = [{id: "settings", title: "Settings", items: [{kind: "setting", key: "setting:sound"}]},
                   {id: "apps", title: "Applications", items: [{kind: "app", key: "app:a"}]}];
        compare(Filters.chipsOf(g), ["apps", "settings"]);
        const only = Filters.apply(g, "settings", "Settings");
        compare(only.length, 1);
        compare(only[0].items.map(i => i.key), ["setting:sound"]);
    }
}
