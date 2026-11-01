#include "runtimefiles.h"

#include "procparse.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QSaveFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>

#include <algorithm>
#include <fstream>
#include <sstream>
#include <sys/stat.h>
#include <unistd.h>

namespace activity {

namespace {

constexpr int kMaxWindows = 256;

// A JSON number that is a whole, positive pid (above 1: never init).
bool pidValue(const QJsonValue &v, int &pid)
{
    if (!v.isDouble())
        return false;
    const double d = v.toDouble();
    if (d != static_cast<double>(static_cast<qint64>(d)) || d <= 1 || d > 0x7fffffff)
        return false;
    pid = static_cast<int>(d);
    return true;
}

} // namespace

QString runtimeFolder(const QString &xdgRuntimeDir, const QString &waylandDisplay)
{
    if (!xdgRuntimeDir.startsWith(QLatin1Char('/')) || waylandDisplay.isEmpty())
        return QString();
    QString name = waylandDisplay.section(QLatin1Char('/'), -1);
    name.replace(QRegularExpression(QStringLiteral("[^A-Za-z0-9._-]")), QStringLiteral("_"));
    if (name.isEmpty())
        return QString();
    QString root = xdgRuntimeDir;
    while (root.size() > 1 && root.endsWith(QLatin1Char('/')))
        root.chop(1);
    return root + QStringLiteral("/grassfield/activity-") + name;
}

QString runtimeFolder()
{
    return runtimeFolder(qEnvironmentVariable("XDG_RUNTIME_DIR"), qEnvironmentVariable("WAYLAND_DISPLAY"));
}

bool writerAlive(const std::string &procRoot, qint64 pid, quint64 start)
{
    if (pid <= 1 || pid > 0x7fffffff)
        return false;
    std::ifstream f(procRoot + '/' + std::to_string(pid) + "/stat");
    std::stringstream text;
    text << f.rdbuf();
    StatFields st;
    return parseStat(text.str(), st, false) && st.pid == pid && st.starttime == start;
}

Projection parseProjection(const QByteArray &text, const std::string &procRoot)
{
    Projection p;
    if (text.size() > kProjectionMax)
        return p;
    QJsonParseError error{};
    const QJsonDocument doc = QJsonDocument::fromJson(text, &error);
    if (error.error != QJsonParseError::NoError || !doc.isObject())
        return p;
    const QJsonObject root = doc.object();
    const QJsonValue version = root.value(QStringLiteral("v"));
    const QJsonObject writer = root.value(QStringLiteral("writer")).toObject();
    const QJsonValue windows = root.value(QStringLiteral("windows")), hung = root.value(QStringLiteral("notResponding"));
    int writerPid = 0;
    const QJsonValue start = writer.value(QStringLiteral("start"));
    if (!version.isDouble() || version.toDouble() != 1 || !pidValue(writer.value(QStringLiteral("pid")), writerPid)
        || !start.isDouble() || start.toDouble() < 0 || !windows.isArray() || !hung.isArray()
        || windows.toArray().size() > kMaxWindows || hung.toArray().size() > kMaxWindows)
        return p;
    if (!writerAlive(procRoot, writerPid, static_cast<quint64>(start.toDouble())))
        return p; // stale: the shell that wrote it has ended
    for (const QJsonValue &w : windows.toArray()) {
        const QJsonObject o = w.toObject();
        int pid = 0;
        const QJsonValue app = o.value(QStringLiteral("app")), idle = o.value(QStringLiteral("idleInhibit"));
        if (!w.isObject() || !pidValue(o.value(QStringLiteral("pid")), pid) || !app.isString() || app.toString().size() > 256
            || !idle.isBool())
            return Projection{};
        if (!p.apps.contains(pid))
            p.apps.insert(pid, app.toString());
        if (idle.toBool())
            p.idleInhibitors.insert(pid);
    }
    for (const QJsonValue &h : hung.toArray()) {
        int pid = 0;
        if (!pidValue(h, pid))
            return Projection{};
        p.notResponding.insert(pid);
    }
    p.valid = true;
    return p;
}

namespace {

QByteArray number(double x)
{
    return QByteArray::number(std::clamp(x, 0.0, 1.0), 'f', 3);
}

} // namespace

QByteArray dockTileText(qint64 pid, quint64 start, const QString &kind, const QVariantList &samples)
{
    QByteArray values;
    const qsizetype first = std::max<qsizetype>(0, samples.size() - kDockTileSamples);
    for (qsizetype k = first; k < samples.size(); ++k) {
        const QVariant &v = samples.at(k);
        if (!values.isEmpty())
            values += ',';
        if (v.typeId() == QMetaType::QVariantList) {
            const QVariantList pair = v.toList();
            values += '[' + number(pair.value(0).toDouble()) + ',' + number(pair.value(1).toDouble()) + ']';
        } else {
            values += number(v.toDouble());
        }
    }
    return "{\"v\":1,\"writer\":{\"pid\":" + QByteArray::number(pid) + ",\"start\":" + QByteArray::number(start) + "},\"kind\":\""
        + kind.toLatin1() + "\",\"samples\":[" + values + "]}";
}

bool writeDockTile(const QString &folder, const QByteArray &text)
{
    if (folder.isEmpty() || text.size() > kDockTileMax || !QDir().mkpath(folder))
        return false;
    // The folder is the user's alone (AD29), whoever made it first.
    ::chmod(QFile::encodeName(folder).constData(), 0700);
    QSaveFile f(folder + QStringLiteral("/dock-tile.json"));
    if (!f.open(QIODevice::WriteOnly))
        return false;
    f.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    f.write(text);
    return f.commit();
}

void removeDockTile(const QString &folder)
{
    if (!folder.isEmpty())
        QFile::remove(folder + QStringLiteral("/dock-tile.json"));
}

quint64 ownStartTime(const std::string &procRoot)
{
    std::ifstream f(procRoot + "/self/stat");
    std::stringstream text;
    text << f.rdbuf();
    StatFields st;
    return parseStat(text.str(), st, false) ? st.starttime : 0;
}

ProjectionWatch::ProjectionWatch(QString folder, std::string procRoot, QObject *parent)
    : QObject(parent), m_folder(std::move(folder)), m_procRoot(std::move(procRoot))
{
    m_settle.setSingleShot(true);
    m_settle.setInterval(50);
    connect(&m_settle, &QTimer::timeout, this, &ProjectionWatch::read);
    connect(&m_watcher, &QFileSystemWatcher::directoryChanged, &m_settle, qOverload<>(&QTimer::start));
    connect(&m_watcher, &QFileSystemWatcher::fileChanged, &m_settle, qOverload<>(&QTimer::start));
    read();
}

QString ProjectionWatch::file() const
{
    return m_folder.isEmpty() ? QString() : m_folder + QStringLiteral("/windows.json");
}

void ProjectionWatch::recheck()
{
    read();
}

void ProjectionWatch::read()
{
    if (m_folder.isEmpty())
        return;
    // The folder may come after the app (the shell makes it, and $XDG_RUNTIME_DIR/grassfield with it, when the app's window
    // opens): its nearest folder that exists is watched until then, and each one that comes is watched in turn.
    QString watched = m_folder;
    while (!QFileInfo(watched).isDir()) {
        const QString parent = QFileInfo(watched).absolutePath();
        if (parent == watched)
            break;
        watched = parent;
    }
    if (QFileInfo(watched).isDir() && !m_watcher.directories().contains(watched))
        m_watcher.addPath(watched);
    Projection next;
    QFile f(file());
    if (f.open(QIODevice::ReadOnly)) {
        if (!m_watcher.files().contains(file()))
            m_watcher.addPath(file()); // a rename into place drops the old watch: added again at each read
        next = parseProjection(f.read(kProjectionMax + 1), m_procRoot);
    }
    if (next != m_projection) {
        m_projection = next;
        emit changed();
    }
}

} // namespace activity
