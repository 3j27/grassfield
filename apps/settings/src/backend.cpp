#include "backend.h"

#include <algorithm>
#include <numeric>

#include "runmode.h"

#include <QCollator>
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
#include <QStorageInfo>
#include <QTimeZone>
#include <QDateTime>
#include <QLocale>
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
constexpr int kActionJobMs = 60000; // a D-Bus action: its look-ups are 3 s reads (kReadMs), then exactly one call of up to kActMs (30 s)
constexpr int kPrivilegedJobMs = 250000; // two calls that each wait for the polkit dialog (kPrivilegedMs, 120 s), ADR-0026

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
    // The session bus: the user's own service manager (Login Items).
    grassfield::settings::SystemBusConnection sessionConnection{QDBusConnection::SessionBus, QStringLiteral("gf-settings-session-bus")}; // i18n-ignore: a connection name
    grassfield::settings::BusJobs sessionJobs{[this] { return sessionConnection.caller(); }};
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
    start(argv, tag, grassfield::settings::actionTimeoutMs(argv, timeoutMs));
    return true;
}

// One D-Bus job on a worker thread, on the app's one connection to the system bus (a blocked service never blocks the window, and
// nothing a job holds outlives the Backend: busjobs.h). `job` returns "" on success, else the reason; its second argument
// receives the output (JSON) of a query.
void Backend::runBus(const QString &tag, std::function<QString(grassfield::settings::BusCaller &, QString *)> job, int timeoutMs, bool session)
{
    const bool dev = m_dev;
    (session ? m_bus->sessionJobs : m_bus->jobs).start(
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
    static const QStringList known{QStringLiteral("wifi.state"), QStringLiteral("bt.state"), QStringLiteral("host.state"), QStringLiteral("time.state"),
                                   QStringLiteral("time.zones"), QStringLiteral("locale.state"), QStringLiteral("user.units")};
    if (!known.contains(what)) {
        qWarning().noquote() << "refused a bus query that is not known:" << what;
        emit finished(tag, false, QString());
        return;
    }
    const QStringList own = userUnitDirs();
    runBus(tag, [what, own](BusCaller &bus, QString *output) {
        const StateResult r = what == QLatin1String("wifi.state") ? wifiState(bus)
            : what == QLatin1String("bt.state")                  ? bluetoothState(bus)
            : what == QLatin1String("host.state")                ? hostState(bus)
            : what == QLatin1String("time.state")                ? timeState(bus)
            : what == QLatin1String("time.zones")                ? timeZones(bus)
            : what == QLatin1String("locale.state")              ? localeState(bus)
                                                                 : userUnits(bus, own);
        if (!r.ok)
            return r.error.isEmpty() ? QCoreApplication::translate("SystemBus", "no answer") : r.error;
        *output = QString::fromUtf8(QJsonDocument(r.json).toJson(QJsonDocument::Compact));
        return QString();
    }, kQueryJobMs, what == QLatin1String("user.units"));
}

QStringList Backend::userUnitDirs() const
{
    // The user's own unit directories (systemd.unit(5), the user manager's search path): config, then data.
    const QString config = qEnvironmentVariableIsSet("XDG_CONFIG_HOME") ? qEnvironmentVariable("XDG_CONFIG_HOME") : QDir::homePath() + QStringLiteral("/.config");
    const QString data = qEnvironmentVariableIsSet("XDG_DATA_HOME") ? qEnvironmentVariable("XDG_DATA_HOME") : QDir::homePath() + QStringLiteral("/.local/share");
    return {QDir::cleanPath(config + QStringLiteral("/systemd/user")), QDir::cleanPath(data + QStringLiteral("/systemd/user"))};
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
    const QStringList own = userUnitDirs();
    runBus(tag, [op, own](BusCaller &bus, QString *) { return runAction(bus, op, own); }, privilegedAction(op) ? kPrivilegedJobMs : kActionJobMs, sessionAction(op));
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
                               // The panel's size in millimetres as the output reports it (About: the diagonal in inches).
                               {"physicalWidth", s->physicalSize().width()},
                               {"physicalHeight", s->physicalSize().height()},
                               {"primary", s == primary}});
    }
    return out;
}

