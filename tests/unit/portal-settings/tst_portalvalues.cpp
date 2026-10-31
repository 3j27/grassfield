// The Settings portal backend (apps/portal-settings, ADR-0035 D-8): the values it publishes for the Grassfield settings, the
// namespace filter of ReadAll, and the backend object itself on a scratch settings file (no bus): what it answers, and which
// SettingChanged signals a change of the file or of the clock brings.
#include "portalvalues.h"
#include "settingsbackend.h"

#include <QCoreApplication>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QSaveFile>
#include <QTemporaryDir>

#include <gtest/gtest.h>

#include <atomic>
#include <functional>
#include <future>
#include <memory>
#include <string>
#include <vector>

#include <sys/stat.h>
#include <unistd.h>

using namespace grassfield::portal;

namespace {

QJsonObject json(const char *text)
{
    return QJsonDocument::fromJson(QByteArray(text)).object();
}

const QTime kNoon(12, 0);
const QTime kNight(21, 0);

void ensureApp()
{
    static int argc = 1;
    static char name[] = "portal-settings-unit-tests";
    static char *argv[] = {name, nullptr};
    // One application for the whole test process, kept until it exits.
    static QCoreApplication *app = QCoreApplication::instance() ? nullptr : new QCoreApplication(argc, argv);
    Q_UNUSED(app);
}

// Runs the event loop until `done` or `ms` elapse.
template<typename F>
bool spin(F done, int ms = 3000)
{
    QElapsedTimer timer;
    timer.start();
    while (!done() && timer.elapsed() < ms)
        QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
    return done();
}

void writeAtomically(const QString &path, const QByteArray &text)
{
    QSaveFile file(path);
    ASSERT_TRUE(file.open(QIODevice::WriteOnly));
    file.write(text);
    ASSERT_TRUE(file.commit());
}

} // namespace

TEST(PortalValues, TheSchemaDefaultsWhenTheFileSaysNothing)
{
    const Input in = readInput(QJsonObject());
    EXPECT_EQ(in.appearance, QStringLiteral("dark"));
    EXPECT_EQ(in.accent, QStringLiteral("multicolor"));
    EXPECT_FALSE(in.increaseContrast);
    EXPECT_FALSE(in.reduceMotion);
    // Wrong types keep the defaults too, as the shell reads them.
    const Input odd = readInput(json(R"({"appearance": 3, "accent": "blue", "accessibility": {"reduceMotion": "yes"}})"));
    EXPECT_EQ(odd.appearance, QStringLiteral("dark"));
    EXPECT_EQ(odd.accent, QStringLiteral("multicolor"));
    EXPECT_FALSE(odd.reduceMotion);
}

TEST(PortalValues, AppearanceAndTheAutoSchedule)
{
    EXPECT_EQ(values(readInput(json(R"({"appearance": "light"})")), kNight).colorScheme(), 2u);
    EXPECT_EQ(values(readInput(json(R"({"appearance": "dark"})")), kNoon).colorScheme(), 1u);
    EXPECT_EQ(values(readInput(json(R"({"appearance": "auto"})")), kNoon).colorScheme(), 2u);
    EXPECT_EQ(values(readInput(json(R"({"appearance": "auto"})")), kNight).colorScheme(), 1u);
    EXPECT_EQ(values(readInput(json(R"({"appearance": "auto"})")), QTime(6, 59)).colorScheme(), 1u);
    EXPECT_EQ(values(readInput(json(R"({"appearance": "auto"})")), QTime(7, 0)).colorScheme(), 2u);
}

