// ADR-0035 D-5, step 5c; docs/specs/system-dialogs.md section 2 (OW2, A-OW2): Files' Choose Application panels
// (ApplicationChooser): what the panel is given (the type's applications, Files left out, its default one; one document
// named), the answer after the panel went and the call returned, none for Cancel or an application that is not installed,
// and a panel that closes unanswered when its owner (a job) goes. In files-kio-tests (tst_kiodialogs.cpp's main: a scratch
// home, offscreen): the applications are desktop files of the scratch XDG_DATA_HOME, KDE's service cache built from them.
#include "applicationchooser.h"

#include <QCoreApplication>
#include <QDeadlineTimer>
#include <QDir>
#include <QEventLoop>
#include <QFile>
#include <QStandardPaths>
#include <QTimer>

#include <KJob>
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
