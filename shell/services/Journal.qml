pragma Singleton
import QtQuick
import Quickshell

// "Appears once", measured (ADR-0040 section 7, ID-16): each surface logs `grassfield-shell: shown <surface> <output> <ms>` when it
// becomes visible and `hidden` when it goes, `ms` counted from the shell's start (this singleton is created with the first
// surface). The nested test (tests/visual/appear-once.sh) reads these lines from the journal.
Singleton {
    id: root

    readonly property double startedAt: Date.now()

    function shown(surface: string, output: string): void {
        console.info("grassfield-shell: shown " + surface + " " + (output !== "" ? output : "-") + " " + Math.round(Date.now() - root.startedAt));
    }

    function hidden(surface: string, output: string): void {
        console.info("grassfield-shell: hidden " + surface + " " + (output !== "" ? output : "-") + " " + Math.round(Date.now() - root.startedAt));
    }
}
