#pragma once

// menu/1: JSON lines between grassfield-shell and grassfield-menu-bridge (ADR-0008, docs/specs/menu-bridge.md).
// Pure logic (QtCore only), unit-tested in tests/unit/menu-bridge/.
//
// shell -> bridge (one JSON object per line, at most limits::kShellLine bytes):
//   {"type":"hello","v":"menu/1","appmenu":true|false}
//   {"type":"open","window":"<hex>","service":"<bus name>","path":"<object path>","pid":N}
//   {"type":"about-to-show","window":"<hex>","id":N}
//   {"type":"activate","window":"<hex>","id":N}
//   {"type":"close","window":"<hex>"}
// bridge -> shell:
//   {"type":"status","v":"menu/1","state":"standby"|"active","registrar":true|false}
//   {"type":"menu","window":"<hex>","revision":N,"items":[...]}      (items: see Layout.h)
//   {"type":"error","window":"<hex>"|"","code":"<code>","message":"<text>"}
//
// Everything the shell sends is untrusted: every field is type- and range-checked, unknown types are refused.

#include <QByteArray>
#include <QJsonArray>
#include <QString>
#include <QStringView>

#include <optional>

namespace gf::menubridge {

    inline constexpr char kProtocol[]      = "menu/1";
    inline constexpr char kBridgeVersion[] = "0.1.0";

    namespace limits {
        inline constexpr qsizetype kShellLine    = 4096; // bytes of one shell -> bridge line (newline excluded)
        inline constexpr int       kDepth        = 8;    // menu levels below the root item
        inline constexpr int       kItems        = 2000; // items in one menu tree
        inline constexpr int       kLabel        = 256;  // characters of a label (after mnemonic removal)
        inline constexpr int       kIconName     = 128;  // characters of an icon name
        inline constexpr int       kShortcuts    = 4;    // shortcuts per item
        inline constexpr int       kShortcutKeys = 6;    // keys per shortcut
        inline constexpr int       kKeyName      = 32;   // characters of one key name
        inline constexpr int       kOpenWindows  = 16;   // windows with an open menu at the same time
        inline constexpr int       kNameLength   = 255;  // D-Bus bus name / object path
        inline constexpr int       kBadLines     = 32;   // invalid lines tolerated per shell connection
    } // namespace limits

    // D-Bus bus name: unique (":1.42") or well-known ("org.kde.Foo"); same rules as the plugin (FR19).
    bool isValidBusName(QStringView name);
    // D-Bus object path: "/" or "/"-separated non-empty [A-Za-z0-9_] elements, no trailing "/".
    bool isValidObjectPath(QStringView path);
    // Hyprland window address as in gfc/1 events: 1 to 16 hex digits, no "0x".
    bool isValidWindow(QStringView window);

    struct ShellMessage {
        enum class Type {
            Hello,
            Open,
            AboutToShow,
            Activate,
            Close,
        };
        Type    type    = Type::Hello;
        bool    appmenu = false; // hello: the plugin advertises "appmenu" and the menu bar renders bridge menus
        QString window;          // lowercase hex (open, about-to-show, activate, close)
        QString service;         // open
        QString path;            // open
        qint64  pid = 0;         // open: > 0
        int     id  = 0;         // about-to-show, activate: >= 0
    };

    // Parses and validates one line (without its newline). On failure returns nullopt and sets *error to a short
    // code: "too-long", "parse", "type", "version" or "field:<name>".
    std::optional<ShellMessage> parseShellMessage(const QByteArray& line, QString* error);

    // Bridge -> shell lines, each ending with '\n'.
    QByteArray menuMessage(const QString& window, quint32 revision, const QJsonArray& items);
    QByteArray errorMessage(const QString& window, const QString& code, const QString& message);
    QByteArray statusMessage(const QString& state, bool registrar);

} // namespace gf::menubridge
