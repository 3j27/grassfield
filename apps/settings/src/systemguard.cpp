#include "systemguard.h"

#include "runmode.h"

#include <algorithm>
#include <cstdlib>

#include <QDir>
#include <QFileInfo>
#include <QList>
#include <QRegularExpression>
#include <QUrl>

namespace grassfield::settings {

bool devSession()
{
    return grassfield::apps::runmode::dev();
}

bool isUuid(const QString &s)
{
    static const QRegularExpression re(QRegularExpression::anchoredPattern(QStringLiteral("[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}")));
    return re.match(s).hasMatch();
}

bool isPortalAppId(const QString &s)
{
    static const QRegularExpression re(QRegularExpression::anchoredPattern(QStringLiteral("[A-Za-z0-9_][A-Za-z0-9_.+-]{0,254}")));
    return re.match(s).hasMatch() && !s.contains(QLatin1String(".."));
}

bool isPortalToken(const QString &s)
{
    static const QRegularExpression re(QRegularExpression::anchoredPattern(QStringLiteral("[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}")));
    return re.match(s).hasMatch();
}

QList<Mount> parseMounts(const QByteArray &text)
{
    // fstab(5) escaping: \ooo (three octal digits) for a space, a tab, a newline or a backslash.
    const auto unescape = [](const QByteArray &field) {
        QByteArray out;
        for (qsizetype i = 0; i < field.size(); ++i) {
            if (field.at(i) == '\\' && i + 3 < field.size()) {
                const QByteArray digits = field.mid(i + 1, 3);
                bool ok = digits.size() == 3;
                for (const char c : digits)
                    ok = ok && c >= '0' && c <= '7';
                if (ok) {
                    out.append(char(digits.toInt(nullptr, 8)));
                    i += 3;
                    continue;
                }
            }
            out.append(field.at(i));
        }
        return QString::fromUtf8(out);
    };
    QList<Mount> out;
    for (const QByteArray &line : text.split('\n')) {
        const QList<QByteArray> f = line.simplified().split(' ');
        if (f.size() >= 3 && !f.at(0).isEmpty())
            out.append({unescape(f.at(0)), unescape(f.at(1)), unescape(f.at(2))});
    }
    return out;
}

bool isLocalVolume(const QString &device, const QString &type)
{
    static const QStringList virtualTypes{QStringLiteral("tmpfs"), QStringLiteral("devtmpfs"), QStringLiteral("proc"), QStringLiteral("sysfs"),
                                          QStringLiteral("overlay"), QStringLiteral("squashfs"), QStringLiteral("efivarfs"), QStringLiteral("ramfs"),
                                          QStringLiteral("autofs"), QStringLiteral("cgroup2"), QStringLiteral("debugfs")};
    if (type.startsWith(QLatin1String("fuse")) || virtualTypes.contains(type))
        return false;
    return device.startsWith(QLatin1String("/dev/")) || type == QLatin1String("zfs");
}

QString mountPointOf(const QList<Mount> &mounts, const QString &path)
{
    QString best;
    for (const Mount &m : mounts) {
        const bool holds = m.mountPoint == QLatin1String("/") || path == m.mountPoint || path.startsWith(m.mountPoint + QLatin1Char('/'));
        if (holds && m.mountPoint.size() > best.size())
            best = m.mountPoint;
    }
    return best;
}

QString xdgHome(const QString &value, const QString &fallback)
{
    return value.startsWith(QLatin1Char('/')) ? QDir::cleanPath(value) : fallback;
}

QStringList xdgDirs(const QString &value, const QString &fallback)
{
    QStringList out;
    for (const QString &d : value.split(QLatin1Char(':'), Qt::SkipEmptyParts)) {
        if (d.startsWith(QLatin1Char('/')))
            out << QDir::cleanPath(d);
    }
    return out.isEmpty() && value != fallback ? xdgDirs(fallback, fallback) : out;
}

bool isReadOnlyQuery(const QStringList &argv)
{
    if (argv.isEmpty())
        return false;
    const QString &program = argv.first();
    const QStringList args = argv.mid(1);
    // Wi-Fi and Bluetooth are not commands any more: they go over D-Bus (systembus.h, whose own guard allows only reads in a dev
    // session). nmcli and bluetoothctl are therefore neither queries nor actions here.
    // Sound pane: the devices, and their PipeWire node names (the Type column).
    if (program == QLatin1String("wpctl"))
        return args == QStringList{"status"} || args == QStringList{QStringLiteral("status"), QStringLiteral("-n")};
    // About pane (Backend::run): package versions and graphics adapters. Storage pane: the installed packages' sizes (pacman -Qi).
    if (program == QLatin1String("pacman"))
        return args == QStringList{QStringLiteral("-Qi")}
            || (args.size() == 2 && args.at(0) == QLatin1String("-Q")
                && (args.at(1) == QLatin1String("hyprland") || args.at(1) == QLatin1String("quickshell") || args.at(1) == QLatin1String("quickshell-git")));
    if (program == QLatin1String("lspci"))
        return args.isEmpty();
    // Storage pane: the size of the user's folders.
    if (program == QLatin1String("du"))
        return isFolderSizeQuery(args);
    // Battery: the power profiles this machine offers (Omarchy's list of power-profiles-daemon's).
    if (program == QLatin1String("omarchy-powerprofiles-list"))
        return args.isEmpty();
    // Printers (ADR-0030): the queues with their state, description and location; the default (the user's first); the device
    // URIs; what cupsd and DNS-SD find (Add Printer); one queue's options (its paper sizes). `lpoptions -p <queue> -l` lists,
    // it changes nothing; any other lpoptions form may write and is an action.
    if (program == QLatin1String("lpstat"))
        return args == QStringList{QStringLiteral("-l"), QStringLiteral("-p")} || args == QStringList{QStringLiteral("-d")}
            || args == QStringList{QStringLiteral("-v")} || args == QStringList{QStringLiteral("-a")}
            || args == QStringList{QStringLiteral("-l"), QStringLiteral("-e")};
    if (program == QLatin1String("lpoptions"))
        return args.size() == 3 && args.at(0) == QLatin1String("-p") && isPrinterName(args.at(1)) && args.at(2) == QLatin1String("-l");
    // omarchy-language is not a query: a dev session never runs a script nobody here has read (ADR-0019), and the owner's
    // Omarchy 4.0.4 does not ship it. Language & Region reads it only in a real session, and only when it is installed.
    return false;
}

bool isPrinterName(const QString &name)
{
    static const QRegularExpression re(QRegularExpression::anchoredPattern(QStringLiteral("[A-Za-z0-9_.+@][A-Za-z0-9_.+@-]{0,126}")));
    return re.match(name).hasMatch();
}

bool isPaperKeyword(const QString &keyword)
{
    static const QRegularExpression re(QRegularExpression::anchoredPattern(QStringLiteral("[A-Za-z0-9][A-Za-z0-9._-]{0,39}")));
    return re.match(keyword).hasMatch() && !keyword.startsWith(QLatin1String("Custom."));
}

bool isPrinterUri(const QString &uri)
{
    if (uri.size() > 1024)
        return false;
    for (const QChar c : uri) {
        if (c.isSpace() || c.unicode() < 0x20 || c.unicode() == 0x7f || c.category() == QChar::Other_Format)
            return false;
    }
    static const QRegularExpression re(QRegularExpression::anchoredPattern(QStringLiteral("(dnssd|ipp|ipps|ippusb)://[^/?#][^#]*")));
    return re.match(uri).hasMatch();
}

bool isFolderSizeQuery(const QStringList &args)
{
    // du -s -x --block-size=1 -- <1 to 16 folders of the user's home>: sizes only, never across file systems.
    const QStringList head{QStringLiteral("-s"), QStringLiteral("-x"), QStringLiteral("--block-size=1"), QStringLiteral("--")};
    if (args.size() < head.size() + 1 || args.size() > head.size() + 16 || args.mid(0, head.size()) != head)
        return false;
    const QString home = QDir::cleanPath(QDir::homePath());
    for (const QString &path : args.mid(head.size())) {
        if (!path.startsWith(QLatin1Char('/')) || path.contains(QLatin1String("/..")) || path.contains(QLatin1String("/./")) || path.size() > 4096)
            return false;
        for (const QChar c : path) {
            if (c.unicode() <= 0x1f || c.unicode() == 0x7f)
                return false;
        }
        if (QDir::cleanPath(path) != path || !(path == home || path.startsWith(home + QLatin1Char('/'))))
            return false;
    }
    return true;
}

bool isLanguageCode(const QString &code)
{
    static const QRegularExpression re(QRegularExpression::anchoredPattern(QStringLiteral("[a-z]{2,3}(-[A-Za-z]{2,4})?")));
    return re.match(code).hasMatch();
}

namespace {

// The real location of a path that may not exist: the longest existing prefix is canonicalised (symlinks and ".." resolved
// by the file system), the rest is appended. "" when it cannot be resolved or the rest holds "..".
QString resolvedPath(const QString &path)
{
    QString prefix = path;
    QStringList rest;
    while (!QFileInfo::exists(prefix)) {
        // A symlink that leads nowhere is not a missing name: where it would lead is unknown.
        if (QFileInfo(prefix).isSymLink())
            return QString();
        const int i = prefix.lastIndexOf(QLatin1Char('/'));
        if (i <= 0) {
            // The first component is missing too (it must not be dropped: /nonexistent/<root>/.dev/x is not <root>/.dev/x).
            rest.prepend(prefix.mid(i + 1));
            prefix = QStringLiteral("/");
            break;
        }
        rest.prepend(prefix.mid(i + 1));
        prefix = prefix.left(i);
    }
    QStringList tail;
    for (const QString &r : std::as_const(rest)) {
        if (r == QLatin1String(".."))
            return QString();
        if (!r.isEmpty() && r != QLatin1String("."))
            tail << r;
    }
    const QString base = QFileInfo(prefix).canonicalFilePath();
    if (base.isEmpty())
        return QString();
    return tail.isEmpty() ? base : QDir::cleanPath(base + QLatin1Char('/') + tail.join(QLatin1Char('/')));
}

// An absolute path without control characters, at most 4096 bytes; in a dev session under <devRoot>/.dev.
bool wallpaperPathOk(const QString &path, const QString &devRoot)
{
    if (!path.startsWith(QLatin1Char('/')) || path.toUtf8().size() > 4096)
        return false;
    for (const QChar c : path) {
        const ushort u = c.unicode();
        if (u <= 0x1f || (u >= 0x7f && u <= 0x9f) || u == 0x061c || u == 0x200e || u == 0x200f || u == 0x2028 || u == 0x2029 || (u >= 0x202a && u <= 0x202e) || (u >= 0x2066 && u <= 0x2069))
            return false;
    }
    if (devRoot.isEmpty())
        return true;
    // By the real location, not by the text: a symlink inside .dev (or "link/..") must not lead out of it.
    const QString dev = QFileInfo(devRoot + QStringLiteral("/.dev")).canonicalFilePath();
    const QString real = resolvedPath(path);
    return !dev.isEmpty() && !real.isEmpty() && (real == dev || real.startsWith(dev + QLatin1Char('/')));
}

// A decimal number within [min, max], at most 6 characters.
bool numberIn(const QString &s, int min, int max)
{
    if (s.isEmpty() || s.size() > 6)
        return false;
    for (const QChar c : s) {
        if (c < QLatin1Char('0') || c > QLatin1Char('9'))
            return false;
    }
    const int n = s.toInt();
    return n >= min && n <= max;
}

} // namespace

bool isAutostartWrite(const QString &path, const QString &autostartDir, const QString &devRoot, bool dev)
{
    static const QRegularExpression name(QRegularExpression::anchoredPattern(QStringLiteral("[A-Za-z0-9._+-]{1,200}\\.desktop")));
    // An absolute path already clean: "link/../autostart" would read as the folder in text while the kernel resolves the ".."
    // through the link (counter-review of 2026-10-26).
    if (!path.startsWith(QLatin1Char('/')) || QDir::cleanPath(path) != path)
        return false;
    const QFileInfo file(path);
    if (autostartDir.isEmpty() || file.path() != QDir::cleanPath(autostartDir) || !name.match(file.fileName()).hasMatch())
        return false;
    if (file.isSymLink())
        return false;
    if (!dev)
        return true;
    // By the folder's real location, not its text: a symlink inside .dev must not lead a write out of it.
    const QString devDir = devRoot.isEmpty() ? QString() : QFileInfo(devRoot + QStringLiteral("/.dev")).canonicalFilePath();
    const QString real = resolvedPath(QDir::cleanPath(autostartDir));
    return !devDir.isEmpty() && !real.isEmpty() && (real == devDir || real.startsWith(devDir + QLatin1Char('/')));
}

bool isIconFile(const QString &path)
{
    static const QRegularExpression raster(QRegularExpression::anchoredPattern(QStringLiteral(".+\\.(png|xpm|jpe?g)")),
                                           QRegularExpression::CaseInsensitiveOption);
    if (!path.startsWith(QLatin1Char('/')) || QDir::cleanPath(path) != path || !raster.match(path).hasMatch())
        return false;
    const QFileInfo info(path);
    return info.isFile() && info.size() <= 1024 * 1024;
}

bool namesWallpaperTool(const QString &program)
{
    return program == QLatin1String("grassfield-wallpaper") || program.endsWith(QLatin1String("/grassfield-wallpaper"));
}

bool isWallpaperQuery(const QStringList &argv, const WallpaperContext &ctx)
{
    if (argv.size() < 2 || ctx.tool.isEmpty() || !ctx.tool.startsWith(QLatin1Char('/')) || argv.first() != ctx.tool)
        return false;
    const QString &sub = argv.at(1);
    if (sub == QLatin1String("formats"))
        return argv.size() == 2;
    if (sub == QLatin1String("list"))
        return argv.size() == 6 && argv.at(2) == QLatin1String("--max") && numberIn(argv.at(3), 1, 500) && argv.at(4) == QLatin1String("--")
            && wallpaperPathOk(argv.at(5), ctx.devRoot);
    if (sub == QLatin1String("thumb"))
        return argv.size() == 8 && argv.at(2) == QLatin1String("--width") && numberIn(argv.at(3), 16, 1024) && argv.at(4) == QLatin1String("--out")
            && !ctx.cacheDir.isEmpty() && argv.at(5) == ctx.cacheDir + QStringLiteral("/thumbs") && argv.at(6) == QLatin1String("--")
            && wallpaperPathOk(argv.at(7), ctx.devRoot);
    return false;
}

bool isActionProgram(const QString &program)
{
    return program == QLatin1String("wpctl") || program == QLatin1String("xdg-open") || program == QLatin1String("omarchy-language")
        || program == QLatin1String("omarchy-powerprofiles-set") || program == QLatin1String("brightnessctl") || program == QLatin1String("lpoptions");
}

bool isBacklightName(const QString &name)
{
    static const QRegularExpression re(QRegularExpression::anchoredPattern(QStringLiteral("[A-Za-z0-9_.:][A-Za-z0-9_.:-]{0,63}")));
    return re.match(name).hasMatch();
}

bool isDisplayTrialId(const QString &id)
{
    static const QRegularExpression re(QRegularExpression::anchoredPattern(QStringLiteral("[A-Za-z0-9]{1,32}")));
    return re.match(id).hasMatch();
}

bool isDisplayLine(const QString &line)
{
    const QStringList f = line.split(QLatin1Char('\t'));
    if (f.size() != 6 || f.at(0) != QLatin1String("v1") || !f.at(1).startsWith(QLatin1String("desc:")))
        return false;
    const QString desc = f.at(1).mid(5);
    if (desc.isEmpty() || desc.toUtf8().size() > 160)
        return false;
    for (const QChar c : desc) {
        if (c.unicode() < 0x20 || c.unicode() == 0x7f)
            return false;
    }
    static const QRegularExpression mode(QRegularExpression::anchoredPattern(QStringLiteral("([0-9]{1,5})x([0-9]{1,5})@([0-9]{1,4})(\\.[0-9]{1,3})?")));
    const QRegularExpressionMatch m = mode.match(f.at(2));
    if (!m.hasMatch())
        return false;
    const int w = m.captured(1).toInt(), h = m.captured(2).toInt();
    const double hz = (m.captured(3) + m.captured(4)).toDouble();
    if (w < 1 || w > 16384 || h < 1 || h > 16384 || hz < 1 || hz > 1000)
        return false;
    static const QRegularExpression pos(QRegularExpression::anchoredPattern(QStringLiteral("(-?[0-9]{1,5})x(-?[0-9]{1,5})")));
    const QRegularExpressionMatch p = pos.match(f.at(3));
    if (!p.hasMatch() || std::abs(p.captured(1).toInt()) > 32768 || std::abs(p.captured(2).toInt()) > 32768)
        return false;
    static const QRegularExpression scale(QRegularExpression::anchoredPattern(QStringLiteral("[0-9](\\.[0-9]{1,6})?")));
    if (!scale.match(f.at(4)).hasMatch())
        return false;
    const double sc = f.at(4).toDouble();
    if (sc < 0.5 || sc > 4)
        return false;
    static const QRegularExpression transform(QRegularExpression::anchoredPattern(QStringLiteral("[0-7]")));
    return transform.match(f.at(5)).hasMatch();
}

bool asksForPassword(const QStringList &argv)
{
    return !argv.isEmpty() && argv.first() == QLatin1String("omarchy-language");
}

int actionTimeoutMs(const QStringList &argv, int requested)
{
    constexpr int kPromptMs = 130000;
    return !argv.isEmpty() && argv.first() == QLatin1String("omarchy-language") ? std::max(requested, kPromptMs) : requested;
}

bool isAllowedAction(const QStringList &argv)
{
    if (argv.isEmpty() || !isActionProgram(argv.first()))
        return false;
    // Omarchy's own per-user language switch (it generates the locale through Omarchy's sudoers grant or pkexec): one code.
    if (argv.first() == QLatin1String("omarchy-language"))
        return argv.size() == 2 && isLanguageCode(argv.at(1));
    // Battery > Low Power Mode: Omarchy remembers a power profile for the power adapter and one for the battery, and applies it
    // (power-profiles-daemon, whose own polkit action lets the active session switch).
    if (argv.first() == QLatin1String("omarchy-powerprofiles-set"))
        return argv.size() == 3 && (argv.at(1) == QLatin1String("ac") || argv.at(1) == QLatin1String("battery"))
            && (argv.at(2) == QLatin1String("power-saver") || argv.at(2) == QLatin1String("balanced") || argv.at(2) == QLatin1String("performance"));
    // Displays > Brightness: the same command as the shell's Brightness.qml, one backlight and a whole percentage.
    if (argv.first() == QLatin1String("brightnessctl")) {
        static const QRegularExpression percent(QRegularExpression::anchoredPattern(QStringLiteral("(100|[1-9]?[0-9])%")));
        return argv.size() == 6 && argv.at(1) == QLatin1String("-q") && argv.at(2) == QLatin1String("-d") && isBacklightName(argv.at(3))
            && argv.at(4) == QLatin1String("set") && percent.match(argv.at(5)).hasMatch();
    }
    // Sound: exactly the three forms of the page (qml/System.js): a device made the default, its volume (0.00 to 1.00), its mute.
    if (argv.first() == QLatin1String("wpctl")) {
        static const QRegularExpression id(QRegularExpression::anchoredPattern(QStringLiteral("[0-9]{1,9}")));
        static const QRegularExpression volume(QRegularExpression::anchoredPattern(QStringLiteral("0\\.[0-9]{2}|1\\.00")));
        if (argv.size() == 3 && argv.at(1) == QLatin1String("set-default"))
            return id.match(argv.at(2)).hasMatch();
        if (argv.size() == 4 && argv.at(1) == QLatin1String("set-volume"))
            return id.match(argv.at(2)).hasMatch() && volume.match(argv.at(3)).hasMatch();
        if (argv.size() == 4 && argv.at(1) == QLatin1String("set-mute"))
            return id.match(argv.at(2)).hasMatch() && (argv.at(3) == QLatin1String("0") || argv.at(3) == QLatin1String("1"));
        return false;
    }
    // Printers: the user's default printer, or one queue's paper size (~/.cups/lpoptions).
    if (argv.first() == QLatin1String("lpoptions"))
        return (argv.size() == 3 && argv.at(1) == QLatin1String("-d") && isPrinterName(argv.at(2)))
            || (argv.size() == 5 && argv.at(1) == QLatin1String("-p") && isPrinterName(argv.at(2)) && argv.at(3) == QLatin1String("-o")
                && argv.at(4).startsWith(QLatin1String("PageSize=")) && isPaperKeyword(argv.at(4).mid(9)));
    if (argv.first() != QLatin1String("xdg-open"))
        return true;
    if (argv.size() != 2)
        return false;
    const QString &link = argv.at(1);
    if (link.startsWith(QLatin1Char('-')))
        return false;
    for (const QChar c : link) {
        if (c.isSpace() || c.category() == QChar::Other_Control || c.category() == QChar::Other_Format)
            return false;
    }
    const QUrl url(link, QUrl::StrictMode);
    return url.isValid() && url.scheme() == QLatin1String("https") && !url.host().isEmpty() && url.userInfo().isEmpty();
}

} // namespace grassfield::settings
