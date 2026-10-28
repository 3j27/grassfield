// The Store window's backend (ADR-0037 step 2) in a dev session with the fixture plumbing of ADR-0019: a fake pacman
// (GRASSFIELD_STORE_FIXTURE/bin/pacman), Arch's AppStream from the fixture, a catalog URL on disk, a keyring folder without
// a key, and every XDG folder in a scratch directory. Nothing reads the system's package manager, keys or home.
#include "storebackend.h"
#include "storeenv.h"
#include "storetest.h"

#include <QDir>
#include <QDirIterator>
#include <QEventLoop>
#include <QFileInfo>
#include <QTemporaryDir>
#include <QTimer>

#include <gtest/gtest.h>

using namespace grassfield::store;

namespace {

// The process environment of a dev session pointed at `root`, put back as it was afterwards.
class DevEnvironment
{
public:
    explicit DevEnvironment(const QString &root)
    {
        set("GRASSFIELD_DEV", "1");
        unset("GRASSFIELD_SESSION");
        set("GRASSFIELD_STORE_FIXTURE", root + QStringLiteral("/fixture"));
        set("GRASSFIELD_STORE_KEYRING", root + QStringLiteral("/keyring"));
        set("GRASSFIELD_STORE_CATALOG_URL", QUrl::fromLocalFile(root + QStringLiteral("/served/grassfield-catalog.v1.json")).toString());
        set("GRASSFIELD_CONFIG_HOME", root + QStringLiteral("/config"));
        set("GRASSFIELD_STATE_HOME", root + QStringLiteral("/state"));
        set("XDG_CACHE_HOME", root + QStringLiteral("/cache"));
        set("XDG_DATA_HOME", root + QStringLiteral("/data"));
        set("GRASSFIELD_LANG", "en_US");
    }
    ~DevEnvironment()
    {
        for (auto it = m_saved.cbegin(); it != m_saved.cend(); ++it) {
            if (it.value())
                qputenv(it.key().constData(), *it.value());
            else
                qunsetenv(it.key().constData());
        }
    }

    void set(const char *name, const QString &value)
    {
        save(name);
        qputenv(name, value.toUtf8());
    }
    void unset(const char *name)
    {
        save(name);
        qunsetenv(name);
    }

private:
    void save(const char *name)
    {
        if (!m_saved.contains(name))
            m_saved.insert(name, qEnvironmentVariableIsSet(name) ? std::optional<QByteArray>(qgetenv(name)) : std::nullopt);
    }
    QMap<QByteArray, std::optional<QByteArray>> m_saved;
};

// A fake pacman: the repositories' list, the explicit and foreign packages, the files of the foreign ones, one -Si.
const QByteArray kPacman = R"(case "$1" in
  -Sl) printf '%s\n' 'extra gimp 3.0.4-1 [installed]' 'extra sketch 2.1-1 [installed]' 'extra paint 1-1' 'extra cafe 1-1 [installed]' \
         'multilib steam 1.0-1' 'grassfield grassfield-desktop 1.0.0-1 [installed]' ;;
  -Qqe) printf '%s\n' gimp sketch yay grassfield-desktop ;;
  -Qqm) printf '%s\n' yay localapp grassfield-dev ;;
  -Ql) shift; [ "$1" = -- ] && shift
       for p in "$@"; do
         case $p in
           localapp) echo 'localapp /usr/share/applications/localapp.desktop' ;;
           yay) echo 'yay /usr/bin/yay' ;;
           grassfield-dev) echo 'grassfield-dev /usr/share/applications/dev.desktop' ;;
         esac
       done ;;
  -Si) [ "$3" = gimp ] || exit 1
       printf '%s\n' 'Repository      : extra' 'Name            : gimp' 'Version         : 3.0.4-1' 'Download Size   : 21.56 MiB' \
         'Installed Size  : 120.00 MiB' 'Build Date      : Thu Oct 15 08:27:03 2026' ;;
  *) exit 1 ;;
esac)";

