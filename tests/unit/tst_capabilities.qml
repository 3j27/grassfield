import QtQuick
import QtTest
import "../../shell/platform/CapabilityEvent.js" as CapabilityEvent

// Capabilities events of grassfield-compositor (gfc/1): what counts as "plugin present".
TestCase {
    name: "Capabilities"

    function ev(features) {
        return JSON.stringify({v: "gfc/1", type: "capabilities", features: features});
    }

    function test_listedFeaturesMeanPresent() {
        const m = CapabilityEvent.parse(ev(["decorations", "overview", "desktop-focus"]), "gfc/1");
        verify(m.present);
        compare(m.features.length, 3);
    }

    function test_emptyListAtUnloadMeansPluginGone() {
        const m = CapabilityEvent.parse('{"v":"gfc/1","type":"capabilities","features":[]}', "gfc/1");
        verify(m !== null);
        verify(!m.present, "the unload event withdraws the plugin, not only its features");
        compare(m.features.length, 0);
    }

    function test_foreignOrMalformedEventsAreIgnored() {
        compare(CapabilityEvent.parse("not json", "gfc/1"), null);
        compare(CapabilityEvent.parse(ev(["overview"]), "gfc/2"), null);
        compare(CapabilityEvent.parse('{"v":"gfc/1","type":"overview","state":"open"}', "gfc/1"), null);
        compare(CapabilityEvent.parse('{"v":"gfc/1","type":"capabilities","features":"overview"}', "gfc/1"), null);
        compare(CapabilityEvent.parse("null", "gfc/1"), null);
    }

    function test_nonStringFeaturesAreDropped() {
        const m = CapabilityEvent.parse(ev([1, null, "overview"]), "gfc/1");
        compare(m.features.length, 1);
        compare(m.features[0], "overview");
        verify(!CapabilityEvent.parse(ev([1, null]), "gfc/1").present);
    }
}
