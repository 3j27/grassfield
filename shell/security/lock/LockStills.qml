pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.services

// What the lock surfaces show, prepared while the session is unlocked (ADR-0040 step 4a, ID-7; display only): one LockStill
// per output (its backdrop) and the account picture, decoded ahead. Lock.qml creates this object at run time
// (Qt.createComponent), never as a declared child: a file of the display that fails to load costs the surfaces their
// backdrop and picture (the artwork and the initials show), never the lock itself (review of cbd6ef05, MAJOR 3).
Item {
    id: root

    // The account picture to decode ahead (Lock.qml's avatarSource, bound after creation).
    property string avatarSource: ""
    // The picture, already decoded, or "" (a lock surface then shows the initials).
    readonly property string avatarReady: avatarPreload.status === Image.Ready ? String(avatarPreload.source) : ""
    // Counts the backdrops' decisions, so that a surface's binding is evaluated again.
    property int revision: 0

    function backdropOf(output: string): var {
        for (const s of stills.instances) {
            if (s.output === output)
                return s.backdrop;
        }
        return null;
    }

    // The moving Grassfield artwork (ADR-0040 step 9, as the integrator decided in the review of e067f26f): wallpaper.moving
    // and where its clouds rest on an output's desktop (WallpaperState); the lock moves them from there and gives back where
    // they came to rest. Display data like the rest of this file.
    readonly property bool moving: WallpaperState.moving
    function motionOf(output: string): real {
        return WallpaperState.motionOf(output);
    }
    function restMotion(output: string, at: real): void {
        WallpaperState.setMotion(output, at);
    }

    Variants {
        id: stills
        model: Quickshell.screens

        LockStill {
            onBackdropChanged: root.revision += 1
        }
    }

    // Same options as LockView's picture (the pixmap cache key): no sourceSize (the shell's copy is at most 256 x 256).
    Image {
        id: avatarPreload
        visible: false
        source: VisualFixtures.active ? "" : root.avatarSource
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
    }
}
