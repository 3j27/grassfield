// The listings of grassfield-portal's Open and Save panels (FolderModel.chooser; ADR-0035 D-4, docs/specs/system-dialogs.md
// section 1): over a real KIO listing of a scratch folder, the files a panel cannot take are dimmed and never selected, a
// panel that takes one item keeps one, a folder panel dims every file, and the Applications location dims every application
// but those Choose Application takes.
// Part of files-kio-tests (a scratch home).
#include "filesapp.h"
#include "applicationslogic.h"
#include "filelogic.h"
#include "foldermodel.h"

#include <QCoreApplication>
#include <QDeadlineTimer>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJSEngine>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QThread>

#include <KService>
#include <KSycoca>

#include <gtest/gtest.h>

namespace {

class FolderChooserTest : public ::testing::Test
{
protected:
    void SetUp() override
    {
        ASSERT_TRUE(m_dir.isValid());
        for (const char *name : {"a.txt", "b.png", "report.PDF"}) {
            QFile f(m_dir.filePath(QString::fromLatin1(name)));
            ASSERT_TRUE(f.open(QIODevice::WriteOnly));
            f.write("x");
        }
        ASSERT_TRUE(QDir(m_dir.path()).mkdir(QStringLiteral("sub")));
        m_model.setUrl(QUrl::fromLocalFile(m_dir.path()));
        QDeadlineTimer deadline(10000);
        while ((m_model.loading() || m_model.count() < 4) && !deadline.hasExpired()) {
            QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
            QThread::msleep(5);
        }
        ASSERT_EQ(m_model.count(), 4);
    }

    int row(const char *name)
    {
        for (int r = 0; r < m_model.count(); ++r)
            if (m_model.nameAt(r) == QLatin1String(name))
                return r;
        return -1;
    }

    bool dimmed(const char *name) { return m_model.data(m_model.index(row(name), 0), FolderModel::DimmedRole).toBool(); }

    QTemporaryDir m_dir;
    FolderModel m_model;
};

} // namespace

TEST_F(FolderChooserTest, FilesOnlyWithoutAPanel)
{
    for (const char *name : {"a.txt", "b.png", "report.PDF", "sub"})
        EXPECT_FALSE(dimmed(name)) << name;
    m_model.select(row("a.txt"), Qt::NoModifier);
    m_model.select(row("b.png"), Qt::ControlModifier);
    EXPECT_EQ(m_model.selectedCount(), 2);
}

TEST_F(FolderChooserTest, ThePanelsFilterDimsAndRefuses)
{
    m_model.setChooser({{QStringLiteral("globs"), QStringList{QStringLiteral("*.txt"), QStringLiteral("*.pdf")}}, {QStringLiteral("single"), true}});
    EXPECT_FALSE(dimmed("a.txt"));
    EXPECT_TRUE(dimmed("b.png"));
    EXPECT_FALSE(dimmed("report.PDF")); // a glob ignores case
    EXPECT_FALSE(dimmed("sub"));        // folders open
    m_model.select(row("b.png"), Qt::NoModifier);
    EXPECT_EQ(m_model.selectedCount(), 0);
    m_model.select(row("a.txt"), Qt::NoModifier);
    EXPECT_EQ(m_model.selectedUrls(), QList<QUrl>{QUrl::fromLocalFile(m_dir.filePath(QStringLiteral("a.txt")))});
    // A click on a dimmed item does nothing (macOS; integrator nested pass of f9a25ce, NIT: it cleared Choose Application's
    // preselected application). A key that lands there selects nothing: no selection out of sight for Return (review of
    // step 5c, MINOR 2).
    m_model.select(row("b.png"), Qt::NoModifier, true);
    EXPECT_EQ(m_model.selectedUrls(), QList<QUrl>{QUrl::fromLocalFile(m_dir.filePath(QStringLiteral("a.txt")))});
    EXPECT_EQ(m_model.currentRow(), row("a.txt"));
    m_model.select(row("b.png"), Qt::NoModifier);
    EXPECT_EQ(m_model.selectedCount(), 0);
    EXPECT_EQ(m_model.currentRow(), row("b.png"));
    m_model.select(row("a.txt"), Qt::NoModifier, true);
    // One item at most: Ctrl and Shift are plain clicks, Select All does nothing.
    m_model.select(row("report.PDF"), Qt::ControlModifier);
    EXPECT_EQ(m_model.selectedCount(), 1);
    m_model.select(row("sub"), Qt::ShiftModifier);
    EXPECT_EQ(m_model.selectedCount(), 1);
    m_model.selectAll();
    EXPECT_EQ(m_model.selectedCount(), 1);
}

