#include <gtest/gtest.h>

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QTemporaryDir>

#include <unistd.h>

#include "systemguard.h"

using namespace grassfield::settings;

namespace {

const QString kTool = QStringLiteral("/usr/lib/grassfield/grassfield-wallpaper");
const QString kCache = QStringLiteral("/home/u/.cache/grassfield/wallpapers");

WallpaperContext installed()
{
    return {kTool, kCache, QString()};
}

// A real worktree-like tree: <root>/.dev/{wallpapers,cache}, <root>/outside, and a symlink <root>/.dev/link -> <root>/outside.
struct DevTree {
    QTemporaryDir tmp;
    QString root;
    DevTree()
    {
        root = QFileInfo(tmp.path()).canonicalFilePath();
        QDir().mkpath(root + QStringLiteral("/.dev/wallpapers"));
        QDir().mkpath(root + QStringLiteral("/.dev/cache/wallpapers"));
        QDir().mkpath(root + QStringLiteral("/outside"));
        QFile secret(root + QStringLiteral("/outside/secret.jpg"));
        (void) secret.open(QIODevice::WriteOnly);
        QFile ok(root + QStringLiteral("/.dev/wallpapers/a.jpg"));
        (void) ok.open(QIODevice::WriteOnly);
        (void) ::symlink(QFile::encodeName(root + QStringLiteral("/outside")).constData(), QFile::encodeName(root + QStringLiteral("/.dev/link")).constData());
        // A symlink that leads nowhere (yet): the file system will create the target wherever it points.
        (void) ::symlink(QFile::encodeName(root + QStringLiteral("/outside/not-yet")).constData(), QFile::encodeName(root + QStringLiteral("/.dev/dangling")).constData());
    }
};

const DevTree &tree()
{
    static const DevTree t;
    return t;
}

WallpaperContext dev()
{
    const QString r = tree().root;
    return {r + QStringLiteral("/.dev/build/grassfield-wallpaper"), r + QStringLiteral("/.dev/cache/wallpapers"), r};
}

QStringList list(const QString &tool, const QString &max, const QString &folder)
{
    return {tool, QStringLiteral("list"), QStringLiteral("--max"), max, QStringLiteral("--"), folder};
}

QStringList thumb(const QString &tool, const QString &width, const QString &out, const QString &src)
{
    return {tool, QStringLiteral("thumb"), QStringLiteral("--width"), width, QStringLiteral("--out"), out, QStringLiteral("--"), src};
}

} // namespace

TEST(WallpaperGuard, AcceptsTheVectorsThePageUses)
{
    EXPECT_TRUE(isWallpaperQuery({kTool, QStringLiteral("formats")}, installed()));
    EXPECT_TRUE(isWallpaperQuery(list(kTool, QStringLiteral("500"), QStringLiteral("/home/u/Pictures")), installed()));
    EXPECT_TRUE(isWallpaperQuery(thumb(kTool, QStringLiteral("320"), kCache + QStringLiteral("/thumbs"), QStringLiteral("/home/u/Pictures/a.jpg")), installed()));
    const WallpaperContext d = dev();
    EXPECT_TRUE(isWallpaperQuery(list(d.tool, QStringLiteral("500"), d.devRoot + QStringLiteral("/.dev/wallpapers")), d));
    EXPECT_TRUE(isWallpaperQuery(thumb(d.tool, QStringLiteral("320"), d.cacheDir + QStringLiteral("/thumbs"), d.devRoot + QStringLiteral("/.dev/wallpapers/a.jpg")), d));
}

TEST(WallpaperGuard, RefusesAnotherProgramCalledTheSame)
{
    for (const char *other : {"/tmp/grassfield-wallpaper", "/usr/bin/grassfield-wallpaper", "grassfield-wallpaper", "/usr/lib/grassfield/../grassfield/grassfield-wallpaper", "/usr/lib/grassfield/grassfield-wallpaper "}) {
        EXPECT_FALSE(isWallpaperQuery({QString::fromLatin1(other), QStringLiteral("formats")}, installed())) << other;
        EXPECT_TRUE(namesWallpaperTool(QString::fromLatin1(other)) || QString::fromLatin1(other).endsWith(QLatin1Char(' '))) << other;
    }
    EXPECT_FALSE(isWallpaperQuery({kTool}, installed()));
    EXPECT_FALSE(isWallpaperQuery({}, installed()));
    // Without a tool path nothing is accepted.
    EXPECT_FALSE(isWallpaperQuery({QString(), QStringLiteral("formats")}, WallpaperContext{}));
    // The generic read-only list no longer knows the helper.
    EXPECT_FALSE(isReadOnlyQuery({kTool, QStringLiteral("formats")}));
    EXPECT_FALSE(isReadOnlyQuery({kTool, QStringLiteral("list"), QStringLiteral("--max"), QStringLiteral("5"), QStringLiteral("--"), QStringLiteral("/")}));
}

