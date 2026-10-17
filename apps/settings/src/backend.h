#pragma once

#include <QFileSystemWatcher>
#include <QObject>
#include <QString>
#include <QStringList>
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

public:
    explicit Backend(QObject *parent = nullptr);

    QString configFile() const { return m_configFile; }
    QString qtVersion() const;
    QString appVersion() const;
    QString bindingsFile() const { return m_bindingsFile; }

    // {exists: bool, ok: bool, text: string}. Reads at most 4 MiB.
    Q_INVOKABLE QVariantMap readText(const QString &path) const;
    // Atomic replace (QSaveFile); creates the directory. Returns "" on success, else an error message.
    Q_INVOKABLE QString writeText(const QString &path, const QString &text) const;
    // Run a program with an argument vector (no shell), 3 s timeout. Returns stdout, "" on any failure.
    Q_INVOKABLE QString run(const QStringList &argv) const;
    // Emit fileChanged(path) whenever the file is created, replaced, changed or removed.
    Q_INVOKABLE bool watch(const QString &path);

signals:
    void fileChanged(const QString &path);

private:
    void onPath(const QString &path);

    QString m_configFile;
    QString m_bindingsFile;
    QFileSystemWatcher m_watcher;
    QStringList m_watched;
};
