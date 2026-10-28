#include "storebackend.h"

#include "appscope.h"
#include "autoappearance.h"
#include "catalog.h"
#include "childprocess.h"
#include "chromecaps.h"
#include "fetch.h"
#include "runmode.h"
#include "shortcutstyle.h"
#include "storeenv.h"
#include "translationloader.h"

#include <QCoreApplication>
#include <QRegularExpression>

#include <QCollator>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QWindow>
#include <QImageReader>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkInformation>
#include <QSaveFile>
#include <QStandardPaths>
#include <QUrl>

#include <pwd.h>
#include <unistd.h>

namespace grassfield::store {

namespace {

constexpr int kStaleHours = 6;       // SR26: the catalog is fetched again when its copy is older
constexpr int kOldDays = 30;         // SR29: a catalog older than this is used with a note
constexpr qint64 kSignatureMax = 64 * 1024;
constexpr int kFetchMs = 15000;      // ADR-0037 c
constexpr qint64 kAppStreamPackageMax = 64 * 1024 * 1024;
constexpr int kAppStreamDownloadMs = 120000;
constexpr int kMaxWebApps = 500;
constexpr qint64 kConfigMax = 1024 * 1024; // grassfield.json (ADR-0020: a real one is a few KiB)

QString configFile()
{
    return apps::runmode::configDir() + QStringLiteral("/grassfield.json");
}

// The application when it is a QGuiApplication (the window's), else null (the unit tests' QCoreApplication).
QGuiApplication *guiApp()
{
    return qobject_cast<QGuiApplication *>(QCoreApplication::instance());
}

QByteArray readSmall(const QString &path, qint64 max)
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly) || f.size() > max)
        return {};
    return f.read(max);
}

QString dataHome()
{
    const QString xdg = qEnvironmentVariable("XDG_DATA_HOME");
    return xdg.isEmpty() ? QDir::homePath() + QStringLiteral("/.local/share") : xdg;
}

// Where the catalog comes from, decided once per job (channel.h): the dev plumbing's URL, else the channel's.
struct Source {
    QString channel = QStringLiteral("stable");
    QUrl catalog;       // invalid: nothing to fetch (no hosting yet)
    bool devPlumbing = false;
    std::optional<Channel> base;
};

Source catalogSource()
{
    Source s;
    const std::optional<Channel> conf = channelFromConf(readSmall(env::grassfieldConf(), 64 * 1024));
    const Channel channel = conf ? *conf : defaultChannel(buildBase(readSmall(QStringLiteral("/usr/share/grassfield/pacman/repository.conf"), 64 * 1024)));
    s.channel = channel.name;
    const QUrl override = env::catalogUrlOverride();
    if (override.isValid()) {
        s.catalog = override;
        s.devPlumbing = true;
    } else if (fetchable(channel)) {
        s.catalog = catalogUrl(channel);
        s.base = channel;
    }
    return s;
}

QUrl iconSource(const Source &s, const QString &sha256)
{
    if (s.devPlumbing)
        return s.catalog.resolved(QUrl(QStringLiteral("catalog/%1.png").arg(sha256)));
    return s.base ? iconUrl(*s.base, sha256) : QUrl();
}

// The launcher icon of a web app: a file, or an icon name looked up where omarchy-webapp-install puts them.
QString webAppIcon(const QString &value)
{
    if (value.isEmpty())
        return {};
    if (value.startsWith(QLatin1Char('/')))
        return QFileInfo(value).isFile() ? value : QString();
    if (value.contains(QLatin1Char('/')) || value.startsWith(QLatin1Char('.')))
        return {};
    for (const QString &root : {dataHome() + QStringLiteral("/icons/hicolor"), QStringLiteral("/usr/share/icons/hicolor")}) {
        for (const QString &file : {QStringLiteral("/256x256/apps/%1.png"), QStringLiteral("/scalable/apps/%1.svg")}) {
            const QString path = root + file.arg(value);
            if (QFileInfo(path).isFile())
                return path;
        }
    }
    return {};
}

QList<view::WebAppEntry> readWebApps()
{
    QList<view::WebAppEntry> out;
    QDirIterator it(dataHome() + QStringLiteral("/applications"), {QStringLiteral("*.desktop")}, QDir::Files);
    int seen = 0;
    while (it.hasNext() && seen++ < kMaxWebApps) {
        const QString path = it.next();
        const auto entry = view::parseWebAppEntry(readSmall(path, 64 * 1024));
        if (entry) {
            view::WebAppEntry e = *entry;
            e.icon = webAppIcon(e.icon);
            e.file = QFileInfo(path).completeBaseName();
            out.append(e);
        }
    }
    return out;
}

// The packages no repository has that own an application entry (`pacman -Ql`, as the user).
QSet<QString> foreignWithEntry(const QString &pacman, const QSet<QString> &foreign)
{
    QSet<QString> out;
    QStringList names;
    for (const QString &n : foreign) {
        if (isPackageName(n) && !n.startsWith(QLatin1String("grassfield"))) // Grassfield's own local builds are never listed
            names.append(n);
    }
    if (names.isEmpty())
        return out;
    names.sort();
    const ChildResult r = runChild(pacman, QStringList{QStringLiteral("-Ql"), QStringLiteral("--")} + names);
    if (!r.ok())
        return out;
    for (const QByteArray &line : r.out.split('\n')) {
        const int space = line.indexOf(' ');
        if (space <= 0)
            continue;
        const QByteArray path = line.mid(space + 1);
        if (path.startsWith("/usr/share/applications/") && path.endsWith(".desktop"))
            out.insert(QString::fromUtf8(line.left(space)));
    }
    return out;
}

// The application entries of /usr/share/applications and the packages that own them (pacman -Qo, as the user): package ->
// desktop ids, sorted. An entry no package owns is left out.
QHash<QString, QStringList> readEntries(const QString &pacman, const QString &dir)
{
    QHash<QString, QStringList> out;
    QStringList files;
    for (const QString &name : QDir(dir).entryList({QStringLiteral("*.desktop")}, QDir::Files, QDir::Name)) {
        if (isDesktopId(name))
            files.append(dir + QLatin1Char('/') + name);
        if (files.size() >= 4000)
            break;
    }
    if (files.isEmpty())
        return out;
    // pacman -Qo exits 1 when a file has no owner; the others are still listed.
    const ChildResult r = runChild(pacman, QStringList{QStringLiteral("-Qo"), QStringLiteral("--")} + files);
    if (!r.started || r.timedOut || r.overflow)
        return out;
    static const QRegularExpression owned(QStringLiteral("^(\\S+) is owned by (\\S+) \\S+$"));
    for (const QByteArray &line : r.out.split('\n')) {
        const QRegularExpressionMatch m = owned.match(QString::fromUtf8(line).trimmed());
        if (!m.hasMatch() || !isPackageName(m.captured(2)))
            continue;
        out[m.captured(2)].append(QFileInfo(m.captured(1)).fileName());
    }
    for (QStringList &ids : out)
        ids.sort();
    return out;
}

// What the Store never removes (removal.h): Omarchy's two package lists, read where Omarchy installs them, and pacman's
// HoldPkg (pacman-conf; pacman's own default when it cannot be read).
DenyList readDenyList()
{
    DenyList deny;
    for (const QString &list : {QStringLiteral("/omarchy-base.packages"), QStringLiteral("/omarchy-other.packages")})
        deny.omarchy.unite(parsePackageList(readSmall(env::omarchyLists() + list, 1024 * 1024)));
    const ChildResult hold = runChild(env::pacmanConf(), {QStringLiteral("HoldPkg")});
    if (hold.ok())
        deny.holdPkg = parsePackageList(hold.out);
    if (deny.holdPkg.isEmpty())
        deny.holdPkg = {QStringLiteral("pacman"), QStringLiteral("glibc")};
    return deny;
}

