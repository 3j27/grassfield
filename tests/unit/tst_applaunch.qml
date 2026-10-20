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
        compare(env.XDG_DATA_HOME, "/w/.dev/apps-home/data");
        compare(env.HOME, "/w/.dev/apps-home/home");
        // The system data dirs keep resolving desktop entries and icons.
        verify(!("XDG_DATA_DIRS" in env));
    }

    function test_mergeEnvironment() {
        const base = {"HOME": "/h"};
        const extra = {"XCURSOR_SIZE": "48"};
        compare(AppLaunch.mergeEnvironment(base, extra), {"HOME": "/h", "XCURSOR_SIZE": "48"});
        compare(AppLaunch.mergeEnvironment({}, {}), {});
        compare(AppLaunch.mergeEnvironment(base, {}), {"HOME": "/h"});
        // Neither input is modified.
        compare(base, {"HOME": "/h"});
        compare(extra, {"XCURSOR_SIZE": "48"});
    }

    function test_appsHomeIsNextToTheStateHome() {
        compare(AppLaunch.appsHomeFor("/w/.dev/state", "/run"), "/w/.dev/apps-home");
        compare(AppLaunch.appsHomeFor("/w/.dev/state/", "/run"), "/w/.dev/apps-home");
        compare(AppLaunch.appsHomeFor("", "/run"), "/run/grassfield-dev/apps-home");
    }

    function test_scopedArgv() {
        // A real session: the application runs in a scope of its own through uwsm's app launcher.
        compare(AppLaunch.scopedArgv(["foot"], true), ["uwsm-app", "--", "foot"]);
        compare(AppLaunch.scopedArgv(["gio", "open", "/h/a b.txt"], true), ["uwsm-app", "--", "gio", "open", "/h/a b.txt"]);
        // An argument that looks like an option stays the application's (after "--").
        compare(AppLaunch.scopedArgv(["-x"], true), ["uwsm-app", "--", "-x"]);
        // A dev session or no uwsm-app: unchanged; nothing to start: nothing added.
        compare(AppLaunch.scopedArgv(["foot", "-e", "top"], false), ["foot", "-e", "top"]);
        compare(AppLaunch.scopedArgv([], true), []);
        compare(AppLaunch.scopedArgv(undefined, true), []);
        // The input is not modified.
        const argv = ["foot"];
        AppLaunch.scopedArgv(argv, true);
        compare(argv, ["foot"]);
    }

    function test_fieldCodesAreDropped() {
        compare(AppLaunch.stripFieldCodes(["chromium", "%U"]), ["chromium"]);
        compare(AppLaunch.stripFieldCodes(["foot", "--title", "%c", "%f"]), ["foot", "--title"]);
        compare(AppLaunch.stripFieldCodes(["app", "--url=%u", "100%%"]), ["app", "--url=", "100%"]);
        compare(AppLaunch.stripFieldCodes([]), []);
        compare(AppLaunch.stripFieldCodes(["%U"]), []);
    }

    // Dev open policy (ADR-0011): every helper that asks another application to open something is recognised.
    function test_openRequests() {
        compare(AppLaunch.openRequest(["gio", "open", "/a"]).targets, ["/a"]);
        compare(AppLaunch.openRequest(["gio", "open", "/a", "/b"]).targets, ["/a", "/b"]);
        compare(AppLaunch.openRequest(["/usr/bin/gio", "open", "trash:///"]).targets, ["trash:///"]);
        compare(AppLaunch.openRequest(["xdg-open", "/a"]).targets, ["/a"]);
        compare(AppLaunch.openRequest(["gtk-launch", "org.gnome.gedit", "/a"]).targets, ["/a"]);
        compare(AppLaunch.openRequest(["gtk-launch", "org.gnome.gedit"]).refuse, "application launch");
        compare(AppLaunch.openRequest(["gio", "launch", "x.desktop"]).refuse, "application launch");
        compare(AppLaunch.openRequest(["gio", "open"]).refuse, "nothing to open");
    }

    function test_otherHelpersAreNotOpenRequests() {
        compare(AppLaunch.openRequest(["gio", "trash", "--", "/a"]), null);
        compare(AppLaunch.openRequest(["nm-connection-editor"]), null);
        compare(AppLaunch.openRequest([]), null);
    }

    function test_autostart() {
        compare(AppLaunch.autostartDir(true, "/w/.dev/apps-home", "/x", "/h"), "/w/.dev/apps-home/config/autostart");
        compare(AppLaunch.autostartDir(false, "", "/x", "/h"), "/x/autostart");
        compare(AppLaunch.autostartDir(false, "", "", "/h"), "/h/.config/autostart");
        const text = AppLaunch.autostartText({name: "My App", icon: "my-app", command: ["/usr/bin/my app", "--x=%u", "50%"], runInTerminal: false});
        verify(text.startsWith("[Desktop Entry]\nType=Application\nName=My App\n"));
        verify(text.indexOf('Exec="/usr/bin/my app" --x= "50%%"\n') > 0);
        verify(text.indexOf("Icon=my-app\n") > 0 && text.indexOf("Terminal=false\n") > 0);
        compare(AppLaunch.execQuote("a$b"), '"a\\$b"');
    }

    // Hostile names and arguments: nothing can add a key or a line to the autostart file; backslashes follow the Desktop
    // Entry escape rules (the string escape after the quoting rule); control characters in Exec are refused.
    function test_autostartHostile() {
        const lines = t => t.split("\n").filter(l => l !== "");
        const bad = AppLaunch.autostartText({name: "Evil\nHidden=true\nExec=rm", icon: "i\rHidden=true", command: ["/bin/x"], runInTerminal: false});
        compare(lines(bad).filter(l => l.startsWith("Hidden=")).length, 0);
        compare(lines(bad).length, 6, "Entry, Type, Name, Exec, Icon, Terminal: no line is added");
        verify(bad.indexOf("Name=Evil\\nHidden=true\\nExec=rm\n") > 0);
        compare(AppLaunch.autostartText({name: "x", command: ["/bin/x", "a\nHidden=true"]}), "");
        compare(AppLaunch.autostartText({name: "x", command: ["/bin/x", "a\u0000b"]}), "");
        compare(AppLaunch.autostartText({name: "x", command: ["/bin/x", "a\u001b[0m"]}), "");
        compare(AppLaunch.autostartText({name: "x", command: ["%f"]}), "");
        // one literal backslash in a quoted argument is four backslashes in the file (quoting rule, then string escape)
        const bs = AppLaunch.autostartText({name: "a\\b", command: ["/bin/x", "c\\d"]});
        verify(bs.indexOf("Name=a\\\\b\n") > 0, bs);
        verify(bs.indexOf('Exec=/bin/x "c\\\\\\\\d"\n') > 0, bs);
        // empty, spaced, quoted and shell-looking arguments are quoted
        const q = AppLaunch.autostartText({name: "x", command: ["/bin/x", "", "a b", "q\"z", "$(id)", "it's"]});
        compare(AppLaunch.autostartText({name: "x", command: ["/bin/x", "t\tx"]}), "", "a tab in Exec is a control character");
        verify(q.indexOf('Exec=/bin/x "" "a b" "q\\\\"z" "\\\\$(id)" "it\'s"\n') > 0, q);
    }

    function test_autostartFileNames() {
        compare(AppLaunch.autostartFile("/d/autostart", "org.x.App"), "/d/autostart/org.x.App.desktop");
        compare(AppLaunch.autostartFile("/d/autostart", "../evil"), "");
        compare(AppLaunch.autostartFile("/d/autostart", "a/b"), "");
        compare(AppLaunch.autostartFile("/d/autostart", ".hidden"), "");
        compare(AppLaunch.autostartFile("/d/autostart", "a\nb"), "");
        compare(AppLaunch.autostartFile("/d/autostart", ""), "");
        compare(AppLaunch.autostartFile("/d/autostart", "x".repeat(300)), "");
        compare(AppLaunch.autostartFile("", "x"), "");
    }
}
