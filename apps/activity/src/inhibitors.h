// Preventing Sleep (spec AM38): logind's inhibitors (org.freedesktop.login1.Manager.ListInhibitors, system bus, read only),
// asked again at each sample while the Energy tab is shown. The projection's idle-inhibit flag joins at step 3.
#pragma once

#include <QDBusArgument>
#include <QList>
#include <QObject>
#include <QSet>
#include <QString>

namespace activity {

struct Inhibitor {
    QString what, who, why, mode;
    uint uid = 0, pid = 0;
};

// The pids holding an inhibitor whose What includes sleep or idle, in block mode.
QSet<int> sleepPreventers(const QList<Inhibitor> &inhibitors);

class InhibitorWatch : public QObject
{
    Q_OBJECT

public:
    explicit InhibitorWatch(QObject *parent = nullptr);
    // One asynchronous call; at most one in flight. Its answer comes as changed().
    void refresh();
    const QSet<int> &pids() const { return m_pids; }

signals:
    void changed();

private:
    QSet<int> m_pids;
    bool m_pending = false;
};

} // namespace activity

QDBusArgument &operator<<(QDBusArgument &arg, const activity::Inhibitor &i);
const QDBusArgument &operator>>(const QDBusArgument &arg, activity::Inhibitor &i);
Q_DECLARE_METATYPE(activity::Inhibitor)