TEST(PortalValues, TheAccentOfEachAppearanceFromTheTokens)
{
    const Values light = values(readInput(json(R"({"appearance": "light", "accent": {"color": "blue"}})")), kNoon);
    EXPECT_EQ(light.accentRgb, 0x1F5FCCu);
    EXPECT_DOUBLE_EQ(light.red(), 0x1F / 255.0);
    EXPECT_DOUBLE_EQ(light.blue(), 0xCC / 255.0);
    const Values dark = values(readInput(json(R"({"appearance": "dark", "accent": {"color": "blue"}})")), kNoon);
    EXPECT_EQ(dark.accentRgb, 0x5AA2FFu);
    // multicolor is the Grassfield green of each appearance; an unknown name reads as multicolor.
    EXPECT_EQ(values(readInput(json(R"({"appearance": "light"})")), kNoon).accentRgb, 0x195E3Fu);
    EXPECT_EQ(values(readInput(json(R"({"appearance": "dark"})")), kNoon).accentRgb, 0x4FB36Bu);
    const Values unknown = values(readInput(json(R"({"accent": {"color": "teal"}})")), kNoon);
    EXPECT_EQ(unknown.accentName, QStringLiteral("multicolor"));
    // Every accent of Accent.js has a theme name, in both appearances, with and without Increase Contrast.
    int names = 0;
    for (const auto &accent : tokens::kAccents) {
        for (const bool hc : {false, true}) {
            for (const char *appearance : {"light", "dark"}) {
                ++names;
                const Values v = values(readInput(QJsonObject{
                                            {QStringLiteral("appearance"), QLatin1String(appearance)},
                                            {QStringLiteral("accent"), QJsonObject{{QStringLiteral("color"), QLatin1String(accent.name)}}},
                                            {QStringLiteral("accessibility"), QJsonObject{{QStringLiteral("increaseContrast"), hc}}}}),
                                        kNoon);
                EXPECT_EQ(v.gtkTheme(), QStringLiteral("Grassfield-%1%2%3")
                                            .arg(QLatin1String(accent.name), hc ? QStringLiteral("-hc") : QString(),
                                                 v.dark ? QStringLiteral("-dark") : QString()));
            }
        }
    }
    EXPECT_EQ(names, 36);
}