QVariantList Backend::volumes() const
{
    // Real file systems only (no tmpfs, proc, overlay or the like): the start-up volume first, then the others by mount point.
    static const QStringList virtualTypes{QStringLiteral("tmpfs"), QStringLiteral("devtmpfs"), QStringLiteral("proc"), QStringLiteral("sysfs"),
                                          QStringLiteral("overlay"), QStringLiteral("squashfs"), QStringLiteral("efivarfs"), QStringLiteral("ramfs"),
                                          QStringLiteral("autofs"), QStringLiteral("fuse.portal"), QStringLiteral("cgroup2"), QStringLiteral("debugfs")};
    QVariantList out;
    QStringList seen;
    const QString home = QDir::homePath();
    auto entry = [&home](const QStorageInfo &v) {
        return QVariantMap{{"root", v.rootPath()},
                           {"name", v.name()},
                           {"device", QString::fromUtf8(v.device())},
                           {"type", QString::fromUtf8(v.fileSystemType())},
                           {"total", double(v.bytesTotal())},
                           {"available", double(v.bytesAvailable())},
                           {"free", double(v.bytesFree())},
                           {"readOnly", v.isReadOnly()},
                           {"isRoot", v.isRoot()},
                           {"holdsHome", QStorageInfo(home).rootPath() == v.rootPath()}};
    };
    const QStorageInfo root = QStorageInfo::root();
    if (root.isValid() && root.isReady()) {
        out.append(entry(root));
        seen << QString::fromUtf8(root.device());
    }
    QList<QStorageInfo> others = QStorageInfo::mountedVolumes();
    std::sort(others.begin(), others.end(), [](const QStorageInfo &a, const QStorageInfo &b) { return a.rootPath() < b.rootPath(); });
    for (const QStorageInfo &v : others) {
        const QString device = QString::fromUtf8(v.device());
        if (!v.isValid() || !v.isReady() || v.bytesTotal() <= 0 || virtualTypes.contains(QString::fromUtf8(v.fileSystemType())) || seen.contains(device)
            || v.rootPath().startsWith(QLatin1String("/boot")))
            continue;
        seen << device; // a btrfs subvolume mounted twice is one volume
        out.append(entry(v));
    }
    return out;
}

QVariantMap Backend::zoneInfo(const QString &zone) const
{
    // Names of a time zone in the UI language (Date & Time: "Central European Summer Time", "France", "UTC+02:00"); pure, no
    // privilege: Qt's own time zone data.
    const QTimeZone tz(zone.toUtf8());
    if (zone.isEmpty() || !tz.isValid())
        return {};
    const QDateTime now = QDateTime::currentDateTime();
    const QLocale locale;
    const QLocale::Territory territory = tz.territory();
    return {{"longName", tz.displayName(now, QTimeZone::LongName, locale)},
            {"shortName", tz.displayName(now, QTimeZone::ShortName, locale)},
            {"offset", tz.displayName(now, QTimeZone::OffsetName, locale)},
            {"offsetSeconds", tz.offsetFromUtc(now)},
            {"territory", territory == QLocale::AnyTerritory ? QString() : QLocale::territoryToString(territory)}};
}

QVariantList Backend::regionLocales() const
{
    // The default locale is the UI language (translationloader.h). A region's name carries the script only when it is not
    // the one the language and territory imply ("sr_Latn_RS", but "fr_CH").
    const QLocale ui;
    QList<QLocale> found;
    QStringList names;
    for (const QLocale &l : QLocale::matchingLocales(ui.language(), QLocale::AnyScript, QLocale::AnyTerritory)) {
        if (l.territory() == QLocale::AnyTerritory)
            continue;
        const QString base = QLocale::languageToCode(l.language()) + QLatin1Char('_') + QLocale::territoryToCode(l.territory());
        const QString name = QLocale(base).script() == l.script() ? base
            : QLocale::languageToCode(l.language()) + QLatin1Char('_') + QLocale::scriptToCode(l.script()) + QLatin1Char('_') + QLocale::territoryToCode(l.territory());
        if (names.contains(name))
            continue;
        names << name;
        found << l;
    }
    QCollator collator(ui);
    QList<int> order(found.size());
    std::iota(order.begin(), order.end(), 0);
    std::sort(order.begin(), order.end(), [&](int a, int b) { return collator.compare(found[a].nativeTerritoryName(), found[b].nativeTerritoryName()) < 0; });
    QVariantList out;
    for (int i : order)
        out << QVariantMap{{"name", names[i]}, {"territory", found[i].nativeTerritoryName()}};
    return out;
}