struct Scratch {
    QTemporaryDir dir;
    std::unique_ptr<DevEnvironment> env;
    Scratch()
    {
        storetest::ensureApp();
        const QString root = dir.path();
        for (const char *sub : {"fixture/bin", "fixture/swcatalog/xml", "keyring", "served", "config", "state", "cache", "data/applications"})
            QDir().mkpath(root + QLatin1Char('/') + QLatin1String(sub));
        storetest::script(root + QStringLiteral("/fixture/bin/pacman"), kPacman);
        storetest::writeFile(root + QStringLiteral("/fixture/swcatalog/xml/extra.xml.gz"),
                             storetest::gzip(storetest::readFixture(QStringLiteral("appstream-extra.xml"))));
        storetest::writeFile(root + QStringLiteral("/fixture/swcatalog/xml/product.xml.gz"),
                             storetest::gzip(storetest::readFixture(QStringLiteral("appstream-product.xml"))));
        // Two web app launchers (Omarchy's), and a desktop entry of something else.
        storetest::writeFile(root + QStringLiteral("/data/applications/Mail.desktop"),
                             "[Desktop Entry]\nName=Mail\nExec=omarchy-launch-webapp \"https://mail.example.com/\"\nIcon=mail\n");
        storetest::writeFile(root + QStringLiteral("/data/applications/Chat.desktop"),
                             "[Desktop Entry]\nName=Chat\nExec=omarchy-launch-webapp https://chat.example.org\n");
        storetest::writeFile(root + QStringLiteral("/data/applications/editor.desktop"), "[Desktop Entry]\nName=Editor\nExec=vim\n");
        storetest::writeFile(root + QStringLiteral("/state/software-update.json"),
                             R"({"version":1,"state":"available","others":3,"grassfield":{"installed":"1.0.0-1","available":"1.0.1-1"},
                                 "otherPackages":[{"name":"gimp","installed":"3.0.4-1","available":"3.0.6-1"}]})");
        env = std::make_unique<DevEnvironment>(root);
    }
    QString path(const QString &rel) const { return dir.filePath(rel); }
};

// Waits until the backend has no job running (or 20 s passed).
bool settle(StoreBackend &backend)
{
    QEventLoop loop;
    QTimer timeout;
    timeout.setSingleShot(true);
    QObject::connect(&timeout, &QTimer::timeout, &loop, &QEventLoop::quit);
    timeout.start(20000);
    while (timeout.isActive() && (backend.loading() || backend.refreshing())) {
        QTimer::singleShot(20, &loop, &QEventLoop::quit);
        loop.exec();
    }
    // A follow-up fetch may start right after the first load: let it run too.
    for (int i = 0; i < 25 && timeout.isActive(); ++i) {
        QTimer::singleShot(20, &loop, &QEventLoop::quit);
        loop.exec();
        if (backend.loading() || backend.refreshing())
            i = 0;
    }
    return timeout.isActive();
}

// The packageInfo answers, collected; wait() returns once there are `count` of them (or 10 s passed).
struct Answers {
    QList<std::pair<QString, QVariantMap>> list;
    explicit Answers(StoreBackend &backend)
    {
        QObject::connect(&backend, &StoreBackend::packageInfo, &backend,
                         [this](const QString &package, const QVariantMap &facts) { list.append({package, facts}); });
    }
    bool wait(int count)
    {
        QEventLoop loop;
        for (int i = 0; i < 500 && list.size() < count; ++i) {
            QTimer::singleShot(20, &loop, &QEventLoop::quit);
            loop.exec();
        }
        return list.size() >= count;
    }
};

QStringList ids(const QVariantList &list)
{
    QStringList out;
    for (const QVariant &v : list)
        out.append(v.toMap().value(QStringLiteral("id")).toString());
    return out;
}

} // namespace

