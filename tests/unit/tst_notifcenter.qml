import QtQuick
import QtTest
import "../../shell/notifications/CenterLogic.js" as CenterLogic

// Focus choice after a clear and hover counting of the Notifications column (shell/notifications/CenterLogic.js).
TestCase {
    name: "NotificationCenterLogic"

    // Displayed rows from "app:key" words.
    function rows(spec) {
        return spec.split(" ").filter(w => w !== "").map(w => ({appName: w.split(":")[0], key: w.split(":")[1]}));
    }

    // Collapsed group (3 shown): Mail 4 was revealed into the slot of the cleared Mail 3. Focus follows the slot, not Calendar.
    function test_collapsedGroupRevealedCardTakesFocus() {
        // before: mail:m1 mail:m2 mail:m3 cal:c1 ; Mail 3 (slot 2) cleared, Mail 4 revealed into slot 2
        compare(CenterLogic.focusAfterClear(rows("mail:m1 mail:m2 mail:m4 cal:c1"), 2, "mail"), "m4");
        // the next Delete (focus on m4, slot 2) reveals Mail 5 and clears no other app's card
        compare(CenterLogic.focusAfterClear(rows("mail:m1 mail:m2 mail:m5 cal:c1"), 2, "mail"), "m5");
    }

    // Nothing left to reveal: the cleared card was the group's last one, its group has cards before it.
    function test_lastCardOfGroupFocusesTheGroupsNewLastCard() {
        compare(CenterLogic.focusAfterClear(rows("mail:m1 mail:m2 cal:c1"), 2, "mail"), "m2");
        // expanded group, the last card cleared
        compare(CenterLogic.focusAfterClear(rows("mail:m1 mail:m2 mail:m3 cal:c1 chat:h1"), 3, "mail"), "m3");
    }

    // Middle of a group: the card that moved up takes the slot.
    function test_middleCardOfGroupFocusesTheNextOfTheGroup() {
        compare(CenterLogic.focusAfterClear(rows("mail:m1 mail:m3 mail:m4 cal:c1"), 1, "mail"), "m3");
        compare(CenterLogic.focusAfterClear(rows("mail:m2 mail:m3 cal:c1"), 0, "mail"), "m2");
    }

    // A group's only card (or a whole group): the next group's first card, else the previous.
    function test_goneGroupFocusesNextThenPrevious() {
        compare(CenterLogic.focusAfterClear(rows("mail:m1 cal:c1 cal:c2"), 1, "chat"), "c1");
        compare(CenterLogic.focusAfterClear(rows("mail:m1 mail:m2"), 2, "cal"), "m2");
        compare(CenterLogic.focusAfterClear(rows("cal:c1 cal:c2"), 0, "mail"), "c1");
    }

    function test_nothingLeftFocusesNothing() {
        compare(CenterLogic.focusAfterClear([], 0, "mail"), "");
        compare(CenterLogic.focusAfterClear([], 5, "mail"), "");
    }

    // An out-of-range slot (the cleared card was the last row) falls back to the last row.
    function test_slotPastTheEndFocusesTheLastRow() {
        compare(CenterLogic.focusAfterClear(rows("mail:m1 cal:c1"), 2, "chat"), "c1");
    }

    // The x sticks out of the card: the pointer can enter it before it leaves the card, or after; the group stays hot.
    function test_hoverCountsKeepTheGroupWhileAnyPartIsHovered() {
        let c = {};
        c = CenterLogic.hoverStep(c, "mail", true);   // card
        verify(CenterLogic.isHovered(c, "mail"));
        c = CenterLogic.hoverStep(c, "mail", true);   // x entered first or second: both orders
        c = CenterLogic.hoverStep(c, "mail", false);  // card left
        verify(CenterLogic.isHovered(c, "mail"));
        c = CenterLogic.hoverStep(c, "mail", false);  // x left
        verify(!CenterLogic.isHovered(c, "mail"));
    }

    function test_hoverCountsAreNeverNegativeAndIndependentPerApp() {
        let c = CenterLogic.hoverStep({}, "mail", false);
        compare(c.mail, 0);
        c = CenterLogic.hoverStep(c, "cal", true);
        verify(!CenterLogic.isHovered(c, "mail"));
        verify(CenterLogic.isHovered(c, "cal"));
        const frozen = {mail: 1};
        CenterLogic.hoverStep(frozen, "mail", true);
        compare(frozen.mail, 1);
    }
}
