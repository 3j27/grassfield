#pragma once

// menu/1: JSON lines between grassfield-shell and grassfield-menu-bridge (ADR-0008, docs/specs/menu-bridge.md).
// Pure logic (QtCore only), unit-tested in tests/unit/menu-bridge/.
//
// shell -> bridge (one JSON object per line, at most limits::kShellLine bytes):
//   {"type":"hello","v":"menu/1","appmenu":true|false}
//   {"type":"open","window":"<hex>","service":"<bus name>","path":"<object path>","pid":N}
//   {"type":"open-registered","window":"<hex>","pid":N}
//       (additive, ADR-0008 amendment 2026-10-25: the window has no set_address registration and its Wayland client is
//        pid N; open the menu that process registered with com.canonical.AppMenu.Registrar, e.g. Electron's)
//   {"type":"about-to-show","window":"<hex>","id":N}
//   {"type":"activate","window":"<hex>","id":N}
//   {"type":"close","window":"<hex>"}
//   {"type":"lock","locked":true|false}
//       (additive, ADR-0052: the session's lock state; until the first one of a connection the bridge counts it locked and
//        sends ongoing activities redacted)
//   {"type":"ongoing-action","id":"<16 hex>","action":"<action id>"}
//       (additive, ADR-0052: the user clicked button `action` of activity `id`; refused while locked)
// bridge -> shell:
//   {"type":"status","v":"menu/1","state":"standby"|"active","registrar":true|false}
//   {"type":"menu","window":"<hex>","revision":N,"items":[...]}      (items: see Layout.h)
//   {"type":"error","window":"<hex>"|"","code":"<code>","message":"<text>"}
//   {"type":"launcher","app":"<desktop id>","count":N|null,"progress":P|null,"urgent":true|false|null}
//       (additive, ADR-0018, Launcher.h: an application's own Dock badge, progress and attention hint, from
//        com.canonical.Unity.LauncherEntry. null: the update did not touch the value. count 0 hides the badge,
//        progress -1 hides the bar; all three null: forget the app, the sender left the bus.)
//   {"type":"screensaver","inhibited":true|false,"count":N}
//       (additive, GF-016, ScreenSaver.h: applications hold org.freedesktop.ScreenSaver idle inhibitors; sent on every
//        change and when a shell connects. The shell's idle module neither dims nor locks on idle while true.)
//   {"type":"ongoing","id":"<16 hex>","app":"<desktop id>","kind":"<kind>","title":"...","subtitle":"...","progress":P|null,
//    "started":ms|null,"ends":ms|null,"actions":[{"id":"...","label":"..."}],"redacted":true|false}
//   {"type":"ongoing-end","id":"<16 hex>"}
//       (additive, ADR-0052, Ongoing.h: applications' ongoing activities over org.grassfield.Ongoing1; replayed when a shell
//        connects; redacted (no app, text or action) while the shell reports the session locked)
//
// Everything the shell sends is untrusted: every field is type- and range-checked, unknown types are refused.

#include <QByteArray>
#include <QJsonArray>
#include <QString>
#include <QStringView>

#include <optional>

#ifndef GRASSFIELD_VERSION
#define GRASSFIELD_VERSION "unknown" // only a build without the VERSION file's definition
#endif

namespace gf::menubridge {

    inline constexpr char kProtocol[]      = "menu/1";
    // The product version, from the VERSION file (cmake/GrassfieldVersion.cmake, build-direct.sh).
    inline constexpr char kBridgeVersion[] = GRASSFIELD_VERSION;

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
    // ADR-0052: an ongoing activity's key (16 lowercase hex digits) and an action id ([a-z][a-z0-9-]{0,31}).
    bool isValidOngoingKey(QStringView key);
    bool isValidOngoingAction(QStringView action);

    struct ShellMessage {
        enum class Type {
            Hello,
            Open,
            OpenRegistered,
            AboutToShow,
            Activate,
            Close,
            Lock,          // ADR-0052
            OngoingAction, // ADR-0052
        };
        Type    type    = Type::Hello;
        bool    appmenu = false; // hello: the plugin advertises "appmenu" and the menu bar renders bridge menus
        QString window;          // lowercase hex (open, open-registered, about-to-show, activate, close)
        QString service;         // open
        QString path;            // open
        qint64  pid = 0;         // open, open-registered: > 0
        int     id  = 0;         // about-to-show, activate: >= 0
        bool    locked = true;   // lock
        QString ongoing;         // ongoing-action: the activity's key (16 lowercase hex digits)
        QString action;          // ongoing-action: [a-z][a-z0-9-]{0,31}
    };

    // Parses and validates one line (without its newline). On failure returns nullopt and sets *error to a short
    // code: "too-long", "parse", "type", "version" or "field:<name>".
    std::optional<ShellMessage> parseShellMessage(const QByteArray& line, QString* error);

    // Bridge -> shell lines, each ending with '\n'.
    QByteArray menuMessage(const QString& window, quint32 revision, const QJsonArray& items);
    QByteArray errorMessage(const QString& window, const QString& code, const QString& message);
    QByteArray statusMessage(const QString& state, bool registrar);
    QByteArray launcherMessage(const QString& app, std::optional<qint64> count, std::optional<double> progress, std::optional<bool> urgent);
    // {"type":"screensaver","inhibited":true|false,"count":N} (additive, GF-016, ScreenSaver.h): applications hold
    // org.freedesktop.ScreenSaver idle inhibitors (N cookies, capped at 1024 in the line).
    QByteArray screensaverMessage(bool inhibited, int count);

} // namespace gf::menubridge
