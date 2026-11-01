import QtQuick
import QtTest
import "../../shell/security"
import "../../shell/security/SheetQueue.js" as Logic

// The one queue of the secret sheets and the polkit sheet (shell/security/SheetQueue.{js,qml}; ADR-0035 D-9, master-prompt
// R12): arrival order across both kinds, a polkit request that arrives behind secret ones waits, a secret one that arrives
// behind the polkit sheet waits, a place is kept until its sheet is gone, and the end of a sheet is said before the queue
// changes.
TestCase {
    name: "SheetQueue"

    Component {
        id: queueC
        SheetQueue {}
    }

    function test_logicOrder() {
        const q = Logic.create();
        compare(Logic.secretHead(q), "");
        verify(!Logic.polkitWaits(q), "an empty queue: polkit goes at once");
        verify(Logic.addSecret(q, "p1"));
        verify(!Logic.addSecret(q, "p1"), "an id is queued once");
        verify(!Logic.addSecret(q, ""), "no empty id");
        verify(Logic.polkitWaits(q), "a polkit request arriving now comes after p1");
        Logic.setPolkit(q, true);
        verify(Logic.addSecret(q, "p2"));
        compare(Logic.secretHead(q), "p1");
        verify(Logic.polkitWaits(q), "p1 came first");
        Logic.removeSecret(q, "p1");
        verify(!Logic.polkitWaits(q), "p1 gone: polkit's turn");
        compare(Logic.secretHead(q), "", "p2 came after polkit");
        Logic.setPolkit(q, true);
        compare(Logic.secretHead(q), "", "a polkit sheet still present keeps its place");
        Logic.setPolkit(q, false);
        compare(Logic.secretHead(q), "p2", "polkit gone: p2's turn");
        Logic.setPolkit(q, true);
        verify(Logic.polkitWaits(q), "a new polkit request goes behind p2");
        compare(Logic.count(q), 1);
    }

    function test_objectSignalsBeforeChange() {
        const sq = createTemporaryObject(queueC, this);
        const seen = [];
        sq.sheetEnded.connect(kind => seen.push(kind + ":" + sq.polkitWaits + ":" + sq.secretHead));
        verify(sq.addSecret("p1"));
        sq.polkitPresent = true;
        compare(sq.polkitWaits, true);
        compare(sq.secretHead, "p1");
        compare(sq.secretCount, 1);
        sq.removeSecret("p1");
        compare(seen, ["secret:true:p1"], "the end is said while the queue still holds p1");
        compare(sq.polkitWaits, false);
        verify(sq.addSecret("p2"));
        compare(sq.secretHead, "", "p2 waits behind the polkit sheet");
        sq.polkitPresent = false;
        compare(seen[1], "polkit:false:", "the polkit sheet's end is said before p2 becomes the head");
        compare(sq.secretHead, "p2");
        sq.removeSecret("nope");
        compare(seen.length, 2, "removing an id that is not queued says nothing");
        verify(sq.hasSecret("p2"));
    }

    // A polkit request arriving behind secret requests waits from its very first evaluation (no place yet).
    function test_polkitArrivingWaits() {
        const sq = createTemporaryObject(queueC, this);
        sq.addSecret("p1");
        compare(sq.polkitWaits, true, "before polkitPresent is even set");
        sq.polkitPresent = true;
        compare(sq.polkitWaits, true);
    }
}