TEST_F(FolderChooserTest, MimeTypesAndSeveralItems)
{
    m_model.setChooser({{QStringLiteral("mimeTypes"), QStringList{QStringLiteral("image/*")}}});
    EXPECT_TRUE(dimmed("a.txt"));
    EXPECT_FALSE(dimmed("b.png"));
    m_model.selectAll();
    EXPECT_EQ(m_model.selectedCount(), 2); // the picture and the folder
    // A new filter drops from the selection what the panel can no longer take.
    m_model.setChooser({{QStringLiteral("mimeTypes"), QStringList{QStringLiteral("text/plain")}}});
    EXPECT_EQ(m_model.selectedCount(), 1);
    EXPECT_FALSE(dimmed("a.txt"));
}

TEST_F(FolderChooserTest, AFolderPanelDimsEveryFile)
{
    m_model.select(row("a.txt"), Qt::NoModifier);
    m_model.setChooser({{QStringLiteral("foldersOnly"), true}, {QStringLiteral("single"), true}});
    EXPECT_EQ(m_model.selectedCount(), 0);
    for (const char *name : {"a.txt", "b.png", "report.PDF"})
        EXPECT_TRUE(dimmed(name)) << name;
    EXPECT_FALSE(dimmed("sub"));
    m_model.select(row("sub"), Qt::NoModifier);
    EXPECT_EQ(m_model.selectedCount(), 1);
}

// The Applications location (grassfield-apps:/, Files' launchers) in a panel: every application is dimmed and never selected,
// whatever the filter (an application is a launcher, not a file an application can open). Its entry in the scratch home.
TEST(FolderChooserApplications, EveryApplicationIsDimmedInAPanel)
{
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + QStringLiteral("/applications");
    ASSERT_TRUE(QDir().mkpath(dir));
    QFile entry(dir + QStringLiteral("/org.example.PanelEditor.desktop"));
    ASSERT_TRUE(entry.open(QIODevice::WriteOnly));
    entry.write("[Desktop Entry]\nType=Application\nName=Panel Editor\nExec=true\n");
    entry.close();
    FolderModel model;
    model.setUrl(QUrl(QStringLiteral("grassfield-apps:/")));
    const auto rowOf = [&model] {
        for (int r = 0; r < model.count(); ++r)
            if (model.nameAt(r) == QLatin1String("Panel Editor"))
                return r;
        return -1;
    };
    QDeadlineTimer deadline(10000);
    while (rowOf() < 0 && !deadline.hasExpired()) {
        QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
        QThread::msleep(5);
    }
    const int row = rowOf();
    ASSERT_GE(row, 0);
    EXPECT_TRUE(model.isApplications());
    EXPECT_FALSE(model.data(model.index(row, 0), FolderModel::DimmedRole).toBool()); // Files: an application opens
    model.setChooser({{QStringLiteral("globs"), QStringList{QStringLiteral("*")}}});
    EXPECT_TRUE(model.data(model.index(row, 0), FolderModel::DimmedRole).toBool());
    model.select(row, Qt::NoModifier);
    EXPECT_EQ(model.selectedCount(), 0);
    model.setChooser({{QStringLiteral("foldersOnly"), true}});
    EXPECT_TRUE(model.data(model.index(row, 0), FolderModel::DimmedRole).toBool());
    QFile::remove(entry.fileName());
}

