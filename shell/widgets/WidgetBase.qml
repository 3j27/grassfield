import QtQuick
import Quickshell
import qs.lib
import Grassfield.Ui

// widgets/1 host API, as seen by a widget (docs/specs/widgets.md). Every widget's root is a
// WidgetBase; the host fills it into its tile and sets the properties below.
Item {
    id: root

    // "small" | "medium" | "large": one of the manifest's sizes. The widget lays out in its own width/height.
    property string size: "small"
    // False while the widget is not visible (gallery closed, Center closed): stop timers and sampling.
    property bool active: true
    // True for the gallery's preview of a widget that is not placed: a widget whose data costs a network read (Weather) shows
    // what is already known and never asks for more (ADR-0045 OC-14: fetched only while placed).
    property bool preview: false
    // Appearance and motion settings, mirrored from the shell.
    property bool dark: Appearance.dark
    property bool reduceMotion: Appearance.reduceMotion
    // True in the nested development session (GRASSFIELD_DEV=1): actions that reach the owner's real apps are suppressed.
    readonly property bool devSession: Mode.dev

    // Inner padding of the tile (a token).
    readonly property real padding: Tokens.spacingLg
    readonly property bool isSmall: size === "small"
    readonly property bool isMedium: size === "medium"
    readonly property bool isLarge: size === "large"
}