QString Backend::autostartDir() const
{
    const QString config = qEnvironmentVariableIsSet("XDG_CONFIG_HOME") ? qEnvironmentVariable("XDG_CONFIG_HOME") : QDir::homePath() + QStringLiteral("/.config");
    return QDir::cleanPath(config + QStringLiteral("/autostart"));
}

QStringList Backend::systemAutostartDirs() const
{
    // $XDG_CONFIG_DIRS (default /etc/xdg), each with autostart/ (the XDG Autostart specification).
    const QString dirs = qEnvironmentVariableIsSet("XDG_CONFIG_DIRS") ? qEnvironmentVariable("XDG_CONFIG_DIRS") : QStringLiteral("/etc/xdg");
    QStringList out;
    for (const QString &d : dirs.split(QLatin1Char(':'), Qt::SkipEmptyParts)) {
        if (d.startsWith(QLatin1Char('/')))
            out << QDir::cleanPath(d + QStringLiteral("/autostart"));
    }
    return out;
}

QStringList Backend::applicationDirs() const
{
    // The XDG Base Directory folders of the desktop entries: $XDG_DATA_HOME (default ~/.local/share) first, then $XDG_DATA_DIRS
    // (default /usr/local/share:/usr/share), each with applications/.
    const QString home = qEnvironmentVariableIsSet("XDG_DATA_HOME") ? qEnvironmentVariable("XDG_DATA_HOME") : QDir::homePath() + QStringLiteral("/.local/share");
    const QString dirs = qEnvironmentVariableIsSet("XDG_DATA_DIRS") ? qEnvironmentVariable("XDG_DATA_DIRS") : QStringLiteral("/usr/local/share:/usr/share");
    QStringList out;
    for (const QString &d : (QStringList{home} + dirs.split(QLatin1Char(':'), Qt::SkipEmptyParts))) {
        const QString dir = QDir::cleanPath(d + QStringLiteral("/applications"));
        if (d.startsWith(QLatin1Char('/')) && !out.contains(dir))
            out << dir;
    }
    return out;
}

QStringList Backend::currentDesktops() const
{
    return qEnvironmentVariable("XDG_CURRENT_DESKTOP").split(QLatin1Char(':'), Qt::SkipEmptyParts);
}

QStringList Backend::desktopEntries(const QString &dir) const
{
    // The .desktop files of one folder (no recursion, regular files only), sorted.
    QDir d(dir);
    if (!dir.startsWith(QLatin1Char('/')) || !d.exists())
        return {};
    return d.entryList({QStringLiteral("*.desktop")}, QDir::Files | QDir::Readable, QDir::Name);
}

bool Backend::autostartWriteAllowed(const QString &path) const
{
    // Only <autostartDir>/<name>.desktop, a plain name; in a dev session the folder must lie under <worktree>/.dev (the
    // isolated XDG_CONFIG_HOME of isolated.sh), never the owner's ~/.config/autostart.
    static const QRegularExpression name(QRegularExpression::anchoredPattern(QStringLiteral("[A-Za-z0-9._+-]{1,200}\\.desktop")));
    const QString dir = autostartDir();
    if (QFileInfo(path).path() != dir || !name.match(QFileInfo(path).fileName()).hasMatch())
        return false;
    if (!m_dev)
        return true;
    const QString dev = QFileInfo(m_devRoot + QStringLiteral("/.dev")).canonicalFilePath();
    QString probe = dir;
    while (!QFileInfo::exists(probe) && probe.contains(QLatin1Char('/')))
        probe = probe.left(probe.lastIndexOf(QLatin1Char('/')));
    const QString real = QFileInfo(probe).canonicalFilePath();
    return !m_devRoot.isEmpty() && !dev.isEmpty() && !real.isEmpty() && (real == dev || real.startsWith(dev + QLatin1Char('/')));
}

QString Backend::writeAutostart(const QString &path, const QString &text) const
{
    if (!autostartWriteAllowed(path))
        return QStringLiteral("refused"); // i18n-ignore: a reason the page maps to its own sentence
    return writeText(path, text);
}

QString Backend::removeAutostart(const QString &path) const
{
    if (!autostartWriteAllowed(path))
        return QStringLiteral("refused"); // i18n-ignore: a reason the page maps to its own sentence
    QFile f(path);
    if (!f.exists())
        return QString();
    return f.remove() ? QString() : f.errorString();
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
