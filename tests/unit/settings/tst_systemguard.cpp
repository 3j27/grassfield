#include <gtest/gtest.h>

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QTemporaryDir>

#include <sys/stat.h>
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

// Wi-Fi and Bluetooth are read over D-Bus now: the only queries left are Sound's, the About pane's.
TEST(QueryGuard, NoNetworkOrBluetoothCommandIsAQuery)
{
    EXPECT_TRUE(isReadOnlyQuery({QStringLiteral("wpctl"), QStringLiteral("status")}));
    EXPECT_TRUE(isReadOnlyQuery({QStringLiteral("lspci")}));
    EXPECT_TRUE(isReadOnlyQuery({QStringLiteral("pacman"), QStringLiteral("-Q"), QStringLiteral("hyprland")}));
    EXPECT_FALSE(isReadOnlyQuery({QStringLiteral("wpctl"), QStringLiteral("set-volume"), QStringLiteral("52"), QStringLiteral("0.5")}));
    EXPECT_FALSE(isReadOnlyQuery({QStringLiteral("nmcli"), QStringLiteral("-t"), QStringLiteral("-f"), QStringLiteral("WIFI"), QStringLiteral("radio")}));
    EXPECT_FALSE(isReadOnlyQuery({QStringLiteral("bluetoothctl"), QStringLiteral("show")}));
    EXPECT_FALSE(isReadOnlyQuery({QStringLiteral("bluetoothctl"), QStringLiteral("devices"), QStringLiteral("Paired")}));
}

TEST(QueryGuard, TheGeneralPanesReadsAreExact)
{
    const QString home = QDir::cleanPath(QDir::homePath());
    auto du = [](const QStringList &paths) {
        return QStringList{QStringLiteral("du"), QStringLiteral("-s"), QStringLiteral("-x"), QStringLiteral("--block-size=1"), QStringLiteral("--")} + paths;
    };
    // Storage: the installed packages' sizes and the sizes of folders of the home, nothing else.
    EXPECT_TRUE(isReadOnlyQuery({QStringLiteral("pacman"), QStringLiteral("-Qi")}));
    EXPECT_FALSE(isReadOnlyQuery({QStringLiteral("pacman"), QStringLiteral("-Qi"), QStringLiteral("hyprland")}));
    EXPECT_FALSE(isReadOnlyQuery({QStringLiteral("pacman"), QStringLiteral("-Syu")}));
    EXPECT_TRUE(isReadOnlyQuery(du({home + QStringLiteral("/Documents"), home + QStringLiteral("/.local/share/Trash")})));
    EXPECT_TRUE(isReadOnlyQuery(du({home})));
    for (const QString &bad : {QStringLiteral("/etc"), QStringLiteral("/"), home + QStringLiteral("/../root"), home + QStringLiteral("/./x"),
                               home + QStringLiteral("/a/"), QStringLiteral("Documents"), home + QStringLiteral("/a\nb"), home + QStringLiteral("x")})
        EXPECT_FALSE(isReadOnlyQuery(du({bad}))) << bad.toStdString();
    EXPECT_FALSE(isReadOnlyQuery(du({})));
    QStringList many;
    for (int i = 0; i < 17; ++i)
        many << home + QStringLiteral("/f%1").arg(i);
    EXPECT_FALSE(isReadOnlyQuery(du(many)));
    EXPECT_FALSE(isReadOnlyQuery({QStringLiteral("du"), QStringLiteral("-s"), QStringLiteral("--"), home}));
    EXPECT_FALSE(isReadOnlyQuery({QStringLiteral("du"), QStringLiteral("-s"), QStringLiteral("-x"), QStringLiteral("--block-size=1"), QStringLiteral("--exclude=x"), home}));
    // Language & Region: omarchy-language is never a query, not even its reads (a dev session runs no script nobody here has
    // read; Omarchy 4.0.4 does not ship it). Integrator review of PR #6.
    EXPECT_FALSE(isReadOnlyQuery({QStringLiteral("omarchy-language")}));
    EXPECT_FALSE(isReadOnlyQuery({QStringLiteral("omarchy-language"), QStringLiteral("list")}));
    EXPECT_FALSE(isReadOnlyQuery({QStringLiteral("omarchy-language"), QStringLiteral("fr")}));
    EXPECT_FALSE(isReadOnlyQuery({QStringLiteral("omarchy-language"), QStringLiteral("locale")}));
}

