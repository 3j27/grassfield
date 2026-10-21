#pragma once

#include <QFileSystemWatcher>
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

public:
    explicit Backend(QObject *parent = nullptr);
    ~Backend() override;

    QString configFile() const { return m_configFile; }
    QString qtVersion() const;
    QString appVersion() const;
    QString bindingsFile() const { return m_bindingsFile; }
    bool devSession() const { return m_dev; }
    QString wallpaperTool() const { return m_wallpaperTool; }
    QString wallpaperCache() const { return m_wallpaperCache; }
    QString picturesDir() const { return m_picturesDir; }
    QString devRoot() const { return m_devRoot; }
    QString wallpaperStatusFile() const;
    QString wallpaperRecentFile() const;

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
    Q_INVOKABLE void query(const QStringList &argv, const QString &tag, int timeoutMs = 5000);
    // State-changing action (Wi-Fi, Bluetooth, volume). Only nmcli, bluetoothctl and wpctl run. In a dev session
    // nothing runs: one "dev guard: <what> suppressed" line is logged, suppressed(what) is emitted, false returned.
    // Otherwise finished(tag, ok, stdout) follows the command and true is returned when it started.
    Q_INVOKABLE bool act(const QString &what, const QStringList &argv, const QString &tag, int timeoutMs = 15000);
    // The outputs the compositor reports to this client (Qt screens): [{name, model, manufacturer, x, y, width,
    // height, scale, pixelWidth, pixelHeight, refreshRate, primary}]. Read-only; never talks to Hyprland.
    Q_INVOKABLE QVariantList screens() const;
    // Emit fileChanged(path) whenever the file is created, replaced, changed or removed.
    Q_INVOKABLE bool watch(const QString &path);

signals:
    void fileChanged(const QString &path);
    void finished(const QString &tag, bool ok, const QString &output);
    // Emitted just before finished(tag, false, ...): a short single-line reason (stderr, else stdout, "timed out",
    // or the start error), at most 160 characters. Plain text from a tool: show it as text only.
    void failed(const QString &tag, const QString &reason);
    void suppressed(const QString &what);

private:
    bool wallpaperAllowed(const QStringList &argv) const;
    void onPath(const QString &path);
    void start(const QStringList &argv, const QString &tag, int timeoutMs);

    QString m_configFile;
    QString m_bindingsFile;
    bool m_dev;
    QString m_wallpaperTool;
    QString m_wallpaperCache;
    QString m_picturesDir;
    QString m_devRoot;
    QFileSystemWatcher m_watcher;
    QStringList m_watched;
};