// Choose Application (grassfield-portal's AppChooser, ADR-0035 D-5, step 5b): the applications the chooser names by desktop id
// are taken, the others dimmed and never selected; `allApplications` takes every one.
TEST(FolderChooserApplications, ChooseApplicationTakesTheNamedOnes)
{
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + QStringLiteral("/applications");
    ASSERT_TRUE(QDir().mkpath(dir));
    for (const char *id : {"org.example.ChooserEditor", "org.example.ChooserViewer"}) {
        QFile entry(dir + QLatin1Char('/') + QString::fromLatin1(id) + QStringLiteral(".desktop"));
        ASSERT_TRUE(entry.open(QIODevice::WriteOnly));
        entry.write(QByteArray("[Desktop Entry]\nType=Application\nName=") + QByteArray(id).mid(12) + "\nExec=true\n");
    }
    FolderModel model;
    model.setUrl(QUrl(QStringLiteral("grassfield-apps:/")));
    const auto rowOf = [&model](const char *name) {
        for (int r = 0; r < model.count(); ++r)
            if (model.nameAt(r) == QLatin1String(name))
                return r;
        return -1;
    };
    QDeadlineTimer deadline(10000);
    while ((rowOf("ChooserEditor") < 0 || rowOf("ChooserViewer") < 0) && !deadline.hasExpired()) {
        QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
        QThread::msleep(5);
    }
    const int editor = rowOf("ChooserEditor");
    const int viewer = rowOf("ChooserViewer");
    ASSERT_GE(editor, 0);
    ASSERT_GE(viewer, 0);
    const auto dimmed = [&model](int row) { return model.data(model.index(row, 0), FolderModel::DimmedRole).toBool(); };
    model.setChooser({{QStringLiteral("foldersOnly"), true}, {QStringLiteral("single"), true},
                      {QStringLiteral("applications"), QStringList{QStringLiteral("org.example.ChooserEditor")}}});
    EXPECT_FALSE(dimmed(editor));
    EXPECT_TRUE(dimmed(viewer));
    model.select(viewer, Qt::NoModifier);
    EXPECT_EQ(model.selectedCount(), 0) << "a dimmed application is never selected";
    model.select(editor, Qt::NoModifier);
    EXPECT_EQ(model.selectedCount(), 1);
    model.setChooser({{QStringLiteral("foldersOnly"), true}, {QStringLiteral("single"), true}, {QStringLiteral("allApplications"), true}});
    EXPECT_FALSE(dimmed(editor));
    EXPECT_FALSE(dimmed(viewer));
    for (const char *id : {"org.example.ChooserEditor", "org.example.ChooserViewer"})
        QFile::remove(dir + QLatin1Char('/') + QString::fromLatin1(id) + QStringLiteral(".desktop"));
}

// New Folder of a Save panel (FilesApp::makeFolder): a taken name, a folder's or a file's, is told by KIO's own error, since
// the panels never look at the disk on the GUI thread first (ADR-0035 4b-18; re-review of 6b26afc); a new name is made; an
// invalid one is refused at once.
TEST(PanelNewFolder, ATakenNameIsToldByKio)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    ASSERT_TRUE(QDir(dir.path()).mkdir(QStringLiteral("taken")));
    QFile file(dir.filePath(QStringLiteral("a file")));
    ASSERT_TRUE(file.open(QIODevice::WriteOnly));
    file.close();
    FilesApp app(QList<QUrl>{});
    QJSEngine engine;
    engine.globalObject().setProperty(QStringLiteral("out"), engine.newArray());
    const QJSValue record = engine.evaluate(QStringLiteral("(function (url, error) { out.push({url: url, error: error}); })"));
    ASSERT_TRUE(record.isCallable());
    const auto make = [&](const QString &name) {
        const int before = engine.globalObject().property(QStringLiteral("out")).property(QStringLiteral("length")).toInt();
        app.makeFolder(QUrl::fromLocalFile(dir.path()), name, record);
        QDeadlineTimer deadline(10000);
        while (engine.globalObject().property(QStringLiteral("out")).property(QStringLiteral("length")).toInt() == before && !deadline.hasExpired()) {
            QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
            QThread::msleep(5);
        }
        return engine.globalObject().property(QStringLiteral("out")).property(quint32(before));
    };
    const QString takenMessage = QStringLiteral("The name “%1” is already taken. Please choose a different name.");
    QJSValue answer = make(QStringLiteral("taken"));
    EXPECT_EQ(answer.property(QStringLiteral("url")).toString(), QString());
    EXPECT_EQ(answer.property(QStringLiteral("error")).toString(), takenMessage.arg(QStringLiteral("taken")));
    answer = make(QStringLiteral("a file"));
    EXPECT_EQ(answer.property(QStringLiteral("error")).toString(), takenMessage.arg(QStringLiteral("a file")));
    answer = make(QStringLiteral("fresh"));
    EXPECT_EQ(answer.property(QStringLiteral("error")).toString(), QString());
    EXPECT_EQ(QUrl(answer.property(QStringLiteral("url")).toString()), QUrl::fromLocalFile(dir.filePath(QStringLiteral("fresh"))));
    EXPECT_TRUE(QFileInfo(dir.filePath(QStringLiteral("fresh"))).isDir());
    answer = make(QStringLiteral("a/b"));
    EXPECT_TRUE(answer.property(QStringLiteral("error")).toString().startsWith(QStringLiteral("The name “a/b” can’t be used.")));
}

