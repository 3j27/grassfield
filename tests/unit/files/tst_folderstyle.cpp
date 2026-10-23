// Unit tests for apps/files/src/folderstylelogic.{h,cpp} and folderstylestore.{h,cpp} (gtest). Built and run by
// scripts/dev/test.sh. The store tests only touch folders they create under GRASSFIELD_TEST_TMP, a directory inside
// the repository's .dev/ (set by scripts/dev/test.sh); they skip without it or without user extended attributes there.
#include "folderstylelogic.h"
#include "folderstylestore.h"
#include "tagstore.h"

#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QCoreApplication>
#include <QFileSystemWatcher>
#include <QMutex>
#include <QMutexLocker>
#include <QTemporaryDir>
#include <QEventLoop>
#include <QTimer>
#include <QThread>

#include <memory>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>

#include <gtest/gtest.h>

using FolderStyleLogic::Style;

namespace
{
std::unique_ptr<QTemporaryDir> sandbox(QString *why)
{
    const QString base = qEnvironmentVariable("GRASSFIELD_TEST_TMP");
    if (base.isEmpty() || !QDir::cleanPath(base).contains(QLatin1String("/.dev/"))) {
        *why = QStringLiteral("GRASSFIELD_TEST_TMP (a directory under .dev/) is not set");
        return nullptr;
    }
    QDir().mkpath(base);
    auto dir = std::make_unique<QTemporaryDir>(base + QStringLiteral("/folderstyle-XXXXXX"));
    if (!dir->isValid()) {
        *why = QStringLiteral("cannot create a directory in ") + base;
        return nullptr;
    }
    return dir;
}

QString makeFolder(const QTemporaryDir &dir, const QString &name)
{
    const QString path = dir.filePath(name);
    QDir().mkpath(path);
    return path;
}

bool xattrSupported(const QString &path)
{
    const int rc = ::lsetxattr(QFile::encodeName(path).constData(), "user.grassfield.probe", "1", 1, 0);
    if (rc == 0)
        ::lremovexattr(QFile::encodeName(path).constData(), "user.grassfield.probe");
    return rc == 0;
}

Style style(const char *color, const char *glyph = "")
{
    Style s;
    s.color = QString::fromUtf8(color);
    s.glyph = QString::fromUtf8(glyph);
    return s;
}
} // namespace

#define SKIP_WITHOUT_SANDBOX(dirVar)                                                                                    \
    QString why;                                                                                                         \
    auto dirVar = sandbox(&why);                                                                                         \
    if (!dirVar)                                                                                                         \
        GTEST_SKIP() << why.toStdString();                                                                               \
    if (!xattrSupported(dirVar->path()))                                                                                 \
    GTEST_SKIP() << "no user extended attributes under the test sandbox"

// ---- logic ----

TEST(FolderStyleLogic, ColourValidation)
{
    EXPECT_TRUE(FolderStyleLogic::validColor(QStringLiteral("theme")));
    EXPECT_TRUE(FolderStyleLogic::validColor(QStringLiteral("accent")));
    EXPECT_TRUE(FolderStyleLogic::validColor(QStringLiteral("#A0b1C2")));
    EXPECT_FALSE(FolderStyleLogic::validColor(QStringLiteral("#12345")));
    EXPECT_FALSE(FolderStyleLogic::validColor(QStringLiteral("red")));
    EXPECT_FALSE(FolderStyleLogic::validColor(QString()));
    EXPECT_EQ(FolderStyleLogic::normalizeColor(QStringLiteral("#A0B1C2")), QStringLiteral("#a0b1c2"));
    EXPECT_EQ(FolderStyleLogic::normalizeColor(QStringLiteral("bogus")), QString());
}

TEST(FolderStyleLogic, GlyphIsOneGraphemeCluster)
{
    EXPECT_EQ(FolderStyleLogic::normalizeGlyph(QStringLiteral("  ")), QString());
    EXPECT_EQ(FolderStyleLogic::normalizeGlyph(QStringLiteral(" ★ ")), QStringLiteral("★"));
    // A pasted word keeps its first letter only; an emoji with a skin tone or a ZWJ sequence stays whole.
    EXPECT_EQ(FolderStyleLogic::normalizeGlyph(QStringLiteral("music")), QStringLiteral("m"));
    const QString thumbs = QString::fromUtf8("\xF0\x9F\x91\x8D\xF0\x9F\x8F\xBD"); // thumbs up, medium skin tone
    EXPECT_EQ(FolderStyleLogic::normalizeGlyph(thumbs + QStringLiteral("x")), thumbs);
    const QString family = QString::fromUtf8("\xF0\x9F\x91\xA8\xE2\x80\x8D\xF0\x9F\x91\xA9\xE2\x80\x8D\xF0\x9F\x91\xA7"); // man, woman, girl
    EXPECT_EQ(FolderStyleLogic::normalizeGlyph(family), family);
    // A control character is no symbol.
    EXPECT_EQ(FolderStyleLogic::normalizeGlyph(QString(QChar(0x07))), QString());
}

namespace
{
// "1F468 200D 1F469" -> the string of those code points (a lone surrogate stays one).
QString fromCodePoints(const QString &hex)
{
    QString s;
    for (const QString &h : hex.split(QLatin1Char(' '), Qt::SkipEmptyParts)) {
        const uint cp = h.toUInt(nullptr, 16);
        if (cp > 0xFFFF) {
            s.append(QChar(QChar::highSurrogate(cp)));
            s.append(QChar(QChar::lowSurrogate(cp)));
        } else {
            s.append(QChar(ushort(cp)));
        }
    }
    return s;
}
} // namespace

