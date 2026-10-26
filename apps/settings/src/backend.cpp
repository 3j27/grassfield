#include "backend.h"

#include "runmode.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QProcess>
#include <QProcessEnvironment>
#include <QRegularExpression>
#include <QSaveFile>
#include <QScreen>
#include <QStandardPaths>
#include <QTimer>

#include "busjobs.h"
#include "qtbuscaller.h"
#include "systemguard.h"


#ifndef GRASSFIELD_DEV_BINDINGS
#define GRASSFIELD_DEV_BINDINGS ""
#endif

namespace {
constexpr qint64 kMaxRead = 4 * 1024 * 1024;
constexpr int kRunTimeoutMs = 3000;
constexpr int kMaxReason = 160;
constexpr int kQueryJobMs = 10000;  // a D-Bus state read: past this the page gets "timed out"
constexpr int kActionJobMs = 60000; // a D-Bus action: up to two calls of systembus.cpp kActMs (30 s) in a row (look up, then act)

// Every tool runs in the C locale: the parsers (qml/System.js) read the English, untranslated output.
void forceCLocale(QProcess &p)
{
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.insert(QStringLiteral("LC_ALL"), QStringLiteral("C"));
    env.insert(QStringLiteral("LANG"), QStringLiteral("C"));
    env.remove(QStringLiteral("LANGUAGE"));
    p.setProcessEnvironment(env);
}

// One short line explaining a failure: first non-empty line of stderr, else of stdout (bluetoothctl reports errors there).
QString reasonOf(const QByteArray &err, const QByteArray &out)
{
    for (const QByteArray &src : {err, out}) {
        for (const QString &line : QString::fromUtf8(src).split(QLatin1Char('\n'))) {
            QString t = line.simplified();
            t.remove(QRegularExpression(QStringLiteral("[\\x00-\\x1f\\x7f]")));
            if (!t.isEmpty())
                return t.left(kMaxReason);
        }
    }
    return QString();
}

QString resolveConfigFile()
{
    // GRASSFIELD_CONFIG_HOME wins, like the shell; else $XDG_CONFIG_HOME/grassfield (runmode.h).
    return grassfield::apps::runmode::configDir() + "/grassfield.json";
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
    grassfield::settings::registerBusTypes();
    m_bus = std::make_unique<Bus>();
    connect(&m_watcher, &QFileSystemWatcher::fileChanged, this, &Backend::onPath);
    connect(&m_watcher, &QFileSystemWatcher::directoryChanged, this, &Backend::onPath);
    if (m_dev) {
        // The dev binary sits in <worktree>/.dev/build: the helper next to it, the cache and the pictures under .dev.
        const QString dev = QDir(QCoreApplication::applicationDirPath() + QStringLiteral("/..")).canonicalPath();
        m_devRoot = QFileInfo(dev).dir().absolutePath();
        m_wallpaperTool = QCoreApplication::applicationDirPath() + QStringLiteral("/grassfield-wallpaper");
        m_wallpaperCache = dev + QStringLiteral("/cache/wallpapers");
        const QString pictures = grassfield::apps::runmode::devValue("PICTURES_DIR");
        m_picturesDir = pictures.isEmpty() ? dev + QStringLiteral("/wallpapers") : pictures;
    } else {
        m_wallpaperTool = QStringLiteral("/usr/lib/grassfield/grassfield-wallpaper");
        const QString xdg = qEnvironmentVariable("XDG_CACHE_HOME");
        m_wallpaperCache = (xdg.isEmpty() ? QDir::homePath() + QStringLiteral("/.cache") : xdg) + QStringLiteral("/grassfield/wallpapers");
        const QString pictures = grassfield::apps::runmode::devValue("PICTURES_DIR");
        m_picturesDir = pictures.isEmpty() ? QStandardPaths::writableLocation(QStandardPaths::PicturesLocation) : pictures;
    }
}

QString Backend::wallpaperStatusFile() const
{
    return QFileInfo(m_configFile).absolutePath() + QStringLiteral("/wallpaper-state.json");
}

QString Backend::wallpaperRecentFile() const
{
    return QFileInfo(m_configFile).absolutePath() + QStringLiteral("/wallpaper-recent.json");
}

struct Backend::Bus {
    grassfield::settings::SystemBusConnection connection;
    grassfield::settings::BusJobs jobs{[this] { return connection.caller(); }};
};

Backend::~Backend()
{
    // Never destroy a running QProcess. This comes first: the D-Bus jobs below may abandon the process (_Exit), which skips every
    // destructor, and a wpctl or the wallpaper helper still running would be left behind.
    const auto procs = findChildren<QProcess *>(QString(), Qt::FindDirectChildrenOnly);
    for (QProcess *p : procs) {
        p->disconnect(this);
        if (p->state() != QProcess::NotRunning) {
            p->kill();
            p->waitForFinished(1000);
        }
    }
    m_bus.reset(); // waits for a D-Bus job a moment at most, then abandons it (busjobs.h): the window closes promptly
}

void Backend::start(const QStringList &argv, const QString &tag, int timeoutMs)
{
    auto *p = new QProcess(this);
    forceCLocale(*p);
    auto *timer = new QTimer(p);
    timer->setSingleShot(true);
    connect(timer, &QTimer::timeout, p, [p] {
        p->setProperty("timedOut", true);
        p->kill();
    });
    connect(p, &QProcess::errorOccurred, this, [this, p, tag](QProcess::ProcessError e) {
        if (e == QProcess::FailedToStart) {
            emit failed(tag, p->errorString().left(kMaxReason));
            emit finished(tag, false, QString());
            p->deleteLater();
        }
    });
    connect(p, &QProcess::finished, this, [this, p, tag](int code, QProcess::ExitStatus status) {
        const bool ok = status == QProcess::NormalExit && code == 0;
        const QByteArray out = p->readAllStandardOutput();
        if (!ok)
            emit failed(tag, p->property("timedOut").toBool() ? QCoreApplication::translate("SystemBus", "timed out") : reasonOf(p->readAllStandardError(), out));
        emit finished(tag, ok, QString::fromUtf8(out));
        p->deleteLater();
    });
    p->start(argv.first(), argv.mid(1), QIODevice::ReadOnly);
    timer->start(timeoutMs);
}

// A command that names the wallpaper helper runs only as one of the vectors of systemguard.h::isWallpaperQuery, with the
// helper at its exact path, in every session.
bool Backend::wallpaperAllowed(const QStringList &argv) const
{
    return grassfield::settings::isWallpaperQuery(argv, {m_wallpaperTool, m_wallpaperCache, m_devRoot});
}

void Backend::query(const QStringList &argv, const QString &tag, int timeoutMs)
{
    const bool helper = !argv.isEmpty() && grassfield::settings::namesWallpaperTool(argv.first());
    if (argv.isEmpty() || (helper ? !wallpaperAllowed(argv) : (m_dev && !grassfield::settings::isReadOnlyQuery(argv)))) {
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
    if (!grassfield::settings::isAllowedAction(argv)) {
        qWarning().noquote() << "refused an action with an unknown program:" << what;
        return false;
    }
    start(argv, tag, timeoutMs);
    return true;
}

// One D-Bus job on a worker thread, on the app's one connection to the system bus (a blocked service never blocks the window, and
// nothing a job holds outlives the Backend: busjobs.h). `job` returns "" on success, else the reason; its second argument
// receives the output (JSON) of a query.
void Backend::runBus(const QString &tag, std::function<QString(grassfield::settings::BusCaller &, QString *)> job, int timeoutMs)
{
    const bool dev = m_dev;
    m_bus->jobs.start(
        [dev, job = std::move(job)](grassfield::settings::BusCaller &real, QString *output) {
            grassfield::settings::GuardedCaller guarded(real, dev);
            return job(guarded, output);
        },
        [this, tag](const QString &reason, const QString &output) {
            if (!reason.isEmpty()) {
                emit failed(tag, reason);
                emit finished(tag, false, QString());
            } else {
                emit finished(tag, true, output);
            }
        },
        timeoutMs);
}

void Backend::busQuery(const QString &what, const QString &tag)
{
    using namespace grassfield::settings;
    if (what != QLatin1String("wifi.state") && what != QLatin1String("bt.state")) {
        qWarning().noquote() << "refused a bus query that is not known:" << what;
        emit finished(tag, false, QString());
        return;
    }
    const bool wifi = what == QLatin1String("wifi.state");
    runBus(tag, [wifi](BusCaller &bus, QString *output) {
        const StateResult r = wifi ? wifiState(bus) : bluetoothState(bus);
        if (!r.ok)
            return r.error.isEmpty() ? QCoreApplication::translate("SystemBus", "no answer") : r.error;
        *output = QString::fromUtf8(QJsonDocument(r.json).toJson(QJsonDocument::Compact));
        return QString();
    }, kQueryJobMs);
}

bool Backend::busAct(const QString &what, const QVariantMap &op, const QString &tag)
{
    using namespace grassfield::settings;
    if (m_dev) {
        qInfo().noquote() << "dev guard:" << what << "suppressed";
        emit suppressed(what);
        return false;
    }
    if (!validAction(op)) {
        qWarning().noquote() << "refused a bus action that is not well formed:" << what;
        return false;
    }
    runBus(tag, [op](BusCaller &bus, QString *) { return runAction(bus, op); }, kActionJobMs);
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
                               {"serial", s->serialNumber()},
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
        return QCoreApplication::translate("SystemBus", "cannot create the directory of %1").arg(path);
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
    // Same allow-list as query(), in every session: nothing else runs through this door.
    const bool helper = !argv.isEmpty() && grassfield::settings::namesWallpaperTool(argv.first());
    if (argv.isEmpty() || !(helper ? wallpaperAllowed(argv) : grassfield::settings::isReadOnlyQuery(argv))) {
        if (!argv.isEmpty())
            qWarning().noquote() << "refused run() of a command that is not a read-only query:" << argv.first();
        return QString();
    }
    QProcess p;
    forceCLocale(p);
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
