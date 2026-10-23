import QtQuick
import QtTest
import "../../shell/services/DevGate.js" as DevGate

// GF-AUDIT-001 SEC-03/SEC-04: one dev gate for every security module and IPC test hook. Open only with
// GRASSFIELD_DEV exactly "1" and GRASSFIELD_SESSION not "1": a GRASSFIELD_DEV that leaks into a real session
// (GRASSFIELD_SESSION=1, config/hypr/session.lua) opens nothing. The runtime check (real Lock singleton, both variables
// set) is tests/security/dev_gate.sh; the source check that every hook uses this gate is tests/security/ipc_inventory.sh.
TestCase {
    name: "DevGate"

    function test_openOnlyInADevSession() {
        verify(DevGate.allowed("1", undefined));
        verify(DevGate.allowed("1", ""));
        verify(DevGate.allowed("1", "0"));
    }

    function test_closedInARealSession() {
        verify(!DevGate.allowed("1", "1"), "GRASSFIELD_DEV leaked into a packaged session");
        verify(!DevGate.allowed(undefined, "1"));
        verify(!DevGate.allowed("", "1"));
    }

    function test_closedWithoutExactDev() {
        const values = [undefined, null, "", "0", "true", "yes", " 1", "1 ", "01", 1, true];
        for (let i = 0; i < values.length; i++)
            verify(!DevGate.allowed(values[i], undefined), JSON.stringify(values[i]));
    }

    function test_refusedAnswer() {
        compare(DevGate.REFUSED, "refused");
    }
}
