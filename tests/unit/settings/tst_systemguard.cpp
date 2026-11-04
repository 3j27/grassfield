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
    // The node names (the Type column), and nothing else of wpctl's: not another option, not a device's details.
    EXPECT_TRUE(isReadOnlyQuery({QStringLiteral("wpctl"), QStringLiteral("status"), QStringLiteral("-n")}));
    EXPECT_FALSE(isReadOnlyQuery({QStringLiteral("wpctl"), QStringLiteral("status"), QStringLiteral("-k")}));
    EXPECT_FALSE(isReadOnlyQuery({QStringLiteral("wpctl"), QStringLiteral("status"), QStringLiteral("-n"), QStringLiteral("-n")}));
    EXPECT_FALSE(isReadOnlyQuery({QStringLiteral("wpctl"), QStringLiteral("-n"), QStringLiteral("status")}));
    EXPECT_FALSE(isReadOnlyQuery({QStringLiteral("wpctl"), QStringLiteral("inspect"), QStringLiteral("52")}));
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

TEST(ActionGuard, BrightnessTakesOneBacklightAndAPercentage)
{
    const QString b = QStringLiteral("brightnessctl");
    const auto cmd = [&](const char *dev, const char *value) {
        return QStringList{b, QStringLiteral("-q"), QStringLiteral("-d"), QString::fromLatin1(dev), QStringLiteral("set"), QString::fromLatin1(value)};
    };
    for (const char *ok : {"0%", "5%", "50%", "100%"})
        EXPECT_TRUE(isAllowedAction(cmd("intel_backlight", ok))) << ok;
    EXPECT_TRUE(isAllowedAction(cmd("amdgpu_bl1", "40%")));
    // The shell's relative steps, raw values, another device option, a name that is an option, more arguments: refused.
    for (const char *no : {"101%", "5%+", "5%-", "50", "-5%", "050%", "50 %", "%", "50%\n"})
        EXPECT_FALSE(isAllowedAction(cmd("intel_backlight", no))) << no;
    for (const char *no : {"-x", "", "a/b", "../x", "intel backlight", "x;y", "intel_backlight\n"})
        EXPECT_FALSE(isAllowedAction(cmd(no, "50%"))) << no;
    EXPECT_FALSE(isAllowedAction({b, QStringLiteral("-d"), QStringLiteral("intel_backlight"), QStringLiteral("set"), QStringLiteral("50%")}));
    EXPECT_FALSE(isAllowedAction({b, QStringLiteral("-q"), QStringLiteral("-d"), QStringLiteral("intel_backlight"), QStringLiteral("set"), QStringLiteral("50%"), QStringLiteral("-r")}));
    EXPECT_FALSE(isAllowedAction({b, QStringLiteral("-q"), QStringLiteral("--class=leds"), QStringLiteral("intel_backlight"), QStringLiteral("set"), QStringLiteral("50%")}));
    EXPECT_FALSE(isReadOnlyQuery(cmd("intel_backlight", "50%")));
}

// Printers (ADR-0030): the CUPS reads are exact; the user's defaults are the only lpoptions actions.
TEST(PrinterGuard, TheReadsAreExactAndChangeNothing)
{
    const auto q = [](std::initializer_list<const char *> args) {
        QStringList out;
        for (const char *a : args)
            out << QString::fromLatin1(a);
        return out;
    };
    for (const QStringList &ok : {q({"lpstat", "-l", "-p"}), q({"lpstat", "-d"}), q({"lpstat", "-v"}), q({"lpstat", "-a"}), q({"lpstat", "-l", "-e"}),
                                  q({"lpoptions", "-p", "GF_Office", "-l"})})
        EXPECT_TRUE(isReadOnlyQuery(ok)) << ok.join(QLatin1Char(' ')).toStdString();
    for (const QStringList &no : {q({"lpstat"}), q({"lpstat", "-p", "-l"}), q({"lpstat", "-t"}), q({"lpstat", "-h", "evil.example", "-p"}), q({"lpstat", "-e"}), q({"lpstat", "-e", "-l"}),
                                  q({"lpoptions", "-l"}), q({"lpoptions", "-p", "GF_Office"}), q({"lpoptions", "-d", "GF_Office"}), q({"lpoptions", "-p", "-x", "-l"}),
                                  q({"lpoptions", "-p", "GF_Office", "-o", "PageSize=A4"}), q({"lpadmin", "-x", "GF_Office"}), q({"lp", "/etc/passwd"}), q({"cancel", "-a"})})
        EXPECT_FALSE(isReadOnlyQuery(no)) << no.join(QLatin1Char(' ')).toStdString();
    EXPECT_FALSE(isActionProgram(QStringLiteral("lpstat")));
    EXPECT_FALSE(isActionProgram(QStringLiteral("lpadmin")));
    EXPECT_FALSE(isActionProgram(QStringLiteral("lp")));
}