// No catalog yet (none served, then one whose signature no key in the keyring makes): the built-in Discover and
// categories, AppStream's apps, the local search, a product page, Installed and the Updates list all work.
TEST(StoreBackend, WithoutACatalog)
{
    Scratch s;
    StoreBackend backend;
    EXPECT_TRUE(backend.devSession());
    EXPECT_EQ(backend.language(), QStringLiteral("en"));
    EXPECT_TRUE(backend.loading());
    backend.start();
    ASSERT_TRUE(settle(backend));
    EXPECT_FALSE(backend.loading());
    EXPECT_GE(backend.revision(), 1);

    const QVariantMap catalog = backend.catalogStatus();
    EXPECT_FALSE(catalog.value(QStringLiteral("inUse")).toBool());
    EXPECT_EQ(catalog.value(QStringLiteral("problem")), QStringLiteral("unavailable")); // nothing served
    EXPECT_EQ(catalog.value(QStringLiteral("channel")), QStringLiteral("stable"));
    EXPECT_EQ(backend.appDataStatus().value(QStringLiteral("origin")), QStringLiteral("installed"));

    // Discover is the built-in one: rows by category, GIMP (Graphics) among them.
    const QVariantList sections = backend.sections();
    ASSERT_EQ(ids(sections), QStringList{QStringLiteral("discover")});
    EXPECT_TRUE(sections.at(0).toMap().value(QStringLiteral("builtIn")).toBool());
    const QVariantList categories = backend.categories();
    EXPECT_TRUE(ids(categories).contains(QStringLiteral("graphics")));
    EXPECT_EQ(ids(backend.categoryApps(QStringLiteral("graphics"))),
              (QStringList{QStringLiteral("org.gimp.GIMP"), QStringLiteral("org.example.Paint")}));
    EXPECT_TRUE(backend.categoryApps(QStringLiteral("graphics"), QStringLiteral("webapp")).isEmpty());
    EXPECT_EQ(ids(backend.search(QStringLiteral("gimp"))).value(0), QStringLiteral("org.gimp.GIMP"));
    EXPECT_TRUE(backend.search(QStringLiteral("zzzz")).isEmpty());

    const QVariantMap sketch = backend.app(QStringLiteral("org.example.Sketch"));
    EXPECT_EQ(sketch.value(QStringLiteral("name")), QStringLiteral("Sketch Pad"));
    EXPECT_EQ(sketch.value(QStringLiteral("releases")).toList().size(), 3);
    EXPECT_TRUE(backend.app(QStringLiteral("org.example.Nothing")).isEmpty());

    // pacman -Si answers the Information list.
    Answers info(backend);
    backend.requestPackageInfo(QStringLiteral("gimp"));
    ASSERT_TRUE(info.wait(1));
    EXPECT_EQ(info.list.at(0).first, QStringLiteral("gimp"));
    EXPECT_EQ(info.list.at(0).second.value(QStringLiteral("version")), QStringLiteral("3.0.4-1"));
    EXPECT_EQ(info.list.at(0).second.value(QStringLiteral("buildDate")), QStringLiteral("October 15, 2026"));
    backend.requestPackageInfo(QStringLiteral("-rf")); // not a package name: no query
    backend.requestPackageInfo(QStringLiteral("cafe"));
    ASSERT_TRUE(info.wait(2));
    EXPECT_EQ(info.list.size(), 2);
    EXPECT_EQ(info.list.at(1).first, QStringLiteral("cafe"));
    EXPECT_TRUE(info.list.at(1).second.isEmpty()); // pacman knows nothing: no facts

    // Installed: explicit packages with metadata, then web apps, then packages no repository has that own an entry.
    const QVariantList installed = backend.installed();
    QStringList groups;
    for (const QVariant &g : installed)
        groups.append(g.toMap().value(QStringLiteral("group")).toString());
    EXPECT_EQ(groups, (QStringList{QStringLiteral("arch"), QStringLiteral("webapp"), QStringLiteral("foreign")}));
    EXPECT_EQ(ids(installed.at(0).toMap().value(QStringLiteral("apps")).toList()),
              (QStringList{QStringLiteral("org.gimp.GIMP"), QStringLiteral("org.example.Sketch")})); // cafe is not explicit
    EXPECT_EQ(ids(installed.at(1).toMap().value(QStringLiteral("apps")).toList()),
              (QStringList{QStringLiteral("webapp:Chat"), QStringLiteral("webapp:Mail")}));
    EXPECT_EQ(ids(installed.at(2).toMap().value(QStringLiteral("apps")).toList()), QStringList{QStringLiteral("package:localapp")});

    const QVariantMap updates = backend.updates();
    EXPECT_EQ(updates.value(QStringLiteral("state")), QStringLiteral("available"));
    EXPECT_EQ(ids(updates.value(QStringLiteral("apps")).toList()), QStringList{QStringLiteral("org.gimp.GIMP")});
    EXPECT_EQ(updates.value(QStringLiteral("otherCount")).toInt(), 2);

    // Links never open from a dev session; screenshots are https only.
    EXPECT_FALSE(backend.openLink(QStringLiteral("https://www.gimp.org/")));
    EXPECT_TRUE(backend.screenshotSource(QStringLiteral("http://example.com/a.png")).isEmpty());
    EXPECT_EQ(backend.screenshotSource(QStringLiteral("https://example.com/a b.png")), QString()); // a space: not an https URL
    if (backend.online()) {
        EXPECT_EQ(backend.screenshotSource(QStringLiteral("https://example.com/a.png")),
                  QStringLiteral("image://screenshot/https%3A%2F%2Fexample.com%2Fa.png"));
    }

    // A catalog served now, signed by no key the keyring trusts (it has none): fetched on Ctrl+R, refused, not used.
    storetest::writeFile(s.path(QStringLiteral("served/grassfield-catalog.v1.json")), storetest::readFixture(QStringLiteral("catalog-good.json")));
    storetest::writeFile(s.path(QStringLiteral("served/grassfield-catalog.v1.json.sig")), "not a signature");
    const int before = backend.revision();
    backend.refresh();
    EXPECT_TRUE(backend.refreshing());
    ASSERT_TRUE(settle(backend));
    EXPECT_GT(backend.revision(), before);
    EXPECT_FALSE(backend.catalogStatus().value(QStringLiteral("inUse")).toBool());
    EXPECT_EQ(backend.catalogStatus().value(QStringLiteral("problem")), QStringLiteral("untrusted"));
    EXPECT_TRUE(backend.sections().at(0).toMap().value(QStringLiteral("builtIn")).toBool());
}

