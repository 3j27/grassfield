import QtQuick
import QtTest
import "../../shell/overlay/controlcenter" as CC

// GF-097: the fixed labels of a 2x1 Quick Settings capsule never end in an ellipsis. A long title wraps to two lines
// at its own size (macOS never shrinks a title); a fixed state wraps too.
TestCase {
    name: "CcLabels"
    when: windowShown
    width: 400
    height: 200

    // The capsule is 139 wide (Tokens.quicksettingsCell * 2 + gap).
    Component {
        id: rowComponent
        CC.RadioRow {
            width: 139
            inset: 13
        }
    }

    function findTexts(item, out) {
        for (let i = 0; i < item.children.length; i++) {
            const c = item.children[i];
            if (c.hasOwnProperty("truncated") && c.hasOwnProperty("text"))
                out.push(c);
            findTexts(c, out);
        }
        return out;
    }

    function check_row(title, subtitle) {
        const row = createTemporaryObject(rowComponent, this, {title: title, subtitle: subtitle, iconName: "moon"});
        verify(row);
        wait(50);
        const texts = findTexts(row, []);
        verify(texts.length >= 2);
        for (const t of texts) {
            if (t.text !== "")
                verify(!t.truncated, "\"" + t.text + "\" is truncated");
        }
    }

    function test_appearanceFitsInEnglish() {
        check_row("Appearance", "Auto");
    }

    function test_doNotDisturbWraps() {
        check_row("Do Not Disturb", "Off");
    }

    function test_airplaneState() {
        check_row("Airplane Mode", "On");
    }

    function test_frenchTitles() {
        check_row("Ne pas déranger", "Désactivé");
        check_row("Mode Avion", "Activé");
        check_row("Apparence", "Automatique");
    }
}