struct JobInput {
    bool fetchCatalog = false;
    bool fetchAppData = false;
    bool online = true;
    bool aur = false; // the AUR source is on: the catalog's AUR apps are offered
};

std::shared_ptr<const Snapshot> buildSnapshot(const JobInput &in, const std::atomic_bool &cancel)
{
    auto snap = std::make_shared<Snapshot>();
    snap->fallback.categories = view::builtInCategories();

    // pacman's lists, as the user (no root, no lock).
    const Pacman pacman(env::pacman());
    snap->sync = pacman.syncList();
    snap->pacmanRead = !snap->sync.isEmpty();
    snap->explicitPackages = pacman.explicitlyInstalled();
    if (cancel)
        return snap;
    snap->foreignWithEntry = foreignWithEntry(env::pacman(), pacman.foreign());
    snap->entries = readEntries(env::pacman(), env::systemApplications());
    snap->deny = readDenyList();

    // Arch's AppStream: installed, else the copy fetched before (refreshed first when asked and online).
    const QString root = env::swcatalogRoot();
    if (QDir(root + QStringLiteral("/xml")).exists()) {
        snap->appstream = readAppStream(root, AppStreamData::Origin::Installed);
    } else {
        if (in.fetchAppData && in.online) {
            AppStreamTools tools;
            tools.pacman = env::pacman();
            tools.gpg = env::gpg();
            tools.pacmanGnupg = env::pacmanGnupg();
            tools.bsdtar = env::bsdtar;
            const bool devPlumbing = !env::fixture().isEmpty();
            tools.download = [devPlumbing](const QString &url, const QString &file, qint64 maxBytes, int timeoutMs) {
                return downloadTo(QUrl(url), file, FetchLimits{maxBytes, timeoutMs}, devPlumbing);
            };
            QString error;
            if (!refreshFetched(env::cacheDir(), tools, &error))
                snap->appstreamProblem = error.contains(QLatin1String("signature")) ? QStringLiteral("unverified") : QStringLiteral("unavailable");
        }
        snap->appstream = readFetched(env::cacheDir());
    }
    if (cancel)
        return snap;

    // The catalog: fetched when asked (its copy stale, or Ctrl+R), else the cached copy, checked again either way.
    const Source source = catalogSource();
    snap->channel = source.channel;
    snap->catalogConfigured = source.catalog.isValid();
    CatalogStore store(env::cacheDir(), env::stateFile(), env::gpgv, env::keyringDir());
    CatalogStore::Result result;
    bool loaded = false;
    // A catalog on disk (dev plumbing) needs no network.
    const bool reachable = in.online || (source.devPlumbing && source.catalog.isLocalFile());
    if (in.fetchCatalog && reachable && source.catalog.isValid()) {
        const FetchResult json = fetch(source.catalog, FetchLimits{kCatalogMaxBytes, kFetchMs}, store.cachedEtag(source.channel), source.devPlumbing);
        if (json.status == FetchResult::Status::NotModified) {
            store.touch(source.channel);
        } else if (json.status == FetchResult::Status::Ok) {
            const FetchResult sig = fetch(signatureUrl(source.catalog), FetchLimits{kSignatureMax, kFetchMs}, {}, source.devPlumbing);
            if (sig.status == FetchResult::Status::Ok) {
                result = store.accept(source.channel, json.body, sig.body, json.etag);
                loaded = result.outcome == CatalogStore::Outcome::Accepted;
                if (!loaded) {
                    snap->fetchProblem = result.outcome == CatalogStore::Outcome::NoTrustedKey ? QStringLiteral("untrusted") : QStringLiteral("refused");
                    snap->catalogReason = result.reason;
                }
            } else {
                snap->fetchProblem = QStringLiteral("unavailable");
            }
        } else {
            snap->fetchProblem = QStringLiteral("unavailable");
        }
    }
    if (!loaded)
        result = store.loadCached(source.channel); // the previous accepted copy stays in use
    snap->catalogOutcome = result.outcome;
    if (snap->catalogReason.isEmpty())
        snap->catalogReason = result.reason;
    snap->catalogFetchedAt = store.fetchedAt(source.channel);
    if (result.outcome == CatalogStore::Outcome::Accepted && result.catalog)
        snap->catalog = std::move(result.catalog);

    // The catalog's icons for apps without metadata, fetched once each (the cache keeps only those matching their hash).
    if (snap->catalog && reachable && (in.fetchCatalog || in.fetchAppData)) {
        for (const CatalogApp &a : snap->catalog->apps) {
            if (cancel)
                break;
            if (!a.icon || !store.iconPath(*a.icon).isEmpty())
                continue;
            const QUrl url = iconSource(source, a.icon->sha256);
            if (!url.isValid())
                continue;
            const FetchResult icon = fetch(url, FetchLimits{kIconMaxBytes, kFetchMs}, {}, source.devPlumbing);
            if (icon.status == FetchResult::Status::Ok)
                store.storeIcon(*a.icon, icon.body);
        }
    }

    snap->webApps = readWebApps();

    ModelInputs model;
    model.catalog = snap->catalog ? &*snap->catalog : &snap->fallback;
    model.appstream = snap->appstream.components;
    model.appstreamRoot = snap->appstream.root;
    model.sync = snap->sync;
    model.aurOn = in.aur;
    model.catalogIcon = [&store](const CatalogIcon &icon) { return store.iconPath(icon); };
    snap->apps = buildModel(model);
    // A setup runs from the installed Omarchy (b.2): hidden when Omarchy has no such recipe (spec, "Refusals"), and none
    // runs while a pinned file differs.
    const QString omarchy = env::omarchyRoot();
    snap->apps.removeIf([&omarchy](const StoreApp &a) {
        if (a.source != CatalogSource::Kind::OmarchySetup || !a.entry)
            return false;
        const QFileInfo install(omarchy + QStringLiteral("/bin/") + a.entry->source.install);
        const QFileInfo remove(omarchy + QStringLiteral("/bin/") + a.entry->source.remove);
        return !install.isFile() || !install.isExecutable() || !remove.isFile() || !remove.isExecutable();
    });
    if (snap->catalog && snap->catalog->omarchy)
        snap->omarchyDiffers = omarchyDifference(omarchy, snap->catalog->omarchy->files);
    QSet<QString> webUrls;
    for (const view::WebAppEntry &w : snap->webApps)
        webUrls.insert(w.url);
    for (int i = 0; i < snap->apps.size(); ++i) {
        StoreApp &a = snap->apps[i];
        if (a.source == CatalogSource::Kind::WebApp && a.entry)
            a.installed = webUrls.contains(a.entry->source.url);
        // Open's entry when neither our catalog nor AppStream names one: the package's own (the first by name, f); a
        // setup's, its first package's that has one.
        if (a.desktopId.isEmpty() && a.source == CatalogSource::Kind::Repo && a.installed)
            a.desktopId = snap->entries.value(a.package).value(0);
        for (const QString &p : a.packages) {
            if (a.desktopId.isEmpty() && a.source == CatalogSource::Kind::OmarchySetup && a.installed)
                a.desktopId = snap->entries.value(p).value(0);
        }
        snap->index.insert(a.id, i);
    }
    // The tints of the hero and card artwork: the app's icon decoded here, off the GUI thread.
    if (snap->catalog) {
        for (const CatalogSection &section : snap->catalog->sections) {
            for (const CatalogBlock &block : section.blocks) {
                for (const CatalogItem &item : block.items) {
                    const int i = snap->index.value(item.app, -1);
                    if (i < 0 || snap->tints.contains(item.app) || snap->apps.at(i).icon.isEmpty())
                        continue;
                    QImageReader reader(snap->apps.at(i).icon);
                    reader.setScaledSize(QSize(48, 48));
                    const QColor tint = view::heroTint(reader.read(), 6.0); // 6:1 with white: the 80 % lines hold 4.5:1 (A2)
                    snap->tints.insert(item.app, tint.isValid() ? tint.name() : QString());
                }
            }
        }
    }
    return snap;
}

} // namespace

