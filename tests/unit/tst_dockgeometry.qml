import QtQuick
import QtTest
import "../../shell/dock/Geometry.js" as Geometry
import "../../shell/dock/DockModel.js" as DockModel

TestCase {
    name: "DockGeometry"

    readonly property var base: ({
            iconSize: 48,
            padding: 10,
            indicatorSize: 4,
            spacing: 4,
            bottomMargin: 6,
            separatorHeight: 49,
            badgeSize: 20,
            radiusIcon: 11
        })

    function test_clampSize() {
        compare(Geometry.clampSize(48, 32, 96, 48), 48);
        compare(Geometry.clampSize(10, 32, 96, 48), 32);
        compare(Geometry.clampSize(500, 32, 96, 48), 96);
        compare(Geometry.clampSize(40.6, 32, 96, 48), 41);
        compare(Geometry.clampSize("64", 32, 96, 48), 64);
        compare(Geometry.clampSize("big", 32, 96, 48), 48);
        compare(Geometry.clampSize(null, 32, 96, 48), 48);
        compare(Geometry.clampSize(undefined, 32, 96, 48), 48);
        compare(Geometry.clampSize(true, 32, 96, 48), 48);
        compare(Geometry.clampSize(NaN, 32, 96, 48), 48);
    }

    function test_defaultSizeKeepsTheTokens() {
        const m = Geometry.metrics(48, base);
        compare(m.iconSize, 48);
        compare(m.separatorHeight, 49);
        compare(m.badgeSize, 20);
        fuzzyCompare(m.iconRadius, 11, 1e-9);
        compare(DockModel.shelfHeight(m), 48 + 20 + 4 + 4);
        compare(DockModel.reservedHeight(m, false), 76 + 6);
    }

    function test_proportionalPartsFollowTheSize() {
        const big = Geometry.metrics(96, base);
        compare(big.iconSize, 96);
        compare(big.separatorHeight, 98);
        compare(big.badgeSize, 40);
        fuzzyCompare(big.iconRadius, 22, 1e-9);
        // The shelf and its exclusive zone grow by exactly the growth of the tile.
        compare(DockModel.shelfHeight(big) - DockModel.shelfHeight(Geometry.metrics(48, base)), 48);
        compare(DockModel.reservedHeight(big, false) - DockModel.reservedHeight(Geometry.metrics(48, base), false), 48);
        compare(DockModel.reservedHeight(big, true), 0);
    }

    function test_smallSizeKeepsTheBadgeReadable() {
        const small = Geometry.metrics(32, base);
        compare(small.badgeSize, 20);
        compare(small.badgeScale, 1);
        compare(small.separatorHeight, 33);
        fuzzyCompare(small.iconRadius, 11 * 32 / 48, 1e-9);
    }
}
