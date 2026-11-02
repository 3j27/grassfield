// The glue of Files' data-changing commands (review of PR #98): over real files in a scratch folder, FilesApp's
// Get Info permissions (setAccess, applyToEnclosed), Delete Immediately (deletePermanently), Make Alias, New Folder with
// Selection and Rename N Items; each command that renames or makes several things is ONE undo step, and nothing is replaced.
// Real KIO jobs where the commands use them; part of files-kio-tests (a scratch home).
#include "filesapp.h"
#include "applicationslogic.h"
#include "filelogic.h"

#include <QCoreApplication>
#include <QDeadlineTimer>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QTemporaryDir>
#include <QThread>
#include <QVariantMap>

#include <KIO/FileUndoManager>

#include <gtest/gtest.h>

#include <sys/stat.h>

namespace
{
bool waitFor(const std::function<bool()> &done, int ms = 15000)
{
    QDeadlineTimer deadline(ms);
    while (!done() && !deadline.hasExpired()) {
        QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
        QThread::msleep(5);
    }
    return done();
}

void write(const QString &path, const QByteArray &bytes = QByteArray("x"))
{
    QDir().mkpath(QFileInfo(path).absolutePath());
    QFile f(path);
    ASSERT_TRUE(f.open(QIODevice::WriteOnly));
    f.write(bytes);
}

QByteArray read(const QString &path)
{
    QFile f(path);
    return f.open(QIODevice::ReadOnly) ? f.readAll() : QByteArray();
}

bool present(const QString &path)
{
    return QFileInfo::exists(path) || QFileInfo(path).isSymLink();
}

unsigned modeOf(const QString &path)
{
    struct stat st{};
    return ::stat(QFile::encodeName(path).constData(), &st) == 0 ? unsigned(st.st_mode & 07777) : 0xffffffffu;
}

bool setMode(const QString &path, unsigned mode)
{
    return ::chmod(QFile::encodeName(path).constData(), mode) == 0;
}

QUrl url(const QString &path)
{
    return QUrl::fromLocalFile(path);
}

// Records what a command tells the user.
struct Told {
    explicit Told(FilesApp &app) { QObject::connect(&app, &FilesApp::operationFailed, &app, [this](const QString &m) { messages << m; }); }
    QStringList messages;
};

// A scratch folder per test; the undo history of this process is emptied of KIO jobs still running.
class FileOps : public ::testing::Test
{
protected:
    void SetUp() override
    {
        ASSERT_TRUE(m_dir.isValid());
        // Other tests of this binary may have left commands in KIO's history: what counts is what changes.
        m_kioUndoBefore = KIO::FileUndoManager::self()->isUndoAvailable();
        m_serialBefore = KIO::FileUndoManager::self()->currentCommandSerialNumber();
    }
    QString d(const char *name = "") const { return m_dir.filePath(QString::fromLatin1(name)); }
    QTemporaryDir m_dir;
    bool m_kioUndoBefore = false;
    quint64 m_serialBefore = 0;
};
} // namespace

TEST_F(FileOps, SetAccessChangesOnlyTheUsersOwnPlainItemsThroughThePinnedItem)
{
    FilesApp app(QList<QUrl>{});
    Told told(app);
    write(d("f.txt"));
    ASSERT_TRUE(setMode(d("f.txt"), 0644));
    int changed = 0;
    QObject::connect(&app, &FilesApp::permissionsChanged, &app, [&changed](const QUrl &) { ++changed; });

    // Others: no access; group: read and write.
    app.setAccess(url(d("f.txt")), 2, 0);
    EXPECT_EQ(modeOf(d("f.txt")), 0640u);
    app.setAccess(url(d("f.txt")), 1, 3);
    EXPECT_EQ(modeOf(d("f.txt")), 0660u);
    EXPECT_EQ(changed, 2) << "the window is told to read the item again";
    const QVariantMap p = app.permissionsOf(url(d("f.txt")));
    EXPECT_TRUE(p.value(QStringLiteral("editable")).toBool());

    // Not a valid row or privilege: nothing changes.
    app.setAccess(url(d("f.txt")), 3, 0);
    app.setAccess(url(d("f.txt")), 0, 9);
    EXPECT_EQ(modeOf(d("f.txt")), 0660u);

    // An alias keeps its own permissions and the original's are not touched through it (O_NOFOLLOW).
    ASSERT_TRUE(QFile::link(d("f.txt"), d("link")));
    const QVariantMap l = app.permissionsOf(url(d("link")));
    EXPECT_FALSE(l.value(QStringLiteral("editable")).toBool());
    EXPECT_FALSE(l.value(QStringLiteral("reason")).toString().isEmpty());
    app.setAccess(url(d("link")), 0, 0);
    EXPECT_EQ(modeOf(d("f.txt")), 0660u) << "the link's target is left alone";

    // System items and other people's items are shown, never changed.
    EXPECT_FALSE(app.permissionsOf(QUrl::fromLocalFile(QStringLiteral("/proc/self"))).value(QStringLiteral("editable")).toBool());
    const unsigned env = modeOf(QStringLiteral("/usr/bin/env"));
    EXPECT_FALSE(app.permissionsOf(QUrl::fromLocalFile(QStringLiteral("/usr/bin/env"))).value(QStringLiteral("editable")).toBool()) << "owned by root";
    app.setAccess(QUrl::fromLocalFile(QStringLiteral("/usr/bin/env")), 2, 0);
    EXPECT_EQ(modeOf(QStringLiteral("/usr/bin/env")), env);
    // A server's item has no permissions to show.
    EXPECT_FALSE(app.permissionsOf(QUrl(QStringLiteral("sftp://host/file"))).value(QStringLiteral("valid")).toBool());
    EXPECT_TRUE(told.messages.isEmpty()) << told.messages.join(QLatin1Char('|')).toStdString();
}

