#pragma once

#include <QDBusMessage>
#include <QEventLoop>
#include <QList>
#include <QObject>
#include <QVariantList>

namespace grassfield::settings {

// The signals one QtBusCaller listens to (qtbuscaller.h listen, ADR-0045 OC-0.7: fprintd's EnrollStatus), kept in order for
// nextSignal. It lives on the job's worker thread: Qt D-Bus posts each signal there, and nextSignal runs a local event loop
// that `take` ends as soon as one arrives. A slot that takes only the QDBusMessage receives the signal whatever its arguments.
// Its own header because it needs moc (CMake's AUTOMOC; build-direct.sh and tests/integration/settings_dbus.sh run moc on it).
class SignalQueue : public QObject
{
    Q_OBJECT

public:
    QList<QVariantList> kept;
    QEventLoop *waiting = nullptr;

public Q_SLOTS:
    void take(const QDBusMessage &message)
    {
        kept.append(message.arguments());
        if (waiting)
            waiting->quit();
    }
};

} // namespace grassfield::settings
