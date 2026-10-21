#include <gtest/gtest.h>

#include "systemguard.h"

using namespace grassfield::settings;

namespace {

const QString kTool = QStringLiteral("/usr/lib/grassfield/grassfield-wallpaper");
const QString kCache = QStringLiteral("/home/u/.cache/grassfield/wallpapers");

WallpaperContext installed()
{
    return {kTool, kCache, QString()};
}

WallpaperContext dev()
{
    return {QStringLiteral("/w/repo/.dev/build/grassfield-wallpaper"), QStringLiteral("/w/repo/.dev/cache/wallpapers"), QStringLiteral("/w/repo")};
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
    EXPECT_TRUE(isWallpaperQuery(list(d.tool, QStringLiteral("500"), QStringLiteral("/w/repo/.dev/wallpapers")), d));
    EXPECT_TRUE(isWallpaperQuery(thumb(d.tool, QStringLiteral("320"), d.cacheDir + QStringLiteral("/thumbs"), QStringLiteral("/w/repo/.dev/wallpapers/a.jpg")), d));
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
    EXPECT_FALSE(isWallpaperQuery(list(kTool, QStringLiteral("5"), QStringLiteral("/a") + QChar(0x202e) + QStringLiteral("b")), installed()));
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
    for (const char *outside : {"/home/u/Pictures", "/w/repo", "/w/repo/.devious/a.jpg", "/w/repo/.dev/../secret.jpg", "/w/other/.dev/a.jpg", "/"}) {
        EXPECT_FALSE(isWallpaperQuery(list(d.tool, QStringLiteral("5"), QString::fromLatin1(outside)), d)) << outside;
        EXPECT_FALSE(isWallpaperQuery(thumb(d.tool, QStringLiteral("320"), out, QString::fromLatin1(outside)), d)) << outside;
    }
    EXPECT_TRUE(isWallpaperQuery(list(d.tool, QStringLiteral("5"), QStringLiteral("/w/repo/.dev")), d));
    EXPECT_TRUE(isWallpaperQuery(list(d.tool, QStringLiteral("5"), QStringLiteral("/w/repo/.dev//wallpapers/./x")), d));
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
