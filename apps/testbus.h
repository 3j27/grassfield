// A private test bus (ADR-0019): what a Grassfield helper run as a dev session accepts as its session bus, so that a dev run
// never acts on the user's own bus. Shared by apps/secrets-handover and apps/portal-settings. Header-only, Qt Core.
#pragma once

#include <QDir>
#include <QMap>
#include <QString>
#include <QStringList>

namespace grassfield::apps {

// Dev sessions only (ADR-0019: the overrides of the tests apply only there): every ';' entry of the
// address is unix:path=<a socket under `dir`> (percent-escapes decoded, dots resolved) or tcp on loopback. The rule of
// tests/integration/settings_dbus/probe.cpp and of the fakes (tests/fixtures/fake-secret-service.py).
inline bool isPrivateTestBus(const QString &address, const QString &dir)
{
    if (address.isEmpty() || !dir.startsWith(QLatin1Char('/')))
        return false;
    const QString root = QDir::cleanPath(dir);
    const QStringList entries = address.split(QLatin1Char(';'), Qt::SkipEmptyParts);
    if (entries.isEmpty())
        return false;
    for (const QString &entry : entries) {
        const qsizetype colon = entry.indexOf(QLatin1Char(':'));
        if (colon <= 0)
            return false;
        const QString transport = entry.left(colon);
        QMap<QString, QString> kv;
        for (const QString &pair : entry.mid(colon + 1).split(QLatin1Char(','), Qt::SkipEmptyParts)) {
            const qsizetype eq = pair.indexOf(QLatin1Char('='));
            if (eq <= 0)
                return false;
            kv.insert(pair.left(eq), QString::fromUtf8(QByteArray::fromPercentEncoding(pair.mid(eq + 1).toUtf8())));
        }
        if (transport == QLatin1String("unix")) {
            for (auto it = kv.cbegin(); it != kv.cend(); ++it)
                if (it.key() != QLatin1String("path") && it.key() != QLatin1String("guid"))
                    return false;
            const QString path = kv.value(QStringLiteral("path"));
            if (!path.startsWith(QLatin1Char('/')) || !QDir::cleanPath(path).startsWith(root + QLatin1Char('/')))
                return false;
        } else if (transport == QLatin1String("tcp")) {
            for (auto it = kv.cbegin(); it != kv.cend(); ++it)
                if (it.key() != QLatin1String("host") && it.key() != QLatin1String("port") && it.key() != QLatin1String("family")
                    && it.key() != QLatin1String("guid"))
                    return false;
            const QString host = kv.value(QStringLiteral("host"));
            if (host != QLatin1String("127.0.0.1") && host != QLatin1String("localhost") && host != QLatin1String("::1"))
                return false;
        } else {
            return false;
        }
    }
    return true;
}

} // namespace grassfield::apps