TEST(PrinterGuard, OnlyTheUsersDefaultsAreActions)
{
    const QString o = QStringLiteral("lpoptions");
    EXPECT_TRUE(isAllowedAction({o, QStringLiteral("-d"), QStringLiteral("GF_Office")}));
    EXPECT_TRUE(isAllowedAction({o, QStringLiteral("-d"), QStringLiteral("HP_LaserJet_M15w@host")}));
    for (const char *size : {"A4", "Letter", "Legal", "A5", "na_letter_8.5x11in", "B5"})
        EXPECT_TRUE(isAllowedAction({o, QStringLiteral("-p"), QStringLiteral("GF_Office"), QStringLiteral("-o"), QStringLiteral("PageSize=") + QString::fromLatin1(size)})) << size;
    for (const char *size : {"", "A4 B5", "-A4", "A4\n", "Custom.4x6in,x", "a;b"})
        EXPECT_FALSE(isAllowedAction({o, QStringLiteral("-p"), QStringLiteral("GF_Office"), QStringLiteral("-o"), QStringLiteral("PageSize=") + QString::fromLatin1(size)})) << size;
    // Another option, another destination form, a name that is an option, more arguments, the root-only forms: refused.
    EXPECT_FALSE(isAllowedAction({o, QStringLiteral("-p"), QStringLiteral("GF_Office"), QStringLiteral("-o"), QStringLiteral("job-sheets=none")}));
    EXPECT_FALSE(isAllowedAction({o, QStringLiteral("-p"), QStringLiteral("GF_Office"), QStringLiteral("-o"), QStringLiteral("PageSize=A4"), QStringLiteral("-o"), QStringLiteral("x=y")}));
    EXPECT_FALSE(isAllowedAction({o, QStringLiteral("-d"), QStringLiteral("-E")}));
    EXPECT_FALSE(isAllowedAction({o, QStringLiteral("-d"), QStringLiteral("a b")}));
    EXPECT_FALSE(isAllowedAction({o, QStringLiteral("-d"), QStringLiteral("GF_Office/instance")}));
    EXPECT_FALSE(isAllowedAction({o, QStringLiteral("-x"), QStringLiteral("GF_Office")}));
    EXPECT_FALSE(isAllowedAction({o, QStringLiteral("-h"), QStringLiteral("evil.example"), QStringLiteral("-d"), QStringLiteral("GF_Office")}));
    EXPECT_FALSE(isAllowedAction({o}));
    EXPECT_FALSE(isAllowedAction({QStringLiteral("/usr/bin/lpoptions"), QStringLiteral("-d"), QStringLiteral("GF_Office")}));
    EXPECT_FALSE(isAllowedAction({QStringLiteral("lpadmin"), QStringLiteral("-x"), QStringLiteral("GF_Office")}));
}