TEST(WallpaperGuard, RefusesSubcommandsSettingsDoesNotUse)
{
    EXPECT_FALSE(isWallpaperQuery({kTool, QStringLiteral("prepare"), QStringLiteral("--size"), QStringLiteral("10x10"), QStringLiteral("--fit"), QStringLiteral("fill"), QStringLiteral("--color"), QStringLiteral("#000000"), QStringLiteral("--out"), kCache, QStringLiteral("--"), QStringLiteral("/a.jpg")}, installed()));
    EXPECT_FALSE(isWallpaperQuery({kTool, QStringLiteral("rm")}, installed()));
    EXPECT_FALSE(isWallpaperQuery({kTool, QStringLiteral("formats"), QStringLiteral("extra")}, installed()));
    EXPECT_FALSE(isWallpaperQuery({kTool, QStringLiteral("--help")}, installed()));
}

TEST(WallpaperGuard, ListArgumentsAreExact)
{
    const QString ok = QStringLiteral("/home/u/Pictures");
    EXPECT_FALSE(isWallpaperQuery(list(kTool, QStringLiteral("0"), ok), installed()));
    EXPECT_FALSE(isWallpaperQuery(list(kTool, QStringLiteral("501"), ok), installed()));
    EXPECT_FALSE(isWallpaperQuery(list(kTool, QStringLiteral("-5"), ok), installed()));
    EXPECT_FALSE(isWallpaperQuery(list(kTool, QStringLiteral("5x"), ok), installed()));
    EXPECT_FALSE(isWallpaperQuery(list(kTool, QString(), ok), installed()));
    EXPECT_FALSE(isWallpaperQuery(list(kTool, QStringLiteral("1000000000"), ok), installed()));
    EXPECT_FALSE(isWallpaperQuery(list(kTool, QStringLiteral("5"), QStringLiteral("relative")), installed()));
    EXPECT_FALSE(isWallpaperQuery(list(kTool, QStringLiteral("5"), QStringLiteral("-rf")), installed()));
    EXPECT_FALSE(isWallpaperQuery(list(kTool, QStringLiteral("5"), QStringLiteral("/a\nb")), installed()));
    for (const ushort mark : {0x202e, 0x202a, 0x2066, 0x200e, 0x200f, 0x061c, 0x2028, 0x0085})
        EXPECT_FALSE(isWallpaperQuery(list(kTool, QStringLiteral("5"), QStringLiteral("/a") + QChar(mark) + QStringLiteral("b")), installed())) << mark;
    EXPECT_FALSE(isWallpaperQuery(list(kTool, QStringLiteral("5"), QStringLiteral("/") + QString(5000, QLatin1Char('a'))), installed()));
    QStringList missingDashes = list(kTool, QStringLiteral("5"), ok);
    missingDashes.removeAt(4);
    EXPECT_FALSE(isWallpaperQuery(missingDashes, installed()));
    QStringList wrongOption = list(kTool, QStringLiteral("5"), ok);
    wrongOption[2] = QStringLiteral("--limit");
    EXPECT_FALSE(isWallpaperQuery(wrongOption, installed()));
    QStringList extra = list(kTool, QStringLiteral("5"), ok);
    extra << QStringLiteral("/second");
    EXPECT_FALSE(isWallpaperQuery(extra, installed()));
}

TEST(WallpaperGuard, ThumbOutIsExactlyTheThumbnailFolder)
{
    const QString src = QStringLiteral("/home/u/Pictures/a.jpg");
    const QString good = kCache + QStringLiteral("/thumbs");
    EXPECT_TRUE(isWallpaperQuery(thumb(kTool, QStringLiteral("320"), good, src), installed()));
    for (const QString &out : {kCache, kCache + QStringLiteral("/thumbs/"), kCache + QStringLiteral("/thumbs/../prepared"), kCache + QStringLiteral("/../thumbs"), QStringLiteral("/tmp"),
                               QStringLiteral("/home/u/.config/grassfield"), QStringLiteral("thumbs"), QString(), kCache + QStringLiteral("/thumbs2"), QStringLiteral("/home/u/.ssh")}) {
        EXPECT_FALSE(isWallpaperQuery(thumb(kTool, QStringLiteral("320"), out, src), installed())) << out.toStdString();
    }
    EXPECT_FALSE(isWallpaperQuery(thumb(kTool, QStringLiteral("15"), good, src), installed()));
    EXPECT_FALSE(isWallpaperQuery(thumb(kTool, QStringLiteral("1025"), good, src), installed()));
    EXPECT_FALSE(isWallpaperQuery(thumb(kTool, QStringLiteral("abc"), good, src), installed()));
    EXPECT_FALSE(isWallpaperQuery(thumb(kTool, QStringLiteral("320"), good, QStringLiteral("a.jpg")), installed()));
    EXPECT_FALSE(isWallpaperQuery(thumb(kTool, QStringLiteral("320"), good, QStringLiteral("--out")), installed()));
    // No cache directory known: no thumbnails.
    EXPECT_FALSE(isWallpaperQuery(thumb(kTool, QStringLiteral("320"), QStringLiteral("/thumbs"), src), WallpaperContext{kTool, QString(), QString()}));
}

