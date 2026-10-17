import QtQuick
import QtTest
import "../../shell/services/AppLaunch.js" as AppLaunch

// Launch helpers of Apps.qml: isolated XDG homes for apps started from a GRASSFIELD_DEV session, and
// Exec field-code stripping for the dev launch path.
TestCase {
    name: "AppLaunch"

    function test_isolatedEnvironment() {
        const env = AppLaunch.isolatedEnvironment("/w/.dev/apps-home");
        compare(env.XDG_CONFIG_HOME, "/w/.dev/apps-home/config");
        compare(env.XDG_CACHE_HOME, "/w/.dev/apps-home/cache");
        compare(env.XDG_STATE_HOME, "/w/.dev/apps-home/state");
        // The data dirs keep resolving desktop entries and icons.
        verify(!("XDG_DATA_HOME" in env));
        verify(!("XDG_DATA_DIRS" in env));
    }

    function test_appsHomeIsNextToTheStateHome() {
        compare(AppLaunch.appsHomeFor("/w/.dev/state", "/run"), "/w/.dev/apps-home");
        compare(AppLaunch.appsHomeFor("/w/.dev/state/", "/run"), "/w/.dev/apps-home");
        compare(AppLaunch.appsHomeFor("", "/run"), "/run/grassfield-dev/apps-home");
    }

    function test_fieldCodesAreDropped() {
        compare(AppLaunch.stripFieldCodes(["chromium", "%U"]), ["chromium"]);
        compare(AppLaunch.stripFieldCodes(["foot", "--title", "%c", "%f"]), ["foot", "--title"]);
        compare(AppLaunch.stripFieldCodes(["app", "--url=%u", "100%%"]), ["app", "--url=", "100%"]);
        compare(AppLaunch.stripFieldCodes([]), []);
        compare(AppLaunch.stripFieldCodes(["%U"]), []);
    }
}
