import QtQuick
import QtTest
import "../../shell/services/Airplane.js" as Airplane
import "../../shell/services/Rfkill.js" as Rfkill

// Airplane Mode is its own state (REQ-QS-CC3, macOS model): on remembers the radios that were on, off restores exactly
// those, and Wi-Fi off alone is not Airplane Mode.
TestCase {
    name: "Airplane"

    function dev(type, soft) {
        return {id: 0, type: type, soft: soft, hard: false};
    }

    function test_wifiOffAloneIsNotAirplaneMode() {
        // No Bluetooth on this machine, Wi-Fi switched off by hand: the state is off, so the capsule is off.
        const radios = Airplane.radiosFromServices(false, null);
        verify(!Airplane.reconcile(Airplane.end(), radios).on);
        const rf = Airplane.radiosFromRfkill([dev("wlan", true)]);
        verify(!Airplane.reconcile(Airplane.end(), rf).on);
    }

    function test_onRemembersTheRadiosThatWereOn() {
        const radios = Airplane.radiosFromRfkill([dev("wlan", false), dev("bluetooth", true)]);
        const s = Airplane.begin(radios);
        verify(s.on);
        compare(s.restore, ["wlan"]);
    }

    function test_offRestoresExactlyThoseNotEveryRadio() {
        const before = Airplane.radiosFromRfkill([dev("wlan", false), dev("bluetooth", true)]);
        const s = Airplane.begin(before);
        // Everything is blocked now.
        const during = Airplane.radiosFromRfkill([dev("wlan", true), dev("bluetooth", true)]);
        verify(Airplane.reconcile(s, during).on);
        compare(Airplane.typesToRestore(s, during), ["wlan"]);
        compare(Rfkill.command(false, ["wlan"]).join(" "), "rfkill unblock wlan");
        verify(!Airplane.end().on);
    }

    function test_blockCoversEveryGovernedRadio() {
        compare(Rfkill.command(true, []).join(" "), "rfkill block wlan bluetooth wwan");
        compare(Rfkill.command(false).join(" "), "rfkill unblock wlan bluetooth wwan");
        compare(Rfkill.command(false, ["gps", "bluetooth"]).join(" "), "rfkill unblock bluetooth");
    }

    function test_staysOnWhileAnyRadioIsOffAndClearsWhenAllAreBackOn() {
        const s = {on: true, restore: ["wlan", "bluetooth"]};
        verify(Airplane.reconcile(s, Airplane.radiosFromServices(true, false)).on);
        verify(!Airplane.reconcile(s, Airplane.radiosFromServices(true, true)).on);
        verify(!Airplane.reconcile(s, {}).on);
    }

    function test_restoreSkipsARadioThatIsGone() {
        const s = {on: true, restore: ["wlan", "bluetooth"]};
        compare(Airplane.typesToRestore(s, {wlan: false}), ["wlan"]);
    }

    function test_persistence() {
        const s = {on: true, restore: ["wlan"]};
        compare(Airplane.parse(Airplane.serialize(s)), s);
        verify(!Airplane.parse("garbage").on);
        verify(!Airplane.parse("{\"on\":true}").on);
        compare(Airplane.parse("{\"on\":true,\"restore\":[\"wlan\",\"x\"]}").restore, ["wlan"]);
        verify(!Airplane.parse(Airplane.serialize(Airplane.end())).on);
    }

    function test_aTypeWithSeveralDevicesIsOnWhileAnyIs() {
        const r = Airplane.radiosFromRfkill([dev("wlan", true), dev("wlan", false)]);
        compare(r.wlan, true);
    }
}
