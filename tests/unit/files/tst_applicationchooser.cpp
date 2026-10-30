// ADR-0035 D-5, step 5c; docs/specs/system-dialogs.md section 2 (OW2, A-OW2): Files' Choose Application panels
// (ApplicationChooser): what the panel is given (the type's applications, Files left out, its default one; one document
// named), the answer after the panel went and the call returned, none for Cancel or an application that is not installed,
// and a panel that closes unanswered when its owner (a job) goes. In files-kio-tests (tst_kiodialogs.cpp's main: a scratch
// home, offscreen): the applications are desktop files of the scratch XDG_DATA_HOME, KDE's service cache built from them.
#include "applicationchooser.h"
#include "filesapp.h"
#include "kioprompts.h"

#include <QCoreApplication>
#include <QDeadlineTimer>
#include <QDir>
#include <QEventLoop>
#include <QFile>
#include <QStandardPaths>
#include <QTimer>

#include <KJob>
#include <KService>
#include <KSycoca>

#include <gtest/gtest.h>

#include <memory>

namespace
{
const QString kA = QStringLiteral("org.example.GfChooseA");
const QString kB = QStringLiteral("org.example.GfChooseB");

void writeEntry(const QString &dir, const QString &id, const QString &mimeTypes)
{
    QFile entry(dir + QLatin1Char('/') + id + QStringLiteral(".desktop"));
    ASSERT_TRUE(entry.open(QIODevice::WriteOnly));
    entry.write(QStringLiteral("[Desktop Entry]\nType=Application\nName=%1\nExec=true %f\nMimeType=%2\n").arg(id, mimeTypes).toUtf8());
}

// Two applications for text/plain (B the default), and Files, which also says it takes it; KDE's cache rebuilt (it looks
// at the folders at most every 1.5 s).
void installApplications()
{
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + QStringLiteral("/applications");
    ASSERT_TRUE(QDir().mkpath(dir));
    writeEntry(dir, kA, QStringLiteral("text/plain;"));
    writeEntry(dir, kB, QStringLiteral("text/plain;"));
    writeEntry(dir, QStringLiteral("org.grassfield.Files"), QStringLiteral("inode/directory;text/plain;"));
    const QString config = QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation);
    ASSERT_TRUE(QDir().mkpath(config));
    QFile mimeapps(config + QStringLiteral("/mimeapps.list"));
    ASSERT_TRUE(mimeapps.open(QIODevice::WriteOnly));
    mimeapps.write(QStringLiteral("[Default Applications]\ntext/plain=%1.desktop;\n").arg(kB).toUtf8());
    mimeapps.close();
    QDeadlineTimer deadline(15000);
    while (!ApplicationChooser::candidates(QStringLiteral("text/plain")).contains(kA) && !deadline.hasExpired()) {
        QEventLoop loop;
        QTimer::singleShot(200, &loop, &QEventLoop::quit);
        loop.exec();
        KSycoca::self()->ensureCacheValid();
    }
}

void spin()
{
    QEventLoop loop;
    QTimer::singleShot(0, &loop, &QEventLoop::quit);
    loop.exec();
}

// A job that runs until the test ends it.
class IdleJob : public KJob
{
public:
    void start() override
    {
    }
    void end()
    {
        emitResult();
    }
};
} // namespace

TEST(ApplicationChooser, ThePanelIsGivenChooseApplication)
{
    const QVariantMap one = ApplicationChooser::request(QStringLiteral("notes.txt"), 1, {kA, kB}, kB);
    EXPECT_EQ(one.value(QStringLiteral("kind")).toString(), QStringLiteral("application"));
    EXPECT_EQ(one.value(QStringLiteral("applications")).toStringList(), QStringList({kA, kB}));
    EXPECT_EQ(one.value(QStringLiteral("lastChoice")).toString(), kB);
    EXPECT_EQ(one.value(QStringLiteral("filename")).toString(), QStringLiteral("notes.txt"));
    EXPECT_EQ(one.value(QStringLiteral("count")).toInt(), 1);
    // Modal to the Files window it opens over, with the panel's own title and button.
    EXPECT_TRUE(one.value(QStringLiteral("modal")).toBool());
    EXPECT_TRUE(one.value(QStringLiteral("parented")).toBool());
    EXPECT_EQ(one.value(QStringLiteral("title")).toString(), QString());
    EXPECT_EQ(one.value(QStringLiteral("acceptLabel")).toString(), QString());
    EXPECT_FALSE(one.value(QStringLiteral("multiple")).toBool());
    // Several documents: none named, their number.
    const QVariantMap two = ApplicationChooser::request(QStringLiteral("notes.txt"), 2, {}, QString());
    EXPECT_EQ(two.value(QStringLiteral("filename")).toString(), QString());
    EXPECT_EQ(two.value(QStringLiteral("count")).toInt(), 2);
}

