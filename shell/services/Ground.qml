pragma Singleton
import QtQuick
import Quickshell
import Grassfield.Ui

// The session's ground (ADR-0040 ID-2, P-1 one ground): the one colour that shows before a Grassfield surface has drawn and
// after the last one is gone. Each output's wallpaper reports its own (a picture's mean colour, a colour, the artwork's ground:
// WallpaperConfig.groundOf); the wallpaper window draws it under the wallpaper, the compositor gets the first screen's as its
// background colour (Compositor.qml; Hyprland holds one), and the exit cover fades to the one Hyprland accepted. Until a report, and wherever none
// applies, the static default `session.ground`, which config/hypr/grassfield/looknfeel.lua sets at the session's start.
Singleton {
    id: root

    // {output name: "#RRGGBB"}.
    property var grounds: ({})
    readonly property string firstScreen: Quickshell.screens.length > 0 ? Quickshell.screens[0].name : ""
    // The ground of the first screen (the compositor's background), the static default without one.
    readonly property string current: WallpaperConfig.groundFor(root.grounds, root.firstScreen, Tokens.sessionGround)
    // The first screen has reported its ground: until then the compositor keeps what it has (the config's static default,
    // or the previous run's ground after a shell restart), so no flash to the default.
    readonly property bool known: WallpaperConfig.groundFor(root.grounds, root.firstScreen, "") !== ""
    // The background colour Hyprland last accepted (Compositor.qml; the config's static default before): the exit cover fades
    // to this one, which is what shows once the shell has stopped.
    property string accepted: Tokens.sessionGround

    // An output without a report yet (a hotplugged one, ID-15) has the compositor's ground.
    function of(output: string): string {
        return WallpaperConfig.groundFor(root.grounds, output, root.current);
    }

    function report(output: string, ground: string): void {
        if (!/^#[0-9A-Fa-f]{6}$/.test(ground) || root.grounds[output] === ground)
            return;
        const next = Object.assign({}, root.grounds);
        next[output] = ground;
        root.grounds = next;
    }
}
