pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import qs.services
import "StatusLogic.js" as Logic

// A third-party status item (StatusNotifierItem) in the menu bar. The app's own icon at the bar's icon size, a dot
// while it needs attention, its title as the accessible name. Left press: the menu or Activate (StatusLogic.clickAction),
// right press: the menu, middle press: SecondaryActivate, wheel: Scroll. Menus open as popup kind "tray".
BarButton {
    id: root

    // The Quickshell SystemTrayItem; the delegate's identity is this object (service and path), never its id.
    required property var item
    // The bar window (MenuBar's PanelWindow): menu bookkeeping.
    required property var bar

    objectName: "menubar-tray"
    padding: Tokens.menubarStatusItemPadding
    accessibleName: Logic.accessibleName(root.item)
    opensMenu: Logic.opensMenu(root.item)
    active: root.bar.isOpen("tray") && Popups.data.item === root.item

    function perform(button: string): void {
        if (!root.item)
            return;
        switch (Logic.clickAction(root.item, button)) {
        case "menu":
            root.bar.openTray(root, root.item);
            break;
        case "activate":
            Popups.close();
            root.item.activate();
            break;
        case "secondary":
            Popups.close();
            root.item.secondaryActivate();
            break;
        }
    }

    onActivated: root.perform("left")
    onAuxPressed: button => root.perform(button)
    onEntered: root.bar.hoverSwitchTray(root, root.item)
    onScrolled: delta => {
        if (root.item)
            root.item.scroll(delta, false);
    }
    onScrolledHorizontally: delta => {
        if (root.item)
            root.item.scroll(delta, true);
    }

    Item {
        width: Tokens.menubarIconSize
        height: Tokens.menubarIconSize

        Image {
            anchors.fill: parent
            // The item can already be gone while its delegate is being removed.
            source: root.item ? root.item.icon : ""
            sourceSize: Qt.size(Tokens.menubarIconSize * 2, Tokens.menubarIconSize * 2)
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            smooth: true
        }

        // Needs attention (SNI NeedsAttention): a dot at the corner.
        Rectangle {
            visible: Logic.needsAttention(root.item)
            width: Tokens.menubarIconSize / 3
            height: width
            radius: width / 2
            anchors {
                right: parent.right
                top: parent.top
            }
            color: Appearance.colors.accent
        }
    }
}