TEST(ApplicationChooser, TheTypesApplicationsWithoutFiles)
{
    installApplications();
    const QStringList candidates = ApplicationChooser::candidates(QStringLiteral("text/plain"));
    EXPECT_TRUE(candidates.contains(kA));
    EXPECT_TRUE(candidates.contains(kB));
    EXPECT_FALSE(candidates.contains(QStringLiteral("org.grassfield.Files"))) << "Files opens no document with itself";
    EXPECT_EQ(candidates.count(kA), 1);
    EXPECT_EQ(ApplicationChooser::defaultApplication(QStringLiteral("text/plain")), kB);
    EXPECT_TRUE(ApplicationChooser::candidates(QString()).isEmpty());
    EXPECT_EQ(ApplicationChooser::defaultApplication(QString()), QString());
}

// The type's default application with NoDisplay=true (Omarchy: image/png=imv.desktop, and imv is NoDisplay) is a candidate
// and the default, as the Open With submenu (FilesApp::applicationsFor) lists it: the panel is given what the submenu shows
// (its listing then lists it: FolderChooserApplications.ChooseApplicationListsTheCandidatesTheGridHides).
TEST(ApplicationChooser, ADefaultTheGridHidesIsTheSubmenusToo)
{
    installApplications();
    const QString hidden = QStringLiteral("org.example.GfChooseHiddenViewer");
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + QStringLiteral("/applications");
    {
        QFile entry(dir + QLatin1Char('/') + hidden + QStringLiteral(".desktop"));
        ASSERT_TRUE(entry.open(QIODevice::WriteOnly));
        entry.write("[Desktop Entry]\nType=Application\nName=Hidden Viewer\nExec=true %f\nMimeType=image/png;\nNoDisplay=true\n");
    }
    {
        QFile mimeapps(QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) + QStringLiteral("/mimeapps.list"));
        ASSERT_TRUE(mimeapps.open(QIODevice::WriteOnly));
        mimeapps.write(QStringLiteral("[Default Applications]\ntext/plain=%1.desktop;\nimage/png=%2.desktop;\n").arg(kB, hidden).toUtf8());
    }
    QDeadlineTimer deadline(15000);
    while (ApplicationChooser::defaultApplication(QStringLiteral("image/png")) != hidden && !deadline.hasExpired()) {
        QEventLoop loop;
        QTimer::singleShot(200, &loop, &QEventLoop::quit);
        loop.exec();
        KSycoca::self()->ensureCacheValid();
    }
    EXPECT_EQ(ApplicationChooser::defaultApplication(QStringLiteral("image/png")), hidden);
    EXPECT_TRUE(ApplicationChooser::candidates(QStringLiteral("image/png")).contains(hidden));
    FilesApp files(QList<QUrl>{});
    bool inSubmenu = false;
    const QVariantList submenu = files.applicationsFor({QUrl::fromLocalFile(QDir::tempPath() + QStringLiteral("/picture.png"))});
    for (const QVariant &v : submenu)
        inSubmenu = inSubmenu || v.toMap().value(QStringLiteral("id")).toString() == hidden + QStringLiteral(".desktop");
    EXPECT_TRUE(inSubmenu) << "the Open With submenu lists it";
    QFile::remove(dir + QLatin1Char('/') + hidden + QStringLiteral(".desktop"));
}

