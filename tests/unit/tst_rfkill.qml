import QtQuick
import QtTest
import "../../shell/services/Rfkill.js" as Rfkill

// Airplane Mode as an rfkill soft block (REQ-QS-CC3): parsing `rfkill --json list`, the derived state, the command line
// and the fallback reason.
TestCase {
    name: "Rfkill"

    readonly property string listing: JSON.stringify({rfkilldevices: [
        {id: 0, type: "wlan", device: "phy0", soft: "blocked", hard: "unblocked"},
        {id: 1, type: "bluetooth", device: "hci0", soft: "blocked", hard: "unblocked"},
        {id: 2, type: "gps", device: "x", soft: "unblocked", hard: "unblocked"}
    ]})

    function test_parseBothKeySpellingsAndGarbage() {
        const d = Rfkill.parseList(listing);
        compare(d.length, 3);
        compare(d[0].type, "wlan");
        verify(d[0].soft);
        verify(!d[0].hard);
        compare(Rfkill.parseList(listing.replace("rfkilldevices", "rfkill-devices")).length, 3);
        compare(Rfkill.parseList("not json").length, 0);
        compare(Rfkill.parseList("{}").length, 0);
        compare(Rfkill.parseList("null").length, 0);
    }

    function test_airplaneOnWhenEveryGovernedRadioIsBlocked() {
        const a = Rfkill.airplane(Rfkill.parseList(listing));
        verify(a.known);
        verify(a.on);
    }

    function test_airplaneOffWhenOneRadioIsOn() {
        const d = Rfkill.parseList(listing);
        d[1].soft = false;
        verify(!Rfkill.airplane(d).on);
    }

    function test_hardBlockedCountsAsOff() {
        const d = Rfkill.parseList(listing);
        d[0].soft = false;
        d[0].hard = true;
        verify(Rfkill.airplane(d).on);
    }

    function test_noGovernedRadioIsUnknown() {
        const d = Rfkill.parseList(listing).filter(r => r.type === "gps");
        verify(!Rfkill.airplane(d).known);
        verify(!Rfkill.airplane([]).on);
    }

    function test_command() {
        compare(Rfkill.command(true).join(" "), "rfkill block wlan bluetooth wwan");
        compare(Rfkill.command(false).join(" "), "rfkill unblock wlan bluetooth wwan");
    }

    function test_unavailableReason() {
        compare(Rfkill.unavailableReason(true, true, true), "");
        compare(Rfkill.unavailableReason(false, false, true), "missing");
        compare(Rfkill.unavailableReason(true, true, false), "no-tool");
        compare(Rfkill.unavailableReason(true, false, true), "not-writable");
    }
}