TEST(PortalValues, GtkThemeColourSchemeAndAnimations)
{
    const Values v = values(readInput(json(R"({"appearance": "light", "accent": {"color": "graphite"},
                                               "accessibility": {"increaseContrast": true, "reduceMotion": true}})")), kNoon);
    EXPECT_EQ(v.gtkTheme(), QStringLiteral("Grassfield-graphite-hc"));
    EXPECT_EQ(v.gnomeColorScheme(), QStringLiteral("prefer-light"));
    const SettingsMap map = SettingsBackend::toMap(v);
    EXPECT_EQ(map.value(QStringLiteral("org.freedesktop.appearance")).value(QStringLiteral("contrast")).toUInt(), 1u);
    EXPECT_EQ(map.value(QStringLiteral("org.freedesktop.appearance")).value(QStringLiteral("reduced-motion")).toUInt(), 1u);
    EXPECT_FALSE(map.value(QStringLiteral("org.gnome.desktop.interface")).value(QStringLiteral("enable-animations")).toBool());
    const auto accent = map.value(QStringLiteral("org.freedesktop.appearance")).value(QStringLiteral("accent-color")).value<AccentColor>();
    EXPECT_DOUBLE_EQ(accent.green, 0x61 / 255.0);
}

TEST(PortalValues, ReadAllNamespaceFilter)
{
    const QString appearance = QStringLiteral("org.freedesktop.appearance");
    EXPECT_TRUE(namespaceMatches({}, appearance));
    EXPECT_TRUE(namespaceMatches({QString()}, appearance));
    EXPECT_TRUE(namespaceMatches({appearance}, appearance));
    EXPECT_TRUE(namespaceMatches({QStringLiteral("org.freedesktop.*")}, appearance));
    EXPECT_FALSE(namespaceMatches({QStringLiteral("org.gnome.*")}, appearance));
    EXPECT_FALSE(namespaceMatches({QStringLiteral("org.freedesktop.appearance.x")}, appearance));
}

TEST(SettingsBackend, AnswersFromTheFileAndSignalsOnlyWhatChanged)
{
    ensureApp();
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const QString file = dir.path() + QStringLiteral("/grassfield.json");
    writeAtomically(file, R"({"appearance": "light", "accent": {"color": "pink"}})");
    SettingsBackend::Options options;
    options.configFile = file;
    options.clock = [] { return kNoon; };
    SettingsBackend backend(options);

    EXPECT_EQ(backend.ReadAll({}).size(), 2);
    EXPECT_EQ(backend.ReadAll({QStringLiteral("org.gnome.*")}).keys(), QStringList{QStringLiteral("org.gnome.desktop.interface")});
    EXPECT_EQ(backend.Read(QStringLiteral("org.gnome.desktop.interface"), QStringLiteral("gtk-theme")).variant().toString(),
              QStringLiteral("Grassfield-pink"));
    // A key it does not own: no value (on the bus, the NotFound error that sends the frontend to the next backend).
    EXPECT_FALSE(backend.Read(QStringLiteral("org.gnome.desktop.interface"), QStringLiteral("font-name")).variant().isValid());

    QStringList changed;
    QObject::connect(&backend, &SettingsBackend::SettingChanged, [&](const QString &ns, const QString &key, const QDBusVariant &) {
        changed << ns + QLatin1Char(' ') + key;
    });
    // The accent changes: the accent colour and the GTK theme, nothing else.
    writeAtomically(file, R"({"appearance": "light", "accent": {"color": "orange"}})");
    ASSERT_TRUE(spin([&] { return changed.size() >= 2; })) << changed.join(QLatin1Char(',')).toStdString();
    spin([] { return false; }, 200);
    changed.sort();
    EXPECT_EQ(changed, (QStringList{QStringLiteral("org.freedesktop.appearance accent-color"),
                                    QStringLiteral("org.gnome.desktop.interface gtk-theme")}));
    // Reduce Motion: the two motion keys; after an atomic replace the file is still watched.
    changed.clear();
    writeAtomically(file, R"({"appearance": "light", "accent": {"color": "orange"}, "accessibility": {"reduceMotion": true}})");
    ASSERT_TRUE(spin([&] { return changed.size() >= 2; }));
    changed.sort();
    EXPECT_EQ(changed, (QStringList{QStringLiteral("org.freedesktop.appearance reduced-motion"),
                                    QStringLiteral("org.gnome.desktop.interface enable-animations")}));
    // Increase Contrast: the contrast key and the GTK theme, which becomes the accent's -hc variant.
    changed.clear();
    writeAtomically(file, R"({"appearance": "light", "accent": {"color": "orange"},
                              "accessibility": {"reduceMotion": true, "increaseContrast": true}})");
    ASSERT_TRUE(spin([&] { return changed.size() >= 2; }));
    spin([] { return false; }, 200);
    changed.sort();
    EXPECT_EQ(changed, (QStringList{QStringLiteral("org.freedesktop.appearance contrast"),
                                    QStringLiteral("org.gnome.desktop.interface gtk-theme")}));
    EXPECT_EQ(backend.Read(QStringLiteral("org.gnome.desktop.interface"), QStringLiteral("gtk-theme")).variant().toString(),
              QStringLiteral("Grassfield-orange-hc"));
    // A file that is not JSON keeps the last good settings (ADR-0020 §2: a hand edit with a typo changes nothing).
    changed.clear();
    writeAtomically(file, "{not json");
    spin([] { return false; }, 300);
    EXPECT_TRUE(changed.isEmpty()) << changed.join(QLatin1Char(',')).toStdString();
    EXPECT_EQ(backend.Read(QStringLiteral("org.gnome.desktop.interface"), QStringLiteral("gtk-theme")).variant().toString(),
              QStringLiteral("Grassfield-orange-hc"));
    // An empty object reads as the defaults (dark, multicolor): every key that differs from them changes.
    writeAtomically(file, "{}");
    ASSERT_TRUE(spin([&] { return changed.contains(QStringLiteral("org.freedesktop.appearance color-scheme")); }));
    EXPECT_EQ(backend.Read(QStringLiteral("org.gnome.desktop.interface"), QStringLiteral("gtk-theme")).variant().toString(),
              QStringLiteral("Grassfield-multicolor-dark"));
    // Written again with the same values: no signal.
    spin([] { return false; }, 200);
    changed.clear();
    writeAtomically(file, R"({"version": 1})");
    spin([] { return false; }, 300);
    EXPECT_TRUE(changed.isEmpty()) << changed.join(QLatin1Char(',')).toStdString();
}

