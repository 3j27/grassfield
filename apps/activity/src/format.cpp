#include "format.h"

#include <QCoreApplication>

#include <cmath>

namespace activity {

QString dash()
{
    return QStringLiteral("—");
}

QString formatBytes(double bytes, const QLocale &locale)
{
    if (bytes < 0 || std::isnan(bytes))
        return dash();
    if (bytes < 1000) {
        const qint64 whole = static_cast<qint64>(bytes);
        return whole == 1 ? QCoreApplication::translate("ActivityFormat", "1 byte")
                          : QCoreApplication::translate("ActivityFormat", "%1 bytes").arg(locale.toString(whole));
    }
    static const char *const units[] = {QT_TRANSLATE_NOOP("ActivityFormat", "%1 KB"), QT_TRANSLATE_NOOP("ActivityFormat", "%1 MB"),
                                        QT_TRANSLATE_NOOP("ActivityFormat", "%1 GB"), QT_TRANSLATE_NOOP("ActivityFormat", "%1 TB"),
                                        QT_TRANSLATE_NOOP("ActivityFormat", "%1 PB")};
    constexpr int unitCount = 5;
    int unit = 0;
    double value = bytes / 1000.0;
    while (value >= 1000.0 && unit < unitCount - 1) {
        value /= 1000.0;
        ++unit;
    }
    // Files' rule (apps/files/src/filelogic.cpp formatSize): kilobytes whole, larger units three significant digits.
    int decimals = unit == 0 ? 0 : (value < 10 ? 2 : (value < 100 ? 1 : 0));
    double scale = std::pow(10.0, decimals);
    double rounded = std::round(value * scale) / scale;
    if (rounded >= 1000.0 && unit < unitCount - 1) { // 999.5 KB rounds up into the next unit
        ++unit;
        rounded /= 1000.0;
        decimals = 2;
    }
    return QCoreApplication::translate("ActivityFormat", units[unit]).arg(locale.toString(rounded, 'f', decimals));
}

QString formatCpuTime(double seconds, const QLocale &locale)
{
    if (seconds < 0 || std::isnan(seconds))
        return dash();
    const qint64 hundredths = static_cast<qint64>(std::floor(seconds * 100.0 + 1e-6));
    const qint64 h = hundredths / 360000;
    const qint64 m = hundredths / 6000 % 60;
    const qint64 s = hundredths / 100 % 60;
    const qint64 cs = hundredths % 100;
    return QStringLiteral("%1:%2:%3%4%5")
        .arg(h)
        .arg(m, 2, 10, QLatin1Char('0'))
        .arg(s, 2, 10, QLatin1Char('0'))
        .arg(locale.decimalPoint())
        .arg(cs, 2, 10, QLatin1Char('0'));
}

QString formatDecimal(double value, const QLocale &locale)
{
    if (value < 0 || std::isnan(value))
        return dash();
    return locale.toString(value, 'f', 1);
}

QString formatCount(double value, const QLocale &locale)
{
    if (value < 0 || std::isnan(value))
        return dash();
    return locale.toString(static_cast<qlonglong>(std::llround(value)));
}

} // namespace activity