// The symbol rule's shared vectors (tests/fixtures/glyph-vectors.json): ui/Grassfield/Ui/FolderStyle.js answers the same
// (tests/unit/tst_foldercolors.qml test_glyphRuleSharedVectors reads the same file): what the preview shows is what is saved.
TEST(FolderStyleLogic, GlyphRuleSharedVectors)
{
    const QDir tests = QFileInfo(QStringLiteral(__FILE__)).absoluteDir(); // tests/unit/files
    QFile file(QDir::cleanPath(tests.filePath(QStringLiteral("../../fixtures/glyph-vectors.json"))));
    ASSERT_TRUE(file.open(QIODevice::ReadOnly)) << file.fileName().toStdString();
    const QJsonArray vectors = QJsonDocument::fromJson(file.readAll()).object().value(QStringLiteral("vectors")).toArray();
    ASSERT_GT(vectors.size(), 100);
    for (const QJsonValue &value : vectors) {
        const QJsonObject v = value.toObject();
        const std::string name = v.value(QStringLiteral("name")).toString().toStdString();
        const QString input = fromCodePoints(v.value(QStringLiteral("input")).toString());
        const QString expected = fromCodePoints(v.value(QStringLiteral("expected")).toString());
        const QString got = FolderStyleLogic::normalizeGlyph(input);
        EXPECT_EQ(got, expected) << name;
        if (!v.value(QStringLiteral("emoji")).isNull())
            EXPECT_EQ(FolderStyleLogic::isEmoji(got), v.value(QStringLiteral("emoji")).toBool()) << name;
        // Normalising is stable: a kept symbol stays as it is.
        EXPECT_EQ(FolderStyleLogic::normalizeGlyph(got), got) << name;
    }
    // Over the cap (more than 16 UTF-16 units in one cluster): nothing.
    QString zalgo = QStringLiteral("e");
    for (int i = 0; i < 16; ++i)
        zalgo += QChar(0x0301);
    EXPECT_EQ(FolderStyleLogic::normalizeGlyph(zalgo), QString());
    EXPECT_EQ(FolderStyleLogic::normalizeGlyph(zalgo.left(16)), zalgo.left(16));
}

TEST(FolderStyleLogic, ParseAndSerializeRoundTrip)
{
    const Style s = style("#FF9500", "\xF0\x9F\x8E\xB5");
    const QByteArray raw = FolderStyleLogic::serialize(s);
    EXPECT_EQ(raw, QByteArray("{\"color\":\"#ff9500\",\"glyph\":\"\xF0\x9F\x8E\xB5\",\"v\":1}"));
    const Style back = FolderStyleLogic::parse(raw);
    EXPECT_EQ(back.color, QStringLiteral("#ff9500"));
    EXPECT_EQ(back.glyph, s.glyph);
    // An empty style stores nothing.
    EXPECT_TRUE(FolderStyleLogic::serialize(Style()).isEmpty());
}

TEST(FolderStyleLogic, GarbageReadsAsEmpty)
{
    EXPECT_TRUE(FolderStyleLogic::parse(QByteArray()).isEmpty());
    EXPECT_TRUE(FolderStyleLogic::parse(QByteArray("not json")).isEmpty());
    EXPECT_TRUE(FolderStyleLogic::parse(QByteArray("[1,2]")).isEmpty());
    EXPECT_TRUE(FolderStyleLogic::parse(QByteArray("{\"color\":5,\"glyph\":[]}")).isEmpty());
    // An invalid colour is dropped, a valid glyph kept.
    const Style s = FolderStyleLogic::parse(QByteArray("{\"color\":\"red\",\"glyph\":\"A\"}"));
    EXPECT_EQ(s.color, QString());
    EXPECT_EQ(s.glyph, QStringLiteral("A"));
    EXPECT_TRUE(FolderStyleLogic::parse(QByteArray(10000, '{')).isEmpty());
}

TEST(FolderStyleLogic, ApplyKeepsUnknownKeys)
{
    const QByteArray stored("{\"v\":1,\"color\":\"#ff0000\",\"future\":{\"a\":[1,2]}}");
    const QByteArray next = FolderStyleLogic::apply(stored, style("#00ff00"));
    EXPECT_NE(next.indexOf("\"future\":{\"a\":[1,2]}"), -1);
    EXPECT_EQ(FolderStyleLogic::parse(next).color, QStringLiteral("#00ff00"));
    // Removing both fields leaves a newer version's data in place.
    const QByteArray cleared = FolderStyleLogic::apply(next, Style());
    EXPECT_FALSE(cleared.isEmpty());
    EXPECT_NE(cleared.indexOf("future"), -1);
    EXPECT_TRUE(FolderStyleLogic::parse(cleared).isEmpty());
    // A value that is only ours and only the version is no value.
    EXPECT_TRUE(FolderStyleLogic::apply(QByteArray("{\"v\":1,\"color\":\"#ff0000\"}"), Style()).isEmpty());
    // Garbage is replaced.
    EXPECT_EQ(FolderStyleLogic::parse(FolderStyleLogic::apply(QByteArray("garbage"), style("accent"))).color, QStringLiteral("accent"));
}

TEST(FolderStyleLogic, OversizedValueIsNotEdited)
{
    EXPECT_FALSE(FolderStyleLogic::tooLargeToEdit(QByteArray(4096, 'x')));
    EXPECT_TRUE(FolderStyleLogic::tooLargeToEdit(QByteArray(4097, 'x')));
}

// ---- store ----