TEST(ApplicationChooser, TheAnswerComesAfterThePanelWent)
{
    installApplications();
    ApplicationChooser chooser;
    QList<QPair<int, QVariantMap>> opened;
    QList<int> closed;
    QStringList answers;
    QObject::connect(&chooser, &ApplicationChooser::opened, &chooser, [&](int id, const QVariantMap &request) {
        opened.append({id, request});
    });
    QObject::connect(&chooser, &ApplicationChooser::closed, &chooser, [&](int id) {
        closed.append(id);
    });
    const QString dir = QDir::tempPath();
    const int id = chooser.ask({QUrl::fromLocalFile(dir + QStringLiteral("/notes.txt"))}, QStringLiteral("text/plain"), nullptr,
                               [&](const QString &chosen) {
                                   EXPECT_EQ(closed, QList<int>({id})) << "the panel went first";
                                   answers << chosen;
                               });
    ASSERT_EQ(opened.size(), 1);
    EXPECT_EQ(opened.first().first, id);
    const QVariantMap request = opened.first().second;
    EXPECT_EQ(request.value(QStringLiteral("filename")).toString(), QStringLiteral("notes.txt"));
    EXPECT_TRUE(request.value(QStringLiteral("applications")).toStringList().contains(kA));
    EXPECT_EQ(request.value(QStringLiteral("lastChoice")).toString(), kB);

    chooser.answer(id, 0, {{QStringLiteral("choice"), kA}});
    EXPECT_TRUE(answers.isEmpty()) << "after the call that answered returns";
    spin();
    EXPECT_EQ(answers, QStringList({kA}));
    // A second answer for the same panel is no answer.
    chooser.answer(id, 0, {{QStringLiteral("choice"), kB}});
    spin();
    EXPECT_EQ(answers, QStringList({kA}));
    EXPECT_EQ(closed, QList<int>({id}));
}

TEST(ApplicationChooser, CancelAndAWrongChoiceAreNone)
{
    installApplications();
    ApplicationChooser chooser;
    QObject::connect(&chooser, &ApplicationChooser::opened, &chooser, [](int, const QVariantMap &) {});
    QStringList answers;
    const auto ask = [&] {
        return chooser.ask({QUrl::fromLocalFile(QDir::tempPath() + QStringLiteral("/notes.txt"))}, {}, nullptr, [&](const QString &chosen) {
            answers << chosen;
        });
    };
    chooser.answer(ask(), 1, {{QStringLiteral("choice"), kA}});
    chooser.answer(ask(), 0, {{QStringLiteral("choice"), QStringLiteral("org.example.NotInstalled")}});
    chooser.answer(ask(), 0, {{QStringLiteral("choice"), 7}});
    chooser.answer(ask(), 0, {{QStringLiteral("choice"), QStringLiteral("../") + kA}});
    chooser.answer(ask(), 0, {});
    spin();
    EXPECT_EQ(answers, QStringList({QString(), QString(), QString(), QString(), QString()}));
}

TEST(ApplicationChooser, ThePanelGoesWithItsOwner)
{
    ApplicationChooser chooser;
    QObject::connect(&chooser, &ApplicationChooser::opened, &chooser, [](int, const QVariantMap &) {});
    QList<int> closed;
    int answered = 0;
    QObject::connect(&chooser, &ApplicationChooser::closed, &chooser, [&](int id) {
        closed.append(id);
    });
    const QList<QUrl> urls{QUrl::fromLocalFile(QDir::tempPath() + QStringLiteral("/notes.txt"))};
    // An owner deleted: the panel closes, and nothing answers.
    auto *owner = new QObject;
    const int first = chooser.ask(urls, {}, owner, [&](const QString &) {
        ++answered;
    });
    delete owner;
    EXPECT_EQ(closed, QList<int>({first}));
    // A job that ends.
    auto *job = new IdleJob;
    const int second = chooser.ask(urls, {}, job, [&](const QString &) {
        ++answered;
    });
    job->end();
    EXPECT_EQ(closed, QList<int>({first, second}));
    chooser.answer(second, 1);
    // A job that ends between the answer and its delivery: nothing reaches it.
    auto *late = new IdleJob;
    late->setAutoDelete(false);
    const int third = chooser.ask(urls, {}, late, [&](const QString &) {
        ++answered;
    });
    chooser.answer(third, 1);
    late->end();
    spin();
    EXPECT_EQ(answered, 0);
    delete late;
}