StoreBackend::StoreBackend(QObject *parent)
    : QObject(parent)
    , m_cancel(std::make_shared<std::atomic_bool>(false))
{
    m_pool.setMaxThreadCount(2); // one load and one product page's pacman -Si at a time
    // qGuiApp casts whatever application there is: the unit tests' is a QCoreApplication.
    if (auto *gui = guiApp())
        connect(gui, &QGuiApplication::focusWindowChanged, this, &StoreBackend::focusWindowChanged);
    const QString system = i18n::systemLanguage();
    m_language = system.startsWith(QLatin1String("fr")) ? QStringLiteral("fr") : QStringLiteral("en");
    m_macDevice = apps::macDeviceHere();

    const QString file = configFile();
    const QString dir = QFileInfo(file).absolutePath();
    if (QFileInfo(dir).isDir())
        m_watcher.addPath(dir);
    if (QFileInfo::exists(file))
        m_watcher.addPath(file);
    const QString caps = apps::capabilitiesFile();
    if (!caps.isEmpty() && QFileInfo(QFileInfo(caps).absolutePath()).isDir())
        m_watcher.addPath(QFileInfo(caps).absolutePath());
    const auto reread = [this] {
        const QString f = configFile();
        if (QFileInfo::exists(f) && !m_watcher.files().contains(f))
            m_watcher.addPath(f);
        readAppearance();
    };
    connect(&m_watcher, &QFileSystemWatcher::fileChanged, this, reread);
    connect(&m_watcher, &QFileSystemWatcher::directoryChanged, this, reread);
    readAppearance();
    m_autoTimer.setInterval(apps::kAutoRecheckMs);
    connect(&m_autoTimer, &QTimer::timeout, this, [this] {
        if (m_autoAppearance)
            readAppearance();
    });
    m_autoTimer.start();

    // The local user (SR1): the full name of passwd, its initials, and AccountsService's picture when there is one.
    if (const passwd *pw = getpwuid(getuid())) {
        const QString login = QString::fromLocal8Bit(pw->pw_name);
        QString name = QString::fromLocal8Bit(pw->pw_gecos).section(QLatin1Char(','), 0, 0).trimmed();
        if (name.isEmpty())
            name = login;
        name = cleanPlainText(name, 64, false);
        const QString picture = QStringLiteral("/var/lib/AccountsService/icons/") + login;
        const QFileInfo info(picture);
        m_user = {{QStringLiteral("name"), name},
                  {QStringLiteral("initials"), view::initials(name)},
                  {QStringLiteral("picture"), info.isFile() && info.isReadable() && info.size() < 1024 * 1024
                                                  ? QUrl::fromLocalFile(picture).toString() : QString()}};
    }
    readNetwork();

    // The queue (operations.h): the system's programs, or in a dev session the fake ones (ADR-0019; none: nothing runs).
    OperationsConfig ops;
    ops.pkexec = env::pkexec();
    ops.helper = env::helperPath;
    ops.statusDir = env::statusDir();
    ops.updateLock = env::updateLock();
    ops.dbLock = env::dbLock();
    ops.pacmanLog = env::pacmanLog();
    ops.pacman = env::pacman();
    ops.stateFile = env::stateFile();
    ops.applications = dataHome() + QStringLiteral("/applications");
    ops.run = env::runPath;
    ops.runDir = env::runDir();
    ops.omarchy = [](const QString &command, const QStringList &args) {
        const QString fake = env::installer();
        if (apps::runmode::dev())
            return fake.isEmpty() ? QStringList() : QStringList{fake, command} + args;
        return QStringList{env::omarchyCommand(command)} + args;
    };
    m_operations = std::make_unique<Operations>(ops);
    connect(m_operations.get(), &Operations::changed, this, &StoreBackend::operationsChanged);
    connect(m_operations.get(), &Operations::finished, this, [this](const QString &app) {
        m_installPlans.remove(app);
        m_removePlans.remove(app);
        checkStaleLock();
        run(Job{}); // the system changed: read it again
    });
    connect(m_operations.get(), &Operations::idle, this, [this] {
        if (m_quitWhenIdle)
            QCoreApplication::quit();
    });
}

StoreBackend::~StoreBackend()
{
    *m_cancel = true;
}

bool StoreBackend::devSession() const
{
    return apps::runmode::dev();
}

void StoreBackend::readAppearance()
{
    bool dark = true, reduce = false, contrast = false;
    qreal scale = 1;
    QString accent = QStringLiteral("multicolor"), highlight = QStringLiteral("automatic"), doubleClick = QStringLiteral("zoom");
    QString shortcutSetting, formats = QStringLiteral("auto");
    bool aur = false, flathub = false, screenshots = true; // the schema's defaults (store.*)
    const QByteArray bytes = readSmall(configFile(), 1024 * 1024);
    if (!bytes.isEmpty()) {
        const QJsonObject root = QJsonDocument::fromJson(bytes).object();
        const QString setting = root.value(QStringLiteral("appearance")).toString();
        m_autoAppearance = setting == QLatin1String("auto");
        dark = apps::isDarkAppearance(setting, QTime::currentTime());
        const QJsonObject a11y = root.value(QStringLiteral("accessibility")).toObject();
        reduce = a11y.value(QStringLiteral("reduceMotion")).toBool(false);
        contrast = a11y.value(QStringLiteral("increaseContrast")).toBool(false);
        scale = qBound(1.0, a11y.value(QStringLiteral("textSize")).toDouble(1), 1.3);
        const QString d = root.value(QStringLiteral("windows")).toObject().value(QStringLiteral("titlebarDoubleClick")).toString();
        if (d == QLatin1String("minimize") || d == QLatin1String("none"))
            doubleClick = d;
        static const QStringList names{QStringLiteral("blue"), QStringLiteral("purple"), QStringLiteral("pink"), QStringLiteral("red"),
                                       QStringLiteral("orange"), QStringLiteral("yellow"), QStringLiteral("green"), QStringLiteral("graphite")};
        const QJsonObject accentObject = root.value(QStringLiteral("accent")).toObject();
        if (names.contains(accentObject.value(QStringLiteral("color")).toString()))
            accent = accentObject.value(QStringLiteral("color")).toString();
        if (names.contains(accentObject.value(QStringLiteral("highlight")).toString()))
            highlight = accentObject.value(QStringLiteral("highlight")).toString();
        shortcutSetting = root.value(QStringLiteral("keyboard")).toObject().value(QStringLiteral("shortcutStyle")).toString();
        const QString f = root.value(QStringLiteral("region")).toObject().value(QStringLiteral("formats")).toString();
        if (!f.isEmpty())
            formats = f;
        // The Store's own keys (SD20): a value that is not a boolean reads as the default, as every reader of the contract.
        const QJsonObject store = root.value(QStringLiteral("store")).toObject();
        const QJsonObject sources = store.value(QStringLiteral("sources")).toObject();
        aur = sources.value(QStringLiteral("aur")).toBool(false);
        flathub = sources.value(QStringLiteral("flathub")).toBool(false);
        screenshots = store.value(QStringLiteral("screenshots")).toBool(true);
    } else {
        m_autoAppearance = false;
    }
    m_formats = i18n::formatsLocale(i18n::systemLanguage(), formats);
    if (aur != m_aur || flathub != m_flathub || screenshots != m_screenshots) {
        const bool sourcesMoved = aur != m_aur || flathub != m_flathub;
        m_aur = aur;
        m_flathub = flathub;
        m_screenshots = screenshots;
        *m_screenshotGate = screenshotsAllowed();
        emit sourcesChanged();
        if (sourcesMoved && m_snapshot)
            run(Job{}); // the sources' apps come or go: the model is built again
    }
    const QString shortcuts = apps::shortcutStyle(shortcutSetting, m_macDevice);
    const bool canMinimize = apps::minimizeAvailableInFile();
    if (dark != m_dark || reduce != m_reduceMotion || contrast != m_increaseContrast || scale != m_textScale || accent != m_accentColor
        || highlight != m_accentHighlight || doubleClick != m_titlebarDoubleClick || canMinimize != m_canMinimize || shortcuts != m_shortcutStyle) {
        m_dark = dark;
        m_reduceMotion = reduce;
        m_increaseContrast = contrast;
        m_textScale = scale;
        m_accentColor = accent;
        m_accentHighlight = highlight;
        m_titlebarDoubleClick = doubleClick;
        m_canMinimize = canMinimize;
        m_shortcutStyle = shortcuts;
        emit appearanceChanged();
    }
}