TEST_F(FileOps, ApplyToEnclosedReachesEveryItemButNeverFollowsALink)
{
    FilesApp app(QList<QUrl>{});
    Told told(app);
    write(d("outside.txt"));
    ASSERT_TRUE(setMode(d("outside.txt"), 0644));
    write(d("root/file1.txt"));
    write(d("root/sub/file2.txt"));
    ASSERT_TRUE(setMode(d("root/file1.txt"), 0644));
    ASSERT_TRUE(setMode(d("root/sub/file2.txt"), 0666));
    ASSERT_TRUE(QFile::link(d("outside.txt"), d("root/to-outside")));
    ASSERT_TRUE(setMode(d("root"), 0755));
    // The folder's own privileges first: others get nothing.
    app.setAccess(url(d("root")), 2, 0);
    EXPECT_EQ(modeOf(d("root")), 0750u);

    int told1 = 0;
    QObject::connect(&app, &FilesApp::permissionsChanged, &app, [&told1](const QUrl &) { ++told1; });
    app.applyToEnclosed(url(d("root")));
    ASSERT_TRUE(waitFor([&] { return told1 > 0; })) << "the window is told when chmod ended";
    EXPECT_EQ(modeOf(d("root/file1.txt")) & 07, 0u) << "others lost their access to the files inside";
    EXPECT_EQ(modeOf(d("root/sub/file2.txt")) & 07, 0u) << "at any depth";
    EXPECT_EQ(modeOf(d("root/sub")) & 07, 0u);
    EXPECT_EQ(modeOf(d("outside.txt")), 0644u) << "a link inside is not followed";
    // Not a folder, a link or a system item: nothing runs.
    told1 = 0;
    app.applyToEnclosed(url(d("root/file1.txt")));
    app.applyToEnclosed(url(d("root/to-outside")));
    app.applyToEnclosed(QUrl::fromLocalFile(QStringLiteral("/proc")));
    QCoreApplication::processEvents(QEventLoop::AllEvents, 100);
    EXPECT_EQ(told1, 0);
    EXPECT_TRUE(told.messages.isEmpty()) << told.messages.join(QLatin1Char('|')).toStdString();
}

TEST_F(FileOps, DeleteImmediatelyDeletesAnyItemAndNeverAnApplication)
{
    FilesApp app(QList<QUrl>{});
    Told told(app);
    write(d("a.txt"));
    write(d("folder/inner/b.txt"));
    write(d("keep.txt"));
    // Not in the Trash, a file and a folder with content: both go, the neighbour stays.
    app.deletePermanently({url(d("a.txt")), url(d("folder"))});
    ASSERT_TRUE(waitFor([&] { return !present(d("a.txt")) && !present(d("folder")); }));
    EXPECT_TRUE(present(d("keep.txt")));
    EXPECT_EQ(KIO::FileUndoManager::self()->currentCommandSerialNumber(), m_serialBefore) << "never undoable: nothing was recorded";
    EXPECT_EQ(app.canUndo(), m_kioUndoBefore);
    EXPECT_TRUE(told.messages.isEmpty());
    // An application of the Applications location is refused with the permission message, whatever the window asked.
    app.deletePermanently({ApplicationsLogic::entryUrl(QStringLiteral("org.example.Nothing"))});
    ASSERT_EQ(told.messages.size(), 1);
    EXPECT_TRUE(told.messages.first().contains(QStringLiteral("permission")));
    // Nothing to delete: nothing happens.
    app.deletePermanently({});
    EXPECT_EQ(told.messages.size(), 1);
}