TEST(ActionGuard, OmarchyLanguageTakesOneCodeOnly)
{
    const QString lang = QStringLiteral("omarchy-language");
    for (const char *ok : {"fr", "en", "pt-BR", "zh-CN", "fil"})
        EXPECT_TRUE(isAllowedAction({lang, QString::fromLatin1(ok)})) << ok;
    for (const char *no : {"", "FR", "fr\n", "fr; rm -rf ~", "--help", "list", "seed", "locale", "fr-", "f", "francais-de-france"})
        EXPECT_FALSE(isAllowedAction({lang, QString::fromLatin1(no)})) << no;
    EXPECT_FALSE(isAllowedAction({lang}));
    EXPECT_FALSE(isAllowedAction({lang, QStringLiteral("seed"), QStringLiteral("fr")}));
    EXPECT_FALSE(isAllowedAction({QStringLiteral("/usr/bin/omarchy-language"), QStringLiteral("fr")}));
}

TEST(ActionGuard, OmarchyLanguageMayWaitForItsPrompt)
{
    EXPECT_EQ(actionTimeoutMs({QStringLiteral("omarchy-language"), QStringLiteral("fr")}, 15000), 130000);
    EXPECT_EQ(actionTimeoutMs({QStringLiteral("wpctl"), QStringLiteral("set-mute")}, 15000), 15000);
    EXPECT_EQ(actionTimeoutMs({}, 15000), 15000);
}

TEST(ActionGuard, OnlyTheNamedProgramsRun)
{
    // xdg-open opens the attribution links of the wallpaper page (by bare name, never a path or a shell); omarchy-language is
    // Language & Region's (one code, ActionGuard.OmarchyLanguageTakesOneCodeOnly).
    for (const char *ok : {"wpctl", "xdg-open", "omarchy-language"})
        EXPECT_TRUE(isActionProgram(QString::fromLatin1(ok))) << ok;
    // nmcli and bluetoothctl are gone: Wi-Fi and Bluetooth are D-Bus calls (systembus.h), never commands.
    for (const char *no : {"", "sh", "bash", "/usr/bin/xdg-open", "xdg-open ", "gio", "rm", "env", "nmcli", "bluetoothctl"})
        EXPECT_FALSE(isActionProgram(QString::fromLatin1(no))) << no;
}

TEST(ActionGuard, XdgOpenOnlyOpensOneCleanHttpsLink)
{
    const QString open = QStringLiteral("xdg-open");
    EXPECT_TRUE(isAllowedAction({open, QStringLiteral("https://commons.wikimedia.org/wiki/File:Example.jpg")}));
    EXPECT_TRUE(isAllowedAction({open, QStringLiteral("https://creativecommons.org/licenses/by-sa/4.0/")}));
    // Local files and entries run whatever handler claims them; other schemes, credentials, options, extra words: no.
    for (const char *no : {"file:///etc/passwd", "/home/u/app.desktop", "app.desktop", "http://example.org/", "ftp://example.org/",
                           "javascript:alert(1)", "https://", "https://user:pw@example.org/", "--help", "-",
                           "https://example.org/a b", "https://example.org/\na", "https://exa\u202emple.org/", ""})
        EXPECT_FALSE(isAllowedAction({open, QString::fromUtf8(no)})) << no;
    EXPECT_FALSE(isAllowedAction({open}));
    EXPECT_FALSE(isAllowedAction({open, QStringLiteral("https://example.org/"), QStringLiteral("https://example.org/")}));
    // The other programs keep their whole argument vectors (their pages build them).
    EXPECT_TRUE(isAllowedAction({QStringLiteral("wpctl"), QStringLiteral("set-mute"), QStringLiteral("52"), QStringLiteral("1")}));
    EXPECT_FALSE(isAllowedAction({QStringLiteral("nmcli"), QStringLiteral("radio"), QStringLiteral("wifi"), QStringLiteral("on")}));
    EXPECT_FALSE(isAllowedAction({QStringLiteral("bluetoothctl"), QStringLiteral("power"), QStringLiteral("off")}));
    EXPECT_FALSE(isAllowedAction({QStringLiteral("sh"), QStringLiteral("-c"), QStringLiteral("xdg-open https://x.org")}));
    EXPECT_FALSE(isAllowedAction({}));
}