// French: the catalog's words come in French where the built-in categories have them.
// GRASSFIELD_STORE_OFFLINE is dev plumbing (ADR-0019): in a dev session the Store counts as offline, so screenshotSource
// gives nothing and the screenshot provider's gate is shut; a packaged session (GRASSFIELD_SESSION=1) ignores it.
TEST(StoreEnv, OfflineOnlyInADevSession)
{
    Scratch s;
    s.env->set("GRASSFIELD_STORE_OFFLINE", QStringLiteral("1"));
    {
        StoreBackend backend;
        EXPECT_TRUE(env::offlineForced());
        EXPECT_FALSE(backend.online());
        EXPECT_FALSE(backend.screenshotGate()->load());
        EXPECT_TRUE(backend.screenshotSource(QStringLiteral("https://example.org/shot.png")).isEmpty());
    }
    s.env->set("GRASSFIELD_SESSION", QStringLiteral("1"));
    EXPECT_FALSE(env::offlineForced());
    s.env->unset("GRASSFIELD_SESSION");
    s.env->unset("GRASSFIELD_DEV");
    EXPECT_FALSE(env::offlineForced());
}

// The Store's own keys of grassfield.json (SD20): read with the contract's rule (not a boolean: the default), followed while
// the Store runs, and the file read and written whole for the settings window's switches (Preferences.js sets the key).
TEST(StoreBackend, SourcesFromGrassfieldJson)
{
    Scratch s;
    const QString config = s.path(QStringLiteral("config/grassfield.json"));
    {
        StoreBackend backend;
        EXPECT_FALSE(backend.sources().value(QStringLiteral("aur")).toBool());
        EXPECT_FALSE(backend.sources().value(QStringLiteral("flathub")).toBool());
        EXPECT_TRUE(backend.sources().value(QStringLiteral("screenshots")).toBool());
        EXPECT_FALSE(backend.readConfig().value(QStringLiteral("exists")).toBool());
    }
    storetest::writeFile(config, R"({"version":1,"store":{"sources":{"aur":true,"flathub":"yes"},"screenshots":false}})");
    {
        StoreBackend backend;
        EXPECT_TRUE(backend.sources().value(QStringLiteral("aur")).toBool());
        EXPECT_FALSE(backend.sources().value(QStringLiteral("flathub")).toBool()); // a string: the default
        EXPECT_FALSE(backend.sources().value(QStringLiteral("screenshots")).toBool());
        EXPECT_FALSE(backend.screenshotGate()->load());
        EXPECT_TRUE(backend.screenshotSource(QStringLiteral("https://example.com/a.png")).isEmpty());

        // Written whole, then followed: the switch's key changes, the source goes.
        const QVariantMap read = backend.readConfig();
        ASSERT_TRUE(read.value(QStringLiteral("ok")).toBool());
        EXPECT_TRUE(read.value(QStringLiteral("text")).toString().contains(QLatin1String("\"aur\":true")));
        int changes = 0;
        QObject::connect(&backend, &StoreBackend::sourcesChanged, &backend, [&changes] { ++changes; });
        EXPECT_EQ(backend.writeConfig(QStringLiteral("{\n  \"version\": 1,\n  \"store\": {\"sources\": {\"aur\": false}}\n}\n")), QString());
        QEventLoop loop;
        for (int i = 0; i < 250 && changes == 0; ++i) {
            QTimer::singleShot(20, &loop, &QEventLoop::quit);
            loop.exec();
        }
        EXPECT_GE(changes, 1);
        EXPECT_FALSE(backend.sources().value(QStringLiteral("aur")).toBool());
        EXPECT_TRUE(backend.sources().value(QStringLiteral("screenshots")).toBool());

        // Never more than 1 MiB, either way; a folder in the file's place is not read.
        EXPECT_EQ(backend.writeConfig(QString(1024 * 1024 + 1, QLatin1Char(' '))), QStringLiteral("too large"));
        storetest::writeFile(config, QByteArray(1024 * 1024 + 1, ' '));
        EXPECT_TRUE(backend.readConfig().value(QStringLiteral("exists")).toBool());
        EXPECT_FALSE(backend.readConfig().value(QStringLiteral("ok")).toBool());
        QFile::remove(config);
        ASSERT_TRUE(QDir().mkpath(config));
        EXPECT_FALSE(backend.readConfig().value(QStringLiteral("ok")).toBool());
    }
}

