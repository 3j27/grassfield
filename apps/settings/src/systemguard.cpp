#include "systemguard.h"

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
    // Wallpaper helper (ADR-0016): listing, thumbnails (cache files only) and the format list. It validates its own
    // arguments; the program must be the helper by absolute path.
    if (program.startsWith(QLatin1Char('/')) && program.endsWith(QLatin1String("/grassfield-wallpaper")))
        return !args.isEmpty() && (args.at(0) == QLatin1String("list") || args.at(0) == QLatin1String("thumb") || args.at(0) == QLatin1String("formats"));
    return false;
}

bool isActionProgram(const QString &program)
{
    return program == QLatin1String("nmcli") || program == QLatin1String("bluetoothctl") || program == QLatin1String("wpctl");
}

} // namespace grassfield::settings
