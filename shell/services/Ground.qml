pragma Singleton
import QtQuick
import Quickshell
import Grassfield.Ui

// The session's ground (ADR-0040 ID-2, P-1 one ground): the one colour that shows before a Grassfield surface has drawn and
// after the last one is gone. Each output's wallpaper reports its own (a picture's mean colour, a colour, the artwork's ground:
// WallpaperConfig.groundOf); the wallpaper window draws it under the wallpaper, the exit cover fades to it, and the compositor
// gets the first screen's as its background colour (Compositor.qml; Hyprland holds one). Until a report, and wherever none
// applies, the static default `session.ground`, which config/hypr/grassfield/looknfeel.lua sets at the session's start.
Singleton {
    id: root

    // {output name: "#RRGGBB"}.
    property var grounds: ({})
    // The ground of the first screen (the compositor's background), the static default without one.
    readonly property string current: {
        const first = Quickshell.screens.length > 0 ? Quickshell.screens[0].name : "";
        return root.grounds[first] ?? Tokens.sessionGround;
    }

    // An output without a report yet (a hotplugged one, ID-15) has the compositor's ground.
    function of(output: string): string {
        return root.grounds[output] ?? root.current;
    }

    function report(output: string, ground: string): void {
        if (!/^#[0-9A-Fa-f]{6}$/.test(ground) || root.grounds[output] === ground)
            return;
        const next = Object.assign({}, root.grounds);
        next[output] = ground;
        root.grounds = next;
    }
}