TEST(FolderStyleStore, WritesTheAttributeAndReadsItBack)
{
    SKIP_WITHOUT_SANDBOX(dir);
    FolderStyleStore store(dir->filePath(QStringLiteral("cfg/folder-styles.json")));
    const QString folder = makeFolder(*dir, QStringLiteral("music"));
    EXPECT_TRUE(store.read(folder).isEmpty());
    const auto r = store.write(folder, style("#e5484d", "\xF0\x9F\x8E\xB5"));
    ASSERT_TRUE(r.ok) << r.error.toStdString();
    EXPECT_FALSE(r.fellBack);
    EXPECT_TRUE(r.changed);
    const Style s = store.read(folder);
    EXPECT_EQ(s.color, QStringLiteral("#e5484d"));
    EXPECT_EQ(s.glyph, QString::fromUtf8("\xF0\x9F\x8E\xB5"));
    QByteArray raw;
    EXPECT_EQ(TagStore::readAttr(folder, FolderStyleLogic::attributeName(), &raw), TagStore::ReadResult::Ok);
    // The same value again changes nothing.
    EXPECT_FALSE(store.write(folder, style("#e5484d", "\xF0\x9F\x8E\xB5")).changed);
    // Reset removes the attribute.
    ASSERT_TRUE(store.write(folder, Style()).ok);
    EXPECT_TRUE(store.read(folder).isEmpty());
    EXPECT_EQ(TagStore::readAttr(folder, FolderStyleLogic::attributeName(), &raw), TagStore::ReadResult::NoData);
}

TEST(FolderStyleStore, NeverTouchesOtherAttributes)
{
    SKIP_WITHOUT_SANDBOX(dir);
    FolderStyleStore store(dir->filePath(QStringLiteral("cfg/folder-styles.json")));
    const QString folder = makeFolder(*dir, QStringLiteral("tagged"));
    const QByteArray p = QFile::encodeName(folder);
    ASSERT_EQ(::lsetxattr(p.constData(), "user.xdg.tags", "Red,project", 11, 0), 0);
    ASSERT_EQ(::lsetxattr(p.constData(), "user.other.app", "keep", 4, 0), 0);
    ASSERT_TRUE(store.write(folder, style("accent")).ok);
    ASSERT_TRUE(store.write(folder, Style()).ok);
    char buf[64];
    ssize_t n = ::lgetxattr(p.constData(), "user.xdg.tags", buf, sizeof buf);
    ASSERT_EQ(n, 11);
    EXPECT_EQ(QByteArray(buf, int(n)), QByteArray("Red,project"));
    n = ::lgetxattr(p.constData(), "user.other.app", buf, sizeof buf);
    ASSERT_EQ(n, 4);
    EXPECT_EQ(QByteArray(buf, int(n)), QByteArray("keep"));
}

TEST(FolderStyleStore, KeepsNewerVersionKeysInTheAttribute)
{
    SKIP_WITHOUT_SANDBOX(dir);
    FolderStyleStore store(dir->filePath(QStringLiteral("cfg/folder-styles.json")));
    const QString folder = makeFolder(*dir, QStringLiteral("future"));
    const QByteArray p = QFile::encodeName(folder);
    const QByteArray before("{\"v\":2,\"color\":\"#ff0000\",\"badge\":\"gold\"}");
    ASSERT_EQ(::lsetxattr(p.constData(), FolderStyleLogic::attributeName(), before.constData(), size_t(before.size()), 0), 0);
    ASSERT_TRUE(store.write(folder, style("#00ff00")).ok);
    QByteArray raw;
    ASSERT_EQ(TagStore::readAttr(folder, FolderStyleLogic::attributeName(), &raw), TagStore::ReadResult::Ok);
    EXPECT_NE(raw.indexOf("\"badge\":\"gold\""), -1);
    EXPECT_NE(raw.indexOf("\"v\":2"), -1);
}

TEST(FolderStyleStore, FailedReadAbortsTheWrite)
{
    SKIP_WITHOUT_SANDBOX(dir);
    if (::geteuid() == 0)
        GTEST_SKIP() << "root ignores permissions";
    FolderStyleStore store(dir->filePath(QStringLiteral("cfg/folder-styles.json")));
    const QString folder = makeFolder(*dir, QStringLiteral("locked"));
    ASSERT_TRUE(store.write(folder, style("#e5484d")).ok);
    ASSERT_EQ(::chmod(QFile::encodeName(folder).constData(), 0), 0);
    const auto r = store.write(folder, style("#00ff00"));
    ::chmod(QFile::encodeName(folder).constData(), 0755);
    EXPECT_FALSE(r.ok);
    EXPECT_FALSE(r.error.isEmpty());
    EXPECT_FALSE(r.fellBack) << "a failed read must not be answered by the fallback store";
    // Nothing was replaced.
    EXPECT_EQ(store.read(folder).color, QStringLiteral("#e5484d"));
    EXPECT_EQ(store.fallbackCount(), 0);
}

TEST(FolderStyleStore, ReadOnlyFolderUsesTheFallbackStore)
{
    SKIP_WITHOUT_SANDBOX(dir);
    if (::geteuid() == 0)
        GTEST_SKIP() << "root ignores permissions";
    const QString file = dir->filePath(QStringLiteral("cfg/folder-styles.json"));
    FolderStyleStore store(file);
    const QString folder = makeFolder(*dir, QStringLiteral("readonly"));
    ASSERT_EQ(::chmod(QFile::encodeName(folder).constData(), 0555), 0);
    const auto r = store.write(folder, style("#8e5bea", "\xE2\x98\x85"));
    EXPECT_TRUE(r.ok) << r.error.toStdString();
    EXPECT_TRUE(r.fellBack);
    EXPECT_EQ(store.fallbackCount(), 1);
    EXPECT_EQ(store.read(folder).color, QStringLiteral("#8e5bea"));
    EXPECT_EQ(store.read(folder).glyph, QString::fromUtf8("\xE2\x98\x85"));
    // The attribute was not touched, the store file is private and holds the entry.
    QByteArray raw;
    EXPECT_EQ(TagStore::readAttr(folder, FolderStyleLogic::attributeName(), &raw), TagStore::ReadResult::NoData);
    struct stat st;
    ASSERT_EQ(::stat(QFile::encodeName(file).constData(), &st), 0);
    EXPECT_EQ(st.st_mode & 0777, mode_t(0600));
    // A new store object (another process) sees it too.
    FolderStyleStore other(file);
    EXPECT_EQ(other.read(folder).color, QStringLiteral("#8e5bea"));
    // Reset drops the entry.
    ASSERT_TRUE(store.write(folder, Style()).ok);
    EXPECT_EQ(store.fallbackCount(), 0);
    EXPECT_TRUE(store.read(folder).isEmpty());
    ::chmod(QFile::encodeName(folder).constData(), 0755);
}

