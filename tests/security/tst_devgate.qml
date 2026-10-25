import QtQuick
import QtTest
import "../../shell/lib/RunMode.js" as RunMode

// GF-AUDIT-001 SEC-03/SEC-04: one dev gate for every security module and IPC test hook. Since slice M2 (ADR-0019,
// integrator decision) the gate is shell/lib/RunMode.js `dev`, imported by the security modules through a relative path
// (as here), never through the qs.lib module, so no QML import path can replace it. Open only with GRASSFIELD_DEV exactly
// "1" and GRASSFIELD_SESSION not "1": a GRASSFIELD_DEV that leaks into a real session (GRASSFIELD_SESSION=1,
// config/hypr/session.lua) opens nothing. The runtime check (real Lock singleton, both variables set) is
// tests/security/dev_gate.sh; the source check that every hook uses this gate exactly is tests/security/ipc_inventory.sh.
TestCase {
    name: "DevGate"

    // The predicate of shell/services/DevGate.js as it stood before ADR-0019 (removed in M2): the reference the gate must
    // still match on every pair of values.
    function reference(devValue, sessionValue) {
        return devValue === "1" && sessionValue !== "1";
    }

    function test_openOnlyInADevSession() {
        verify(RunMode.dev("1", undefined));
        verify(RunMode.dev("1", ""));
        verify(RunMode.dev("1", "0"));
    }

    function test_closedInARealSession() {
        verify(!RunMode.dev("1", "1"), "GRASSFIELD_DEV leaked into a packaged session");
        verify(!RunMode.dev(undefined, "1"));
        verify(!RunMode.dev("", "1"));
    }

    function test_closedWithoutExactDev() {
        const values = [undefined, null, "", "0", "true", "yes", " 1", "1 ", "01", 1, true];
        for (let i = 0; i < values.length; i++)
            verify(!RunMode.dev(values[i], undefined), JSON.stringify(values[i]));
    }

    // The gate is the pre-M2 predicate on 15 x 15 = 225 pairs of raw values (unset, null, empty, near misses, numbers,
    // booleans, a full-width digit).
    function test_samePredicateOnEveryPair() {
        const values = [undefined, null, "", "1", "0", "true", "TRUE", "yes", " 1", "1 ", "01", "1\n", 1, true, "１"];
        let pairs = 0;
        for (const d of values) {
            for (const s of values) {
                compare(RunMode.dev(d, s), reference(d, s), JSON.stringify([d, s]));
                pairs++;
            }
        }
        compare(pairs, 225);
    }

    function test_refusedAnswer() {
        compare(RunMode.REFUSED, "refused");
    }
}