TEST(PrinterGuard, NamesAndUrisAreThoseCupsdTurnsIntoADriverlessQueue)
{
    const QByteArray longest(127, 'a'), tooLong(128, 'a'), longKeyword(41, 'a');
    for (const char *ok : {"GF_Office", "a", "HP-LaserJet.2", "x@host", longest.constData()})
        EXPECT_TRUE(isPrinterName(QString::fromLatin1(ok))) << ok;
    for (const char *no : {"", "-a", "a b", "a/b", "a#b", "a\\b", "a\"b", tooLong.constData(), "a\n"})
        EXPECT_FALSE(isPrinterName(QString::fromLatin1(no))) << no;
    for (const char *ok : {"dnssd://GF%20Office._ipp._tcp.local/?uuid=1234", "ipp://192.0.2.7/ipp/print", "ipps://printer.local:631/ipp/print", "ippusb://Brother?serial=1"})
        EXPECT_TRUE(isPrinterUri(QString::fromLatin1(ok))) << ok;
    for (const char *no : {"", "usb://Brother/HL", "socket://192.0.2.7", "file:///dev/null", "ipp://", "ipp:///x", "ipp://host/a b", "ipp://host/\t", "IPP://host/x", "ipp://host/x#y"})
        EXPECT_FALSE(isPrinterUri(QString::fromLatin1(no))) << no;
    EXPECT_FALSE(isPrinterUri(QStringLiteral("ipp://h/") + QString(1100, QLatin1Char('a'))));
    EXPECT_FALSE(isPrinterUri(QStringLiteral("ipp://h/\u202Ex")));
    for (const char *ok : {"A4", "Letter", "na_letter_8.5x11in", "B5"})
        EXPECT_TRUE(isPaperKeyword(QString::fromLatin1(ok))) << ok;
    for (const char *no : {"", "-A4", "A 4", "A4,B5", "Custom.4x6in,x", "Custom.WIDTHxHEIGHT", longKeyword.constData()})
        EXPECT_FALSE(isPaperKeyword(QString::fromLatin1(no))) << no;
}

// Sound: wpctl runs only the page's three forms (review of 2026-10-26: any argument list used to pass).
TEST(ActionGuard, WpctlTakesThePagesThreeFormsOnly)
{
    const auto w = [](std::initializer_list<const char *> args) {
        QStringList out{QStringLiteral("wpctl")};
        for (const char *a : args)
            out << QString::fromLatin1(a);
        return out;
    };
    for (const QStringList &ok : {w({"set-default", "52"}), w({"set-volume", "52", "0.00"}), w({"set-volume", "52", "0.75"}), w({"set-volume", "52", "1.00"}),
                                  w({"set-mute", "52", "0"}), w({"set-mute", "52", "1"})})
        EXPECT_TRUE(isAllowedAction(ok)) << ok.join(QLatin1Char(' ')).toStdString();
    for (const QStringList &no : {w({}), w({"set-default"}), w({"set-default", "@DEFAULT_AUDIO_SINK@"}), w({"set-default", "-1"}), w({"set-default", "52", "x"}),
                                  w({"set-volume", "52", "1.5"}), w({"set-volume", "52", "5%+"}), w({"set-volume", "52", ".5"}), w({"set-volume", "52", "0.5"}),
                                  w({"set-volume", "1234567890", "0.50"}), w({"set-mute", "52", "toggle"}), w({"set-mute", "52", "FAILCASE"}),
                                  w({"set-profile", "52", "1"}), w({"clear-default"}), w({"settings", "--delete"}), w({"status"})})
        EXPECT_FALSE(isAllowedAction(no)) << no.join(QLatin1Char(' ')).toStdString();
}

