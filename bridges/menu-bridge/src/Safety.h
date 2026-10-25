#pragma once

// Start-up guards of grassfield-menu-bridge (master-prompt §3 R3, ADR-0008 "Development").
//
// Owning com.canonical.AppMenu.Registrar makes Qt and Chromium hide their in-window menu bars. On the owner's
// real session bus during development that would strip the menus of every Qt/Chromium app of the owner's
// session, so in a development run (devRun below) the bridge refuses the default session bus (/run/user/<uid>/bus).

#include <QByteArray>
#include <QString>

namespace gf::menubridge {

    // The run mode (ADR-0019), the rule every Grassfield component uses, read by the bridge itself (a process boundary):
    // a development run is GRASSFIELD_DEV == "1" while GRASSFIELD_SESSION != "1"; only the exact string "1" counts.
    // A GRASSFIELD_DEV=1 that leaked into a Grassfield session changes nothing: the bridge runs as in any session
    // (before, it took the development branch, refused the session's default bus and global menus stopped). The values
    // are the raw environment strings (unset reads as empty). Shared vectors: tests/fixtures/run-mode-vectors.json.
    bool devRun(const QByteArray& devValue, const QByteArray& sessionValue);

    // A Grassfield session: GRASSFIELD_SESSION == "1".
    bool sessionRun(const QByteArray& sessionValue);

    // The pid namespace depth of a process from the text of its /proc/<pid>/status: the number of pids on its "NSpid:"
    // line (1 in the initial namespace, one more per nested namespace); 0 when the line is missing or malformed.
    int nsPidDepth(const QByteArray& statusText);

    // A process the bridge may serve a registrar menu for (ADR-0008 amendment 2026-10-25): its pid namespace is as deep
    // as the bridge's own (a sandbox in a nested namespace, a Flatpak app, is refused). False when either status cannot
    // be read.
    bool inBridgePidNamespace(qint64 pid);

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
