#include "systemguard.h"

#include <QList>
#include <QRegularExpression>

namespace grassfield::settings {

bool devSession()
{
    return qEnvironmentVariable("GRASSFIELD_DEV") == QLatin1String("1");
}

bool isWpctlTarget(const QString &s)
{
    static const QRegularExpression digits(QStringLiteral("^[0-9]{1,9}$"));
    return s == QLatin1String("@DEFAULT_AUDIO_SINK@") || s == QLatin1String("@DEFAULT_AUDIO_SOURCE@") || digits.match(s).hasMatch();
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
            {"-t", "-f", "IN-USE,SSID,SIGNAL,SECURITY", "dev", "wifi", "list", "--rescan", "no"},
            {"-t", "-f", "NAME,TYPE", "connection", "show"},
            {"-t", "-f", "DEVICE,TYPE,STATE", "device"},
        };
        return queries.contains(args);
    }
    if (program == QLatin1String("bluetoothctl")) {
        static const QList<QStringList> queries = {
            {"show"},
            {"devices", "Paired"},
            {"devices", "Connected"},
        };
        return queries.contains(args);
    }
    if (program == QLatin1String("wpctl")) {
        if (args == QStringList{"status"})
            return true;
        return args.size() == 2 && args.at(0) == QLatin1String("get-volume") && isWpctlTarget(args.at(1));
    }
    return false;
}

bool isActionProgram(const QString &program)
{
    return program == QLatin1String("nmcli") || program == QLatin1String("bluetoothctl") || program == QLatin1String("wpctl");
}

} // namespace grassfield::settings