// ADR-0031: the lines Settings may write to displays.conf and to a trial, the rule config/hypr/grassfield/displays.lua applies.
TEST(DisplayFiles, LinesAreCheckedFieldByField)
{
    const QString t = QStringLiteral("\t");
    const auto line = [&](const QString &desc, const QString &mode, const QString &pos, const QString &scale, const QString &tr) {
        return QStringLiteral("v1") + t + desc + t + mode + t + pos + t + scale + t + tr;
    };
    EXPECT_TRUE(isDisplayLine(line(QStringLiteral("desc:BOE 0x0BCA"), QStringLiteral("2880x1800@120.00"), QStringLiteral("0x0"), QStringLiteral("1.6"), QStringLiteral("0"))));
    EXPECT_TRUE(isDisplayLine(line(QStringLiteral("desc:Dell Inc. DELL U2720Q 7XXXX"), QStringLiteral("3840x2160@60"), QStringLiteral("-1800x-200"), QStringLiteral("1.333333"), QStringLiteral("7"))));
    EXPECT_TRUE(isDisplayLine(line(QStringLiteral("desc:") + QString(160, QLatin1Char('x')), QStringLiteral("1x1@1"), QStringLiteral("32768x-32768"), QStringLiteral("4"), QStringLiteral("0"))));
    const QString ok = line(QStringLiteral("desc:A"), QStringLiteral("1920x1080@60"), QStringLiteral("0x0"), QStringLiteral("1"), QStringLiteral("0"));
    EXPECT_TRUE(isDisplayLine(ok));
    for (const QString &bad : {QStringLiteral("v2") + ok.mid(2), ok + t, ok.left(ok.lastIndexOf(t)), ok + QStringLiteral("\n"),
                               line(QStringLiteral("name:A"), QStringLiteral("1920x1080@60"), QStringLiteral("0x0"), QStringLiteral("1"), QStringLiteral("0")),
                               line(QStringLiteral("desc:"), QStringLiteral("1920x1080@60"), QStringLiteral("0x0"), QStringLiteral("1"), QStringLiteral("0")),
                               line(QStringLiteral("desc:A\nB"), QStringLiteral("1920x1080@60"), QStringLiteral("0x0"), QStringLiteral("1"), QStringLiteral("0")),
                               line(QStringLiteral("desc:A\x7f"), QStringLiteral("1920x1080@60"), QStringLiteral("0x0"), QStringLiteral("1"), QStringLiteral("0")),
                               line(QStringLiteral("desc:") + QString(161, QLatin1Char('x')), QStringLiteral("1920x1080@60"), QStringLiteral("0x0"), QStringLiteral("1"), QStringLiteral("0")),
                               line(QStringLiteral("desc:") + QString(81, QChar(0xe9)), QStringLiteral("1920x1080@60"), QStringLiteral("0x0"), QStringLiteral("1"), QStringLiteral("0")),
                               line(QStringLiteral("desc:A"), QStringLiteral("preferred"), QStringLiteral("0x0"), QStringLiteral("1"), QStringLiteral("0")),
                               line(QStringLiteral("desc:A"), QStringLiteral("99999x1080@60"), QStringLiteral("0x0"), QStringLiteral("1"), QStringLiteral("0")),
                               line(QStringLiteral("desc:A"), QStringLiteral("1920x1080@0"), QStringLiteral("0x0"), QStringLiteral("1"), QStringLiteral("0")),
                               line(QStringLiteral("desc:A"), QStringLiteral("1920x1080"), QStringLiteral("0x0"), QStringLiteral("1"), QStringLiteral("0")),
                               line(QStringLiteral("desc:A"), QStringLiteral("1920x1080@60"), QStringLiteral("auto"), QStringLiteral("1"), QStringLiteral("0")),
                               line(QStringLiteral("desc:A"), QStringLiteral("1920x1080@60"), QStringLiteral("0x40000"), QStringLiteral("1"), QStringLiteral("0")),
                               line(QStringLiteral("desc:A"), QStringLiteral("1920x1080@60"), QStringLiteral("0x0"), QStringLiteral("0.25"), QStringLiteral("0")),
                               line(QStringLiteral("desc:A"), QStringLiteral("1920x1080@60"), QStringLiteral("0x0"), QStringLiteral("9"), QStringLiteral("0")),
                               line(QStringLiteral("desc:A"), QStringLiteral("1920x1080@60"), QStringLiteral("0x0"), QStringLiteral("auto"), QStringLiteral("0")),
                               line(QStringLiteral("desc:A"), QStringLiteral("1920x1080@60"), QStringLiteral("0x0"), QStringLiteral("1"), QStringLiteral("8"))})
        EXPECT_FALSE(isDisplayLine(bad)) << qPrintable(bad);
    EXPECT_TRUE(isDisplayTrialId(QStringLiteral("a1B2")));
    for (const char *bad : {"", "a-b", "a b", "x\n", "123456789012345678901234567890123"})
        EXPECT_FALSE(isDisplayTrialId(QString::fromLatin1(bad))) << bad;
}