TEST(FolderStyleStore, AnEntryYieldsToTheAttributeOnceItCanBeWritten)
{
    SKIP_WITHOUT_SANDBOX(dir);
    if (::geteuid() == 0)
        GTEST_SKIP() << "root ignores permissions";
    FolderStyleStore store(dir->filePath(QStringLiteral("cfg/folder-styles.json")));
    const QString folder = makeFolder(*dir, QStringLiteral("flip"));
    ::chmod(QFile::encodeName(folder).constData(), 0555);
    ASSERT_TRUE(store.write(folder, style("#e5484d")).fellBack);
    ::chmod(QFile::encodeName(folder).constData(), 0755);
    const auto r = store.write(folder, style("#3fae5a"));
    ASSERT_TRUE(r.ok);
    EXPECT_FALSE(r.fellBack);
    EXPECT_EQ(store.fallbackCount(), 0) << "the stale entry would hide the attribute";
    EXPECT_EQ(store.read(folder).color, QStringLiteral("#3fae5a"));
}

TEST(FolderStyleStore, CorruptStoreIsNeverOverwritten)
{
    SKIP_WITHOUT_SANDBOX(dir);
    if (::geteuid() == 0)
        GTEST_SKIP() << "root ignores permissions";
    const QString file = dir->filePath(QStringLiteral("cfg/folder-styles.json"));
    QDir().mkpath(dir->filePath(QStringLiteral("cfg")));
    QFile f(file);
    ASSERT_TRUE(f.open(QIODevice::WriteOnly));
    f.write("{ this is not json");
    f.close();
    FolderStyleStore store(file);
    EXPECT_TRUE(store.fallbackBroken());
    const QString folder = makeFolder(*dir, QStringLiteral("ro"));
    ::chmod(QFile::encodeName(folder).constData(), 0555);
    const auto r = store.write(folder, style("#e5484d"));
    ::chmod(QFile::encodeName(folder).constData(), 0755);
    EXPECT_FALSE(r.ok);
    QFile again(file);
    ASSERT_TRUE(again.open(QIODevice::ReadOnly));
    EXPECT_EQ(again.readAll(), QByteArray("{ this is not json"));
    // The attribute path does not need the store: a writable folder still works.
    const QString plain = makeFolder(*dir, QStringLiteral("plain"));
    EXPECT_TRUE(store.write(plain, style("#e5484d")).ok);
}

TEST(FolderStyleStore, OnlyRealFoldersAreStyled)
{
    SKIP_WITHOUT_SANDBOX(dir);
    FolderStyleStore store(dir->filePath(QStringLiteral("cfg/folder-styles.json")));
    const QString folder = makeFolder(*dir, QStringLiteral("target"));
    const QString link = dir->filePath(QStringLiteral("link"));
    ASSERT_TRUE(QFile::link(folder, link));
    EXPECT_FALSE(store.write(link, style("#e5484d")).ok);
    EXPECT_TRUE(store.read(folder).isEmpty()) << "a link is never followed to its target";
    QFile f(dir->filePath(QStringLiteral("file")));
    ASSERT_TRUE(f.open(QIODevice::WriteOnly));
    f.close();
    EXPECT_FALSE(store.write(f.fileName(), style("#e5484d")).ok);
    EXPECT_FALSE(store.write(dir->filePath(QStringLiteral("missing")), style("#e5484d")).ok);
}

TEST(FolderStyleStore, ReloadSeesAnotherProcessWrite)
{
    SKIP_WITHOUT_SANDBOX(dir);
    if (::geteuid() == 0)
        GTEST_SKIP() << "root ignores permissions";
    const QString file = dir->filePath(QStringLiteral("cfg/folder-styles.json"));
    FolderStyleStore mine(file);
    FolderStyleStore theirs(file);
    const QString folder = makeFolder(*dir, QStringLiteral("shared"));
    EXPECT_FALSE(mine.reload()) << "nothing yet";
    ::chmod(QFile::encodeName(folder).constData(), 0555);
    ASSERT_TRUE(theirs.write(folder, style("#f5883b")).ok);
    ::chmod(QFile::encodeName(folder).constData(), 0755);
    EXPECT_TRUE(mine.reload());
    EXPECT_EQ(mine.read(folder).color, QStringLiteral("#f5883b"));
    EXPECT_FALSE(mine.reload()) << "unchanged";
}

TEST(FolderStyleStore, ThousandFoldersCostLittleWithoutCustomisation)
{
    SKIP_WITHOUT_SANDBOX(dir);
    FolderStyleStore store(dir->filePath(QStringLiteral("cfg/folder-styles.json")));
    QStringList folders;
    for (int i = 0; i < 1000; ++i)
        folders.append(makeFolder(*dir, QStringLiteral("d%1").arg(i)));
    QElapsedTimer t;
    t.start();
    int customised = 0;
    for (const QString &f : folders)
        customised += !store.read(f).isEmpty();
    const qint64 plain = t.nsecsElapsed() / 1000;
    EXPECT_EQ(customised, 0);
    for (int i = 0; i < 1000; i += 10)
        ASSERT_TRUE(store.write(folders[i], style("#e5484d", "A")).ok);
    t.restart();
    for (const QString &f : folders)
        customised += !store.read(f).isEmpty();
    const qint64 mixed = t.nsecsElapsed() / 1000;
    EXPECT_EQ(customised, 100);
    RecordProperty("read1000_plain_us", plain);
    RecordProperty("read1000_100customised_us", mixed);
    std::printf("folder style: 1000 folders read in %lld us (none customised), %lld us (100 customised)\n", (long long)plain, (long long)mixed);
}