// One document with no file name (a server's root) is named by its address; with nothing to show a panel (no listener, as in
// grassfield-portal's FilesApp) the answer is none at once, never a job waiting for ever (review of step 5c, NITs).
TEST(ApplicationChooser, AnAddressAndNoPanel)
{
    ApplicationChooser chooser;
    QStringList answers;
    QList<int> closed;
    QObject::connect(&chooser, &ApplicationChooser::closed, &chooser, [&closed](int id) {
        closed << id;
    });
    const int id = chooser.ask({QUrl(QStringLiteral("https://example.org/"))}, QStringLiteral("text/html"), nullptr, [&](const QString &chosen) {
        answers << chosen;
    });
    spin();
    spin();
    EXPECT_EQ(answers, QStringList({QString()}));
    EXPECT_EQ(closed, QList<int>({id}));
    QVariantMap request;
    QObject::connect(&chooser, &ApplicationChooser::opened, &chooser, [&request](int, const QVariantMap &r) {
        request = r;
    });
    chooser.ask({QUrl(QStringLiteral("https://example.org/"))}, QStringLiteral("text/html"), nullptr, [](const QString &) {});
    EXPECT_EQ(request.value(QStringLiteral("filename")).toString(), QString());
    EXPECT_EQ(request.value(QStringLiteral("uri")).toString(), QStringLiteral("https://example.org/"));
    // An address's password is never shown (integrator review of step 5c's PR, NIT 4).
    chooser.ask({QUrl(QStringLiteral("ftp://user:secret@host.example/"))}, QStringLiteral("text/html"), nullptr, [](const QString &) {});
    EXPECT_EQ(request.value(QStringLiteral("uri")).toString(), QStringLiteral("ftp://user@host.example/"));
}

// Open With > Other… (FilesApp::chooseApplication): the panel for the selection; the application chosen opens it
// (FilesApp::openWith: here the session blocks launches, which tells openWith was reached); an application of the
// Applications location is no document and gets no panel.
TEST(ApplicationChooser, OtherOpensWithTheChosenOne)
{
    installApplications();
    qputenv("GRASSFIELD_FILES_NO_LAUNCH", "1");
    FilesApp app(QList<QUrl>{});
    auto *chooser = qobject_cast<ApplicationChooser *>(app.applicationChooser());
    ASSERT_NE(chooser, nullptr);
    QList<QPair<int, QVariantMap>> opened;
    QStringList failures;
    QObject::connect(chooser, &ApplicationChooser::opened, chooser, [&](int id, const QVariantMap &request) {
        opened.append({id, request});
    });
    QObject::connect(&app, &FilesApp::operationFailed, &app, [&failures](const QString &message) {
        failures << message;
    });
    app.chooseApplication({QUrl(QStringLiteral("grassfield-app:/org.example.GfChooseA"))});
    EXPECT_TRUE(opened.isEmpty()) << "an application is no document";
    EXPECT_EQ(failures.size(), 1);
    failures.clear();
    const QList<QUrl> docs{QUrl::fromLocalFile(QDir::tempPath() + QStringLiteral("/a.txt")), QUrl::fromLocalFile(QDir::tempPath() + QStringLiteral("/b.txt"))};
    app.chooseApplication(docs);
    ASSERT_EQ(opened.size(), 1);
    EXPECT_EQ(opened.first().second.value(QStringLiteral("count")).toInt(), 2);
    EXPECT_TRUE(opened.first().second.value(QStringLiteral("applications")).toStringList().contains(kA));
    chooser->answer(opened.first().first, 0, {{QStringLiteral("choice"), kA}});
    EXPECT_TRUE(failures.isEmpty());
    spin();
    EXPECT_EQ(failures, QStringList({QStringLiteral("Opening files is disabled in this session (GRASSFIELD_FILES_NO_LAUNCH).")}))
        << "openWith was asked to open them with the chosen application";
    // Cancel opens nothing.
    failures.clear();
    app.chooseApplication(docs);
    ASSERT_EQ(opened.size(), 2);
    chooser->answer(opened.last().first, 1);
    spin();
    EXPECT_TRUE(failures.isEmpty());
    qunsetenv("GRASSFIELD_FILES_NO_LAUNCH");
}

