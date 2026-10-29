// Values as the table shows them (spec AM16): sizes in the session's locale with the decimal unit scale Files uses, CPU
// time as h:mm:ss.ss, shares and indexes with one decimal, counts as whole numbers, and "—" for what is unknown (a negative
// value, as the sampler gives it).
#pragma once

#include <QLocale>
#include <QString>

namespace activity {

QString dash();
// "0 bytes", "999 bytes", "12 KB", "1.23 MB", "12.3 GB", "123 TB" (decimal, three significant digits, as Files).
QString formatBytes(double bytes, const QLocale &locale = QLocale());
// AM21: hours, minutes, seconds and hundredths ("0:01:23.45"; the locale's decimal point).
QString formatCpuTime(double seconds, const QLocale &locale = QLocale());
// One decimal: % CPU, % GPU (AM20, AM46), Energy Impact (AM36).
QString formatDecimal(double value, const QLocale &locale = QLocale());
// A whole number with the locale's grouping: threads, wake-ups per second, open files, packets, page ins.
QString formatCount(double value, const QLocale &locale = QLocale());

} // namespace activity