void StoreBackend::readNetwork()
{
    if (env::offlineForced()) { // dev plumbing (ADR-0019)
        m_online = false;
        *m_screenshotGate = screenshotsAllowed();
        return;
    }
    // Without a reachability backend (no NetworkManager) the Store counts as online: a fetch that fails says so.
    if (!QNetworkInformation::instance() && !QNetworkInformation::loadBackendByFeatures(QNetworkInformation::Feature::Reachability))
        return;
    QNetworkInformation *info = QNetworkInformation::instance();
    const auto update = [this, info] {
        const auto reach = info->reachability();
        const bool online = reach == QNetworkInformation::Reachability::Online || reach == QNetworkInformation::Reachability::Unknown;
        const bool metered = info->supports(QNetworkInformation::Feature::Metered) && info->isMetered();
        if (online != m_online || metered != m_metered) {
            const bool cameOnline = online && !m_online;
            m_online = online;
            m_metered = metered;
            *m_screenshotGate = screenshotsAllowed();
            emit networkChanged();
            if (cameOnline && m_snapshot && !m_metered
                && ((m_snapshot->catalogConfigured && catalogStale()) || m_snapshot->appstream.origin == AppStreamData::Origin::None))
                run(Job{m_snapshot->catalogConfigured && catalogStale(), false, true});
        }
    };
    connect(info, &QNetworkInformation::reachabilityChanged, this, update);
    connect(info, &QNetworkInformation::isMeteredChanged, this, update);
    update();
}

bool StoreBackend::catalogStale() const
{
    const QDateTime at = m_snapshot ? m_snapshot->catalogFetchedAt : QDateTime();
    return !at.isValid() || at.secsTo(QDateTime::currentDateTimeUtc()) > kStaleHours * 3600;
}

void StoreBackend::start()
{
    // A first load from what is on this computer, at once; then the fetches it calls for. An operation an earlier run left
    // in store.json is compared with what is there (SR20), and pacman's lock read.
    run(Job{});
    m_operations->recover();
    checkStaleLock();
}

void StoreBackend::refresh()
{
    run(Job{true, true, true});
}

void StoreBackend::run(Job job)
{
    if (m_jobRunning) {
        // One job at a time; the next one does the most any waiting request asked for.
        if (m_pendingJob) {
            job.fetchCatalog = job.fetchCatalog || m_pendingJob->fetchCatalog;
            job.forced = job.forced || m_pendingJob->forced;
            job.fetchAppData = job.fetchAppData || m_pendingJob->fetchAppData;
        }
        m_pendingJob = job;
        return;
    }
    m_jobRunning = true;
    const bool fetching = job.fetchCatalog || job.fetchAppData;
    if (fetching != m_refreshing) {
        m_refreshing = fetching;
        emit loadingChanged();
    }
    // SR26: never on a metered connection unless asked (Ctrl+R), never offline.
    JobInput in{job.fetchCatalog && (job.forced || !m_metered), job.fetchAppData && (job.forced || !m_metered), m_online, m_aur};
    const std::shared_ptr<std::atomic_bool> cancel = m_cancel;
    m_pool.start([this, in, cancel] {
        std::shared_ptr<const Snapshot> snapshot = buildSnapshot(in, *cancel);
        if (*cancel)
            return;
        QMetaObject::invokeMethod(this, [this, snapshot] { apply(snapshot); }, Qt::QueuedConnection);
    });
}

void StoreBackend::apply(std::shared_ptr<const Snapshot> snapshot)
{
    const bool first = !m_snapshot;
    m_snapshot = std::move(snapshot);
    m_jobRunning = false;
    ++m_revision;
    const bool wasLoading = m_loading, wasRefreshing = m_refreshing;
    m_loading = false;
    m_refreshing = false;
    emit dataChanged();
    if (wasLoading != m_loading || wasRefreshing != m_refreshing)
        emit loadingChanged();
    if (m_pendingJob) {
        const Job next = *m_pendingJob;
        m_pendingJob.reset();
        run(next);
    } else if (first) {
        // After the first load: the catalog when its copy is stale, Arch's AppStream when none is installed or fetched.
        const bool catalog = m_snapshot->catalogConfigured && catalogStale();
        const bool appData = m_snapshot->appstream.origin != AppStreamData::Origin::Installed;
        if ((catalog || appData) && m_online)
            run(Job{catalog, false, appData});
    }
}

QVariantMap StoreBackend::catalogStatus() const
{
    QVariantMap out{{QStringLiteral("inUse"), false}, {QStringLiteral("problem"), QString()}, {QStringLiteral("channel"), QString()},
                    {QStringLiteral("date"), QString()}, {QStringLiteral("old"), false}};
    if (!m_snapshot)
        return out;
    const Snapshot &s = *m_snapshot;
    out.insert(QStringLiteral("channel"), s.channel);
    QString problem;
    if (!s.catalogConfigured)
        problem = QStringLiteral("unconfigured");
    else if (s.catalogOutcome == CatalogStore::Outcome::NoTrustedKey)
        problem = QStringLiteral("untrusted");
    else if (!s.fetchProblem.isEmpty())
        problem = s.fetchProblem;
    else if (s.catalogOutcome == CatalogStore::Outcome::BadSignature || s.catalogOutcome == CatalogStore::Outcome::Refused
             || s.catalogOutcome == CatalogStore::Outcome::Replayed)
        problem = QStringLiteral("refused");
    else if (!s.catalog)
        problem = QStringLiteral("unavailable");
    out.insert(QStringLiteral("problem"), problem);
    if (s.catalog) {
        const QDate made = QDateTime::fromString(s.catalog->generated, Qt::ISODate).date();
        out.insert(QStringLiteral("inUse"), true);
        out.insert(QStringLiteral("date"), view::dayText(made, m_formats, false));
        out.insert(QStringLiteral("old"), made.isValid() && made.daysTo(QDate::currentDate()) > kOldDays);
    }
    return out;
}