// An application Files cannot start: the message names it as the Applications location shows it (the name of the row, told
// apart from an app of the same name) and through FileLogic::displayName, so a bidirectional override in a Name= never
// reaches the banner. Exec= is a program that does not exist.
TEST(ApplicationLaunch, TheFailureNamesTheRowsNameCleaned)
{
    qunsetenv("GRASSFIELD_FILES_NO_LAUNCH");
    qunsetenv("GRASSFIELD_SESSION"); // not a real session: the program is started as it is, so that a missing one fails
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + QStringLiteral("/applications");
    ASSERT_TRUE(QDir().mkpath(dir));
    const QString name = QStringLiteral("Invoice‮fdp.sh");
    QFile entry(dir + QStringLiteral("/org.example.BidiLaunch.desktop"));
    ASSERT_TRUE(entry.open(QIODevice::WriteOnly));
    entry.write(QStringLiteral("[Desktop Entry]\nType=Application\nName=%1\nExec=/nonexistent/grassfield-test-binary\n").arg(name).toUtf8());
    entry.close();
    FilesApp app(QList<QUrl>{});
    auto *model = qobject_cast<FolderModel *>(app.createFolderModel(&app));
    ASSERT_NE(model, nullptr);
    model->setUrl(QUrl(QStringLiteral("grassfield-apps:/")));
    const auto rowOf = [model, &name] {
        for (int r = 0; r < model->count(); ++r)
            if (model->nameAt(r) == name)
                return r;
        return -1;
    };
    QDeadlineTimer deadline(10000);
    while (rowOf() < 0 && !deadline.hasExpired()) {
        QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
        QThread::msleep(5);
    }
    ASSERT_GE(rowOf(), 0);
    // The launch reads KDE's service cache, which looks at the folders at most every 1.5 s: another test of this run may have
    // opened it before the entry was written (tst_applicationchooser.cpp, tst_kiodialogs.cpp's OpenUrlJob).
    deadline = QDeadlineTimer(15000);
    while (!KService::serviceByMenuId(QStringLiteral("org.example.BidiLaunch.desktop")) && !deadline.hasExpired()) {
        QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
        QThread::msleep(100);
        KSycoca::self()->ensureCacheValid();
    }
    QStringList failures;
    QObject::connect(&app, &FilesApp::operationFailed, &app, [&failures](const QString &message) { failures << message; });
    app.launchApplication(ApplicationsLogic::entryUrl(QStringLiteral("org.example.BidiLaunch")));
    ASSERT_EQ(failures.size(), 1);
    EXPECT_FALSE(failures.first().contains(QChar(0x202E))) << failures.first().toStdString();
    EXPECT_EQ(failures.first(), QStringLiteral("“%1” could not be started.").arg(FileLogic::displayName(model->nameAt(rowOf()))));
    QFile::remove(entry.fileName());
}