// ADR-0020 §2: the file is never read without a bound. A FIFO, a device behind a symlink, a directory, a file over 1 MiB and
// an unreadable file are never read and keep the last good settings; a FIFO at start reads as the defaults, at once.
TEST(SettingsBackend, NeverReadsWithoutABound)
{
    ensureApp();
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const QString file = dir.path() + QStringLiteral("/grassfield.json");
    const QByteArray native = QFile::encodeName(file);
    ASSERT_EQ(::mkfifo(native.constData(), 0600), 0);
    SettingsBackend::Options options;
    options.configFile = file;
    options.clock = [] { return kNoon; };
    QElapsedTimer started;
    started.start();
    SettingsBackend backend(options); // would block for ever on a FIFO opened for a plain read
    EXPECT_LT(started.elapsed(), 1000);
    const auto theme = [&] {
        return backend.Read(QStringLiteral("org.gnome.desktop.interface"), QStringLiteral("gtk-theme")).variant().toString();
    };
    EXPECT_EQ(theme(), QStringLiteral("Grassfield-multicolor-dark"));

    // Each case is made next to the file and renamed over it (QSaveFile does not replace a FIFO).
    const auto replaceWith = [&](const std::function<bool(const QByteArray &)> &make) {
        const QByteArray next = QFile::encodeName(dir.path() + QStringLiteral("/next"));
        ::unlink(next.constData());
        ASSERT_TRUE(make(next));
        ASSERT_EQ(::rename(next.constData(), native.constData()), 0);
    };
    const auto regular = [](const QByteArray &text) {
        return [text](const QByteArray &p) {
            QFile f(QFile::decodeName(p));
            return f.open(QIODevice::WriteOnly) && f.write(text) == text.size();
        };
    };
    replaceWith(regular(R"({"appearance": "light", "accent": {"color": "green"}})"));
    ASSERT_TRUE(spin([&] { return theme() == QStringLiteral("Grassfield-green"); })) << theme().toStdString();

    QStringList changed;
    QObject::connect(&backend, &SettingsBackend::SettingChanged, [&](const QString &ns, const QString &key, const QDBusVariant &) {
        changed << ns + QLatin1Char(' ') + key;
    });
    struct Case {
        const char *what;
        std::function<bool(const QByteArray &)> make;
    };
    const QByteArray big = QByteArray("{\"appearance\": \"dark\"}") + QByteArray(qsizetype(1024) * 1024, ' ');
    const std::vector<Case> cases = {
        {"a FIFO", [](const QByteArray &p) { return ::mkfifo(p.constData(), 0600) == 0; }},
        {"a symlink to /dev/zero", [](const QByteArray &p) { return ::symlink("/dev/zero", p.constData()) == 0; }},
        {"a file over 1 MiB", regular(big)},
        {"an unreadable file", [&](const QByteArray &p) {
             return regular(R"({"appearance": "dark"})")(p) && QFile::setPermissions(QFile::decodeName(p), {});
         }},
    };
    for (const Case &c : cases) {
        if (std::string(c.what) == "an unreadable file" && ::geteuid() == 0)
            continue; // root reads it anyway
        changed.clear();
        replaceWith(c.make);
        spin([] { return false; }, 300);
        EXPECT_TRUE(changed.isEmpty()) << c.what << ": " << changed.join(QLatin1Char(',')).toStdString();
        EXPECT_EQ(theme(), QStringLiteral("Grassfield-green")) << c.what;
    }
    ::unlink(native.constData());
    // A directory in its place: the same.
    ASSERT_EQ(::mkdir(native.constData(), 0700), 0);
    spin([] { return false; }, 300);
    EXPECT_EQ(theme(), QStringLiteral("Grassfield-green"));
    ASSERT_EQ(::rmdir(native.constData()), 0);
    // A good file again: read at once.
    replaceWith(regular(R"({"appearance": "light", "accent": {"color": "red"}})"));
    ASSERT_TRUE(spin([&] { return theme() == QStringLiteral("Grassfield-red"); })) << theme().toStdString();
}

