#include "backend.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QProcess>
#include <QSaveFile>
#include <QScreen>
#include <QTimer>

#include "systemguard.h"

#ifndef GRASSFIELD_DEV_BINDINGS
#define GRASSFIELD_DEV_BINDINGS ""
#endif

namespace {
constexpr qint64 kMaxRead = 4 * 1024 * 1024;
constexpr int kRunTimeoutMs = 3000;

QString resolveConfigFile()
{
    // GRASSFIELD_CONFIG_HOME (dev) wins, like the shell; else $XDG_CONFIG_HOME/grassfield.
    const QString dev = qEnvironmentVariable("GRASSFIELD_CONFIG_HOME");
    if (!dev.isEmpty())
        return dev + "/grassfield.json";
    const QString xdg = qEnvironmentVariable("XDG_CONFIG_HOME");
    return (xdg.isEmpty() ? QDir::homePath() + "/.config" : xdg) + "/grassfield/grassfield.json";
}

QString resolveBindingsFile()
{
    // Installed file first; GRASSFIELD_CONFIG_DIR (set in the dev session) and the build-time
    // repository path serve a repo session.
    const QString installed = QStringLiteral("/usr/share/grassfield/hypr/grassfield/bindings.lua");
    if (QFile::exists(installed))
        return installed;
    const QString dir = qEnvironmentVariable("GRASSFIELD_CONFIG_DIR");
    const QStringList dev = {dir.isEmpty() ? QString() : dir + "/grassfield/bindings.lua", QStringLiteral(GRASSFIELD_DEV_BINDINGS)};
    for (const QString &c : dev) {
        if (!c.isEmpty() && QFile::exists(c))
            return c;
    }
    return installed;
}
} // namespace

Backend::Backend(QObject *parent)
    : QObject(parent)
    , m_configFile(resolveConfigFile())
    , m_bindingsFile(resolveBindingsFile())
    , m_dev(grassfield::settings::devSession())
{
    connect(&m_watcher, &QFileSystemWatcher::fileChanged, this, &Backend::onPath);
    connect(&m_watcher, &QFileSystemWatcher::directoryChanged, this, &Backend::onPath);
}

Backend::~Backend()
{
    // Never destroy a running QProcess.
    const auto procs = findChildren<QProcess *>(QString(), Qt::FindDirectChildrenOnly);
    for (QProcess *p : procs) {
        p->disconnect(this);
        if (p->state() != QProcess::NotRunning) {
            p->kill();
            p->waitForFinished(1000);
        }
    }
}

void Backend::start(const QStringList &argv, const QString &tag, int timeoutMs)
{
    auto *p = new QProcess(this);
    auto *timer = new QTimer(p);
    timer->setSingleShot(true);
    connect(timer, &QTimer::timeout, p, [p] { p->kill(); });
    connect(p, &QProcess::errorOccurred, this, [this, p, tag](QProcess::ProcessError e) {
        if (e == QProcess::FailedToStart) {
            emit finished(tag, false, QString());
            p->deleteLater();
        }
    });
    connect(p, &QProcess::finished, this, [this, p, tag](int code, QProcess::ExitStatus status) {
        emit finished(tag, status == QProcess::NormalExit && code == 0, QString::fromUtf8(p->readAllStandardOutput()));
        p->deleteLater();
    });
    p->start(argv.first(), argv.mid(1), QIODevice::ReadOnly);
    timer->start(timeoutMs);
}

void Backend::query(const QStringList &argv, const QString &tag, int timeoutMs)
{
    if (argv.isEmpty() || (m_dev && !grassfield::settings::isReadOnlyQuery(argv))) {
        if (!argv.isEmpty())
            qWarning().noquote() << "dev guard: refused a command that is not a read-only query:" << argv.first();
        emit finished(tag, false, QString());
        return;
    }
    start(argv, tag, timeoutMs);
}

bool Backend::act(const QString &what, const QStringList &argv, const QString &tag, int timeoutMs)
{
    if (m_dev) {
        qInfo().noquote() << "dev guard:" << what << "suppressed";
        emit suppressed(what);
        return false;
    }
    if (argv.isEmpty() || !grassfield::settings::isActionProgram(argv.first())) {
        qWarning().noquote() << "refused an action with an unknown program:" << what;
        return false;
    }
    start(argv, tag, timeoutMs);
    return true;
}

QVariantList Backend::screens() const
{
    QVariantList out;
    const QScreen *primary = QGuiApplication::primaryScreen();
    for (const QScreen *s : QGuiApplication::screens()) {
        const QRect g = s->geometry();
        const qreal dpr = s->devicePixelRatio();
        out.append(QVariantMap{{"name", s->name()},
                               {"model", s->model()},
                               {"manufacturer", s->manufacturer()},
                               {"x", g.x()},
                               {"y", g.y()},
                               {"width", g.width()},
                               {"height", g.height()},
                               {"scale", dpr},
                               {"pixelWidth", qRound(g.width() * dpr)},
                               {"pixelHeight", qRound(g.height() * dpr)},
                               {"refreshRate", s->refreshRate()},
                               {"primary", s == primary}});
    }
    return out;
}

QString Backend::qtVersion() const
{
    return QString::fromLatin1(qVersion());
}

QString Backend::appVersion() const
{
    return QCoreApplication::applicationVersion();
}

QVariantMap Backend::readText(const QString &path) const
{
    QVariantMap out{{"exists", false}, {"ok", false}, {"text", QString()}};
    QFile f(path);
    if (!f.exists())
        return out;
    out["exists"] = true;
    if (!f.open(QIODevice::ReadOnly))
        return out;
    out["text"] = QString::fromUtf8(f.read(kMaxRead));
    out["ok"] = true;
    return out;
}

QString Backend::writeText(const QString &path, const QString &text) const
{
    if (!QDir().mkpath(QFileInfo(path).absolutePath()))
        return QStringLiteral("cannot create the directory of %1").arg(path);
    QSaveFile f(path);
    if (!f.open(QIODevice::WriteOnly))
        return f.errorString();
    f.write(text.toUtf8());
    if (!f.commit())
        return f.errorString();
    return QString();
}

QString Backend::run(const QStringList &argv) const
{
    if (argv.isEmpty())
        return QString();
    QProcess p;
    p.start(argv.first(), argv.mid(1), QIODevice::ReadOnly);
    if (!p.waitForFinished(kRunTimeoutMs) || p.exitStatus() != QProcess::NormalExit || p.exitCode() != 0) {
        // Never destroy a running QProcess: terminate, then kill, each with a bounded wait.
        if (p.state() != QProcess::NotRunning) {
            p.terminate();
            if (!p.waitForFinished(500)) {
                p.kill();
                p.waitForFinished(1000);
            }
        }
        return QString();
    }
    return QString::fromUtf8(p.readAllStandardOutput());
}

bool Backend::watch(const QString &path)
{
    // The file is replaced by rename on every atomic write, so its directory is watched too.
    const QString dir = QFileInfo(path).absolutePath();
    m_watched.append(path);
    QDir().mkpath(dir);
    m_watcher.addPath(dir);
    if (QFile::exists(path))
        m_watcher.addPath(path);
    return true;
}

void Backend::onPath(const QString &path)
{
    for (const QString &w : std::as_const(m_watched)) {
        // After a rename the old inode is gone from the watcher: add the new file.
        if (QFile::exists(w) && !m_watcher.files().contains(w))
            m_watcher.addPath(w);
        if (path == w || path == QFileInfo(w).absolutePath())
            emit fileChanged(w);
    }
}