TEST_F(FileOps, MakeAliasIsOneUndoStepAndNeverReplacesAName)
{
    FilesApp app(QList<QUrl>{});
    Told told(app);
    write(d("report.txt"), "r");
    write(d("notes.txt"), "n");
    write(d("report.txt alias"), "the user's own file");
    app.makeAlias({url(d("report.txt")), url(d("notes.txt"))}, nullptr);
    EXPECT_TRUE(told.messages.isEmpty());
    EXPECT_EQ(read(d("report.txt alias")), QByteArray("the user's own file")) << "a name that exists is never replaced";
    EXPECT_EQ(QFileInfo(d("report.txt alias 2")).symLinkTarget(), d("report.txt"));
    EXPECT_EQ(QFileInfo(d("notes.txt alias")).symLinkTarget(), d("notes.txt"));
    EXPECT_TRUE(app.canUndo());
    // One Undo removes both aliases (the Finder's one step per command); the originals stay.
    app.undo();
    EXPECT_FALSE(present(d("report.txt alias 2")));
    EXPECT_FALSE(present(d("notes.txt alias")));
    EXPECT_EQ(read(d("report.txt")), QByteArray("r"));
    EXPECT_EQ(read(d("report.txt alias")), QByteArray("the user's own file"));
    EXPECT_EQ(app.canUndo(), m_kioUndoBefore) << "the command was ONE step";
    EXPECT_TRUE(app.canRedo());
    app.redo();
    EXPECT_TRUE(QFileInfo(d("report.txt alias 2")).isSymLink());
    EXPECT_TRUE(QFileInfo(d("notes.txt alias")).isSymLink());
    EXPECT_FALSE(app.canRedo());
    // An item on a server has no alias here.
    app.makeAlias({QUrl(QStringLiteral("sftp://host/file"))}, nullptr);
    ASSERT_EQ(told.messages.size(), 1);
    EXPECT_TRUE(told.messages.first().contains(QStringLiteral("on this computer")));
    // An application is refused.
    app.makeAlias({ApplicationsLogic::entryUrl(QStringLiteral("org.example.Nothing"))}, nullptr);
    EXPECT_EQ(told.messages.size(), 2);
}

TEST_F(FileOps, NewFolderWithSelectionIsOneUndoStep)
{
    FilesApp app(QList<QUrl>{});
    Told told(app);
    write(d("a.txt"), "a");
    write(d("b.txt"), "b");
    write(d("New Folder With Items/old.txt"), "o");
    app.newFolderWithItems({url(d("a.txt")), url(d("b.txt"))}, url(m_dir.path()), nullptr);
    EXPECT_TRUE(told.messages.isEmpty());
    // The name is taken: the next one is made, the items move into it, the other folder is untouched.
    EXPECT_EQ(read(d("New Folder With Items 2/a.txt")), QByteArray("a"));
    EXPECT_EQ(read(d("New Folder With Items 2/b.txt")), QByteArray("b"));
    EXPECT_FALSE(present(d("a.txt")));
    EXPECT_EQ(read(d("New Folder With Items/old.txt")), QByteArray("o"));
    // One Undo: the items back, the new folder gone.
    app.undo();
    EXPECT_EQ(read(d("a.txt")), QByteArray("a"));
    EXPECT_EQ(read(d("b.txt")), QByteArray("b"));
    EXPECT_FALSE(present(d("New Folder With Items 2")));
    EXPECT_TRUE(present(d("New Folder With Items/old.txt")));
    EXPECT_EQ(app.canUndo(), m_kioUndoBefore) << "the command was ONE step, not a folder and a move";
    app.redo();
    EXPECT_EQ(read(d("New Folder With Items 2/a.txt")), QByteArray("a"));
    // Items of another folder are refused before anything is made.
    write(d("elsewhere/c.txt"), "c");
    app.newFolderWithItems({url(d("elsewhere/c.txt"))}, url(m_dir.path()), nullptr);
    ASSERT_EQ(told.messages.size(), 1);
    EXPECT_TRUE(told.messages.first().contains(QStringLiteral("items of the shown folder")));
    EXPECT_TRUE(present(d("elsewhere/c.txt")));
    EXPECT_FALSE(present(d("New Folder With Items 3")));
}