// The AUR (step 3b2) through the dev plumbing's folder of answers (GRASSFIELD_STORE_AUR_URL, tests/fixtures/store/aur), turned
// on in grassfield.json: a search after Return (the repositories' names left out), an AUR page and its info, the build
// script, Installed's "AUR" group; nothing of it while the switch is off, and nothing asked by itself on a metered
// connection. The Store counts as online here whatever the machine's network (GRASSFIELD_STORE_OFFLINE=0, dev plumbing):
// the AUR is asked only online.
TEST(StoreBackend, TheAur)
{
    Scratch s;
    s.env->set("GRASSFIELD_STORE_AUR_URL", QUrl::fromLocalFile(QStringLiteral(STORE_FIXTURES "/aur")).toString());
    s.env->set("GRASSFIELD_STORE_OFFLINE", QStringLiteral("0"));
    // Whether the AUR was asked at all: its answers are cached (aur/ in the Store's cache), whoever asked.
    const auto aurCached = [&s](const QString &kind) {
        QDirIterator it(s.path(QStringLiteral("cache/grassfield/store/aur/")) + kind, QDir::Files, QDirIterator::Subdirectories);
        return it.hasNext();
    };
    // pacman: example-app-bin installed explicitly from outside the repositories; example-lib only as its dependency; gimp a
    // repository's package that is also an AUR result here.
    storetest::script(s.path(QStringLiteral("fixture/bin/pacman")), R"(case "$1" in
  -Sl) printf '%s\n' 'extra gimp 3.0.4-1 [installed]' 'extra example-lib 1.3-2' ;;
  -Qqe) printf '%s\n' gimp example-app-bin ;;
  -Qqm) printf '%s\n' example-app-bin example-tool-git localapp ;;
  -Ql) shift; [ "$1" = -- ] && shift; for p in "$@"; do [ "$p" = localapp ] && echo 'localapp /usr/share/applications/localapp.desktop'; done ;;
  *) exit 1 ;;
