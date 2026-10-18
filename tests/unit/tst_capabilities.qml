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
        const m = CapabilityEvent.parse(ev(["decorations", "overview", "desktop-focus-v2"]), "gfc/1");
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

    // The plugin's other events share the raw event name and are never reported as broken capabilities events.
    function test_otherEventTypesAreNotCapabilities() {
        verify(!CapabilityEvent.isMalformedCapabilities('{"v":"gfc/1","type":"appmenu","address":"ab","service":"","path":""}', "gfc/1"));
        verify(!CapabilityEvent.isMalformedCapabilities('{"v":"gfc/1","type":"desktop-focus","state":"granted"}', "gfc/1"));
    }

    function test_nonStringFeaturesAreDropped() {
        const m = CapabilityEvent.parse(ev([1, null, "overview"]), "gfc/1");
        compare(m.features.length, 1);
        compare(m.features[0], "overview");
        verify(!CapabilityEvent.parse(ev([1, null]), "gfc/1").present);
    }

    function test_onlyMalformedCapabilitiesEventsAreReported() {
        verify(CapabilityEvent.isMalformedCapabilities('{"v":"gfc/1","type":"capabilities","features":"overview"}', "gfc/1"));
        verify(CapabilityEvent.isMalformedCapabilities('{"v":"gfc/1","type":"capabilities"}', "gfc/1"));
        verify(!CapabilityEvent.isMalformedCapabilities('{"v":"gfc/1","type":"overview","state":"open"}', "gfc/1"));
        verify(!CapabilityEvent.isMalformedCapabilities(ev(["overview"]), "gfc/1"));
        verify(!CapabilityEvent.isMalformedCapabilities("not json", "gfc/1"));
        verify(!CapabilityEvent.isMalformedCapabilities("null", "gfc/1"));
        verify(!CapabilityEvent.isMalformedCapabilities('{"v":"gfc/2","type":"capabilities"}', "gfc/1"));
    }

    // A plugin of another protocol version is no plugin (parse() is null) and is reported by its version, so the shell
    // can log why it runs degraded. Nothing else counts as another protocol.
    function test_otherProtocolCapabilitiesAreReportedByVersion() {
        const v2 = JSON.stringify({v: "gfc/2", type: "capabilities", features: ["overview"]});
        compare(CapabilityEvent.parse(v2, "gfc/1"), null);
        compare(CapabilityEvent.otherProtocolCapabilities(v2, "gfc/1"), "gfc/2");
        compare(CapabilityEvent.otherProtocolCapabilities('{"type":"capabilities","features":[]}', "gfc/1"), "?");
        compare(CapabilityEvent.otherProtocolCapabilities(ev(["overview"]), "gfc/1"), "");
        compare(CapabilityEvent.otherProtocolCapabilities('{"v":"gfc/2","type":"overview","state":"open"}', "gfc/1"), "");
        compare(CapabilityEvent.otherProtocolCapabilities("not json", "gfc/1"), "");
        compare(CapabilityEvent.otherProtocolCapabilities("null", "gfc/1"), "");
    }
}
