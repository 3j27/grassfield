pragma Singleton
import QtQuick
import Quickshell

// Last pointer position per screen, fed by HoverHandlers of surfaces that are already under the
// pointer (menu bar, wallpaper, Dock). Lets the hot corners learn that the pointer left a corner
// without their own windows having to grow over clickable controls.
Singleton {
    id: root

    // {screenName: {x, y}} in screen coordinates.
    property var last: ({})

    // Emitted for every reported position (screen coordinates, px).
    signal moved(string screen, real x, real y)

    function report(screen: string, x: real, y: real): void {
        last[screen] = {
            x: x,
            y: y
        };
        moved(screen, x, y);
    }
}