// Other… with two documents, one named with a shell's characters: the application chosen (not the type's default one)
// gets both, as two arguments, and no shell reads their names (integrator review of step 5c's PR, MINOR 1).
TEST(ApplicationChooser, OtherGivesEveryDocumentToTheChosenOne)
{
    installApplications();
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + QStringLiteral("/other-docs");
    ASSERT_TRUE(QDir().mkpath(dir));
    const QString out = dir + QStringLiteral("/received");
    const QStringList names{QStringLiteral("a b.txt"), QStringLiteral("c;$(touch pwned).txt")};
    QList<QUrl> docs;
    for (const QString &name : names) {
        QFile doc(dir + QLatin1Char('/') + name);
        ASSERT_TRUE(doc.open(QIODevice::WriteOnly));
        doc.write("text\n");
        docs << QUrl::fromLocalFile(doc.fileName());
    }
    // An application that writes each argument it is given on a line; listed for no type (All Applications).
    const QString script = dir + QStringLiteral("/record");
    {
        QFile f(script);
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
        f.write(QStringLiteral("#!/bin/sh\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done >> '%1'\n").arg(out).toUtf8());
        f.close();
        ASSERT_TRUE(f.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner));
    }
    const QString recorder = QStringLiteral("org.example.GfChooseRecord");
    const QString apps = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + QStringLiteral("/applications");
    {
        QFile entry(apps + QLatin1Char('/') + recorder + QStringLiteral(".desktop"));
        ASSERT_TRUE(entry.open(QIODevice::WriteOnly));
        entry.write(QStringLiteral("[Desktop Entry]\nType=Application\nName=Record\nExec=\"%1\" %F\n").arg(script).toUtf8());
    }
    QDeadlineTimer cache(15000);
    while (!KService::serviceByMenuId(recorder + QStringLiteral(".desktop")) && !cache.hasExpired()) {
        QEventLoop loop;
        QTimer::singleShot(200, &loop, &QEventLoop::quit);
        loop.exec();
        KSycoca::self()->ensureCacheValid();
    }
    ASSERT_TRUE(KService::serviceByMenuId(recorder + QStringLiteral(".desktop")));
    ASSERT_EQ(ApplicationChooser::defaultApplication(QStringLiteral("text/plain")), kB) << "the type's default is another one";

    qunsetenv("GRASSFIELD_FILES_NO_LAUNCH");
    FilesApp app(QList<QUrl>{});
    auto *chooser = qobject_cast<ApplicationChooser *>(app.applicationChooser());
    ASSERT_NE(chooser, nullptr);
    QStringList failures;
    QObject::connect(&app, &FilesApp::operationFailed, &app, [&failures](const QString &message) {
        failures << message;
    });
    int asked = 0;
    QObject::connect(chooser, &ApplicationChooser::opened, chooser, [&](int id, const QVariantMap &request) {
        ++asked;
        EXPECT_EQ(request.value(QStringLiteral("count")).toInt(), 2);
        chooser->answer(id, 0, {{QStringLiteral("choice"), recorder}});
    });
    app.chooseApplication(docs);
    EXPECT_EQ(asked, 1);
    QDeadlineTimer deadline(15000);
    QStringList received;
    while (received.size() < 2 && !deadline.hasExpired()) {
        QEventLoop loop;
        QTimer::singleShot(100, &loop, &QEventLoop::quit);
        loop.exec();
        QFile f(out);
        if (f.open(QIODevice::ReadOnly))
            received = QString::fromUtf8(f.readAll()).split(QLatin1Char('\n'), Qt::SkipEmptyParts);
    }
    EXPECT_TRUE(failures.isEmpty()) << failures.join(QLatin1Char(' ')).toStdString();
    EXPECT_EQ(received, QStringList({docs.at(0).toLocalFile(), docs.at(1).toLocalFile()})) << "both documents, to the chosen application";
    EXPECT_FALSE(QFile::exists(dir + QStringLiteral("/pwned")));
    EXPECT_FALSE(QFile::exists(QDir::homePath() + QStringLiteral("/pwned")));
    EXPECT_FALSE(QFile::exists(QDir::currentPath() + QStringLiteral("/pwned")));
}