TEST(FolderStyleStore, OversizedAttributeIsNotReplaced)
{
    SKIP_WITHOUT_SANDBOX(dir);
    FolderStyleStore store(dir->filePath(QStringLiteral("cfg/folder-styles.json")));
    const QString folder = makeFolder(*dir, QStringLiteral("big"));
    const QByteArray p = QFile::encodeName(folder);
    const QByteArray big = "{\"v\":2,\"future\":\"" + QByteArray(5000, 'z') + "\"}";
    if (::lsetxattr(p.constData(), FolderStyleLogic::attributeName(), big.constData(), size_t(big.size()), 0) != 0)
        GTEST_SKIP() << "this filesystem does not take a 5 KB attribute";
    const auto r = store.write(folder, style("#00ff00"));
    EXPECT_FALSE(r.ok);
    EXPECT_FALSE(r.error.isEmpty());
    EXPECT_FALSE(store.write(folder, Style()).ok) << "a reset would remove the unknown keys too";
    QByteArray raw;
    ASSERT_EQ(TagStore::readAttr(folder, FolderStyleLogic::attributeName(), &raw), TagStore::ReadResult::Ok);
    EXPECT_EQ(raw, big) << "the stored value is untouched";
}

TEST(FolderStyleStore, ResetOnAReadOnlyFolderWithAnAttributeDropsTheEntryAndSaysWhy)
{
    SKIP_WITHOUT_SANDBOX(dir);
    if (::geteuid() == 0)
        GTEST_SKIP() << "root ignores permissions";
    FolderStyleStore store(dir->filePath(QStringLiteral("cfg/folder-styles.json")));
    const QString folder = makeFolder(*dir, QStringLiteral("attr-then-ro"));
    ASSERT_TRUE(store.write(folder, style("#e5484d")).ok); // the attribute, written while writable
    ASSERT_EQ(::chmod(QFile::encodeName(folder).constData(), 0555), 0);
    ASSERT_TRUE(store.write(folder, style("#00ff00")).fellBack); // now only the per-user entry can change
    EXPECT_EQ(store.fallbackCount(), 1);
    const auto r = store.write(folder, Style());
    ::chmod(QFile::encodeName(folder).constData(), 0755);
    EXPECT_FALSE(r.ok) << "the attribute can't be removed: the reset fails with the reason";
    EXPECT_FALSE(r.error.isEmpty());
    EXPECT_TRUE(r.changed) << "the entry is gone, views must refresh";
    EXPECT_EQ(store.fallbackCount(), 0) << "no entry is left behind";
    EXPECT_EQ(store.read(folder).color, QStringLiteral("#e5484d")) << "the folder's own attribute shows";
}

TEST(FolderStyleStore, EntriesFollowRenamesAndAreNotInheritedByNewFolders)
{
    SKIP_WITHOUT_SANDBOX(dir);
    if (::geteuid() == 0)
        GTEST_SKIP() << "root ignores permissions";
    const QString file = dir->filePath(QStringLiteral("cfg/folder-styles.json"));
    FolderStyleStore store(file);
    store.setMountsForTests(FolderStyleStore::Mounts::parse("1 0 0:1 / / rw - ext4 /dev/x rw\n", ""));
    const QString a = makeFolder(*dir, QStringLiteral("a"));
    const QString sub = makeFolder(*dir, QStringLiteral("a/sub"));
    ::chmod(QFile::encodeName(sub).constData(), 0555);
    ::chmod(QFile::encodeName(a).constData(), 0555);
    ASSERT_TRUE(store.write(a, style("#e5484d")).fellBack);
    ASSERT_TRUE(store.write(sub, style("#3fae5a", "A")).fellBack);
    ::chmod(QFile::encodeName(a).constData(), 0755);
    const QString b = dir->filePath(QStringLiteral("b"));
    ASSERT_TRUE(QDir().rename(a, b));
    EXPECT_TRUE(store.moveEntries(a, b));
    EXPECT_EQ(store.read(b).color, QStringLiteral("#e5484d"));
    EXPECT_EQ(store.read(b + QStringLiteral("/sub")).color, QStringLiteral("#3fae5a")) << "folders under it follow";
    EXPECT_TRUE(store.read(a).isEmpty());
    EXPECT_EQ(store.fallbackCount(), 2);
    EXPECT_FALSE(store.moveEntries(a, b)) << "nothing left to move";

    // A folder that goes away outside Files: its entry is pruned at the next write, and a new folder at that path is plain.
    ::chmod(QFile::encodeName(b + QStringLiteral("/sub")).constData(), 0755);
    ASSERT_TRUE(QDir(b).removeRecursively());
    const QString other = makeFolder(*dir, QStringLiteral("other"));
    ::chmod(QFile::encodeName(other).constData(), 0555);
    ASSERT_TRUE(store.write(other, style("#8e5bea")).fellBack);
    ::chmod(QFile::encodeName(other).constData(), 0755);
    store.waitForPrune(); // the write above may have started a background prune: drain it, then force one that sees every change
    store.startPrune(true);
    store.waitForPrune();
    EXPECT_EQ(store.fallbackCount(), 1) << "the entries of the vanished folders are pruned (by the worker)";
    makeFolder(*dir, QStringLiteral("b"));
    EXPECT_TRUE(store.read(b).isEmpty()) << "a new folder at an old path does not inherit the look";

    // Files creating a folder drops an old entry as well.
    ::chmod(QFile::encodeName(b).constData(), 0555);
    ASSERT_TRUE(store.write(b, style("#f5883b")).fellBack);
    ::chmod(QFile::encodeName(b).constData(), 0755);
    EXPECT_TRUE(store.dropEntry(b));
    EXPECT_TRUE(store.read(b).isEmpty());
    EXPECT_FALSE(store.dropEntry(b));
}

