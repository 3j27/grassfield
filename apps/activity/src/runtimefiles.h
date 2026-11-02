// The files Activity Monitor shares with the shell in the display's runtime folder (ADR-0038 f, AD29; spec AM60, AM62,
// Terms): the shell's projection, which the app reads, and the Dock tile's graph, which the app writes (step 3). A file
// names its writer by pid and start time; a reader ignores one whose writer is not that process any more, or that is not
// what its version says (too long, a value of the wrong type).
#pragma once

#include <QByteArray>
#include <QFileSystemWatcher>
#include <QHash>
#include <QObject>
#include <QSet>
#include <QString>
#include <QTimer>
#include <QVariantList>

#include <string>

namespace activity {

// $XDG_RUNTIME_DIR/grassfield/activity-<display>, <display> the last part of WAYLAND_DISPLAY with every character outside
// [A-Za-z0-9._-] replaced by "_" (as the shell's ActivityLinkLogic.runtimeDir); "" without either.
QString runtimeFolder(const QString &xdgRuntimeDir, const QString &waylandDisplay);
QString runtimeFolder(); // from the environment

// The writer a runtime file names is alive: a process of that pid whose stat start time (field 22) is that one.
bool writerAlive(const std::string &procRoot, qint64 pid, quint64 start);

// AM60's projection, as the app uses it.
struct Projection {
    bool valid = false;            // a file of version 1 from a live writer
    QHash<int, QString> apps;      // a window's client pid → its app id (the first window's)
    QSet<int> idleInhibitors;      // pids of a window that inhibits idle
    QSet<int> notResponding;       // pids NotResponding marks
    bool operator==(const Projection &o) const
    {
        return valid == o.valid && apps == o.apps && idleInhibitors == o.idleInhibitors && notResponding == o.notResponding;
    }
    bool operator!=(const Projection &o) const { return !(*this == o); }
};

// The largest projection read (AM60: 256 windows fit in far less).
constexpr qint64 kProjectionMax = 64 * 1024;

// A projection's text: version 1, an object of the types AM60 gives, at most 256 windows, from a live writer; anything else
// is no projection (valid false).
Projection parseProjection(const QByteArray &text, const std::string &procRoot);

// AM62: the Dock tile's graph, `dock-tile.json`: {"v":1,"writer":{pid,start},"kind","samples"} with at most 32 samples, each a
// number or a pair in [0, 1] (three decimals), at most 2 KiB. Written 0600 in the 0700 folder through a temporary name;
// removed when the icon is chosen again and when the app quits. The Dock draws it on this app's tile alone.
constexpr int kDockTileSamples = 32;
constexpr qint64 kDockTileMax = 2048;
QByteArray dockTileText(qint64 pid, quint64 start, const QString &kind, const QVariantList &samples);
bool writeDockTile(const QString &folder, const QByteArray &text);
void removeDockTile(const QString &folder);
// This process's start time (stat field 22), the writer's.
quint64 ownStartTime(const std::string &procRoot = "/proc");

// Watches the projection (the folder for its arrival, the file for its changes; inotify through QFileSystemWatcher, no
// polling) and reads it again; `recheck()` reads it again too (the writer may have ended without a change to the file).
class ProjectionWatch : public QObject
{
    Q_OBJECT

public:
    ProjectionWatch(QString folder, std::string procRoot, QObject *parent = nullptr);
    const Projection &projection() const { return m_projection; }
    QString file() const;
    void recheck();

signals:
    void changed();

private:
    void read();

    QString m_folder;
    std::string m_procRoot;
    QFileSystemWatcher m_watcher;
    QTimer m_settle; // a burst of changes (the rename into place) read once
    Projection m_projection;
};

} // namespace activity
