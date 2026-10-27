// The Secret Service handover of the Grassfield session (ADR-0035 D-12, owner decision Q17-b, step 2c).
//
// Phase 1, before the shell starts (the unit reports ready after it): a ksecretd left over from an earlier session, or from
// the Omarchy session, that still owns org.freedesktop.secrets is asked to quit, so the next libsecret call starts
// gnome-keyring.
// Phase 2, once per user: the items that libsecret clients saved in KWallet while ksecretd held that name are copied into the
// keychain (gnome-keyring), never over an item the keychain already holds; KWallet keeps its copies. One notice when something
// moved. A prompt the user refuses, or any error, leaves everything as it was and the handover runs again at the next session.
//
// It runs as the user, logs counts only (no item, label, attribute or value), and holds a secret only between reading it and
// handing it to the keychain.
#pragma once

#include <QDBusConnection>
#include <QDBusObjectPath>
#include <QDBusVariant>
#include <QObject>
#include <QString>
#include <QVariant>

namespace grassfield::handover {

struct Config {
    QString ksecretd = QStringLiteral("/usr/bin/ksecretd");                 // KWallet's Secret Service daemon
    QString keyring = QStringLiteral("/usr/bin/gnome-keyring-daemon");      // the keychain
    QString dataHome;   // $XDG_DATA_HOME
    QString stateHome;  // $XDG_STATE_HOME
    int promptTimeoutMs = 5 * 60 * 1000;
    int notifyWaitMs = 30 * 1000;
};

enum class Outcome {
    Done,      // ran to its end: the marker is written
    Deferred,  // not now (a refused prompt, a peer that is not who it should be, an error): runs again next session
};

class Handover : public QObject
{
    Q_OBJECT
public:
    Handover(QDBusConnection bus, Config config);

    // Phase 1: true when a leftover ksecretd held org.freedesktop.secrets and no longer does.
    bool releaseLeftover();
    // Phase 2.
    Outcome move();

    int moved() const { return m_moved; }
    int kept() const { return m_kept; }

Q_SIGNALS:
    void promptFinished();

private Q_SLOTS:
    void promptCompleted(bool dismissed, const QDBusVariant &result);

private:
    // The unique name that owns `name`, started by D-Bus when needed, when its process runs `expected`; else empty.
    QString verifiedOwner(const QString &name, const QString &expected);
    bool waitPrompt(const QString &service, const QDBusObjectPath &prompt);
    bool unlock(const QString &service, const QList<QDBusObjectPath> &objects);
    QDBusObjectPath keychainCollection(const QString &service);
    void notice();
    bool writeMarker(const QString &outcome);

    QDBusConnection m_bus;
    Config m_config;
    int m_moved = 0;
    int m_kept = 0;
    bool m_promptDone = false;
    bool m_promptDismissed = true;
    QVariant m_promptResult;
};

} // namespace grassfield::handover
