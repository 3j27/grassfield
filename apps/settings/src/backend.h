#pragma once

#include <QDir>
#include <QFileSystemWatcher>

#include <functional>
#include <memory>

#include "busjobs.h"
#include "systembus.h"

#include "chromecaps.h"
#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariantList>
#include <QVariantMap>

// File and process access for the Settings QML. Deliberately small and generic: all settings logic
// (validation, merge) lives in qml/Store.js.
class Backend : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString configFile READ configFile CONSTANT)
    Q_PROPERTY(QString qtVersion READ qtVersion CONSTANT)
    Q_PROPERTY(QString appVersion READ appVersion CONSTANT)
    Q_PROPERTY(QString bindingsFile READ bindingsFile CONSTANT)
    // The shell's capabilities file (apps/chromecaps.h, ADR-0015 Q4b), read from QML through readText() and watch().
    Q_PROPERTY(QString capabilitiesFile READ capabilitiesFile CONSTANT)
    // GRASSFIELD_DEV=1: the system sections show state but never act on the owner's machine (systemguard.h).
    Q_PROPERTY(bool devSession READ devSession CONSTANT)
    // Wallpaper (ADR-0016): the helper, its cache, the folder of the Pictures section and the files the shell and this app
    // share. In a dev session everything is under the worktree's .dev (devRoot is the worktree, "" otherwise).
    Q_PROPERTY(QString wallpaperTool READ wallpaperTool CONSTANT)
    Q_PROPERTY(QString wallpaperCache READ wallpaperCache CONSTANT)
    Q_PROPERTY(QString picturesDir READ picturesDir CONSTANT)
    Q_PROPERTY(QString devRoot READ devRoot CONSTANT)
    Q_PROPERTY(QString wallpaperStatusFile READ wallpaperStatusFile CONSTANT)
    Q_PROPERTY(QString wallpaperRecentFile READ wallpaperRecentFile CONSTANT)
    // Login Items: the user's autostart folder and the system's (read-only); the applications one can add ($XDG_DATA_HOME and
    // $XDG_DATA_DIRS, each with applications/, the user's first); the session's desktops (XDG_CURRENT_DESKTOP, for OnlyShowIn).
    Q_PROPERTY(QString autostartDir READ autostartDir CONSTANT)
    Q_PROPERTY(QStringList systemAutostartDirs READ systemAutostartDirs CONSTANT)
    Q_PROPERTY(QStringList applicationDirs READ applicationDirs CONSTANT)
    Q_PROPERTY(QStringList currentDesktops READ currentDesktops CONSTANT)
    // Storage: the folders whose size the pane shows lie in the home.
    Q_PROPERTY(QString homeDir READ homeDir CONSTANT)
    // Language & Region: Omarchy's language command is installed (found on PATH, not run; Omarchy 4.0.4 has none).
    Q_PROPERTY(bool omarchyLanguage READ omarchyLanguage CONSTANT)
    // The actions that may wait for a password and still run, tag -> what (polkit actions of busAct, omarchy-language of act:
    // one per tag, busjobs.h InFlight). A page shows its waiting state from it, also when it is opened again while the dialog
    // is up.
    Q_PROPERTY(QVariantMap pendingActions READ pendingActions NOTIFY pendingActionsChanged)