TEST(WallpaperGuard, DevSessionStaysUnderTheWorktreesDevFolder)
{
    const WallpaperContext d = dev();
    const QString out = d.cacheDir + QStringLiteral("/thumbs");
    const QString r = d.devRoot;
    for (const QString &outside : {QStringLiteral("/home/u/Pictures"), r, r + QStringLiteral("/.devious/a.jpg"), r + QStringLiteral("/.dev/../secret.jpg"), r + QStringLiteral("/outside/secret.jpg"),
                                   QStringLiteral("/"),
                                   // Through the symlink .dev/link -> outside: by text it is under .dev, in fact it is not.
                                   r + QStringLiteral("/.dev/link/secret.jpg"), r + QStringLiteral("/.dev/link/new.jpg"), r + QStringLiteral("/.dev/link"), r + QStringLiteral("/.dev/link/../x.jpg"),
                                   r + QStringLiteral("/.dev/wallpapers/../../outside/secret.jpg"),
                                   r + QStringLiteral("/.dev/wallpapers/new/../../../outside/new.jpg")}) {
        EXPECT_FALSE(isWallpaperQuery(list(d.tool, QStringLiteral("5"), outside), d)) << outside.toStdString();
        EXPECT_FALSE(isWallpaperQuery(thumb(d.tool, QStringLiteral("320"), out, outside), d)) << outside.toStdString();
    }
    EXPECT_TRUE(isWallpaperQuery(list(d.tool, QStringLiteral("5"), r + QStringLiteral("/.dev")), d));
    EXPECT_TRUE(isWallpaperQuery(list(d.tool, QStringLiteral("5"), r + QStringLiteral("/.dev//wallpapers/./x")), d)) << "a file that does not exist yet, below .dev";
    EXPECT_TRUE(isWallpaperQuery(list(d.tool, QStringLiteral("5"), r + QStringLiteral("/.dev/wallpapers/a.jpg")), d));
    EXPECT_TRUE(isWallpaperQuery(list(d.tool, QStringLiteral("5"), r + QStringLiteral("/.dev/link/../.dev/wallpapers/a.jpg")), d)) << "through the link and back: really inside";
    EXPECT_TRUE(isWallpaperQuery(list(d.tool, QStringLiteral("5"), r + QStringLiteral("/.dev/wallpapers/../cache")), d));
    // A dangling symlink inside .dev, and paths whose first component is missing (the root prefixed by a name that does not exist).
    EXPECT_FALSE(isWallpaperQuery(list(d.tool, QStringLiteral("5"), r + QStringLiteral("/.dev/dangling")), d));
    EXPECT_FALSE(isWallpaperQuery(list(d.tool, QStringLiteral("5"), r + QStringLiteral("/.dev/dangling/x.jpg")), d));
    EXPECT_FALSE(isWallpaperQuery(thumb(d.tool, QStringLiteral("320"), out, r + QStringLiteral("/.dev/dangling")), d));
    EXPECT_FALSE(isWallpaperQuery(list(d.tool, QStringLiteral("5"), QStringLiteral("/nonexistent-first") + r + QStringLiteral("/.dev/x.jpg")), d));
    EXPECT_FALSE(isWallpaperQuery(thumb(d.tool, QStringLiteral("320"), out, QStringLiteral("/nonexistent-first") + r + QStringLiteral("/.dev/x.jpg")), d));
    // Without a .dev folder nothing is inside it.
    EXPECT_FALSE(isWallpaperQuery(list(d.tool, QStringLiteral("5"), QStringLiteral("/nonexistent-root/.dev/x.jpg")), WallpaperContext{d.tool, d.cacheDir, QStringLiteral("/nonexistent-root")}));
    // The installed helper path is not the dev one.
    EXPECT_FALSE(isWallpaperQuery({kTool, QStringLiteral("formats")}, d));
}

TEST(WallpaperGuard, NamesTheHelperByItsFileName)
{
    EXPECT_TRUE(namesWallpaperTool(QStringLiteral("/x/grassfield-wallpaper")));
    EXPECT_TRUE(namesWallpaperTool(QStringLiteral("grassfield-wallpaper")));
    EXPECT_FALSE(namesWallpaperTool(QStringLiteral("nmcli")));
    EXPECT_FALSE(namesWallpaperTool(QStringLiteral("/x/grassfield-wallpaper2")));
}