QVariantMap StoreBackend::appDataStatus() const
{
    QString origin = QStringLiteral("none");
    if (m_snapshot && m_snapshot->appstream.origin == AppStreamData::Origin::Installed)
        origin = QStringLiteral("installed");
    else if (m_snapshot && m_snapshot->appstream.origin == AppStreamData::Origin::Fetched)
        origin = QStringLiteral("fetched");
    return {{QStringLiteral("origin"), origin}, {QStringLiteral("problem"), m_snapshot ? m_snapshot->appstreamProblem : QString()}};
}

QVariantMap StoreBackend::sources() const
{
    return {{QStringLiteral("aur"), m_aur},
            {QStringLiteral("flathub"), m_flathub},
            {QStringLiteral("flatpak"), !QStandardPaths::findExecutable(QStringLiteral("flatpak")).isEmpty()},
            {QStringLiteral("screenshots"), m_screenshots}};
}

QVariantMap StoreBackend::readConfig() const
{
    QVariantMap out{{QStringLiteral("exists"), false}, {QStringLiteral("ok"), false}, {QStringLiteral("text"), QString()}};
    const QFileInfo info(configFile());
    if (!info.exists())
        return out;
    out.insert(QStringLiteral("exists"), true);
    // A regular file (a link to one is followed) of at most 1 MiB, read whole; anything else is not used, nothing written.
    if (!info.isFile() || info.size() > kConfigMax)
        return out;
    QFile f(info.filePath());
    if (!f.open(QIODevice::ReadOnly))
        return out;
    const QByteArray text = f.read(kConfigMax + 1);
    if (text.size() != info.size())
        return out;
    out.insert(QStringLiteral("text"), QString::fromUtf8(text));
    out.insert(QStringLiteral("ok"), true);
    return out;
}

QString StoreBackend::writeConfig(const QString &text) const
{
    const QByteArray bytes = text.toUtf8();
    if (bytes.size() > kConfigMax)
        return QStringLiteral("too large");
    const QString file = configFile();
    if (!QDir().mkpath(QFileInfo(file).absolutePath()))
        return QStringLiteral("cannot create its folder");
    QSaveFile f(file);
    if (!f.open(QIODevice::WriteOnly) || f.write(bytes) != bytes.size())
        return f.errorString();
    return f.commit() ? QString() : f.errorString();
}

QObject *StoreBackend::focusWindow() const
{
    return guiApp() ? QGuiApplication::focusWindow() : nullptr;
}

QVariantList StoreBackend::sections() const
{
    if (!m_snapshot)
        return {};
    const Snapshot &s = *m_snapshot;
    QVariantList out = s.catalog ? view::sections(*s.catalog, s.apps, s.index, s.tints, m_language) : QVariantList();
    const bool hasDiscover = !out.isEmpty() && out.constFirst().toMap().value(QStringLiteral("id")) == QLatin1String("discover");
    if (!hasDiscover)
        out.prepend(view::builtInDiscover(s.apps, s.categories(), m_language));
    return out;
}

QVariantList StoreBackend::categories() const
{
    QVariantList out;
    if (!m_snapshot)
        return out;
    for (const CatalogCategory &c : m_snapshot->categories()) {
        const int count = int(appsInCategory(m_snapshot->apps, c.id).size());
        if (count == 0)
            continue;
        out.append(QVariantMap{{QStringLiteral("id"), c.id},
                               {QStringLiteral("title"), c.title.pick(m_language)},
                               {QStringLiteral("symbol"), c.symbol},
                               {QStringLiteral("count"), count}});
    }
    return out;
}

QVariantList StoreBackend::categoryApps(const QString &id, const QString &kind) const
{
    QVariantList out;
    if (!m_snapshot)
        return out;
    for (const int i : appsInCategory(m_snapshot->apps, id)) {
        const StoreApp &a = m_snapshot->apps.at(i);
        if (kind.isEmpty() || view::sourceKind(a.source) == kind)
            out.append(view::summary(a, m_language));
    }
    return out;
}

QVariantList StoreBackend::search(const QString &query) const
{
    QVariantList out;
    if (!m_snapshot)
        return out;
    for (const int i : searchApps(m_snapshot->apps, query, m_language))
        out.append(view::summary(m_snapshot->apps.at(i), m_language));
    return out;
}

QVariantMap StoreBackend::app(const QString &id) const
{
    if (!m_snapshot || !m_snapshot->index.contains(id))
        return {};
    const StoreApp &a = m_snapshot->apps.at(m_snapshot->index.value(id));
    const AppStreamComponent *c = a.component >= 0 && a.component < m_snapshot->appstream.components.size()
        ? &m_snapshot->appstream.components.at(a.component) : nullptr;
    return view::detail(a, c, m_snapshot->categories(), m_language, m_formats);
}

void StoreBackend::requestPackageInfo(const QString &package)
{
    if (!isPackageName(package))
        return;
    const QLocale locale = m_formats;
    const QString program = env::pacman();
    const std::shared_ptr<std::atomic_bool> cancel = m_cancel;
    m_pool.start([this, package, program, locale, cancel] {
        const std::optional<PackageInfo> info = Pacman(program).info(package);
        if (*cancel)
            return;
        const QVariantMap facts = info ? view::packageFacts(*info, locale) : QVariantMap();
        QMetaObject::invokeMethod(this, [this, package, facts] { emit packageInfo(package, facts); }, Qt::QueuedConnection);
    });
}

QVariantList StoreBackend::installed() const
{
    QVariantList out;
    if (!m_snapshot)
        return out;
    const Snapshot &s = *m_snapshot;
    QVariantList arch, omarchy, setups, webApps, foreign;
    QSet<QString> catalogWebUrls;
    for (const StoreApp &a : s.apps) {
        if (!a.installed)
            continue;
        QVariantMap m = view::summary(a, m_language);
        m.insert(QStringLiteral("page"), true);
        if (a.source == CatalogSource::Kind::Repo && s.explicitPackages.contains(a.package))
            (a.repo == QLatin1String("omarchy") ? omarchy : arch).append(m);
        else if (a.source == CatalogSource::Kind::OmarchySetup)
            setups.append(m);
        else if (a.source == CatalogSource::Kind::WebApp && a.entry) {
            webApps.append(m);
            catalogWebUrls.insert(a.entry->source.url);
        }
    }
    for (const view::WebAppEntry &w : s.webApps) {
        if (catalogWebUrls.contains(w.url))
            continue;
        webApps.append(QVariantMap{{QStringLiteral("id"), QStringLiteral("webapp:") + w.file},
                                   {QStringLiteral("name"), w.name},
                                   {QStringLiteral("summary"), QUrl(w.url).host()},
                                   {QStringLiteral("icon"), w.icon.isEmpty() ? QString() : QUrl::fromLocalFile(w.icon).toString()},
                                   {QStringLiteral("kind"), QStringLiteral("webapp")},
                                   {QStringLiteral("installed"), true},
                                   {QStringLiteral("launcher"), true},
                                   {QStringLiteral("page"), false}});
    }
    QStringList names(s.foreignWithEntry.cbegin(), s.foreignWithEntry.cend());
    names.sort();
    for (const QString &n : names) {
        foreign.append(QVariantMap{{QStringLiteral("id"), QStringLiteral("package:") + n},
                                   {QStringLiteral("name"), n},
                                   {QStringLiteral("summary"), QString()},
                                   {QStringLiteral("icon"), QString()},
                                   {QStringLiteral("kind"), QStringLiteral("foreign")},
                                   {QStringLiteral("installed"), true},
                                   {QStringLiteral("launcher"), true},
                                   {QStringLiteral("page"), false}});
    }
    const QCollator collator(m_formats); // our own, as view::detail's (storeview.cpp)
    const auto byName = [&collator](QVariantList &list) {
        std::stable_sort(list.begin(), list.end(), [&collator](const QVariant &a, const QVariant &b) {
            return collator.compare(a.toMap().value(QStringLiteral("name")).toString(),
                                    b.toMap().value(QStringLiteral("name")).toString()) < 0;
        });
    };
    for (auto [group, list] : {std::pair{QStringLiteral("arch"), &arch}, std::pair{QStringLiteral("omarchy"), &omarchy},
                               std::pair{QStringLiteral("setup"), &setups}, std::pair{QStringLiteral("webapp"), &webApps},
                               std::pair{QStringLiteral("foreign"), &foreign}}) {
        if (list->isEmpty())
            continue;
        byName(*list);
        out.append(QVariantMap{{QStringLiteral("group"), group}, {QStringLiteral("apps"), *list}});
    }
    return out;
}

