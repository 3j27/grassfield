import QtQuick
import QtTest
import Grassfield.Ui

// The wallpaper's glass-grid probe (shell/desktop/Wallpaper.qml gridProbe): the grab of the shown wallpaper is drawn on a small canvas and read
// back as width x height. The grab is tagged at the window's pixel ratio, so drawImage(url, 0, 0, width, height) fills only the top-left 1/ratio
// of a canvas that has that ratio, and a read of the whole canvas at that ratio adds the empty part as black cells (56 of 160 at 1.25, 120 at 2
// on a white wallpaper). This test reads as the shell does (width x height) and wants no black cell at any ratio: tests/shell/icontile_hidpi.sh
// runs it at 1.05, 1.25, 1.5 and 2.
TestCase {
    id: tc

    name: "WallpaperGrab"
    when: windowShown
    width: 300
    height: 300
    visible: true

    property var res: null

    Rectangle {
        id: src

        width: 160
        height: 100
        color: "white"
    }

    Canvas {
        id: probe

        x: 170
        width: 128
        height: 80
        renderTarget: Canvas.Image
        renderStrategy: Canvas.Immediate
    }

    function test_aWhiteWallpaperHasNoBlackCell() {
        tryVerify(() => probe.available, 3000);
        src.grabToImage(r => {
            tc.res = r;
        }, Qt.size(128, 80));
        tryVerify(() => tc.res !== null, 3000);
        const url = String(tc.res.url);
        probe.loadImage(url);
        tryVerify(() => probe.isImageLoaded(url), 3000);
        const ctx = probe.getContext("2d");
        ctx.clearRect(0, 0, 128, 80);
        ctx.drawImage(url, 0, 0, 128, 80);
        const grid = GlassTint.gridOf(ctx.getImageData(0, 0, 128, 80).data, 128, 80, Tokens.glassGridColumns, Tokens.glassGridRows, 1536, 864);
        const black = grid.max.filter(v => v === 0).length;
        compare(black, 0, "black cells of a white wallpaper (" + grid.max.length + " cells)");
        verify(grid.min.every(v => v > 0.9), "every cell is white");
    }
}
