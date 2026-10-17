#pragma once

// Start-up guards of grassfield-menu-bridge (master-prompt §3 R3, ADR-0008 "Development").
//
// Owning com.canonical.AppMenu.Registrar makes Qt and Chromium hide their in-window menu bars. On the owner's
// real session bus during development that would strip the menus of every Qt/Chromium app of the owner's
// session, so with GRASSFIELD_DEV=1 the bridge refuses the default session bus (/run/user/<uid>/bus).

#include <QString>

namespace gf::menubridge {

    // True when DBUS_SESSION_BUS_ADDRESS `address` is (or falls back to) the user's default session bus: empty
    // (libdbus then uses $XDG_RUNTIME_DIR/bus), any "unix:" entry with path=/run/user/<uid>/bus or runtime=yes,
    // or an "autolaunch:" entry. A private bus (dbus-run-session, dbus-daemon --address=unix:tmpdir=...) is false.
    bool isDefaultSessionBus(const QString& address, uint uid);

    // The bridge socket: `overridePath` (GRASSFIELD_MENU_BRIDGE_SOCKET) when set, else
    // <runtimeDir>/grassfield/menu-bridge.sock; empty when neither is usable (relative paths are refused).
    QString socketPath(const QString& overridePath, const QString& runtimeDir);

    // An AF_UNIX path fits sockaddr_un.sun_path (107 bytes plus the terminating NUL).
    bool fitsSocketPath(const QString& path);

    // Creates the socket's directory with mode 0700 if needed. An existing directory must be a real directory (not
    // a symlink) owned by this user; group/other permission bits are removed. Returns an error text, empty on success.
    QString prepareSocketDirectory(const QString& socketPath);

} // namespace gf::menubridge