TEST(FolderStyleStore, EntriesOfAnUnpluggedVolumeAreKept)
{
    SKIP_WITHOUT_SANDBOX(dir);
    if (::geteuid() == 0)
        GTEST_SKIP() << "root ignores permissions";
    const QString file = dir->filePath(QStringLiteral("cfg/folder-styles.json"));
    QDir().mkpath(dir->filePath(QStringLiteral("cfg")));
    QFile f(file);
    ASSERT_TRUE(f.open(QIODevice::WriteOnly));
    f.write("{\"version\":1,\"serial\":3,\"folders\":{\"/run/media/nobody/GF-TEST-STICK/Photos\":{\"color\":\"#e5484d\"}}}");
    f.close();
    FolderStyleStore store(file);
    const QString folder = makeFolder(*dir, QStringLiteral("ro"));
    ::chmod(QFile::encodeName(folder).constData(), 0555);
    ASSERT_TRUE(store.write(folder, style("#3fae5a")).fellBack);
    ::chmod(QFile::encodeName(folder).constData(), 0755);
    EXPECT_EQ(store.fallbackCount(), 2);
    EXPECT_EQ(store.read(QStringLiteral("/run/media/nobody/GF-TEST-STICK/Photos")).color, QStringLiteral("#e5484d"));
}

TEST(FolderStyleStore, TheCapIsExplicitAndNothingIsDroppedSilently)
{
    SKIP_WITHOUT_SANDBOX(dir);
    if (::geteuid() == 0)
        GTEST_SKIP() << "root ignores permissions";
    const QString file = dir->filePath(QStringLiteral("cfg/folder-styles.json"));
    QDir().mkpath(dir->filePath(QStringLiteral("cfg")));
    const int total = FolderStyleStore::kMaxFallbackEntries + 50;
    QByteArray json = "{\"version\":1,\"serial\":1,\"folders\":{";
    for (int i = 0; i < total; ++i) {
        if (i)
            json += ',';
        json += "\"/run/media/nobody/GF-TEST-STICK/f" + QByteArray::number(i) + "\":{\"color\":\"#e5484d\"}";
    }
    json += "}}";
    QFile f(file);
    ASSERT_TRUE(f.open(QIODevice::WriteOnly));
    f.write(json);
    f.close();
    FolderStyleStore store(file);
    EXPECT_EQ(store.fallbackCount(), total) << "a file over the cap is read whole";
    // A new entry is refused with a reason ...
    const QString folder = makeFolder(*dir, QStringLiteral("ro"));
    ::chmod(QFile::encodeName(folder).constData(), 0555);
    const auto refused = store.write(folder, style("#3fae5a"));
    ::chmod(QFile::encodeName(folder).constData(), 0755);
    EXPECT_FALSE(refused.ok);
    EXPECT_FALSE(refused.error.isEmpty());
    // ... and a write that does save the file (an attribute write whose entry is dropped) keeps every other entry.
    FolderStyleStore again(file);
    EXPECT_EQ(again.fallbackCount(), total) << "nothing was dropped";
    const QString plain = makeFolder(*dir, QStringLiteral("plain"));
    ::chmod(QFile::encodeName(plain).constData(), 0555);
    EXPECT_FALSE(again.write(plain, style("#3fae5a")).ok) << "still full";
    ::chmod(QFile::encodeName(plain).constData(), 0755);
    EXPECT_TRUE(again.dropEntry(QStringLiteral("/run/media/nobody/GF-TEST-STICK/f0")));
    EXPECT_EQ(FolderStyleStore(file).fallbackCount(), total - 1) << "only the entry asked for is gone";
}

// ---- pruning: which entries may be looked at, and where ----

TEST(FolderStyleStore, MountTableDecidesWhatMayBePruned)
{
    const QByteArray mountinfo =
        "1 0 8:1 / / rw - ext4 /dev/sda1 rw\n"
        "2 1 0:50 / /mnt/nas rw - nfs4 server:/export rw\n"
        "3 1 8:17 / /run/media/me/STICK rw - vfat /dev/sdb1 rw\n"
        "4 1 8:33 / /data rw - btrfs /dev/sdc rw\n"
        "5 1 0:60 / /mnt/with\\040space rw - fuse.sshfs me@host: rw\n"
        "6 1 8:49 / /mnt/disk2 rw - ext4 /dev/sdd1 rw\n";
    const QByteArray fstab = "# comment\n/dev/sde1 /mnt/usb ext4 defaults 0 2\n/dev/sdc /data btrfs defaults 0 0\n\n";
    const auto m = FolderStyleStore::Mounts::parse(mountinfo, fstab);
    EXPECT_TRUE(m.isLocalAndMounted(QStringLiteral("/home/u/Projects")));
    EXPECT_TRUE(m.isLocalAndMounted(QStringLiteral("/data/x")));
    EXPECT_TRUE(m.isLocalAndMounted(QStringLiteral("/mnt/disk2/x"))) << "a fixed disk that is mounted";
    EXPECT_FALSE(m.isLocalAndMounted(QStringLiteral("/mnt/nas/Photos"))) << "network";
    EXPECT_FALSE(m.isLocalAndMounted(QStringLiteral("/mnt/with space/x"))) << "FUSE (and an escaped mount point)";
    EXPECT_FALSE(m.isLocalAndMounted(QStringLiteral("/run/media/me/STICK/x"))) << "removable filesystem";
    EXPECT_FALSE(m.isLocalAndMounted(QStringLiteral("/run/media/me/OTHER/x"))) << "a stick that is not plugged in";
    EXPECT_FALSE(m.isLocalAndMounted(QStringLiteral("/mnt/usb/x"))) << "an fstab mount point that is not mounted";
    EXPECT_FALSE(m.isLocalAndMounted(QStringLiteral("/mnt/unknown/x"))) << "under /mnt but no mount: kept";
    EXPECT_FALSE(m.isLocalAndMounted(QStringLiteral("/media/disk/x")));
    EXPECT_FALSE(FolderStyleStore::Mounts().isLocalAndMounted(QStringLiteral("/home/u"))) << "no mount table, no stat";
}

