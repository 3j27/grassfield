#include "systemguard.h"

#include <QDir>
#include <QFileInfo>
#include <QList>
#include <QRegularExpression>
#include <QUrl>

namespace grassfield::settings {

bool devSession()
{
    return qEnvironmentVariable("GRASSFIELD_DEV") == QLatin1String("1");
}

bool isUuid(const QString &s)
{
    static const QRegularExpression re(QStringLiteral("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$"));
    return re.match(s).hasMatch();
}

bool isReadOnlyQuery(const QStringList &argv)
{
    if (argv.isEmpty())
        return false;
    const QString &program = argv.first();
    const QStringList args = argv.mid(1);
    if (program == QLatin1String("nmcli")) {
        static const QList<QStringList> queries = {
            {"-t", "-f", "WIFI", "radio"},
            {"-t", "-f", "IN-USE,SSID-HEX,SIGNAL,SECURITY", "dev", "wifi", "list", "--rescan", "no"},
            {"-t", "-f", "UUID,TYPE", "connection", "show"},
            {"-t", "-f", "DEVICE,TYPE,STATE", "device"},
        };
        if (queries.contains(args))
            return true;
        // SSID of one saved profile, by UUID.
        return args.size() == 7 && args.mid(0, 6) == QStringList{"-t", "-f", "802-11-wireless.ssid", "connection", "show", "uuid"} && isUuid(args.at(6));
    }
    if (program == QLatin1String("bluetoothctl")) {
        static const QList<QStringList> queries = {
            {"show"},
            {"devices", "Paired"},
            {"devices", "Connected"},
        };
        return queries.contains(args);
    }
    if (program == QLatin1String("wpctl"))
        return args == QStringList{"status"};
    // About pane (Backend::run): package versions and graphics adapters.
    if (program == QLatin1String("pacman"))
        return args.size() == 2 && args.at(0) == QLatin1String("-Q")
            && (args.at(1) == QLatin1String("hyprland") || args.at(1) == QLatin1String("quickshell") || args.at(1) == QLatin1String("quickshell-git"));
    if (program == QLatin1String("lspci"))
        return args.isEmpty();
    return false;
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
    return program == QLatin1String("nmcli") || program == QLatin1String("bluetoothctl") || program == QLatin1String("wpctl") || program == QLatin1String("xdg-open");
}

bool isAllowedAction(const QStringList &argv)
{
    if (argv.isEmpty() || !isActionProgram(argv.first()))
        return false;
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
