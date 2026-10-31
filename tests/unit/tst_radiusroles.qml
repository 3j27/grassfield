import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/settings/qml" as SettingsQml

// Radius roles and concentric shapes (ADR-0039 step 13, G5; docs/audits/design-polish-2026-10-29.md § 3.11, measured on the
// 512 Pixels macOS 27 release captures): a Settings group has its own corner, the switcher's selection is concentric with its
// panel, Force Quit's rows and the stack's rows with what holds them, a cover art and a notification's icon tile have their
// own corner, a tiling suggestion's thumbnail is rounded. The Settings group is built here; the shell's surfaces need
// Quickshell, so their sources are read.
TestCase {
    id: tc

    name: "RadiusRoles"
    width: 400
    height: 200
    visible: true
    when: windowShown

    SettingsQml.SettingsGroup {
        id: group
        width: 300
        caption: "Group"
    }

    function source(path) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../" + path), false);
        xhr.send();
        verify(xhr.responseText.length > 0, path);
        return xhr.responseText.replace(/\/\/.*$/gm, "");
    }

    function test_theTokens() {
        compare(Tokens.radiusGroup, 12, "macOS 27's Settings groups: 11.9");
        compare(Tokens.radiusArtwork, 10, "macOS 27's Control Center art: 10.2");
        compare(Tokens.switcherPanelRadius, 60, "macOS 27's App Switcher: 59.7");
        compare(Tokens.switcherSelectionRadius, 33, "macOS 27's App Switcher selection: 32.4-34.1");
    }

    // The switcher's selection square sits concentric in its panel's corner: the corner less the square's inset (the panel's
    // padding and the pitch's margin round the square), within the 45-degree measure's 1 pt.
    function test_theSwitchersSelectionIsConcentric() {
        const inset = Tokens.switcherPadding + (Tokens.switcherPitch - Tokens.switcherSelectionSize) / 2;
        verify(Math.abs(Tokens.switcherPanelRadius - inset - Tokens.switcherSelectionRadius) <= 1,
               "panel " + Tokens.switcherPanelRadius + " less inset " + inset + " against selection " + Tokens.switcherSelectionRadius);
    }

    // A Settings group draws the group's corner.
    function test_aSettingsGroupHasItsOwnCorner() {
        const stack = [group];
        let found = false;
        while (stack.length > 0) {
            const it = stack.shift();
            if (String(it).indexOf("QQuickRectangle") === 0 && it.radius === Tokens.radiusGroup && it.width === group.width)
                found = true;
            for (let i = 0; i < it.children.length; i++)
                stack.push(it.children[i]);
        }
        verify(found, "the group's box takes radius.group");
    }

    // Settings no longer borrows the menus' radius for its groups: what is left reads a menu-like popover (the colour well's);
    // Software Update's sheet followed in step 26.
    function test_settingsBorrowsNoMenuRadius() {
        const left = ["apps/settings/qml/ColorWell.qml"];
        for (const path of ["SettingsGroup", "ListFooter", "GestureRow", "GestureHeader", "PaneBanner", "PaneHero", "NetworkRow",
                            "BluetoothDeviceRow", "DisplayHeader", "PrinterRow", "ServiceRow", "LoginItemsPage", "PrivacyCategoryPage",
                            "SoundDeviceTable", "LayoutPickerSheet", "AddPrinterSheet", "AppPickerSheet", "KeyboardShortcutsSheet", "Main",
                            "SoftwareUpdateSheet"])
            verify(source("apps/settings/qml/" + path + ".qml").indexOf("Tokens.radiusMenu") < 0, path);
        verify(left.every(p => source(p).indexOf("Tokens.radiusMenu") >= 0), "the one kept on purpose");
    }

    function test_theShellsInnerShapes_data() {
        return [
            {tag: "Force Quit's row, concentric with its well", path: "shell/overlay/ForceQuitPanel.qml", line: "radius: Tokens.radiusControl - Tokens.spacingXs"},
            {tag: "the stack's back row, concentric", path: "shell/overlay/StackPopup.qml", line: "radius: Tokens.radiusMenu - backRow.x"},
            {tag: "the stack's Open row, concentric", path: "shell/overlay/StackPopup.qml", line: "radius: Tokens.radiusMenu - openRow.x"},
            {tag: "Control Center's cover art", path: "shell/overlay/controlcenter/NowPlaying.qml", line: "radius: Tokens.radiusArtwork"},
            {tag: "the Now Playing widget's art", path: "shell/widgets/builtin/nowplaying/NowPlaying.qml", line: "radius: Tokens.radiusArtwork"},
            {tag: "a notification's icon tile", path: "shell/notifications/NotificationContent.qml", line: "radius: Tokens.notificationIconRadius"},
            {tag: "a tiling suggestion's thumbnail", path: "shell/overlay/TilingSuggestions.qml", line: "radius: Tokens.tilingSuggestThumbRadius"}
        ];
    }

    function test_theShellsInnerShapes(data) {
        verify(source(data.path).indexOf(data.line) >= 0, data.tag);
    }

    function test_noDockRadiusInANotification() {
        verify(source("shell/notifications/NotificationContent.qml").indexOf("radiusDockIcon") < 0);
    }

    // The suggestion's thumbnail is masked by its rounded shape, as the Overview's.
    function test_theSuggestionThumbnailIsMasked() {
        const text = source("shell/overlay/TilingSuggestions.qml");
        verify(text.indexOf("maskSource: thumbMask") >= 0);
        verify(/id: thumbMask[\s\S]*?visible: false[\s\S]*?layer\.enabled: true/.test(text));
    }
}