QVariantMap StoreBackend::updates() const
{
    const QByteArray json = readSmall(apps::runmode::stateDir() + QStringLiteral("/software-update.json"), 512 * 1024);
    return view::updates(json, m_snapshot ? m_snapshot->apps : QList<StoreApp>(), m_language, m_formats);
}

bool StoreBackend::openLink(const QString &url)
{
    // A product page's links (SR11): https only, through the user's browser; never from a dev session (ADR-0019).
    if (!isHttpsUrl(url) || devSession())
        return false;
    return apps::startApplication(QStringLiteral("xdg-open"), {url});
}

QString StoreBackend::screenshotSource(const QString &url) const
{
    if (!screenshotsAllowed() || !isHttpsUrl(url))
        return {};
    return QStringLiteral("image://screenshot/") + QString::fromLatin1(QUrl::toPercentEncoding(url));
}

QVariantList StoreBackend::operations() const
{
    return m_operations->list();
}

QVariantMap StoreBackend::results() const
{
    QVariantMap out;
    const auto all = m_operations->results();
    for (auto it = all.cbegin(); it != all.cend(); ++it) {
        out.insert(it.key(), QVariantMap{{QStringLiteral("kind"), it->kind},
                                         {QStringLiteral("name"), it->record.name},
                                         {QStringLiteral("outcome"), it->outcome},
                                         {QStringLiteral("present"), it->present},
                                         {QStringLiteral("total"), it->total},
                                         {QStringLiteral("details"), it->details}});
    }
    return out;
}

void StoreBackend::checkStaleLock()
{
    // db.lck there and no pacman running (its process name, /proc/<pid>/comm): pacman stopped mid-way (S6).
    bool stale = QFileInfo::exists(env::dbLock());
    if (stale && env::fixture().isEmpty()) {
        QDirIterator it(QStringLiteral("/proc"), QDir::Dirs | QDir::NoDotAndDotDot);
        while (stale && it.hasNext()) {
            const QString dir = it.next();
            if (QFileInfo(dir).fileName().toLongLong() > 0 && readSmall(dir + QStringLiteral("/comm"), 64).trimmed() == "pacman")
                stale = false;
        }
    }
    if (stale != m_staleLock) {
        m_staleLock = stale;
        emit operationsChanged();
    }
}

std::optional<view::WebAppEntry> StoreBackend::otherWebApp(const QString &id) const
{
    if (!m_snapshot || !id.startsWith(QLatin1String("webapp:")))
        return std::nullopt;
    const QString file = id.mid(7);
    for (const view::WebAppEntry &w : m_snapshot->webApps) {
        if (w.file == file && isWebAppName(w.file) && isHttpsUrl(w.url))
            return w;
    }
    return std::nullopt;
}

const StoreApp *StoreBackend::storeApp(const QString &id) const
{
    if (!m_snapshot || !m_snapshot->index.contains(id))
        return nullptr;
    return &m_snapshot->apps.at(m_snapshot->index.value(id));
}

QString StoreBackend::getBlock(const StoreApp &a) const
{
    switch (a.source) {
    case CatalogSource::Kind::Repo:
        if (env::pkexec().isEmpty())
            return QStringLiteral("dev");
        if (!apps::runmode::dev() && (!QFileInfo(env::helperPath).isExecutable() || !QFileInfo(env::pkexec()).isExecutable()))
            return QStringLiteral("missing");
        break;
    case CatalogSource::Kind::WebApp:
        if (apps::runmode::dev() && env::installer().isEmpty())
            return QStringLiteral("dev");
        if (!apps::runmode::dev() && !QFileInfo(env::omarchyCommand(QStringLiteral("omarchy-webapp-install"))).isExecutable())
            return QStringLiteral("missing");
        if (!a.entry)
            return QStringLiteral("source");
        if (a.icon.isEmpty())
            return QStringLiteral("icon"); // its icon is not cached yet (fetched with the catalog)
        break;
    case CatalogSource::Kind::OmarchySetup:
        if (const QString block = terminalBlock(); !block.isEmpty())
            return block;
        break;
    default:
        return QStringLiteral("source"); // the AUR and Flathub install with step 3's later parts (3b2, 3c)
    }
    return m_online ? QString() : QStringLiteral("offline");
}

QString StoreBackend::terminalBlock() const
{
    const QString launcher = QStringLiteral("omarchy-launch-floating-terminal-with-presentation");
    if (apps::runmode::dev() && env::installer().isEmpty())
        return QStringLiteral("dev");
    if (!apps::runmode::dev() && (!QFileInfo(env::omarchyCommand(launcher)).isExecutable() || !QFileInfo(env::runPath).isExecutable()))
        return QStringLiteral("missing");
    if (env::runDir().isEmpty())
        return QStringLiteral("missing");
    if (!m_snapshot || !m_snapshot->catalog || !m_snapshot->catalog->omarchy || !m_snapshot->omarchyDiffers.isEmpty())
        return QStringLiteral("omarchyChanged");
    return {};
}

SetupCheck StoreBackend::setupCheck(const StoreApp &a, bool install) const
{
    SetupCheck check;
    check.root = env::omarchyRoot();
    if (a.entry)
        check.recipe = install ? a.entry->source.install : a.entry->source.remove;
    if (m_snapshot && m_snapshot->catalog && m_snapshot->catalog->omarchy)
        check.pins = m_snapshot->catalog->omarchy->files;
    return check;
}