// ADR-0019: the dev guard is the one run-mode rule. A GRASSFIELD_DEV=1 that leaked into a packaged session
// (GRASSFIELD_SESSION=1) is not a dev session: the system sections act there.
TEST(DevSession, FollowsTheRunModeRule)
{
    qunsetenv("GRASSFIELD_SESSION");
    qunsetenv("GRASSFIELD_DEV");
    EXPECT_FALSE(grassfield::settings::devSession());
    qputenv("GRASSFIELD_DEV", "1");
    EXPECT_TRUE(grassfield::settings::devSession());
    qputenv("GRASSFIELD_SESSION", "1");
    EXPECT_FALSE(grassfield::settings::devSession());
    qputenv("GRASSFIELD_SESSION", "0");
    EXPECT_TRUE(grassfield::settings::devSession());
    qunsetenv("GRASSFIELD_SESSION");
    qunsetenv("GRASSFIELD_DEV");
}

// Login Items (Backend::writeAutostart, removeAutostart): only a plain <name>.desktop of the autostart folder, never through a
// symlink, and in a dev session only in a folder whose real location lies under <root>/.dev (review of ADR-0030: a symlink in
// .dev led a QSaveFile write out of it).
TEST(AutostartGuard, OnlyPlainEntriesOfTheFolder)
{
    QTemporaryDir tmp;
    const QString dir = QFileInfo(tmp.path()).canonicalFilePath() + QStringLiteral("/autostart");
    QDir().mkpath(dir);
    QFile target(tmp.path() + QStringLiteral("/dotfiles-notes.desktop"));
    ASSERT_TRUE(target.open(QIODevice::WriteOnly));
    target.close();
    ASSERT_EQ(::symlink(QFile::encodeName(target.fileName()).constData(), QFile::encodeName(dir + QStringLiteral("/linked.desktop")).constData()), 0);
    ASSERT_EQ(::symlink(QFile::encodeName(tmp.path() + QStringLiteral("/nowhere")).constData(), QFile::encodeName(dir + QStringLiteral("/dangling.desktop")).constData()), 0);

    EXPECT_TRUE(isAutostartWrite(dir + QStringLiteral("/notes.desktop"), dir, QString(), false));
    EXPECT_TRUE(isAutostartWrite(dir + QStringLiteral("/org.app_x+y-1.desktop"), dir, QString(), false));
    EXPECT_FALSE(isAutostartWrite(dir + QStringLiteral("/linked.desktop"), dir, QString(), false)) << "a symlink to a dotfile";
    EXPECT_FALSE(isAutostartWrite(dir + QStringLiteral("/dangling.desktop"), dir, QString(), false)) << "a symlink that leads nowhere yet";
    for (const QString &bad : {QStringLiteral("/notes"), QStringLiteral("/notes.desktop\n"), QStringLiteral("/../notes.desktop"), QStringLiteral("/sub/notes.desktop"),
                               QStringLiteral("/.desktop"), QStringLiteral("/a b.desktop")})
        EXPECT_FALSE(isAutostartWrite(dir + bad, dir, QString(), false)) << qPrintable(bad);
    EXPECT_FALSE(isAutostartWrite(tmp.path() + QStringLiteral("/notes.desktop"), dir, QString(), false)) << "another folder";
    EXPECT_FALSE(isAutostartWrite(dir + QStringLiteral("/notes.desktop"), QString(), QString(), false));
}

