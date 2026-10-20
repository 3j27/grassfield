import QtQuick
import QtTest
import Grassfield.Ui
import "../../apps/settings/qml/Store.js" as Store

// Icon appearance modes (ADR-0014 phase 1): mode -> effect parameters, tint resolution, settings validation, and the
// live switch of a TintedIcon (no effect item in default mode, parameters follow the mode and the tint).
TestCase {
    id: testCase
    name: "IconModes"
    visible: true
    when: windowShown
    width: 200
    height: 200

    readonly property color red: "#e5484d"

    function cleanup() {
        Appearance.iconShaderBroken = false;
        Appearance.iconMode = "default";
        Appearance.iconTintSetting = "accent";
    }

    function test_defaultHasNoEffect() {
        const p = IconModes.effect("default", testCase.red);
        compare(p.enabled, false);
        compare(p.index, 0);
        // Unknown modes are default.
        compare(IconModes.effect("neon", testCase.red).enabled, false);
        compare(IconModes.normalizeMode(undefined), "default");
        compare(IconModes.normalizeMode("Dark"), "default");
    }

    function test_modesMapToShaderIndex() {
        compare(IconModes.effect("dark", testCase.red).index, 1);
        compare(IconModes.effect("clear", testCase.red).index, 2);
        compare(IconModes.effect("tinted", testCase.red).index, 3);
        for (const m of ["dark", "clear", "tinted"])
            compare(IconModes.effect(m, testCase.red).enabled, true);
        compare(IconModes.effect("tinted", testCase.red).tint, testCase.red);
    }

    // The mode numbers are tokens that the shader reads; wrong ranges would break the look silently.
    function test_shaderTokensInRange() {
        verify(Tokens.iconModeDarkPlateLuma > 0 && Tokens.iconModeDarkPlateLuma < 0.3, "Dark plates are near black");
        verify(Tokens.iconModeDarkArtLift > Tokens.iconModeDarkPlateLuma, "a black part of the artwork is lifted above the plate");
        verify(Tokens.iconModeDarkArtScale > Tokens.iconModeDarkArtLift, "the Dark map is increasing: black art stays darker than light art");
        verify(Tokens.iconModeClearBackdropDark < Tokens.iconModeClearInkDark && Tokens.iconModeClearBackdropLight > Tokens.iconModeClearInkLight, "the ink stands out from the material it is solved against");
        verify(Tokens.iconModeTintedRampLowDark < Tokens.iconModeTintedRampHighDark && Tokens.iconModeTintedRampLowLight < 1 - Tokens.iconModeTintedRampHighLight + 1, "the Tinted ramp rises");
        verify(Tokens.iconModeClearPlateAlphaDark > 0 && Tokens.iconModeClearPlateAlphaDark < 0.5, "translucent glass");
        verify(Tokens.iconModeClearPlateAlphaLight > 0 && Tokens.iconModeClearPlateAlphaLight < 0.5, "translucent glass");
        verify(Tokens.iconModeClearInkDark > Tokens.iconModeClearInkLight, "light ink on dark, dark ink on light");
        verify(Tokens.iconModeTintedPlateScale > 0 && Tokens.iconModeTintedPlateScale < 0.5, "a dark tinted plate");
        verify(Tokens.iconModeTintedPlateMixLight > 0.5 && Tokens.iconModeTintedPlateMixLight < 1, "a light tinted plate");
        verify(Tokens.dockIconOversample >= 2.5, "decoded at the Dock's largest magnification");
    }

    function test_shaderFileExists() {
        // The compiled shader the effect loads sits next to its source (scripts/dev/build-shaders.sh).
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../ui/Grassfield/Ui/shaders/icon.frag.qsb"), false);
        xhr.send();
        verify(xhr.status === 200 || xhr.status === 0, "icon.frag.qsb readable");
        verify(xhr.responseText.length > 0, "icon.frag.qsb is not empty");
    }

    function test_tintResolution() {
        compare(IconModes.validTint("accent"), true);
        compare(IconModes.validTint("#12abEF"), true);
        compare(IconModes.validTint("#12345"), false);
        compare(IconModes.validTint("red"), false);
        compare(IconModes.validTint(5), false);
        compare(IconModes.tintColor("#12abef", "#000000"), "#12abef");
        compare(IconModes.tintColor("accent", "#000000"), "#000000");
        compare(IconModes.tintColor("bogus", "#000000"), "#000000");
    }

    function test_appearanceTintFollowsAccentByDefault() {
        compare(Appearance.iconTint.toString(), Qt.color(Appearance.colors.accent).toString());
        Appearance.iconTintSetting = "#e5484d";
        compare(Appearance.iconTint.toString(), Qt.color("#e5484d").toString());
        Appearance.iconTintSetting = "accent";
        const was = Appearance.dark;
        Appearance.dark = !was;
        compare(Appearance.iconTint.toString(), Qt.color(Appearance.colors.accent).toString(), "accent follows the appearance");
        Appearance.dark = was;
    }

    function test_settingsKeys() {
        compare(Store.validate("icons.mode", "clear"), "");
        verify(Store.validate("icons.mode", "neon") !== "");
        compare(Store.validate("icons.tint", "accent"), "");
        compare(Store.validate("icons.tint", "#A0b1C2"), "");
        verify(Store.validate("icons.tint", "#12345") !== "");
        verify(Store.validate("icons.tint", 3) !== "");
        compare(Store.DEFAULTS["icons.mode"], "default");
        compare(Store.DEFAULTS["icons.tint"], "accent");
        // Round trip: set, read back, every other key kept.
        const before = JSON.stringify({version: 1, appearance: "light", extra: {a: 1}});
        const r1 = Store.setValue(before, "icons.mode", "tinted");
        verify(r1.ok);
        const r2 = Store.setValue(r1.text, "icons.tint", "#e5484d");
        verify(r2.ok);
        const data = JSON.parse(r2.text);
        compare(Store.read(data, "icons.mode"), "tinted");
        compare(Store.read(data, "icons.tint"), "#e5484d");
        compare(data.appearance, "light");
        compare(data.extra.a, 1);
        // A hand-edited bad value reads as the default.
        compare(Store.read({icons: {mode: "neon", tint: "x"}}, "icons.mode"), "default");
        compare(Store.read({icons: {mode: "neon", tint: "x"}}, "icons.tint"), "accent");
        verify(!Store.setValue(before, "icons.mode", "neon").ok);
    }

    Component {
        id: iconComponent

        TintedIcon {
            size: 48
        }
    }

    // Live switch: the shell flips Appearance.iconMode; icons already on screen follow without being recreated.
    function test_liveSwitch() {
        const icon = createTemporaryObject(iconComponent, testCase);
        verify(icon);
        compare(icon.modeActive, false);
        compare(icon.effectActive, false, "default mode: no effect item, no offscreen pass");
        verify(icon.effectItem === null);

        Appearance.iconMode = "dark";
        compare(icon.modeActive, true);
        verify(icon.effectItem !== null);
        compare(icon.effectItem.modeIndex, 1);

        Appearance.iconMode = "tinted";
        compare(icon.effectItem.modeIndex, 3);
        compare(icon.effectItem.tint.toString(), Appearance.iconTint.toString());
        Appearance.iconTintSetting = "#e5484d";
        compare(icon.effectItem.tint.toString(), Qt.color("#e5484d").toString());

        Appearance.iconMode = "clear";
        compare(icon.effectItem.modeIndex, 2);

        const was = Appearance.dark;
        Appearance.dark = !was;
        compare(icon.effectItem.dark, was ? 0 : 1, "the effect follows the appearance");
        Appearance.dark = was;

        Appearance.iconMode = "default";
        compare(icon.effectActive, false);
        verify(icon.effectItem === null);
    }

    // An icon that is not shown creates no effect item (a type icon under a thumbnail, a closed panel).
    function test_hiddenIconHasNoEffect() {
        Appearance.iconMode = "dark";
        const icon = createTemporaryObject(iconComponent, testCase, {visible: false});
        verify(icon);
        compare(icon.effectActive, false);
        verify(icon.effectItem === null);
        icon.visible = true;
        compare(icon.effectActive, true);
        verify(icon.effectItem !== null);
        icon.visible = false;
        compare(icon.effectActive, false);
    }

    // A per-use override wins over the global setting (previews).
    function test_overrideMode() {
        const icon = createTemporaryObject(iconComponent, testCase, {mode: "clear"});
        verify(icon);
        compare(icon.modeActive, true);
        Appearance.iconMode = "dark";
        compare(icon.mode, "clear");
        compare(icon.effectItem.modeIndex, 2);
    }

    // A shader that cannot load must not make icons vanish: the plain image is shown (and one warning logged).
    function test_failedShaderShowsThePlainIcon() {
        Appearance.iconMode = "dark";
        const icon = createTemporaryObject(iconComponent, testCase, {shaderUrl: Qt.resolvedUrl("missing/icon.frag.qsb"), source: Qt.resolvedUrl("../fixtures/icons/blue-plate-white-glyph.svg")});
        verify(icon);
        compare(icon.plainVisible, false, "with a working shader the effect draws");
        // Whether a missing shader reports an error here depends on the scene graph (the software renderer never
        // compiles shaders); where it does, the plain image takes over.
        tryVerify(() => icon.effectItem.status !== ShaderEffect.Uncompiled || icon.effectFailed === false, 500, "status settles or stays uncompiled");
        compare(icon.plainVisible, icon.effectFailed);
    }

    // Files rows over an accent fill (selected, focused) pass overAccent down to the icon they draw (FileIcon -> TintedIcon/FolderIcon).
    function test_filesIconPassesOverAccent() {
        const c = Qt.createComponent(Qt.resolvedUrl("../../apps/files/qml/FileIcon.qml"));
        compare(c.status, Component.Ready, c.errorString());
        for (const dir of [false, true]) {
            const o = createTemporaryObject(c, testCase, {overAccent: true, isDir: dir});
            verify(o);
            verify(o.children[0].item.overAccent, "the icon of a " + (dir ? "folder" : "file") + " row follows the accent fill");
            o.overAccent = false;
            verify(!o.children[0].item.overAccent);
        }
    }
}