public:
    explicit Backend(QObject *parent = nullptr);
    ~Backend() override;

    QString configFile() const { return m_configFile; }
    QString qtVersion() const;
    QString appVersion() const;
    QString bindingsFile() const { return m_bindingsFile; }
    QString capabilitiesFile() const { return grassfield::apps::capabilitiesFile(); }
    bool devSession() const { return m_dev; }
    QString wallpaperTool() const { return m_wallpaperTool; }
    QString wallpaperCache() const { return m_wallpaperCache; }
    QString picturesDir() const { return m_picturesDir; }
    QString devRoot() const { return m_devRoot; }
    QString wallpaperStatusFile() const;
    QString wallpaperRecentFile() const;
    QString autostartDir() const;
    QStringList systemAutostartDirs() const;
    QStringList applicationDirs() const;
    QStringList currentDesktops() const;
    QString homeDir() const { return QDir::cleanPath(QDir::homePath()); }
    bool omarchyLanguage() const;
    QVariantMap pendingActions() const { return m_actions.map(); }

    // {exists: bool, ok: bool, text: string}. Reads at most 4 MiB.
    Q_INVOKABLE QVariantMap readText(const QString &path) const;
    // Atomic replace (QSaveFile); creates the directory. Returns "" on success, else an error message.
    Q_INVOKABLE QString writeText(const QString &path, const QString &text) const;
    // Run one of the read-only queries of systemguard.h::isReadOnlyQuery synchronously (no shell, 3 s timeout, C locale).
    // Returns stdout, "" on any failure and for any command outside that list, in dev and real sessions alike.
    Q_INVOKABLE QString run(const QStringList &argv) const;
    // Every command (query, act, run) runs with LC_ALL=C and LANG=C (LANGUAGE unset): the parsers expect English output.
    // Read-only query without blocking the window: runs argv (no shell), emits finished(tag, ok, stdout). In a dev
    // session only the queries of systemguard.h::isReadOnlyQuery run; anything else is refused (logged, finished(false)).
    // The same command still running under the same tag is not started again: its answer comes under that tag.
    Q_INVOKABLE void query(const QStringList &argv, const QString &tag, int timeoutMs = 5000);
    // State-changing action (Wi-Fi, Bluetooth, volume). Only nmcli, bluetoothctl and wpctl run. In a dev session
    // nothing runs: one "dev guard: <what> suppressed" line is logged, suppressed(what) is emitted, false returned.
    // Otherwise finished(tag, ok, stdout) follows the command and true is returned when it started. An action that may wait
    // for a password is refused (false) while one of its tag still runs (pendingActions); busAct does the same for polkit.
    Q_INVOKABLE bool act(const QString &what, const QStringList &argv, const QString &tag, int timeoutMs = 15000);
    // Wi-Fi and Bluetooth over D-Bus (systembus.h): NetworkManager and BlueZ on the system bus, on a worker thread each, the
    // answer as finished(tag, ok, json) (failed(tag, reason) first when it did not work). `what`: "wifi.state" or "bt.state"
    // (read-only, also in a dev session); for General "host.state", "time.state", "time.zones", "locale.state" (system bus) and
    // "user.units" (the session bus: the user's own services). busAct is the state-changing counterpart of act(): `op` is {op: "wifi.radio", on: true}
    // and the like (systembus.h runAction); in a dev session nothing is sent (one "dev guard: <what> suppressed" line,
    // suppressed(what), false returned); an op that is not well formed is refused (false).
    Q_INVOKABLE void busQuery(const QString &what, const QString &tag);
    Q_INVOKABLE bool busAct(const QString &what, const QVariantMap &op, const QString &tag);
    // The outputs the compositor reports to this client (Qt screens): [{name, model, manufacturer, x, y, width,
    // height, scale, pixelWidth, pixelHeight, refreshRate, physicalWidth, physicalHeight (mm), primary}]. Read-only; never
    // talks to Hyprland.
    Q_INVOKABLE QVariantList screens() const;
    // Mounted local volumes (Storage, About): [{root, name, device, type, total, available, free, readOnly, isRoot, holdsHome}],
    // the start-up volume first. Read-only; never a network or FUSE mount, whose statfs could block this thread
    // (systemguard.h isLocalVolume).
    Q_INVOKABLE QVariantList volumes() const;
    // Date & Time: a zone's names in the UI language {longName, shortName, offset, offsetSeconds, territory}; {} for a zone Qt
    // does not know.
    Q_INVOKABLE QVariantMap zoneInfo(const QString &zone) const;
    // Language & Region: the regions of the UI language, as [{name: "fr_CH", territory: "Suisse"}] sorted by the territory's
    // name (Qt's locale data: what region.formats can hold for this language).
    Q_INVOKABLE QVariantList regionLocales() const;
    // Login Items (XDG autostart): the .desktop file names of a folder; the user's folder ($XDG_CONFIG_HOME/autostart) and the
    // system's ($XDG_CONFIG_DIRS/autostart). Writes go only to the user's folder, one plain <name>.desktop at a time, and in a dev
    // session only when that folder lies under the worktree's .dev (writeAutostart, removeAutostart: "" or a reason).
    Q_INVOKABLE QStringList desktopEntries(const QString &dir) const;
    Q_INVOKABLE QString writeAutostart(const QString &path, const QString &text) const;
    Q_INVOKABLE QString removeAutostart(const QString &path) const;
    // Emit fileChanged(path) whenever the file is created, replaced, changed or removed.
    Q_INVOKABLE bool watch(const QString &path);

signals:
    void fileChanged(const QString &path);
    void finished(const QString &tag, bool ok, const QString &output);
    // Emitted just before finished(tag, false, ...): a short single-line reason (stderr, else stdout, "timed out",
    // or the start error), at most 160 characters. Plain text from a tool: show it as text only.
    void failed(const QString &tag, const QString &reason);
    void suppressed(const QString &what);
    void pendingActionsChanged();

private:
    bool wallpaperAllowed(const QStringList &argv) const;
    void onPath(const QString &path);
    // What a process ends when it finishes: nothing, its query (m_queries) or its action (m_actions).
    enum class Track { None, Query, Action };
    void start(const QStringList &argv, const QString &tag, int timeoutMs, Track track);
    void runBus(const QString &tag, std::function<QString(grassfield::settings::BusCaller &, QString *)> job, int timeoutMs, bool session = false,
                bool action = false);
    bool beginAction(const QString &tag, const QString &what);
    void endAction(const QString &tag);
    grassfield::settings::InFlight m_actions;
    grassfield::settings::InFlight m_queries;
    QStringList userUnitDirs() const;
    bool autostartWriteAllowed(const QString &path) const;

    QString m_configFile;
    QString m_bindingsFile;
    bool m_dev;
    QString m_wallpaperTool;
    QString m_wallpaperCache;
    QString m_picturesDir;
    QString m_devRoot;
    QFileSystemWatcher m_watcher;
    QStringList m_watched;
    struct Bus; // the system bus connection and the D-Bus jobs (busjobs.h), in backend.cpp
    std::unique_ptr<Bus> m_bus;
};