TEST(ActionGuard, PowerProfilesTakeASourceAndAProfileOnly)
{
    const QString set = QStringLiteral("omarchy-powerprofiles-set");
    for (const char *source : {"ac", "battery"}) {
        for (const char *profile : {"power-saver", "balanced", "performance"})
            EXPECT_TRUE(isAllowedAction({set, QString::fromLatin1(source), QString::fromLatin1(profile)})) << source << profile;
    }
    for (const QStringList &no : {QStringList{set}, QStringList{set, QStringLiteral("autodetect")}, QStringList{set, QStringLiteral("ac")},
                                  QStringList{set, QStringLiteral("usb"), QStringLiteral("balanced")}, QStringList{set, QStringLiteral("ac"), QStringLiteral("turbo")},
                                  QStringList{set, QStringLiteral("ac"), QStringLiteral("balanced"), QStringLiteral("x")},
                                  QStringList{set, QStringLiteral("ac"), QStringLiteral("balanced\n")},
                                  QStringList{QStringLiteral("/usr/bin/omarchy-powerprofiles-set"), QStringLiteral("ac"), QStringLiteral("balanced")}})
        EXPECT_FALSE(isAllowedAction(no)) << qPrintable(no.join(QLatin1Char(' ')));
    // The list is a query, with no argument; setting is never a query.
    EXPECT_TRUE(isReadOnlyQuery({QStringLiteral("omarchy-powerprofiles-list")}));
    EXPECT_FALSE(isReadOnlyQuery({QStringLiteral("omarchy-powerprofiles-list"), QStringLiteral("--active-state")}));
    EXPECT_FALSE(isReadOnlyQuery({set, QStringLiteral("ac"), QStringLiteral("balanced")}));
}

// Appearance > Terminal and Developer Apps (ADR-0045 OC-11): Omarchy's theme names are a query with no argument; applying a
// theme is never one (the shell's grassfield-terminal-theme does it, not Settings).
TEST(QueryGuard, OmarchyThemeListOnly)
{
    EXPECT_TRUE(isReadOnlyQuery({QStringLiteral("omarchy-theme-list")}));
    EXPECT_FALSE(isReadOnlyQuery({QStringLiteral("omarchy-theme-list"), QStringLiteral("--all")}));
    EXPECT_FALSE(isReadOnlyQuery({QStringLiteral("/usr/bin/omarchy-theme-list")}));
    EXPECT_FALSE(isReadOnlyQuery({QStringLiteral("omarchy-theme-set"), QStringLiteral("Tokyo Night")}));
    EXPECT_FALSE(isReadOnlyQuery({QStringLiteral("omarchy-theme-current")}));
    EXPECT_FALSE(isAllowedAction({QStringLiteral("omarchy-theme-set"), QStringLiteral("Tokyo Night")}));
    EXPECT_FALSE(isLaunch({QStringLiteral("omarchy-theme-set"), QStringLiteral("Tokyo Night")}));
}

TEST(ActionGuard, OmarchyLanguageMayWaitForItsPrompt)
{
    // It may ask for a password: one at a time per tag (Backend::act, InFlight); wpctl and xdg-open never do.
    EXPECT_TRUE(asksForPassword({QStringLiteral("omarchy-language"), QStringLiteral("fr")}));
    EXPECT_FALSE(asksForPassword({QStringLiteral("wpctl"), QStringLiteral("set-volume")}));
    EXPECT_FALSE(asksForPassword({QStringLiteral("xdg-open"), QStringLiteral("https://example.org")}));
    EXPECT_FALSE(asksForPassword({}));
    EXPECT_EQ(actionTimeoutMs({QStringLiteral("omarchy-language"), QStringLiteral("fr")}, 15000), 130000);
    EXPECT_EQ(actionTimeoutMs({QStringLiteral("wpctl"), QStringLiteral("set-mute")}, 15000), 15000);
    EXPECT_EQ(actionTimeoutMs({}, 15000), 15000);
}

TEST(ActionGuard, OnlyTheNamedProgramsRun)
{
    // xdg-open opens the attribution links of the wallpaper page (by bare name, never a path or a shell); omarchy-language is
    // Language & Region's (one code, ActionGuard.OmarchyLanguageTakesOneCodeOnly).
    for (const char *ok : {"wpctl", "xdg-open", "omarchy-language", "omarchy-powerprofiles-set", "lpoptions"})
        EXPECT_TRUE(isActionProgram(QString::fromLatin1(ok))) << ok;
    // nmcli and bluetoothctl are gone: Wi-Fi and Bluetooth are D-Bus calls (systembus.h), never commands.
    for (const char *no : {"", "sh", "bash", "/usr/bin/xdg-open", "xdg-open ", "gio", "rm", "env", "nmcli", "bluetoothctl"})
        EXPECT_FALSE(isActionProgram(QString::fromLatin1(no))) << no;
}