QString StoreBackend::uninstallBlock(const StoreApp &a) const
{
    if (!a.installed)
        return QStringLiteral("notInstalled");
    if (a.source == CatalogSource::Kind::WebApp) {
        if (apps::runmode::dev() && env::installer().isEmpty())
            return QStringLiteral("dev");
        if (!apps::runmode::dev() && !QFileInfo(env::omarchyCommand(QStringLiteral("omarchy-webapp-remove"))).isExecutable())
            return QStringLiteral("missing");
        return {};
    }
    if (a.source == CatalogSource::Kind::OmarchySetup && m_snapshot) {
        // The recipe removes its packages (omarchy-pkg-drop, pacman -Rns): never one the deny list names (b.1's list).
        for (const QString &p : a.packages) {
            switch (protection(p, m_snapshot->deny)) {
            case Protection::None:
                break;
            case Protection::System:
                return QStringLiteral("system");
            case Protection::Omarchy:
                return QStringLiteral("omarchy");
            case Protection::Grassfield:
                return QStringLiteral("grassfield");
            }
        }
        if (!m_snapshot->deny.omarchyRead())
            return QStringLiteral("listsMissing");
        return terminalBlock();
    }
    if (a.source != CatalogSource::Kind::Repo || !m_snapshot)
        return QStringLiteral("source");
    RemovalFacts facts;
    facts.installed = a.installed;
    facts.explicitlyInstalled = m_snapshot->explicitPackages.contains(a.package);
    facts.inRepository = std::any_of(m_snapshot->sync.cbegin(), m_snapshot->sync.cend(), [&a](const SyncPackage &p) { return p.name == a.package; });
    facts.ownsEntry = m_snapshot->entries.contains(a.package);
    switch (removal(a.package, facts, m_snapshot->deny)) {
    case Removal::Removable:
        break;
    case Removal::NotInstalled:
        return QStringLiteral("notInstalled");
    case Removal::PartOfSystem:
        return QStringLiteral("system");
    case Removal::PartOfOmarchy:
        return QStringLiteral("omarchy");
    case Removal::PartOfGrassfield:
        return QStringLiteral("grassfield");
    case Removal::Dependency:
        return QStringLiteral("dependency");
    case Removal::NotAnApp:
        return QStringLiteral("notApp");
    case Removal::NotFromRepository:
        return QStringLiteral("notFromRepository");
    case Removal::ListsMissing:
        return QStringLiteral("listsMissing");
    }
    if (env::pkexec().isEmpty())
        return QStringLiteral("dev");
    if (!apps::runmode::dev() && (!QFileInfo(env::helperPath).isExecutable() || !QFileInfo(env::pkexec()).isExecutable()))
        return QStringLiteral("missing");
    return {};
}

QVariantMap StoreBackend::actions(const QString &id) const
{
    if (const auto w = otherWebApp(id)) {
        const bool can = apps::runmode::dev() ? !env::installer().isEmpty()
                                              : QFileInfo(env::omarchyCommand(QStringLiteral("omarchy-webapp-remove"))).isExecutable();
        return {{QStringLiteral("installed"), true}, {QStringLiteral("launcher"), true}, {QStringLiteral("get"), QStringLiteral("installed")},
                {QStringLiteral("uninstall"), can ? QString() : (apps::runmode::dev() ? QStringLiteral("dev") : QStringLiteral("missing"))}};
    }
    const StoreApp *a = storeApp(id);
    if (!a)
        return {{QStringLiteral("installed"), false}, {QStringLiteral("launcher"), false},
                {QStringLiteral("get"), QStringLiteral("source")}, {QStringLiteral("uninstall"), QStringLiteral("source")}};
    const bool launcher = a->source == CatalogSource::Kind::WebApp ? a->installed : !a->desktopId.isEmpty();
    return {{QStringLiteral("installed"), a->installed},
            {QStringLiteral("launcher"), launcher},
            {QStringLiteral("get"), a->installed ? QStringLiteral("installed") : getBlock(*a)},
            {QStringLiteral("uninstall"), uninstallBlock(*a)}};
}

PlanTools StoreBackend::planTools() const
{
    PlanTools tools;
    tools.pacman = env::pacman();
    tools.dbLock = env::dbLock();
    tools.updateLock = env::updateLock();
    tools.devPlumbing = !env::fixture().isEmpty();
    const bool dev = tools.devPlumbing;
    tools.head = [dev](const QUrl &url) { return headStatus(url, kFetchMs, dev); };
    return tools;
}

namespace {

QVariantList packageList(const QList<PlannedPackage> &packages, const QLocale &locale)
{
    QVariantList out;
    for (const PlannedPackage &p : packages)
        out.append(QVariantMap{{QStringLiteral("name"), p.name},
                               {QStringLiteral("version"), p.version},
                               {QStringLiteral("repo"), p.repo},
                               {QStringLiteral("size"), view::sizeText(p.downloadSize, locale)}});
    return out;
}

QString refusalName(Refusal r)
{
    switch (r) {
    case Refusal::None:
        return {};
    case Refusal::Busy:
        return QStringLiteral("busy");
    case Refusal::Unfinished:
        return QStringLiteral("unfinished");
    case Refusal::Outdated:
        return QStringLiteral("outdated");
    case Refusal::Offline:
        return QStringLiteral("offline");
    case Refusal::Dependency:
        return QStringLiteral("dependency");
    case Refusal::Protected:
        return QStringLiteral("protected");
    case Refusal::OmarchyChanged:
        return QStringLiteral("omarchyChanged");
    case Refusal::Repository:
        return QStringLiteral("repository");
    case Refusal::NotOnAur:
        return QStringLiteral("notOnAur");
    case Refusal::Failed:
        return QStringLiteral("failed");
    }
    return QStringLiteral("failed");
}

} // namespace

void StoreBackend::plan(const QString &id, const QString &kind)
{
    if (otherWebApp(id)) {
        const bool ok = kind == QLatin1String("remove") && actions(id).value(QStringLiteral("uninstall")).toString().isEmpty();
        emit planReady(id, kind, ok ? QVariantMap{{QStringLiteral("refusal"), QString()}, {QStringLiteral("packages"), QVariantList()}}
                                    : QVariantMap{{QStringLiteral("refusal"), QStringLiteral("unavailable")}});
        return;
    }
    const StoreApp *a = storeApp(id);
    const bool install = kind == QLatin1String("install");
    if (!a || (!install && kind != QLatin1String("remove"))) {
        emit planReady(id, kind, {{QStringLiteral("refusal"), QStringLiteral("unavailable")}});
        return;
    }
    const QString block = install ? getBlock(*a) : uninstallBlock(*a);
    if (!block.isEmpty() && !(install && block == QLatin1String("offline"))) {
        emit planReady(id, kind, {{QStringLiteral("refusal"), QStringLiteral("unavailable")}, {QStringLiteral("detail"), block}});
        return;
    }
    if (a->source == CatalogSource::Kind::WebApp) {
        // The sheet alone (owner, ST3): nothing pacman plans; a launcher and its icon, in the user's own files.
        emit planReady(id, kind, {{QStringLiteral("refusal"), block == QLatin1String("offline") ? QStringLiteral("offline") : QString()},
                                  {QStringLiteral("packages"), QVariantList()}});
        return;
    }
    const PlanTools tools = planTools();
    const bool setup = a->source == CatalogSource::Kind::OmarchySetup;
    const QStringList packages = setup ? a->packages : QStringList{a->package};
    const SetupCheck check = setup ? setupCheck(*a, install) : SetupCheck{};
    const bool online = m_online;
    const bool own = m_operations->running();
    const DenyList deny = m_snapshot->deny;
    const QLocale locale = m_formats;
    const std::shared_ptr<std::atomic_bool> cancel = m_cancel;
    m_pool.start([this, id, kind, install, setup, packages, check, tools, online, own, deny, locale, cancel] {
        QVariantMap out;
        if (install) {
            InstallPlan p = setup ? checkSetupInstall(packages, check, tools, online, own) : checkInstall(packages, tools, online, own);
            out = {{QStringLiteral("refusal"), refusalName(p.refusal)},
                   {QStringLiteral("packages"), packageList(p.packages, locale)},
                   {QStringLiteral("download"), view::sizeText(p.downloadSize, locale)},
                   {QStringLiteral("installed"), view::sizeText(p.installedSize, locale)},
                   {QStringLiteral("unfinished"), p.unfinished},
                   {QStringLiteral("upgrades"), p.upgrades},
                   {QStringLiteral("detail"), p.detail}};
            if (*cancel)
                return;
            QMetaObject::invokeMethod(this, [this, id, kind, out, p] {
                if (p.refusal == Refusal::None)
                    m_installPlans.insert(id, p);
                else
                    m_installPlans.remove(id);
                emit planReady(id, kind, out);
            }, Qt::QueuedConnection);
        } else {
            RemovePlan p = setup ? checkSetupRemove(packages, check, deny, tools, own) : checkRemove(packages, deny, tools, own);
            out = {{QStringLiteral("refusal"), refusalName(p.refusal)},
                   {QStringLiteral("packages"), packageList(p.packages, locale)},
                   {QStringLiteral("dependents"), p.dependents},
                   {QStringLiteral("protected"), p.protectedPackage},
                   {QStringLiteral("detail"), p.detail}};
            if (*cancel)
                return;
            QMetaObject::invokeMethod(this, [this, id, kind, out, p] {
                if (p.refusal == Refusal::None)
                    m_removePlans.insert(id, p);
                else
                    m_removePlans.remove(id);
                emit planReady(id, kind, out);
            }, Qt::QueuedConnection);
        }
    });
}

