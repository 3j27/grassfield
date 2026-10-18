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

public:
    explicit Backend(QObject *parent = nullptr);
    ~Backend() override;

    QString configFile() const { return m_configFile; }
    QString qtVersion() const;
    QString appVersion() const;
    QString bindingsFile() const { return m_bindingsFile; }
    bool devSession() const { return m_dev; }

    // {exists: bool, ok: bool, text: string}. Reads at most 4 MiB.
    Q_INVOKABLE QVariantMap readText(const QString &path) const;
    // Atomic replace (QSaveFile); creates the directory. Returns "" on success, else an error message.
    Q_INVOKABLE QString writeText(const QString &path, const QString &text) const;
    // Run a program with an argument vector (no shell), 3 s timeout. Returns stdout, "" on any failure.
    Q_INVOKABLE QString run(const QStringList &argv) const;
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
    void suppressed(const QString &what);

private:
    void onPath(const QString &path);
    void start(const QStringList &argv, const QString &tag, int timeoutMs);

    QString m_configFile;
    QString m_bindingsFile;
    bool m_dev;
    QFileSystemWatcher m_watcher;
    QStringList m_watched;
};