TEST(SettingsBackend, AutoFollowsTheClock)
{
    ensureApp();
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const QString file = dir.path() + QStringLiteral("/grassfield.json");
    writeAtomically(file, R"({"appearance": "auto"})");
    QTime now = kNoon;
    SettingsBackend::Options options;
    options.configFile = file;
    options.recheckMs = 30;
    options.clock = [&now] { return now; };
    SettingsBackend backend(options);
    EXPECT_EQ(backend.Read(QStringLiteral("org.freedesktop.appearance"), QStringLiteral("color-scheme")).variant().toUInt(), 2u);
    QStringList changed;
    QObject::connect(&backend, &SettingsBackend::SettingChanged, [&](const QString &ns, const QString &key, const QDBusVariant &) {
        changed << ns + QLatin1Char(' ') + key;
    });
    now = kNight;
    ASSERT_TRUE(spin([&] { return changed.contains(QStringLiteral("org.freedesktop.appearance color-scheme")); }));
    EXPECT_EQ(backend.Read(QStringLiteral("org.freedesktop.appearance"), QStringLiteral("color-scheme")).variant().toUInt(), 1u);
    EXPECT_TRUE(changed.contains(QStringLiteral("org.gnome.desktop.interface gtk-theme")));
}

TEST(SettingsBackend, NoFileMeansTheDefaults)
{
    ensureApp();
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    SettingsBackend::Options options;
    options.configFile = dir.path() + QStringLiteral("/missing/grassfield.json");
    options.clock = [] { return kNoon; };
    SettingsBackend backend(options);
    EXPECT_EQ(backend.Read(QStringLiteral("org.freedesktop.appearance"), QStringLiteral("color-scheme")).variant().toUInt(), 1u);
    EXPECT_FALSE(QFileInfo::exists(dir.path() + QStringLiteral("/missing"))); // never created
    // The directory and the file appear later (a first login): read at once, not at the next minute's recheck.
    ASSERT_TRUE(QDir(dir.path()).mkdir(QStringLiteral("missing")));
    writeAtomically(options.configFile, R"({"appearance": "light"})");
    EXPECT_TRUE(spin([&] {
        return backend.Read(QStringLiteral("org.freedesktop.appearance"), QStringLiteral("color-scheme")).variant().toUInt() == 2u;
    }, 1000));
    // Then the file itself is watched again.
    writeAtomically(options.configFile, R"({"appearance": "dark"})");
    EXPECT_TRUE(spin([&] {
        return backend.Read(QStringLiteral("org.freedesktop.appearance"), QStringLiteral("color-scheme")).variant().toUInt() == 1u;
    }, 1000));
}

TEST(SettingsBackend, AnnouncesEveryValueOnce)
{
    ensureApp();
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const QString file = dir.path() + QStringLiteral("/grassfield.json");
    writeAtomically(file, R"({"appearance": "light", "accent": {"color": "red"}})");
    SettingsBackend::Options options;
    options.configFile = file;
    options.clock = [] { return kNoon; };
    SettingsBackend backend(options);
    QMap<QString, QVariant> announced;
    int count = 0;
    QObject::connect(&backend, &SettingsBackend::SettingChanged, [&](const QString &ns, const QString &key, const QDBusVariant &value) {
        ++count;
        announced.insert(ns + QLatin1Char(' ') + key, value.variant());
    });
    backend.announceAll();
    EXPECT_EQ(count, 7);
    EXPECT_EQ(announced.size(), 7);
    EXPECT_EQ(announced.value(QStringLiteral("org.gnome.desktop.interface gtk-theme")).toString(), QStringLiteral("Grassfield-red"));
    EXPECT_EQ(announced.value(QStringLiteral("org.freedesktop.appearance color-scheme")).toUInt(), 2u);
}

