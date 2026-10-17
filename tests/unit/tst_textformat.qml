import QtQuick
import QtTest
import Grassfield.Ui

// Untrusted strings (app ids, titles, device names) must never be parsed as rich text:
// every Text of the shared components is PlainText.
TestCase {
    id: testCase
    name: "TextFormat"
    width: 400
    height: 200
    when: windowShown

    function texts(item, out) {
        for (let i = 0; i < item.children.length; i++) {
            const c = item.children[i];
            if (c.textFormat !== undefined && c.text !== undefined)
                out.push(c);
            texts(c, out);
        }
        return out;
    }

    function checkPlain(component) {
        const obj = createTemporaryObject(component, testCase);
        const found = texts(obj, []);
        verify(found.length > 0, "no Text found");
        for (const t of found)
            compare(t.textFormat, Text.PlainText);
        return found;
    }

    Component {
        id: menuItem
        MenuItem {
            text: "<b>bold</b><img src='x'>"
            shortcut: "<i>x</i>"
        }
    }

    Component {
        id: tooltip
        Tooltip {
            text: "<a href='x'>link</a>"
            shown: true
            delay: 0
        }
    }

    Component {
        id: button
        Button {
            text: "<b>ok</b>"
        }
    }

    function test_menuItem() {
        const found = checkPlain(menuItem);
        compare(found[0].text, "<b>bold</b><img src='x'>");
    }

    function test_tooltip() {
        checkPlain(tooltip);
    }

    function test_button() {
        checkPlain(button);
    }
}