// Software Update (ADR-0033 c.3; docs/specs/updates.md U12, U13): the installed grassfield-channel-set (never one found on PATH)
// with exactly one verb; it asks for the administrator's password itself (pkexec), so one at a time per tag and up to 130 s.
TEST(ActionGuard, ChannelSetTakesOneVerbOnly)
{
    const QString set = QStringLiteral("/usr/lib/grassfield/grassfield-channel-set");
    EXPECT_TRUE(isActionProgram(set));
    for (const char *ok : {"stable", "beta", "repair", "off"})
        EXPECT_TRUE(isAllowedAction({set, QString::fromLatin1(ok)})) << ok;
    for (const char *no : {"", "Beta", "beta\n", "custom", "--help", "-h", "set", "stable; rm -rf ~", "restore"})
        EXPECT_FALSE(isAllowedAction({set, QString::fromLatin1(no)})) << no;
    // Printing the channel is a query, not an action; two verbs are no form of the command.
    EXPECT_FALSE(isAllowedAction({set}));
    EXPECT_FALSE(isAllowedAction({set, QStringLiteral("beta"), QStringLiteral("stable")}));
    // By name (PATH) or through /usr/bin's link: not the installed file.
    EXPECT_FALSE(isActionProgram(QStringLiteral("grassfield-channel-set")));
    EXPECT_FALSE(isAllowedAction({QStringLiteral("grassfield-channel-set"), QStringLiteral("beta")}));
    EXPECT_FALSE(isAllowedAction({QStringLiteral("/usr/bin/grassfield-channel-set"), QStringLiteral("beta")}));
    // Its root helper is never Settings' to run: pkexec starts it, from grassfield-channel-set.
    EXPECT_FALSE(isAllowedAction({QStringLiteral("pkexec"), QStringLiteral("/usr/lib/grassfield/grassfield-channel-helper"), QStringLiteral("set"), QStringLiteral("beta")}));
    EXPECT_FALSE(isAllowedAction({QStringLiteral("/usr/lib/grassfield/grassfield-channel-helper"), QStringLiteral("off")}));
    EXPECT_TRUE(asksForPassword({set, QStringLiteral("beta")}));
    EXPECT_EQ(actionTimeoutMs({set, QStringLiteral("off")}, 15000), 130000);
}

TEST(QueryGuard, TheChannelIsReadWithNoArgumentOnly)
{
    const QString set = QStringLiteral("/usr/lib/grassfield/grassfield-channel-set");
    EXPECT_TRUE(isReadOnlyQuery({set}));
    for (const char *no : {"stable", "beta", "repair", "off", ""})
        EXPECT_FALSE(isReadOnlyQuery({set, QString::fromLatin1(no)})) << no;
    EXPECT_FALSE(isReadOnlyQuery({QStringLiteral("grassfield-channel-set")}));
    EXPECT_FALSE(isReadOnlyQuery({QStringLiteral("/usr/bin/grassfield-channel-set")}));
}