// ADR-0020 §2: a read that hangs (a home that stops answering) is not waited for. The start waits startWaitMs at most and
// answers the defaults; the calls are answered at once all along; a late read is applied when it answers, and a change made
// while a read hangs is read once more after it.
TEST(SettingsBackend, AHungReadIsNotWaitedFor)
{
    ensureApp();
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const QString file = dir.path() + QStringLiteral("/grassfield.json");
    writeAtomically(file, R"({"appearance": "light", "accent": {"color": "pink"}})");
    // Reads number `hang` (1-based) block until the test releases them.
    auto release = std::make_shared<std::promise<void>>();
    std::shared_future<void> released = release->get_future().share();
    auto reads = std::make_shared<std::atomic<int>>(0);
    const auto reader = [reads](int hang, const std::shared_future<void> &released) {
        return [released, reads, hang](const QString &path) {
            if (reads->fetch_add(1) + 1 == hang)
                released.wait();
            return readSettingsFile(path);
        };
    };
    SettingsBackend::Options options;
    options.configFile = file;
    options.clock = [] { return kNoon; };
    options.startWaitMs = 100;
    options.readCutMs = 200;

    // The first read hangs: the start does not wait for it, the defaults are answered at once, then the file's values.
    options.reader = reader(1, released);
    QElapsedTimer started;
    started.start();
    {
        SettingsBackend backend(options);
        EXPECT_LT(started.elapsed(), 1000);
        EXPECT_EQ(backend.Read(QStringLiteral("org.gnome.desktop.interface"), QStringLiteral("gtk-theme")).variant().toString(),
                  QStringLiteral("Grassfield-multicolor-dark"));
        release->set_value();
        EXPECT_TRUE(spin([&] {
            return backend.Read(QStringLiteral("org.gnome.desktop.interface"), QStringLiteral("gtk-theme")).variant().toString()
                == QStringLiteral("Grassfield-pink");
        }));
    }

    // A later read hangs: the last settings stay, no second read starts beside it, and the change made meanwhile is read
    // once more when it answers.
    release = std::make_shared<std::promise<void>>();
    released = release->get_future().share();
    reads->store(0);
    options.reader = reader(2, released);
    SettingsBackend backend(options);
    const auto theme = [&] {
        return backend.Read(QStringLiteral("org.gnome.desktop.interface"), QStringLiteral("gtk-theme")).variant().toString();
    };
    ASSERT_EQ(theme(), QStringLiteral("Grassfield-pink"));
    writeAtomically(file, R"({"appearance": "light", "accent": {"color": "orange"}})"); // read 2: hangs
    ASSERT_TRUE(spin([&] { return reads->load() == 2; }));
    writeAtomically(file, R"({"appearance": "light", "accent": {"color": "red"}})");
    spin([] { return false; }, 400); // past readCutMs
    EXPECT_EQ(reads->load(), 2);
    EXPECT_EQ(theme(), QStringLiteral("Grassfield-pink"));
    release->set_value();
    ASSERT_TRUE(spin([&] { return theme() == QStringLiteral("Grassfield-red"); })) << theme().toStdString();
    EXPECT_TRUE(spin([&] { return reads->load() == 3; })) << reads->load(); // the read once more, on its own thread
    spin([] { return false; }, 200);
    EXPECT_EQ(reads->load(), 3);
}

// The minute timer of "auto" reads the clock, never the file, and does not run for any other appearance.
TEST(SettingsBackend, TheMinuteTimerReadsNoFile)
{
    ensureApp();
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const QString file = dir.path() + QStringLiteral("/grassfield.json");
    for (const char *text : {R"({"appearance": "dark"})", R"({"appearance": "auto"})"}) {
        writeAtomically(file, text);
        auto reads = std::make_shared<std::atomic<int>>(0);
        SettingsBackend::Options options;
        options.configFile = file;
        options.clock = [] { return kNoon; };
        options.recheckMs = 20;
        options.reader = [reads](const QString &path) {
            reads->fetch_add(1);
            return readSettingsFile(path);
        };
        SettingsBackend backend(options);
        spin([] { return false; }, 300);
        EXPECT_EQ(reads->load(), 1) << text;
    }
}