esac)");
    const auto wait = [](auto done) {
        QEventLoop loop;
        for (int i = 0; i < 500 && !done(); ++i) {
            QTimer::singleShot(20, &loop, &QEventLoop::quit);
            loop.exec();
        }
        return done();
    };
    // Long enough for an answer the AUR's folder gives at once (a request that should not have been made) to come.
    const auto pause = [] {
        QEventLoop loop;
        for (int i = 0; i < 40; ++i) {
            QTimer::singleShot(20, &loop, &QEventLoop::quit);
            loop.exec();
        }
    };
    {
        StoreBackend backend; // the AUR off: nothing asked (a search, a page, a build script, the foreign names), no AUR page
        ASSERT_TRUE(backend.online());
        backend.start();
        ASSERT_TRUE(settle(backend));
        QString problem;
        QObject::connect(&backend, &StoreBackend::aurResults, &backend, [&problem](const QString &, const QVariantList &, const QString &p) { problem = p; });
        int infos = 0, scripts = 0;
        bool scriptOk = true;
        QObject::connect(&backend, &StoreBackend::aurInfo, &backend, [&infos] { ++infos; });
        QObject::connect(&backend, &StoreBackend::buildScript, &backend, [&](const QString &, const QString &, bool ok) {
            ++scripts;
            scriptOk = ok;
        });
        backend.searchAur(QStringLiteral("example"));
        EXPECT_EQ(problem, QStringLiteral("off"));
        backend.requestAur(QStringLiteral("aur:example-app-bin"));
        backend.requestBuildScript(QStringLiteral("aur:example-app-bin"));
        wait([&scripts] { return scripts > 0; });
        pause();
        EXPECT_EQ(scripts, 1);
        EXPECT_FALSE(scriptOk) << "no build script while the AUR is off";
        EXPECT_EQ(infos, 0);
        EXPECT_FALSE(aurCached(QString())) << "the AUR was asked while it is off";
        EXPECT_TRUE(backend.app(QStringLiteral("aur:example-app-bin")).isEmpty());
        for (const QVariant &g : backend.installed())
            EXPECT_NE(g.toMap().value(QStringLiteral("group")), QStringLiteral("aur"));
    }
    storetest::writeFile(s.path(QStringLiteral("config/grassfield.json")), R"({"version":1,"store":{"sources":{"aur":true}}})");
    QDir().mkpath(s.path(QStringLiteral("fixture/omarchy/install")));
    storetest::writeFile(s.path(QStringLiteral("fixture/omarchy/install/omarchy-base.packages")), "btop\n");
    {
        // On a metered connection, the AUR on: nothing asked by itself (Installed's foreign names); a search after Return
        // is the user's and goes.
        s.env->set("GRASSFIELD_STORE_OFFLINE", QStringLiteral("metered"));
        StoreBackend backend;
        backend.start();
        ASSERT_TRUE(settle(backend));
        pause();
        EXPECT_FALSE(aurCached(QStringLiteral("info"))) << "the foreign names were asked on a metered connection";
        for (const QVariant &g : backend.installed())
            EXPECT_NE(g.toMap().value(QStringLiteral("group")), QStringLiteral("aur"));
        int answers = 0;
        QVariantList results;
        QObject::connect(&backend, &StoreBackend::aurResults, &backend, [&](const QString &, const QVariantList &list, const QString &) {
            results = list;
            ++answers;
        });
        backend.searchAur(QStringLiteral("example"));
        ASSERT_TRUE(wait([&answers] { return answers == 1; }));
        EXPECT_FALSE(results.isEmpty());
        s.env->set("GRASSFIELD_STORE_OFFLINE", QStringLiteral("0"));
    }
    StoreBackend backend;
    backend.start();
    ASSERT_TRUE(settle(backend));

    // Installed: example-app-bin (explicit, from outside the repositories, known to the AUR) under "AUR", with its page;
    // localapp (unknown to the AUR, with an entry) stays "Not from a repository".
    ASSERT_TRUE(wait([&backend] {
        for (const QVariant &g : backend.installed()) {
            if (g.toMap().value(QStringLiteral("group")) == QLatin1String("aur"))
                return true;
        }
        return false;
    }));
    QHash<QString, QStringList> groups;
    for (const QVariant &g : backend.installed())
        groups.insert(g.toMap().value(QStringLiteral("group")).toString(), ids(g.toMap().value(QStringLiteral("apps")).toList()));
    EXPECT_EQ(groups.value(QStringLiteral("aur")), QStringList{QStringLiteral("aur:example-app-bin")});
    EXPECT_EQ(groups.value(QStringLiteral("foreign")), QStringList{QStringLiteral("package:localapp")});

    // A search after Return: the AUR's results, a repository's name (example-lib) left out.
    QString term, problem;
    QVariantList results;
    int answers = 0;
    QObject::connect(&backend, &StoreBackend::aurResults, &backend, [&](const QString &t, const QVariantList &list, const QString &p) {
        term = t;
        results = list;
        problem = p;
        ++answers;
    });
    backend.searchAur(QStringLiteral("example"));
    ASSERT_TRUE(wait([&answers] { return answers == 1; }));
    EXPECT_EQ(term, QStringLiteral("example"));
    EXPECT_EQ(problem, QString());
    EXPECT_EQ(ids(results), (QStringList{QStringLiteral("aur:example-app-bin"), QStringLiteral("aur:example-tool-git")}));
    EXPECT_EQ(results.at(0).toMap().value(QStringLiteral("votes")).toInt(), 120);
    EXPECT_EQ(results.at(0).toMap().value(QStringLiteral("kind")), QStringLiteral("aur"));
    EXPECT_TRUE(results.at(0).toMap().value(QStringLiteral("installed")).toBool());
    EXPECT_TRUE(results.at(1).toMap().value(QStringLiteral("outOfDate")).toBool());
    backend.searchAur(QStringLiteral("x"));
    ASSERT_TRUE(wait([&answers] { return answers == 2; }));
    EXPECT_EQ(problem, QStringLiteral("short"));

    // The page: a search's facts first, then its info answer's (its dependencies).
    QVariantMap tool = backend.app(QStringLiteral("aur:example-tool-git"));
    EXPECT_EQ(tool.value(QStringLiteral("name")), QStringLiteral("example-tool-git"));
    EXPECT_EQ(tool.value(QStringLiteral("summary")), QStringLiteral("A tool from the development branch"));
    EXPECT_FALSE(tool.value(QStringLiteral("aurRead")).toBool());
    EXPECT_EQ(tool.value(QStringLiteral("aur")).toMap().value(QStringLiteral("maintainer")), QStringLiteral("bob"));
    QStringList infos;
    QObject::connect(&backend, &StoreBackend::aurInfo, &backend, [&infos](const QString &id) { infos.append(id); });
    backend.requestAur(QStringLiteral("aur:example-tool-git"));
    ASSERT_TRUE(wait([&infos] { return infos.size() == 1; }));
    tool = backend.app(QStringLiteral("aur:example-tool-git"));
    EXPECT_TRUE(tool.value(QStringLiteral("aurRead")).toBool());
    EXPECT_EQ(tool.value(QStringLiteral("aur")).toMap().value(QStringLiteral("depends")).toStringList(),
              (QStringList{QStringLiteral("example-app-bin"), QStringLiteral("python")}));
    EXPECT_TRUE(tool.value(QStringLiteral("installed")).toBool()); // pacman -Qm lists it

    // Its build script, plain text.
    QString script;
    bool scriptOk = false;
    QObject::connect(&backend, &StoreBackend::buildScript, &backend, [&](const QString &, const QString &text, bool ok) {
        script = text;
        scriptOk = ok;
    });
    backend.requestBuildScript(QStringLiteral("aur:example-app-bin"));
    ASSERT_TRUE(wait([&scriptOk] { return scriptOk; }));
    EXPECT_TRUE(script.startsWith(QLatin1String("# Maintainer: alice")));

    // Get and Uninstall… go through Omarchy's terminal, which a dev session without its fake program never opens; an AUR name a
    // repository has is not offered from the AUR.
    const QVariantMap actions = backend.actions(QStringLiteral("aur:example-app-bin"));
    EXPECT_TRUE(actions.value(QStringLiteral("installed")).toBool());
    EXPECT_EQ(actions.value(QStringLiteral("get")), QStringLiteral("installed"));
    EXPECT_EQ(actions.value(QStringLiteral("uninstall")), QStringLiteral("dev"));
    backend.requestAur(QStringLiteral("aur:example-lib"));
    ASSERT_TRUE(wait([&infos] { return infos.size() == 2; }));
    EXPECT_EQ(backend.actions(QStringLiteral("aur:example-lib")).value(QStringLiteral("get")), QStringLiteral("repository"));
    EXPECT_EQ(backend.actions(QStringLiteral("aur:example-lib")).value(QStringLiteral("uninstall")), QStringLiteral("notInstalled"));
    // Installed from outside the repositories but only as another package's dependency (pacman -Qqm, not -Qqe): no
    // Uninstall… (a dependency), whatever else.
    EXPECT_EQ(backend.actions(QStringLiteral("aur:example-tool-git")).value(QStringLiteral("uninstall")), QStringLiteral("dependency"));
    // With Omarchy's terminal (the fake program) but no catalog to pin the AUR's commands: refused as unchecked, nothing run.
    s.env->set("GRASSFIELD_STORE_INSTALLER", QStringLiteral("/bin/true"));
    EXPECT_EQ(backend.actions(QStringLiteral("aur:example-app-bin")).value(QStringLiteral("uninstall")), QStringLiteral("omarchyChanged"));

    // The switch turned off while the Store runs: its pages go (an id it remembers is no app any more).
    int changes = 0;
    QObject::connect(&backend, &StoreBackend::sourcesChanged, &backend, [&changes] { ++changes; });
    ASSERT_EQ(backend.writeConfig(QStringLiteral("{\"version\":1,\"store\":{\"sources\":{\"aur\":false}}}\n")), QString());
    ASSERT_TRUE(wait([&changes] { return changes > 0; }));
    EXPECT_TRUE(backend.app(QStringLiteral("aur:example-app-bin")).isEmpty());
    EXPECT_EQ(backend.actions(QStringLiteral("aur:example-app-bin")).value(QStringLiteral("get")), QStringLiteral("source"));
}

