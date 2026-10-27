// org.freedesktop.impl.portal.Settings for the Grassfield session (ADR-0035 D-8, step 2b): the values of portalvalues.h, read
// from grassfield.json when it changes (and each minute for the "auto" schedule), answered from memory: a call never reads a
// file and never blocks (GTK 3 apps call ReadAll synchronously while they start). Every change becomes SettingChanged signals,
// one per key whose value changed. Keys it does not own answer NotFound, so the frontend asks the next backend (x-d-p-gtk).
#pragma once

#include "portalvalues.h"

#include <QDBusArgument>
#include <QDBusConnection>
#include <QDBusContext>
#include <QDBusVariant>
#include <QFileSystemWatcher>
#include <QMap>
#include <QMutex>
#include <QObject>
#include <QTimer>
#include <QVariantMap>

#include <cstdint>
#include <functional>
#include <memory>

class QEventLoop;

// accent-color: "(ddd)", sRGB 0..1.
struct AccentColor {
    double red = 0;
    double green = 0;
    double blue = 0;
    bool operator==(const AccentColor &other) const { return red == other.red && green == other.green && blue == other.blue; }
};
Q_DECLARE_METATYPE(AccentColor)
QDBusArgument &operator<<(QDBusArgument &argument, const AccentColor &color);
const QDBusArgument &operator>>(const QDBusArgument &argument, AccentColor &color);

namespace grassfield::portal {

using SettingsMap = QMap<QString, QVariantMap>; // a{sa{sv}}: namespace -> key -> value

// One read of grassfield.json, made on a worker thread: what it says, and where to watch for its next change.
enum class FileState : std::uint8_t { Read, Missing, Malformed };
struct FileRead {
    FileState state = FileState::Missing;
    Input input;
    QString watchDir;        // the file's directory, or its nearest existing parent while it does not exist yet
    bool fileExists = false;
};
// The read of ADR-0020 §2 (settingsbackend.cpp): never without a bound; a missing file is Missing, anything unusable Malformed.
FileRead readSettingsFile(const QString &path);

class SettingsBackend : public QObject, protected QDBusContext
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.freedesktop.impl.portal.Settings")
    Q_PROPERTY(uint version READ version CONSTANT)

public:
    struct Options {
        QString configFile;                // grassfield.json
        int recheckMs = 60000;             // the "auto" schedule's resolution (apps/autoappearance.h kAutoRecheckMs)
        std::function<QTime()> clock;      // the local time (a fixed one in tests)
        // One read of the file, on a worker thread (the tests pass one that hangs or counts).
        std::function<FileRead(const QString &)> reader = readSettingsFile;
        int readCutMs = 5000;              // ADR-0020 §2: a read that takes longer is not waited for (logged once)
        int startWaitMs = 3000;            // how long the start waits for the first read (the unit allows 5 s)
    };
    // Reads the file once, waiting at most startWaitMs for it (the schema's defaults until it answers).
    explicit SettingsBackend(Options options, QObject *parent = nullptr);
    ~SettingsBackend() override;

    uint version() const { return 1; }
    // Every namespace and key this backend owns, for these values.
    static SettingsMap toMap(const Values &values);
    // SettingChanged once for every key, with its current value: called once the bus name is owned, so that a change made
    // while a crashed backend was restarting still reaches the apps (they ignore a value they already have).
    void announceAll();
    // The frontend passes every backend's SettingChanged on to the apps, so a dconf change that x-d-p-gtk signals (a theme
    // tool writing gtk-theme or color-scheme) would switch them away from Grassfield's values until they restart. For a key
    // this backend owns and a value that differs from its own, it answers x-d-p-gtk's signal with its own value, which the
    // apps then receive last.
    void answerOtherBackends(const QDBusConnection &bus);

public Q_SLOTS:
    SettingsMap ReadAll(const QStringList &namespaces);
    QDBusVariant Read(const QString &ns, const QString &key);

Q_SIGNALS:
    void SettingChanged(const QString &ns, const QString &key, const QDBusVariant &value);

private Q_SLOTS:
    void otherBackendChanged(const QString &ns, const QString &key, const QDBusVariant &value);

private:
    void startRead();
    void readDone(const FileRead &read);
    void watch(const FileRead &read);
    void recompute();

    // Shared with the worker threads: a read that answers after this object is gone posts nothing.
    struct Alive {
        QMutex mutex;
        bool alive = true;
    };

    Options m_options;
    Input m_input; // the last good settings of the file
    QFileSystemWatcher m_watcher;
    QTimer m_debounce;
    QTimer m_recheck;
    QTimer m_cut;
    std::shared_ptr<Alive> m_alive = std::make_shared<Alive>();
    bool m_reading = false;   // a read is on its way (at most one at a time)
    bool m_readAgain = false; // a change came during it: read once more when it answers
    bool m_hung = false;      // the read in flight passed readCutMs
    QEventLoop *m_startLoop = nullptr;
    Values m_values;
    SettingsMap m_map;
};

} // namespace grassfield::portal