TEST_F(FileOps, RenameNItemsIsAllOrNothingAndOneUndoStep)
{
    FilesApp app(QList<QUrl>{});
    Told told(app);
    for (const char *n : {"a.txt", "b.txt", "c.txt"})
        write(d(n), QByteArray(n));
    QVariantMap add;
    add.insert(QStringLiteral("mode"), 1);        // Add Text
    add.insert(QStringLiteral("addText"), QStringLiteral("-new"));
    add.insert(QStringLiteral("where"), 0);       // after the name
    EXPECT_EQ(app.renameItems({url(d("a.txt")), url(d("b.txt")), url(d("c.txt"))}, add, nullptr), QString());
    for (const char *n : {"a-new.txt", "b-new.txt", "c-new.txt"})
        EXPECT_TRUE(present(d(n))) << n;
    EXPECT_FALSE(present(d("a.txt")));
    // One Undo puts all three back.
    EXPECT_TRUE(app.canUndo());
    app.undo();
    for (const char *n : {"a.txt", "b.txt", "c.txt"})
        EXPECT_EQ(read(d(n)), QByteArray(n)) << n;
    EXPECT_FALSE(present(d("b-new.txt")));
    EXPECT_EQ(app.canUndo(), m_kioUndoBefore) << "N renames were ONE step";
    app.redo();
    EXPECT_TRUE(present(d("c-new.txt")));
    app.undo();

    // A name taken on the disk by something else: nothing at all is renamed, and the user is told.
    write(d("b-new.txt"), "the user's own file");
    const QString why = app.renameItems({url(d("a.txt")), url(d("b.txt")), url(d("c.txt"))}, add, nullptr);
    EXPECT_TRUE(why.contains(QStringLiteral("already taken"))) << why.toStdString();
    EXPECT_EQ(read(d("a.txt")), QByteArray("a.txt"));
    EXPECT_EQ(read(d("c.txt")), QByteArray("c.txt"));
    EXPECT_FALSE(present(d("a-new.txt")));
    EXPECT_FALSE(present(d("c-new.txt")));
    EXPECT_EQ(read(d("b-new.txt")), QByteArray("the user's own file")) << "never replaced";
    EXPECT_EQ(app.canUndo(), m_kioUndoBefore) << "a refused command records nothing";
    // A source that vanished since the window listed it: the others are not renamed either.
    ASSERT_TRUE(QFile::remove(d("b-new.txt")));
    ASSERT_TRUE(QFile::remove(d("b.txt")));
    EXPECT_FALSE(app.renameItems({url(d("a.txt")), url(d("b.txt")), url(d("c.txt"))}, add, nullptr).isEmpty());
    EXPECT_EQ(read(d("a.txt")), QByteArray("a.txt"));
    EXPECT_EQ(read(d("c.txt")), QByteArray("c.txt"));
    EXPECT_FALSE(present(d("a-new.txt")));
    EXPECT_FALSE(present(d("c-new.txt")));
    EXPECT_EQ(app.canUndo(), m_kioUndoBefore);
}

TEST_F(FileOps, UndoFollowsTheOrderOfTheCommandsWhoeverRecordedThem)
{
    FilesApp app(QList<QUrl>{});
    Told told(app);
    write(d("one.txt"), "1");
    write(d("a.txt"), "a");
    write(d("b.txt"), "b");
    // A single rename (a KIO job, recorded by KIO), then a batch (Files' own command), then an alias.
    app.rename(url(d("one.txt")), QStringLiteral("uno.txt"), nullptr);
    ASSERT_TRUE(waitFor([&] { return present(d("uno.txt")); }));
    ASSERT_TRUE(waitFor([&] { return KIO::FileUndoManager::self()->isUndoAvailable(); }));
    QVariantMap add;
    add.insert(QStringLiteral("mode"), 1);
    add.insert(QStringLiteral("addText"), QStringLiteral("-x"));
    ASSERT_EQ(app.renameItems({url(d("a.txt")), url(d("b.txt"))}, add, nullptr), QString());
    app.makeAlias({url(d("uno.txt"))}, nullptr);
    ASSERT_TRUE(present(d("uno.txt alias")));
    // Undo, newest first: the alias, the batch, then the single rename (KIO's).
    app.undo();
    EXPECT_FALSE(present(d("uno.txt alias")));
    EXPECT_TRUE(present(d("a-x.txt")));
    app.undo();
    EXPECT_TRUE(present(d("a.txt")));
    EXPECT_TRUE(present(d("b.txt")));
    EXPECT_FALSE(present(d("a-x.txt")));
    EXPECT_TRUE(present(d("uno.txt")));
    EXPECT_TRUE(app.canUndo());
    app.undo();
    ASSERT_TRUE(waitFor([&] { return present(d("one.txt")); }));
    EXPECT_FALSE(present(d("uno.txt")));
    ASSERT_TRUE(waitFor([&] { return app.canRedo(); }));
    // Redo goes back in the order undo went.
    app.redo();
    ASSERT_TRUE(waitFor([&] { return present(d("uno.txt")); }));
    app.redo();
    EXPECT_TRUE(present(d("a-x.txt")));
    app.redo();
    EXPECT_TRUE(QFileInfo(d("uno.txt alias")).isSymLink());
    EXPECT_FALSE(app.canRedo());
    // A new command ends the redo history.
    app.undo();
    EXPECT_TRUE(app.canRedo());
    app.makeAlias({url(d("a-x.txt"))}, nullptr);
    EXPECT_FALSE(app.canRedo());
    EXPECT_TRUE(told.messages.isEmpty()) << told.messages.join(QLatin1Char('|')).toStdString();
}