TEST(StoreBackend, FrenchSession)
{
    Scratch s;
    qputenv("GRASSFIELD_LANG", "fr_FR");
    StoreBackend backend;
    EXPECT_EQ(backend.language(), QStringLiteral("fr"));
    backend.start();
    ASSERT_TRUE(settle(backend));
    QStringList titles;
    for (const QVariant &c : backend.categories())
        titles.append(c.toMap().value(QStringLiteral("title")).toString());
    EXPECT_TRUE(titles.contains(QStringLiteral("Graphisme")));
}

// The real gpgv on the throwaway keys of tests/integration/store_catalog.sh (STORE_TEST_REAL_GPGV): the fixture catalog
// served with its good signature is accepted and used (its sections, Discover first, the hero's app and its tint field),
// then a copy signed by the revoked key is refused on Ctrl+R and the accepted one stays in use.
TEST(StoreBackend, RealSignedCatalog)
{
    const QString keys = qEnvironmentVariable("STORE_TEST_REAL_GPGV");
    if (keys.isEmpty())
        GTEST_SKIP() << "tests/integration/store_catalog.sh runs it in a throwaway container";
    Scratch s;
    QDir(s.path(QStringLiteral("keyring"))).removeRecursively();
    QDir().mkpath(s.path(QStringLiteral("keyring")));
    for (const char *f : {"grassfield.gpg", "grassfield-trusted", "grassfield-revoked"})
        QFile::copy(keys + QLatin1Char('/') + QLatin1String(f), s.path(QStringLiteral("keyring/")) + QLatin1String(f));
    const QString served = s.path(QStringLiteral("served/grassfield-catalog.v1.json"));
    QFile::copy(keys + QStringLiteral("/catalog.json"), served);
    QFile::copy(keys + QStringLiteral("/good.sig"), served + QStringLiteral(".sig"));
    StoreBackend backend;
    backend.start();
    ASSERT_TRUE(settle(backend));
    const QVariantMap status = backend.catalogStatus();
    EXPECT_TRUE(status.value(QStringLiteral("inUse")).toBool()) << status.value(QStringLiteral("problem")).toString().toStdString();
    EXPECT_EQ(status.value(QStringLiteral("problem")), QString());
    EXPECT_EQ(status.value(QStringLiteral("date")), QStringLiteral("October 27"));
    const QVariantList sections = backend.sections();
    ASSERT_FALSE(sections.isEmpty());
    EXPECT_EQ(sections.at(0).toMap().value(QStringLiteral("id")), QStringLiteral("discover"));
    EXPECT_FALSE(sections.at(0).toMap().value(QStringLiteral("builtIn")).toBool());
    const QVariantMap hero = sections.at(0).toMap().value(QStringLiteral("blocks")).toList().at(0).toMap();
    EXPECT_EQ(hero.value(QStringLiteral("kind")), QStringLiteral("hero"));
    EXPECT_EQ(hero.value(QStringLiteral("items")).toList().at(0).toMap().value(QStringLiteral("app")).toMap().value(QStringLiteral("id")),
              QStringLiteral("org.gimp.GIMP"));
    // The catalog's categories now (graphics, games, music-audio).
    QStringList ids;
    for (const QVariant &c : backend.categories())
        ids.append(c.toMap().value(QStringLiteral("id")).toString());
    EXPECT_TRUE(ids.contains(QStringLiteral("graphics")));

    // A setup (b.2): no recipe in the installed Omarchy, hidden; with the files the catalog pins, offered (offline aside);
    // once one of them differs, refused until the catalog has checked the new one.
    const QString steam = QStringLiteral("com.valvesoftware.Steam.desktop");
    EXPECT_TRUE(backend.app(steam).isEmpty()) << "Omarchy has no such recipe here";
    s.env->set("GRASSFIELD_STORE_INSTALLER", QStringLiteral("/bin/true"));
    for (const QString &rel : {QStringLiteral("bin/omarchy-install-gaming-steam"), QStringLiteral("bin/omarchy-remove-gaming-steam"),
                               QStringLiteral("install/helpers/steam.sh")}) {
        const QString file = s.path(QStringLiteral("fixture/omarchy/")) + rel;
        QDir().mkpath(QFileInfo(file).path());
        storetest::script(file, "# made up for the Store's tests: " + rel.toUtf8());
    }
    backend.refresh();
    ASSERT_TRUE(settle(backend));
    ASSERT_FALSE(backend.app(steam).isEmpty());
    const QString get = backend.actions(steam).value(QStringLiteral("get")).toString();
    EXPECT_TRUE(get.isEmpty() || get == QLatin1String("offline")) << qPrintable(get);
    EXPECT_EQ(backend.actions(steam).value(QStringLiteral("uninstall")).toString(), QStringLiteral("notInstalled"));
    // The catalog's AUR app (step 3b2): not in the Store while the AUR is off (the model leaves it out); once it is on, with
    // Omarchy's terminal there and the pins matching, refused while the catalog does not pin the AUR's command and the
    // omarchy-pkg-missing it calls (this fixture pins only the Steam setup's files).
    const QString aurGame = QStringLiteral("aur-game");
    EXPECT_TRUE(backend.app(aurGame).isEmpty()) << "a catalog AUR app while the AUR is off";
    s.env->set("GRASSFIELD_STORE_AUR_URL", QUrl::fromLocalFile(QStringLiteral(STORE_FIXTURES "/aur")).toString());
    int changes = 0;
    QObject::connect(&backend, &StoreBackend::sourcesChanged, &backend, [&changes] { ++changes; });
    ASSERT_EQ(backend.writeConfig(QStringLiteral("{\"version\":1,\"store\":{\"sources\":{\"aur\":true}}}\n")), QString());
    QEventLoop loop;
    for (int i = 0; i < 250 && changes == 0; ++i) {
        QTimer::singleShot(20, &loop, &QEventLoop::quit);
        loop.exec();
    }
    ASSERT_GT(changes, 0);
    ASSERT_TRUE(settle(backend));
    ASSERT_FALSE(backend.app(aurGame).isEmpty());
    EXPECT_EQ(backend.actions(aurGame).value(QStringLiteral("get")).toString(), QStringLiteral("aurUnchecked"));
    storetest::script(s.path(QStringLiteral("fixture/omarchy/install/helpers/steam.sh")), "# changed by an Omarchy update");
    backend.refresh();
    ASSERT_TRUE(settle(backend));
    EXPECT_EQ(backend.actions(steam).value(QStringLiteral("get")).toString(), QStringLiteral("omarchyChanged"));

    QFile::remove(served + QStringLiteral(".sig"));
    QFile::copy(keys + QStringLiteral("/revoked.sig"), served + QStringLiteral(".sig"));
    backend.refresh();
    ASSERT_TRUE(settle(backend));
    EXPECT_EQ(backend.catalogStatus().value(QStringLiteral("problem")), QStringLiteral("refused"));
    EXPECT_TRUE(backend.catalogStatus().value(QStringLiteral("inUse")).toBool()); // the accepted copy stays in use
}