TEST(AutostartGuard, ADevSessionWritesOnlyUnderDev)
{
    const QString root = tree().root;
    const QString inside = root + QStringLiteral("/.dev/config/autostart");
    QDir().mkpath(inside);
    EXPECT_TRUE(isAutostartWrite(inside + QStringLiteral("/notes.desktop"), inside, root, true));
    // A folder that does not exist yet under .dev (isolated.sh creates it on the first write).
    EXPECT_TRUE(isAutostartWrite(root + QStringLiteral("/.dev/fresh/autostart/notes.desktop"), root + QStringLiteral("/.dev/fresh/autostart"), root, true));
    // The owner's folder, a folder outside .dev, a folder reached through the .dev/link symlink to <root>/outside.
    EXPECT_FALSE(isAutostartWrite(QDir::homePath() + QStringLiteral("/.config/autostart/notes.desktop"), QDir::homePath() + QStringLiteral("/.config/autostart"), root, true));
    EXPECT_FALSE(isAutostartWrite(root + QStringLiteral("/outside/notes.desktop"), root + QStringLiteral("/outside"), root, true));
    EXPECT_FALSE(isAutostartWrite(root + QStringLiteral("/.dev/link/notes.desktop"), root + QStringLiteral("/.dev/link"), root, true));
    EXPECT_FALSE(isAutostartWrite(root + QStringLiteral("/.dev/link/sub/notes.desktop"), root + QStringLiteral("/.dev/link/sub"), root, true));
    EXPECT_FALSE(isAutostartWrite(inside + QStringLiteral("/notes.desktop"), inside, QString(), true)) << "no worktree";
}

// A path that only reads as the folder once normalised: <root>/.dev/link is a symlink to <root>/outside, so the kernel resolves
// .dev/link/../config/autostart to <root>/config/autostart, outside .dev (counter-review of 2026-10-26).
TEST(AutostartGuard, ATextualDotDotThroughALinkIsRefused)
{
    const QString root = tree().root;
    const QString inside = root + QStringLiteral("/.dev/config/autostart");
    QDir().mkpath(inside);
    for (const bool dev : {true, false}) {
        EXPECT_FALSE(isAutostartWrite(root + QStringLiteral("/.dev/link/../config/autostart/x.desktop"), inside, root, dev)) << dev;
        EXPECT_FALSE(isAutostartWrite(inside + QStringLiteral("/./x.desktop"), inside, root, dev)) << dev;
        EXPECT_FALSE(isAutostartWrite(inside + QStringLiteral("//x.desktop"), inside, root, dev)) << dev;
        EXPECT_FALSE(isAutostartWrite(QStringLiteral("x.desktop"), QStringLiteral("."), root, dev)) << dev;
    }
    EXPECT_TRUE(isAutostartWrite(inside + QStringLiteral("/x.desktop"), inside, root, true));
}

// Login Items' image://icon with an absolute Icon= path: only a small regular raster file (a FIFO, a device, a link to one,
// an SVG, a huge file or an unclean path shows the page's own tile).
TEST(IconFile, OnlySmallRegularRasterFiles)
{
    QTemporaryDir tmp;
    const QString d = QFileInfo(tmp.path()).canonicalFilePath();
    QFile png(d + QStringLiteral("/app.png"));
    ASSERT_TRUE(png.open(QIODevice::WriteOnly));
    png.write("x");
    png.close();
    QFile big(d + QStringLiteral("/big.png"));
    ASSERT_TRUE(big.open(QIODevice::WriteOnly));
    big.write(QByteArray(1024 * 1024 + 1, 'x'));
    big.close();
    QFile svg(d + QStringLiteral("/app.svg"));
    ASSERT_TRUE(svg.open(QIODevice::WriteOnly));
    svg.close();
    ASSERT_EQ(::mkfifo(QFile::encodeName(d + QStringLiteral("/fifo.png")).constData(), 0600), 0);
    ASSERT_EQ(::symlink("/dev/zero", QFile::encodeName(d + QStringLiteral("/zero.png")).constData()), 0);
    ASSERT_EQ(::symlink(QFile::encodeName(d + QStringLiteral("/fifo.png")).constData(), QFile::encodeName(d + QStringLiteral("/tofifo.png")).constData()), 0);
    ASSERT_EQ(::symlink(QFile::encodeName(d + QStringLiteral("/app.png")).constData(), QFile::encodeName(d + QStringLiteral("/link.png")).constData()), 0);

    EXPECT_TRUE(isIconFile(d + QStringLiteral("/app.png")));
    EXPECT_TRUE(isIconFile(d + QStringLiteral("/link.png"))) << "a link to a small regular file";
    for (const char *bad : {"/fifo.png", "/zero.png", "/tofifo.png", "/big.png", "/app.svg", "/missing.png", "/./app.png", "/sub/../app.png"})
        EXPECT_FALSE(isIconFile(d + QString::fromLatin1(bad))) << bad;
    EXPECT_FALSE(isIconFile(QStringLiteral("app.png")));
    EXPECT_FALSE(isIconFile(d));
}