bool StoreBackend::install(const QString &id)
{
    const StoreApp *a = storeApp(id);
    if (!a || a->installed || m_operations->queued(id) || !getBlock(*a).isEmpty())
        return false;
    OperationRecord r;
    r.id = newOperationId();
    r.kind = QStringLiteral("install");
    r.app = a->id;
    r.name = a->name.pick(m_language);
    if (a->source == CatalogSource::Kind::WebApp) {
        r.path = QStringLiteral("webapp");
        r.webName = a->name.pick(m_language);
        r.webUrl = a->entry->source.url;
        r.webIcon = a->icon;
        if (!isWebAppName(r.webName) || !isHttpsUrl(r.webUrl))
            return false;
    } else {
        // The plan its sheet showed (planReady); the helper, or grassfield-store-run for a setup, checks it all again.
        const auto it = m_installPlans.constFind(id);
        if (it == m_installPlans.cend() || it->packages.isEmpty())
            return false;
        if (a->source == CatalogSource::Kind::OmarchySetup) {
            const SetupCheck check = setupCheck(*a, true);
            r.path = QStringLiteral("terminal");
            r.packages = a->packages;
            r.recipe = check.recipe;
            r.args = a->entry->source.args;
            r.pins = check.pins;
        } else {
            r.path = QStringLiteral("helper");
            r.packages = {a->package};
        }
        r.plan = it->packages;
    }
    m_installPlans.remove(id);
    m_operations->enqueue(r);
    return true;
}

bool StoreBackend::uninstall(const QString &id)
{
    if (const auto w = otherWebApp(id)) {
        if (m_operations->queued(id) || !actions(id).value(QStringLiteral("uninstall")).toString().isEmpty())
            return false;
        OperationRecord r;
        r.id = newOperationId();
        r.kind = QStringLiteral("remove");
        r.path = QStringLiteral("webapp");
        r.app = id;
        r.name = w->name;
        r.webName = w->file;
        r.webUrl = w->url;
        m_operations->enqueue(r);
        return true;
    }
    const StoreApp *a = storeApp(id);
    if (!a || m_operations->queued(id) || !uninstallBlock(*a).isEmpty())
        return false;
    OperationRecord r;
    r.id = newOperationId();
    r.kind = QStringLiteral("remove");
    r.app = a->id;
    r.name = a->name.pick(m_language);
    if (a->source == CatalogSource::Kind::WebApp) {
        // The launcher's own name: the file Omarchy wrote for this address.
        QString file;
        for (const view::WebAppEntry &w : m_snapshot->webApps) {
            if (a->entry && w.url == a->entry->source.url)
                file = w.file;
        }
        if (!isWebAppName(file))
            return false;
        r.path = QStringLiteral("webapp");
        r.webName = file;
        r.webUrl = a->entry->source.url;
    } else {
        const auto it = m_removePlans.constFind(id);
        if (it == m_removePlans.cend() || it->packages.isEmpty())
            return false;
        if (a->source == CatalogSource::Kind::OmarchySetup) {
            const SetupCheck check = setupCheck(*a, false);
            r.path = QStringLiteral("terminal");
            r.packages = a->packages;
            r.recipe = check.recipe;
            r.args = a->entry->source.removeArgs;
            r.pins = check.pins;
        } else {
            r.path = QStringLiteral("helper");
            r.packages = {a->package};
        }
        r.plan = it->packages;
    }
    m_removePlans.remove(id);
    m_operations->enqueue(r);
    return true;
}

bool StoreBackend::removeWaiting(const QString &operationId)
{
    return m_operations->removeWaiting(operationId);
}

void StoreBackend::dismiss(const QString &id)
{
    m_operations->dismiss(id);
}

bool StoreBackend::open(const QString &id)
{
    const StoreApp *a = storeApp(id);
    const auto other = otherWebApp(id);
    if (!other && (!a || !a->installed))
        return false;
    QStringList argv;
    if (other) {
        argv = {QStringLiteral("omarchy-launch-webapp"), other->url};
    } else if (a->source == CatalogSource::Kind::WebApp) {
        // Omarchy's own launcher, which scopes the browser itself (S14: the entry's file name has spaces uwsm refuses).
        if (!a->entry || !isHttpsUrl(a->entry->source.url))
            return false;
        argv = {QStringLiteral("omarchy-launch-webapp"), a->entry->source.url};
    } else {
        if (!isDesktopId(a->desktopId))
            return false;
        argv = {QStringLiteral("uwsm-app"), QStringLiteral("--"), a->desktopId};
    }
    if (apps::runmode::dev()) {
        // Only through the fake program (ADR-0011's dev open policy: a dev session starts nothing of the owner's).
        const QString fake = env::installer();
        return !fake.isEmpty() && QProcess::startDetached(fake, argv);
    }
    if (argv.constFirst() == QLatin1String("omarchy-launch-webapp"))
        return QProcess::startDetached(env::omarchyCommand(argv.constFirst()), argv.mid(1));
    const QString uwsm = QStandardPaths::findExecutable(QStringLiteral("uwsm-app"));
    return !uwsm.isEmpty() && QProcess::startDetached(uwsm, argv.mid(1));
}

bool StoreBackend::openSoftwareUpdate()
{
    const QStringList argv{QStringLiteral("grassfield-settings"), QStringLiteral("--section=general")};
    if (apps::runmode::dev()) {
        const QString fake = env::installer();
        return !fake.isEmpty() && QProcess::startDetached(fake, argv);
    }
    return apps::startApplication(argv.constFirst(), argv.mid(1));
}

void StoreBackend::quitWhenIdle()
{
    if (!m_operations->running()) {
        QCoreApplication::quit();
        return;
    }
    // The running operation ends in pacman or Omarchy's command: the Store waits for it (it holds Omarchy's lock and keeps
    // the result), without a window; the waiting ones are dropped.
    for (const Operations::Item &i : m_operations->items()) {
        if (i.state == Operations::State::Waiting)
            m_operations->removeWaiting(i.record.id);
    }
    m_quitWhenIdle = true;
    if (guiApp()) {
        for (QWindow *w : QGuiApplication::topLevelWindows())
            w->close();
    }
}

} // namespace grassfield::store