// Update Now, Log Out… and Restart… (U11, U14): the exact vectors, started and left running; nothing else is a launch.
TEST(LaunchGuard, OnlyUpdateNowAndTheSessionEnd)
{
    const QString launcher = QStringLiteral("omarchy-launch-floating-terminal-with-presentation");
    const QString end = QStringLiteral("/usr/lib/grassfield/grassfield-session-end");
    const QString runner = QStringLiteral("/usr/lib/grassfield/grassfield-update-run");
    EXPECT_TRUE(isLaunch({runner}));
    EXPECT_TRUE(isLaunch({launcher, QStringLiteral("omarchy-update")}));
    EXPECT_TRUE(isLaunch({launcher, QStringLiteral("omarchy-migrate")}));
    EXPECT_TRUE(isLaunch({end, QStringLiteral("logout")}));
    EXPECT_TRUE(isLaunch({end, QStringLiteral("restart")}));
    // The runner takes no argument and is never found on PATH; its root helper is never Settings' to start.
    EXPECT_FALSE(isLaunch({runner, QStringLiteral("0123456789abcdef0123456789abcdef")}));
    EXPECT_FALSE(isLaunch({QStringLiteral("grassfield-update-run")}));
    EXPECT_FALSE(isLaunch({QStringLiteral("/usr/lib/grassfield/grassfield-update-helper"), QStringLiteral("run"),
                           QStringLiteral("0123456789abcdef0123456789abcdef")}));
    EXPECT_FALSE(isLaunch({QStringLiteral("pkexec"), QStringLiteral("/usr/lib/grassfield/grassfield-update-helper")}));
    EXPECT_FALSE(isLaunch({launcher, QStringLiteral("omarchy-migrate"), QStringLiteral("--pending")}));
    EXPECT_FALSE(isAllowedAction({runner}));
    // Not -y (no question asked), not another command in Omarchy's terminal, not a shut down, not --force.
    EXPECT_FALSE(isLaunch({launcher, QStringLiteral("omarchy-update"), QStringLiteral("-y")}));
    EXPECT_FALSE(isLaunch({launcher, QStringLiteral("omarchy-update -y")}));
    EXPECT_FALSE(isLaunch({launcher, QStringLiteral("bash")}));
    EXPECT_FALSE(isLaunch({launcher}));
    EXPECT_FALSE(isLaunch({QStringLiteral("omarchy-update")}));
    EXPECT_FALSE(isLaunch({end, QStringLiteral("shutdown")}));
    EXPECT_FALSE(isLaunch({end, QStringLiteral("logout"), QStringLiteral("--force")}));
    EXPECT_FALSE(isLaunch({QStringLiteral("grassfield-session-end"), QStringLiteral("logout")}));
    EXPECT_FALSE(isLaunch({}));
    // A launch is no action, an action no launch: each door has its own list.
    EXPECT_FALSE(isAllowedAction({launcher, QStringLiteral("omarchy-update")}));
    EXPECT_FALSE(isLaunch({QStringLiteral("/usr/lib/grassfield/grassfield-channel-set"), QStringLiteral("beta")}));
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
TEST(Volumes, OnlyLocalOnesAreRead)
{
    // Integrator review of PR #6: volumes() ran statfs on every mount on the GUI thread; a stuck network or FUSE mount froze the
    // window. The table comes from /proc/self/mounts and only local volumes are stat'ed.
    const QByteArray table = "/dev/nvme0n1p2 / btrfs rw,relatime 0 0\n"
                             "proc /proc proc rw 0 0\n"
                             "/dev/nvme0n1p2 /home btrfs rw,subvol=/@home 0 0\n"
                             "/dev/nvme0n1p1 /boot vfat rw 0 0\n"
                             "nas:/export/media /mnt/media nfs4 rw,hard 0 0\n"
                             "//nas/share /mnt/share cifs rw 0 0\n"
                             "me@host: /home/u/remote fuse.sshfs rw 0 0\n"
                             "/dev/sdb1 /run/media/u/Win fuseblk rw 0 0\n"
                             "/dev/sdc1 /run/media/u/My\\040Disk exfat rw 0 0\n"
                             "tank/data /tank/data zfs rw 0 0\n"
                             "tmpfs /tmp tmpfs rw 0 0\n"
                             "/dev/loop0 /snap/x squashfs ro 0 0\n";
    const QList<Mount> mounts = parseMounts(table);
    ASSERT_EQ(mounts.size(), 12);
    EXPECT_EQ(mounts.at(8).mountPoint, QStringLiteral("/run/media/u/My Disk"));
    EXPECT_EQ(mounts.at(8).type, QStringLiteral("exfat"));
    QStringList local;
    for (const Mount &m : mounts) {
        if (isLocalVolume(m.device, m.type))
            local << m.mountPoint;
    }
    EXPECT_EQ(local, (QStringList{QStringLiteral("/"), QStringLiteral("/home"), QStringLiteral("/boot"), QStringLiteral("/run/media/u/My Disk"),
                                  QStringLiteral("/tank/data")}));
    // A network file system names a server, not a /dev device; FUSE is refused whatever its device (fuseblk names /dev/sdb1).
    for (const char *net : {"nfs", "nfs4", "cifs", "smb3", "ceph", "9p", "virtiofs"})
        EXPECT_FALSE(isLocalVolume(QStringLiteral("server:/export"), QString::fromLatin1(net))) << net;
    for (const char *fuse : {"fuse", "fuseblk", "fuse.sshfs", "fuse.rclone"})
        EXPECT_FALSE(isLocalVolume(QStringLiteral("/dev/sdb1"), QString::fromLatin1(fuse))) << fuse;
    // The home's volume without a statfs of the home: the longest mount point above it.
    EXPECT_EQ(mountPointOf(mounts, QStringLiteral("/home/u")), QStringLiteral("/home"));
    EXPECT_EQ(mountPointOf(mounts, QStringLiteral("/home/u/remote/x")), QStringLiteral("/home/u/remote"));
    EXPECT_EQ(mountPointOf(mounts, QStringLiteral("/homework")), QStringLiteral("/"));
    EXPECT_EQ(mountPointOf({}, QStringLiteral("/home/u")), QString());
    // A broken line is skipped; a backslash that is not an escape stays.
    EXPECT_EQ(parseMounts("only-two fields\n\n/dev/sda1 /a\\b ext4 rw 0 0\n").size(), 1);
    EXPECT_EQ(parseMounts("/dev/sda1 /a\\b ext4 rw 0 0\n").at(0).mountPoint, QStringLiteral("/a\\b"));
}

TEST(XdgDirs, EmptyOrRelativeMeansNotSet)
{
    // Integrator review of PR #6: an empty XDG_CONFIG_HOME made the autostart folder "/autostart" and the user's units
    // "/systemd/user". Unset, empty or relative: the default (XDG Base Directory specification).
    const QString config = QStringLiteral("/home/u/.config");
    EXPECT_EQ(xdgHome(QString(), config), config);
    EXPECT_EQ(xdgHome(QStringLiteral(""), config), config);
    EXPECT_EQ(xdgHome(QStringLiteral("relative/dir"), config), config);
    EXPECT_EQ(xdgHome(QStringLiteral("/srv/cfg/"), config), QStringLiteral("/srv/cfg"));
    EXPECT_EQ(xdgHome(QStringLiteral("/srv//cfg/../x"), config), QStringLiteral("/srv/x"));
    const QString data = QStringLiteral("/usr/local/share:/usr/share");
    const QStringList defaults{QStringLiteral("/usr/local/share"), QStringLiteral("/usr/share")};
    EXPECT_EQ(xdgDirs(QString(), data), defaults);
    EXPECT_EQ(xdgDirs(QStringLiteral(""), data), defaults);
    EXPECT_EQ(xdgDirs(QStringLiteral("::"), data), defaults);
    EXPECT_EQ(xdgDirs(QStringLiteral("rel:also/rel"), data), defaults);
    EXPECT_EQ(xdgDirs(QStringLiteral("/opt/share::rel:/usr/share/"), data), (QStringList{QStringLiteral("/opt/share"), QStringLiteral("/usr/share")}));
    EXPECT_EQ(xdgDirs(QString(), QStringLiteral("/etc/xdg")), QStringList{QStringLiteral("/etc/xdg")});
}

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

TEST(PrivacyGuard, AppIdsAndTokensAsTheStoreKeysThem)
{
    for (const char *id : {"org.mozilla.firefox", "snap.spotify", "com.example.App_2", "foot", "org.gnome.Maps.Devel", "a+b"})
        EXPECT_TRUE(isPortalAppId(QString::fromLatin1(id))) << id;
    for (const char *id : {"", "../x", "a/b", ".hidden", "a..b", "x\n", "two words", "-x"})
        EXPECT_FALSE(isPortalAppId(QString::fromLatin1(id))) << id;
    EXPECT_FALSE(isPortalAppId(QString(256, QLatin1Char('a'))));
    // The portal's tokens (base64 of 16 bytes with + and / made _, so some begin with _) and legacy UUIDs; nothing else.
    for (const char *t : {"00000000-1111-2222-3333-444444444444", "abc", "_0000_fake_0000_0000_", "Qm9va3NfYW5kX21vcmU", "_"})
        EXPECT_TRUE(isPortalToken(QString::fromLatin1(t))) << t;
    for (const char *t : {"", "../a", "a/b", "a b", "-a", "tok:1", "a.b", "a-b", "00000000-1111-2222-3333-444444444444x"})
        EXPECT_FALSE(isPortalToken(QString::fromLatin1(t))) << t;
    EXPECT_TRUE(isPortalToken(QString(128, QLatin1Char('a'))));
    EXPECT_FALSE(isPortalToken(QString(129, QLatin1Char('a'))));
}