TEST(FolderStyleStore, PruningStatsOnlyLocalEntriesAndOnlyOffTheGuiThread)
{
    SKIP_WITHOUT_SANDBOX(dir);
    if (::geteuid() == 0)
        GTEST_SKIP() << "root ignores permissions";
    const QString file = dir->filePath(QStringLiteral("cfg/folder-styles.json"));
    QDir().mkpath(dir->filePath(QStringLiteral("cfg")));
    const QString goneLocal = dir->filePath(QStringLiteral("vanished"));
    const QString aliveLocal = makeFolder(*dir, QStringLiteral("alive"));
    QByteArray json = "{\"version\":1,\"serial\":1,\"folders\":{";
    const QStringList keys = {goneLocal, aliveLocal, QStringLiteral("/mnt/nas/Photos"), QStringLiteral("/mnt/nas/Gone/Deeper"),
                              QStringLiteral("/mnt/usb/Photos"), QStringLiteral("/run/media/me/STICK/Music")};
    for (int i = 0; i < keys.size(); ++i)
        json += (i ? "," : "") + QByteArray("\"") + keys.at(i).toUtf8() + "\":{\"color\":\"#e5484d\"}";
    json += "}}";
    QFile f(file);
    ASSERT_TRUE(f.open(QIODevice::WriteOnly));
    f.write(json);
    f.close();

    QMutex lock;
    QStringList statted;
    bool onGuiThread = false;
    const QThread *gui = QThread::currentThread();
    FolderStyleStore::setStatObserverForTests([&](const QString &path) {
        QMutexLocker l(&lock);
        statted.append(path);
        onGuiThread = onGuiThread || QThread::currentThread() == gui;
    });
    FolderStyleStore store(file);
    store.setMountsForTests(FolderStyleStore::Mounts::parse(
        "1 0 8:1 / / rw - ext4 /dev/sda1 rw\n2 1 0:50 / /mnt/nas rw - nfs4 server:/export rw\n3 1 8:17 / /run/media/me/STICK rw - vfat /dev/sdb1 rw\n", ""));
    EXPECT_EQ(store.fallbackCount(), 6);
    store.startPrune(true);
    store.waitForPrune();
    FolderStyleStore::setStatObserverForTests(nullptr);
    EXPECT_FALSE(onGuiThread) << "a store entry is never statted on the GUI thread";
    for (const QString &p : statted)
    {
        // The components above a share or an unplugged volume are on the local root and are looked at; nothing at or under
        // the mount points of the network share, the stick or the unmounted fstab/removable points is.
        for (const char *point : {"/mnt/nas", "/mnt/usb", "/run/media/me/STICK"})
            EXPECT_FALSE(p == QLatin1String(point) || p.startsWith(QLatin1String(point) + QLatin1Char('/'))) << "statted: " << p.toStdString();
    }
    EXPECT_EQ(store.fallbackCount(), 5) << "only the vanished local folder is pruned";
    FolderStyleStore again(file);
    EXPECT_TRUE(again.read(goneLocal).isEmpty());
    EXPECT_EQ(again.read(QStringLiteral("/mnt/nas/Photos")).color, QStringLiteral("#e5484d")) << "network entries are kept";
    EXPECT_EQ(again.read(QStringLiteral("/mnt/nas/Gone/Deeper")).color, QStringLiteral("#e5484d"));
    EXPECT_EQ(again.read(QStringLiteral("/mnt/usb/Photos")).color, QStringLiteral("#e5484d")) << "an empty fixed mount point is kept";
    EXPECT_EQ(again.read(QStringLiteral("/run/media/me/STICK/Music")).color, QStringLiteral("#e5484d"));
    EXPECT_EQ(again.read(aliveLocal).color, QStringLiteral("#e5484d"));
}

TEST(FolderStyleStore, ARefusedNewEntryFindsRoomOnceVanishedFoldersArePruned)
{
    SKIP_WITHOUT_SANDBOX(dir);
    if (::geteuid() == 0)
        GTEST_SKIP() << "root ignores permissions";
    const QString file = dir->filePath(QStringLiteral("cfg/folder-styles.json"));
    QDir().mkpath(dir->filePath(QStringLiteral("cfg")));
    QByteArray json = "{\"version\":1,\"serial\":1,\"folders\":{";
    for (int i = 0; i < FolderStyleStore::kMaxFallbackEntries; ++i) {
        if (i)
            json += ',';
        json += "\"" + dir->filePath(QStringLiteral("gone%1").arg(i)).toUtf8() + "\":{\"color\":\"#e5484d\"}";
    }
    json += "}}";
    QFile f(file);
    ASSERT_TRUE(f.open(QIODevice::WriteOnly));
    f.write(json);
    f.close();
    FolderStyleStore store(file);
    store.setMountsForTests(FolderStyleStore::Mounts::parse("1 0 8:1 / / rw - ext4 /dev/sda1 rw\n", ""));
    const QString folder = makeFolder(*dir, QStringLiteral("ro"));
    ::chmod(QFile::encodeName(folder).constData(), 0555);
    EXPECT_FALSE(store.write(folder, style("#3fae5a")).ok) << "full: refused now";
    store.waitForPrune();
    EXPECT_EQ(store.fallbackCount(), 0) << "the vanished folders were pruned in the background";
    EXPECT_TRUE(store.write(folder, style("#3fae5a")).ok) << "room now";
    ::chmod(QFile::encodeName(folder).constData(), 0755);
}

