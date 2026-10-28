// The Secret Service handover of the Grassfield session (ADR-0035 D-12, owner decision Q17-b, step 2c).
//
// Phase 1, before the shell starts (the unit reports ready after it): a ksecretd left over from an earlier session, or from
// the Omarchy session, that still owns org.freedesktop.secrets is asked to quit, so the next libsecret call starts
// gnome-keyring.
// Phase 2, once per user: the items KWallet holds (those libsecret clients saved while ksecretd held that name, and KWallet's
// own entries, which kwalletd also keeps through the Secret Service) are copied into the keychain (gnome-keyring), never over
// an item the keychain already holds; KWallet keeps its copies. One notice when something moved. The password questions of
// KWallet and of the keychain come at most once: a refusal ends the handover for good, with its own notice. Without a
// question, an error leaves everything as it was and the handover runs again at the next session.
//
// It runs as the user, logs counts only (no item, label, attribute or value), and holds a secret only between reading it and
// handing it to the keychain.
#pragma once

#include "logic.h"

#include <QDBusConnection>
#include <QDBusObjectPath>
#include <QDBusVariant>
#include <QList>
#include <QObject>
#include <QString>
#include <QVariant>

namespace grassfield::handover {

struct Config {
    QString ksecretd = QStringLiteral("/usr/bin/ksecretd");                 // KWallet's Secret Service daemon
    QString keyring = QStringLiteral("/usr/bin/gnome-keyring-daemon");      // the keychain
    QString dataHome;   // $XDG_DATA_HOME
    QString stateDir;   // where the marker goes (logic.h stateDirectory)
    int promptTimeoutMs = 5 * 60 * 1000;
    int notifyWaitMs = 30 * 1000;
};

// The user's answer to a password question of KWallet or the keychain.
enum class PromptResult {
    Accepted,
    Declined,  // refused, or not answered within promptTimeoutMs (then dismissed)
    Failed,    // the question could not be shown
};

class Handover : public QObject
{
    Q_OBJECT
public:
    Handover(QDBusConnection bus, Config config);

    // Phase 1: true when a leftover ksecretd held org.freedesktop.secrets and no longer does.
    bool releaseLeftover();
    // Phase 2. The outcome written to the marker, which ends the handover for good: "moved", "nothing", "present",
    // "no-kwallet", "declined" (a question refused or not answered) or "incomplete" (an error after a question); "done"
    // when an earlier session wrote one; "deferred" when nothing was asked and nothing is final (no marker: runs again).
    QString move();

    int moved() const { return m_moved; }
    int kept() const { return m_kept; }
    int skipped() const { return m_skipped; }

Q_SIGNALS:
    void promptFinished();

private Q_SLOTS:
    void promptCompleted(bool dismissed, const QDBusVariant &result);

private:
    struct Candidate {
        QDBusObjectPath item;
        QDBusObjectPath collection;
        Attributes attributes;
        QString label;
        qulonglong modified = 0;
        bool locked = false;  // its collection was locked when listed
    };
    struct Listing {
        QList<Candidate> candidates;
        int duplicates = 0;   // items with the same attributes as a newer one: they stay in KWallet
        int unfindable = 0;   // items without attributes: no lookup can find them, in KWallet or in the keychain
        bool locked = false;  // a collection was locked: the listing may miss entries (see list())
    };

    // The unique name that owns `name`, started by D-Bus when needed, when its process runs `expected`; else empty.
    QString verifiedOwner(const QString &name, const QString &expected);
    Listing list(const QString &source);
    // The candidates the keychain does not hold yet (no item with the same attributes); false on a bus error.
    bool absentFrom(const QString &keychain, const QList<Candidate> &candidates, QList<Candidate> &absent, int &present);
    PromptResult waitPrompt(const QString &service, const QDBusObjectPath &prompt);
    PromptResult unlock(const QString &service, const QList<QDBusObjectPath> &objects);
    QDBusObjectPath keychainCollection(const QString &service, PromptResult &result);
    // Ends the handover for good with `outcome` (the marker); "deferred" when the marker cannot be written.
    QString finish(const QString &outcome);
    // After an error: final ("incomplete") once a question was asked, so it is never asked again; else "deferred".
    QString stop();
    QString declined();
    void notice(const QString &summary, const QString &body);
    bool writeMarker(const QString &outcome);

    QDBusConnection m_bus;
    Config m_config;
    int m_moved = 0;
    int m_kept = 0;
    int m_skipped = 0;
    bool m_asked = false;
    bool m_promptDone = false;
    bool m_promptDismissed = true;
    QVariant m_promptResult;
};

} // namespace grassfield::handover
