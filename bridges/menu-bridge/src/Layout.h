#pragma once

// DBusMenu layouts (com.canonical.dbusmenu) -> menu/1 items. The application's data is untrusted: depth, item count
// and string lengths are capped, labels are reduced to plain text.
//
// A menu/1 item (JSON object):
//   {"id":N, "type":"standard"|"separator", "label":"<plain text>", "enabled":bool, "visible":bool,
//    "toggle-type":""|"checkmark"|"radio", "toggle-state":-1|0|1, "shortcut":[["Control","N"],...],
//    "icon-name":"<freedesktop icon name>", "submenu":bool, "children":[items...]}
// "submenu" is true when the item opens a submenu (children-display "submenu" or children present); its children
// may be empty while the application fills it lazily (AboutToShow), or when the depth cap was reached.

#include "Protocol.h"

#include <QJsonArray>
#include <QJsonObject>
#include <QList>
#include <QSet>
#include <QString>
#include <QVariantMap>

class QDBusArgument;
class QDBusMessage;

namespace gf::menubridge {

    // One DBusMenu layout node "(ia{sv}av)" as read from D-Bus. Property values are plain QVariants; "shortcut"
    // (D-Bus "aas") is converted to a QVariantList of QStringList by readLayout.
    struct RawItem {
        int            id = 0;
        QVariantMap    properties;
        QList<RawItem> children;
    };

    // Shared item budget of one tree; `truncated` records that something was dropped by a cap.
    struct LayoutBudget {
        int  items     = limits::kItems;
        bool truncated = false;
    };

    // Reads a layout node. False (and `out` unspecified) when the argument is not a "(ia{sv}av)" structure. Children
    // deeper than limits::kDepth or beyond the item budget are skipped.
    bool readLayout(const QDBusArgument& arg, RawItem& out, int depth, LayoutBudget& budget);

    // DBusMenu label -> plain text: "_" marks the mnemonic ("__" is a literal underscore), control and bidirectional
    // formatting characters are removed, whitespace runs become one space, at most limits::kLabel characters.
    QString plainLabel(const QString& label);

    // The children of `root` (normally item 0) as menu/1 items.
    QJsonArray mapChildren(const RawItem& root, LayoutBudget& budget);

    // Ids of a mapped tree the shell may act on: activatable leaves (enabled, visible, not separators, no submenu)
    // and submenus (for AboutToShow). The root (0) is always a submenu.
    struct ItemIndex {
        QSet<int> activatable;
        QSet<int> submenus{0};
    };
    ItemIndex indexItems(const QJsonArray& items);

    // The DBusMenu calls the bridge makes, with explicit argument types (Chromium exports no introspection data, so
    // untyped calls are rejected):
    //   GetLayout(int32 0, int32 -1, as [])                      signature "iias"
    //   AboutToShow(int32 id)                                    signature "i"
    //   Event(int32 id, "clicked", variant<int32 0>, uint32 0)   signature "isvu" (no X11 timestamp on Wayland)
    QDBusMessage getLayoutCall(const QString& service, const QString& path);
    QDBusMessage aboutToShowCall(const QString& service, const QString& path, int id);
    QDBusMessage eventCall(const QString& service, const QString& path, int id);

} // namespace gf::menubridge