TEST(FolderStyleStore, AStoreOverTheByteLimitIsNeverWritten)
{
    SKIP_WITHOUT_SANDBOX(dir);
    if (::geteuid() == 0)
        GTEST_SKIP() << "root ignores permissions";
    const QString file = dir->filePath(QStringLiteral("cfg/folder-styles.json"));
    QDir().mkpath(dir->filePath(QStringLiteral("cfg")));
    // Long paths (a few KB each) fill the 4 MiB the reader accepts long before 20000 entries.
    QByteArray json = "{\"version\":1,\"serial\":1,\"folders\":{";
    int n = 0;
    while (json.size() < 4 * 1024 * 1024 - 3400) {
        if (n)
            json += ',';
        json += "\"/run/media/nobody/L/" + QByteArray::number(n) + QByteArray(3000, 'x') + "\":{\"color\":\"#e5484d\"}";
        ++n;
    }
    json += "}}";
    ASSERT_LT(json.size(), 4 * 1024 * 1024);
    QFile f(file);
    ASSERT_TRUE(f.open(QIODevice::WriteOnly));
    f.write(json);
    f.close();
    FolderStyleStore store(file);
    ASSERT_EQ(store.fallbackCount(), n);
    // Entries that would push the file over the limit: refused with a reason, the file untouched and still readable.
    QStringList folders;
    const auto big = [&] {
        for (int i = 0; i < 60; ++i)
            folders.append(makeFolder(*dir, QStringLiteral("ro%1").arg(i)));
    };
    big();
    bool refused = false;
    QString reason;
    for (const QString &folder : folders) {
        ::chmod(QFile::encodeName(folder).constData(), 0555);
        const auto r = store.write(folder, style("#3fae5a", "A"));
        ::chmod(QFile::encodeName(folder).constData(), 0755);
        if (!r.ok) {
            refused = true;
            reason = r.error;
            break;
        }
    }
    store.waitForPrune();
    EXPECT_TRUE(refused) << "a store that would not be read back is refused";
    EXPECT_FALSE(reason.isEmpty());
    QFile after(file);
    ASSERT_TRUE(after.open(QIODevice::ReadOnly));
    EXPECT_LE(after.size(), 4 * 1024 * 1024) << "never written over the limit";
    FolderStyleStore reader(file);
    EXPECT_FALSE(reader.fallbackBroken());
    EXPECT_GE(reader.fallbackCount(), n);
}

// A cut-and-paste with Skip or Rename in the conflict dialog: the look follows only a folder really created at
// destination/name, never a different existing folder of that name.
TEST(FolderStyleLogic, LooksFollowOnlyWhatThePasteReallyCreated)
{
    const QUrl dest = QUrl::fromLocalFile(QStringLiteral("/data/target/"));
    const QList<QUrl> sources = {QUrl::fromLocalFile(QStringLiteral("/data/src/Photos")), QUrl::fromLocalFile(QStringLiteral("/data/src/Music")),
                                 QUrl::fromLocalFile(QStringLiteral("/data/src/Docs")), QUrl::fromLocalFile(QStringLiteral("/data/src/Misc"))};
    QSet<QUrl> created;
    created.insert(QUrl::fromLocalFile(QStringLiteral("/data/target/Photos")));        // moved as it is
    created.insert(QUrl::fromLocalFile(QStringLiteral("/data/target/Music (copy)"))); // Rename in the dialog: another name
    // Docs: Skip (nothing created); Misc: nothing reported.
    const auto follow = FolderStyleLogic::followingPaste(sources, dest, created);
    ASSERT_EQ(follow.size(), 1);
    EXPECT_EQ(follow.at(0).first, sources.at(0));
    EXPECT_EQ(follow.at(0).second, QUrl::fromLocalFile(QStringLiteral("/data/target/Photos")));
    // Overwrite: the folder is created (replaced) under the same name: it follows.
    EXPECT_EQ(FolderStyleLogic::followingPaste({sources.at(2)}, dest, {QUrl::fromLocalFile(QStringLiteral("/data/target/Docs"))}).size(), 1);
    EXPECT_TRUE(FolderStyleLogic::followingPaste(sources, dest, {}).isEmpty());
}

// The premise of the live update (FolderModel::watchShownFolder): a watch on a folder is told when another tool sets the
// look (an extended attribute) of one of its entries.
TEST(FolderStyleStore, AWatchOnTheFolderSeesAnotherToolSettingTheAttributeOfAnEntry)
{
    SKIP_WITHOUT_SANDBOX(dir);
    static int argc = 1;
    static char name[] = "tst";
    static char *argv[] = {name, nullptr};
    if (!QCoreApplication::instance())
        new QCoreApplication(argc, argv);
    const QString shown = makeFolder(*dir, QStringLiteral("shown"));
    const QString entry = makeFolder(*dir, QStringLiteral("shown/Music"));
    QFileSystemWatcher watcher;
    ASSERT_TRUE(watcher.addPath(shown));
    QEventLoop loop;
    bool seen = false;
    QObject::connect(&watcher, &QFileSystemWatcher::directoryChanged, &loop, [&] { seen = true; loop.quit(); });
    QTimer::singleShot(2000, &loop, &QEventLoop::quit);
    const QByteArray value = "{\"v\":1,\"color\":\"#e5484d\"}";
    ASSERT_EQ(::lsetxattr(QFile::encodeName(entry).constData(), FolderStyleLogic::attributeName(), value.constData(), size_t(value.size()), 0), 0);
    EXPECT_TRUE(seen || (loop.exec(), seen)) << "no directoryChanged for an attribute change of an entry";
    FolderStyleStore store(dir->filePath(QStringLiteral("cfg/folder-styles.json")));
    EXPECT_EQ(store.read(entry).color, QStringLiteral("#e5484d")) << "and a read now sees it";
}
