#include "systemguard.h"

#include <QDir>
#include <QList>
#include <QRegularExpression>

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

// An absolute path without control characters, at most 4096 bytes; in a dev session under <devRoot>/.dev.
bool wallpaperPathOk(const QString &path, const QString &devRoot)
{
    if (!path.startsWith(QLatin1Char('/')) || path.toUtf8().size() > 4096)
        return false;
    for (const QChar c : path) {
        const ushort u = c.unicode();
        if (u <= 0x1f || (u >= 0x7f && u <= 0x9f) || u == 0x2028 || u == 0x2029 || (u >= 0x202a && u <= 0x202e) || (u >= 0x2066 && u <= 0x2069))
            return false;
    }
    if (devRoot.isEmpty())
        return true;
    const QString clean = QDir::cleanPath(path);
    const QString dev = QDir::cleanPath(devRoot + QStringLiteral("/.dev"));
    return clean == dev || clean.startsWith(dev + QLatin1Char('/'));
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
    return program == QLatin1String("nmcli") || program == QLatin1String("bluetoothctl") || program == QLatin1String("wpctl");
}

} // namespace grassfield::settings
