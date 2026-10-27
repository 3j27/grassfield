#include "handover.h"

#include "logic.h"
#include "peer.h"

#include <QCoreApplication>
#include <QDBusArgument>
#include <QDBusConnectionInterface>
#include <QDBusMessage>
#include <QDBusMetaType>
#include <QDBusReply>
#include <QDBusVariant>
#include <QDir>
#include <QElapsedTimer>
#include <QEventLoop>
#include <QFileInfo>
#include <QSaveFile>
#include <QThread>
#include <QTimer>

#include <algorithm>
#include <csignal>
#include <sys/syscall.h>
#include <unistd.h>

// The Secret Service's secret: (session, parameters, value, content type), "(oayays)".
struct SecretValue {
    QDBusObjectPath session;
    QByteArray parameters;
    QByteArray value;
    QString contentType;
};
Q_DECLARE_METATYPE(SecretValue)

QDBusArgument &operator<<(QDBusArgument &argument, const SecretValue &secret)
{
    argument.beginStructure();
    argument << secret.session << secret.parameters << secret.value << secret.contentType;
    argument.endStructure();
    return argument;
}

const QDBusArgument &operator>>(const QDBusArgument &argument, SecretValue &secret)
{
    argument.beginStructure();
    argument >> secret.session >> secret.parameters >> secret.value >> secret.contentType;
    argument.endStructure();
    return argument;
}

namespace grassfield::handover {

namespace {

const QString kSecrets = QStringLiteral("org.freedesktop.secrets");
const QString kCompat = QStringLiteral("org.kde.secretservicecompat");
const QString kServicePath = QStringLiteral("/org/freedesktop/secrets");
const QString kService = QStringLiteral("org.freedesktop.Secret.Service");
const QString kCollection = QStringLiteral("org.freedesktop.Secret.Collection");
const QString kItem = QStringLiteral("org.freedesktop.Secret.Item");
const QString kPrompt = QStringLiteral("org.freedesktop.Secret.Prompt");
const QString kSession = QStringLiteral("org.freedesktop.Secret.Session");
const QString kNoObject = QStringLiteral("/");

QDBusMessage call(const QDBusConnection &bus, const QString &service, const QString &path, const QString &interface,
                  const QString &method, const QVariantList &arguments = {}, int timeoutMs = 10000)
{
    QDBusMessage message = QDBusMessage::createMethodCall(service, path, interface, method);
    message.setArguments(arguments);
    return bus.call(message, QDBus::Block, timeoutMs);
}

bool ok(const QDBusMessage &reply)
{
    return reply.type() == QDBusMessage::ReplyMessage;
}

QVariant dbusProperty(const QDBusConnection &bus, const QString &service, const QString &path, const QString &interface,
                      const QString &name)
{
    const QDBusMessage reply = call(bus, service, path, QStringLiteral("org.freedesktop.DBus.Properties"), QStringLiteral("Get"),
                                    {interface, name});
    if (!ok(reply) || reply.arguments().isEmpty())
        return {};
    return reply.arguments().constFirst().value<QDBusVariant>().variant();
}

template<typename T>
T unwrap(const QVariant &value)
{
    if (value.canConvert<QDBusArgument>())
        return qdbus_cast<T>(value.value<QDBusArgument>());
    return value.value<T>();
}

QList<QDBusObjectPath> paths(const QVariant &value)
{
    return unwrap<QList<QDBusObjectPath>>(value);
}

bool releasedBy(const QDBusConnection &bus, const QString &name, const QString &owner, int timeoutMs)
{
    QElapsedTimer timer;
    timer.start();
    while (true) {
        const QDBusReply<QString> now = bus.interface()->serviceOwner(name);
        if (!now.isValid() || now.value() != owner)
            return true;
        if (timer.elapsed() >= timeoutMs)
            return false;
        QThread::msleep(100);
    }
}

} // namespace

Handover::Handover(QDBusConnection bus, Config config)
    : m_bus(std::move(bus))
    , m_config(std::move(config))
{
    qDBusRegisterMetaType<SecretValue>();
    qDBusRegisterMetaType<Attributes>();
}

bool Handover::releaseLeftover()
{
    Peer peer = identify(m_bus, kSecrets);
    // ksecretd, also one whose file a KWallet upgrade replaced since it started. Nobody, gnome-keyring, or a process that is
    // not known for sure: left alone.
    if (peer.owner.isEmpty() || !ranFrom(peer, m_config.ksecretd)) {
        close(peer);
        return false;
    }
    qInfo("grassfield-secrets-handover: a ksecretd from an earlier session holds the Secret Service; asking it to quit");
    // KDBusService exports the application at /MainApplication; quit() is its own, orderly exit. At most 1 + 3 + 2 s, so
    // readiness comes well within the unit's TimeoutStartSec=10 even for a ksecretd that ignores quit.
    call(m_bus, peer.owner, QStringLiteral("/MainApplication"), QStringLiteral("org.qtproject.Qt.QCoreApplication"),
         QStringLiteral("quit"), {}, 1000);
    if (releasedBy(m_bus, kSecrets, peer.owner, 3000)) {
        close(peer);
        qInfo("grassfield-secrets-handover: ksecretd quit; the Secret Service is free");
        return true;
    }
    bool released = false;
    if (alive(peer.pidfd)) {
        // Through the pidfd: the signal can only reach that process, never one that reused its PID.
        ::syscall(SYS_pidfd_send_signal, peer.pidfd, SIGTERM, nullptr, 0);
        released = releasedBy(m_bus, kSecrets, peer.owner, 2000);
    }
    close(peer);
    qInfo(released ? "grassfield-secrets-handover: ksecretd stopped (SIGTERM); the Secret Service is free"
                   : "grassfield-secrets-handover: ksecretd did not quit");
    return released;
}

QString Handover::verifiedOwner(const QString &name, const QString &expected)
{
    // Started by D-Bus only when nobody runs it yet (the package's service file): StartServiceByName fails for a name that
    // has no service file even while it is owned (dbus-daemon looks for the file first; seen with gnome-keyring started by
    // PAM or by hand). Then identified; an owner that went away in between is refused.
    if (!m_bus.interface()->isServiceRegistered(name).value()) {
        const QDBusReply<void> started = m_bus.interface()->startService(name);
        if (!started.isValid())
            return {};
    }
    Peer peer = identify(m_bus, name);
    const QString owner = is(peer, expected) ? peer.owner : QString();
    close(peer);
    return owner;
}

QString Handover::move()
{
    if (QFileInfo::exists(markerPath(m_config.stateDir)))
        return QStringLiteral("done");
    if (!hasWallet(m_config.dataHome))
        return finish(QStringLiteral("nothing"));
    const QDBusReply<QStringList> activatable = m_bus.interface()->activatableServiceNames();
    if (!m_bus.interface()->isServiceRegistered(kCompat).value() && !(activatable.isValid() && activatable.value().contains(kCompat)))
        return finish(QStringLiteral("no-kwallet"));

    // The source: KWallet's own name, never org.freedesktop.secrets (the session keeps that one for gnome-keyring). Item
    // attributes are readable while the wallet is locked (ksecretd keeps them in <wallet>_attributes.json), so nothing is asked
    // unless there is something to move.
    const QString source = verifiedOwner(kCompat, m_config.ksecretd);
    if (source.isEmpty()) {
        qWarning("grassfield-secrets-handover: KWallet's name is not held by ksecretd; not now");
        return QStringLiteral("deferred");
    }
    Listing listing = list(source);
    m_skipped = listing.unfindable;
    if (listing.candidates.isEmpty()) {
        if (listing.locked) {
            qInfo("grassfield-secrets-handover: KWallet is locked and lists nothing to move yet; not now");
            return QStringLiteral("deferred");
        }
        return finish(QStringLiteral("nothing"));
    }

    // The destination: gnome-keyring, started by D-Bus when it does not run yet, and nobody else.
    const QString keychain = verifiedOwner(kSecrets, m_config.keyring);
    if (keychain.isEmpty()) {
        qWarning("grassfield-secrets-handover: the Secret Service is not held by gnome-keyring; not now");
        return QStringLiteral("deferred");
    }
    // What the keychain already holds (the same attributes find an item) stays as it is: never overwritten. A Chromium that
    // already made a new key keeps it.
    QList<Candidate> toMove;
    int present = 0;
    if (!absentFrom(keychain, listing.candidates, toMove, present))
        return QStringLiteral("deferred");
    m_kept = present + listing.duplicates;
    if (toMove.isEmpty()) {
        if (listing.locked) {
            qInfo("grassfield-secrets-handover: KWallet is locked and lists nothing new yet; not now");
            return QStringLiteral("deferred");
        }
        return finish(QStringLiteral("present"));
    }

    // Both sides open, each with its own question when it is locked. The questions come at most once, ever (decision 2c-9):
    // a refusal ends the handover for good.
    PromptResult result = PromptResult::Accepted;
    const QDBusObjectPath target = keychainCollection(keychain, result);
    if (result == PromptResult::Declined)
        return declined();
    if (target.path() == kNoObject)
        return stop();
    result = unlock(keychain, {target});
    if (result != PromptResult::Accepted)
        return result == PromptResult::Declined ? declined() : stop();
    QList<QDBusObjectPath> sourceCollections;
    for (const Candidate &candidate : toMove) {
        if (candidate.locked && !sourceCollections.contains(candidate.collection))
            sourceCollections.append(candidate.collection);
    }
    result = unlock(source, sourceCollections);
    if (result != PromptResult::Accepted)
        return result == PromptResult::Declined ? declined() : stop();
    if (listing.locked) {
        // An open wallet also lists the entries ksecretd had not seen yet (those of older KWallet versions get their
        // attributes when the wallet opens, kwalletfreedesktopcollection.cpp onWalletChangeState): list again.
        listing = list(source);
        m_skipped = listing.unfindable;
        toMove.clear();
        present = 0;
        if (!absentFrom(keychain, listing.candidates, toMove, present))
            return stop();
        m_kept = present + listing.duplicates;
    }

    // "plain" sessions: the value crosses the user's own session bus between two of the user's processes, as with any
    // Secret Service client that does not negotiate a key (decision 2c-4).
    const auto openSession = [this](const QString &service) {
        const QDBusMessage opened = call(m_bus, service, kServicePath, kService, QStringLiteral("OpenSession"),
                                         {QStringLiteral("plain"), QVariant::fromValue(QDBusVariant(QString()))});
        return ok(opened) && opened.signature() == QLatin1String("vo") ? opened.arguments().at(1).value<QDBusObjectPath>()
                                                                        : QDBusObjectPath(kNoObject);
    };
    const QDBusObjectPath readSession = openSession(source);
    const QDBusObjectPath writeSession = openSession(keychain);
    bool failed = readSession.path() == kNoObject || writeSession.path() == kNoObject;
    bool refused = false;
    for (const Candidate &candidate : toMove) {
        if (failed || refused)
            break;
        if (candidate.locked) {
            ++m_skipped; // in a wallet that stayed locked (it had nothing to move when the question was asked)
            continue;
        }
        const QDBusMessage read = call(m_bus, source, candidate.item.path(), kItem, QStringLiteral("GetSecret"),
                                       {QVariant::fromValue(readSession)});
        if (!ok(read) || read.signature() != QLatin1String("(oayays)")) {
            failed = true;
            break;
        }
        auto secret = unwrap<SecretValue>(read.arguments().constFirst());
        if (secret.value.isEmpty()) {
            // Nothing to hand over, and a copy made now would never be replaced later: left in KWallet.
            ++m_skipped;
            continue;
        }
        secret.session = writeSession;
        const QVariantMap properties{{QStringLiteral("org.freedesktop.Secret.Item.Label"), candidate.label},
                                     {QStringLiteral("org.freedesktop.Secret.Item.Attributes"), QVariant::fromValue(candidate.attributes)}};
        const QDBusMessage written = call(m_bus, keychain, target.path(), kCollection, QStringLiteral("CreateItem"),
                                          {properties, QVariant::fromValue(secret), false});
        // Our copy only: copies inside the bus library's message buffers cannot be reached from here (known limitation; the
        // process is not dumpable, so no core file keeps them).
        secret.value.fill('\0');
        if (!ok(written) || written.signature() != QLatin1String("oo")) {
            failed = true;
            break;
        }
        const auto prompt = written.arguments().at(1).value<QDBusObjectPath>();
        if (prompt.path() != kNoObject) {
            result = waitPrompt(keychain, prompt);
            if (result != PromptResult::Accepted) {
                refused = result == PromptResult::Declined;
                failed = !refused;
                break;
            }
        }
        ++m_moved;
    }
    for (const auto &[service, session] : {std::pair{source, readSession}, std::pair{keychain, writeSession}}) {
        if (session.path() != kNoObject)
            call(m_bus, service, session.path(), kSession, QStringLiteral("Close"));
    }
    if (refused)
        return declined();
    // A move cut short without a question is safe: what moved is found in the keychain next time and kept; the rest moves
    // then. After a question it ends here for good ("incomplete").
    if (failed)
        return stop();
    if (m_moved > 0) {
        notice(QCoreApplication::translate("SecretsHandover", "Saved passwords moved"),
               QCoreApplication::translate("SecretsHandover",
                                           "Passwords that apps had saved elsewhere on this computer are now kept with your other saved passwords."));
    }
    return finish(QStringLiteral("moved"));
}

Handover::Listing Handover::list(const QString &source)
{
    Listing listing;
    for (const QDBusObjectPath &collection : paths(dbusProperty(m_bus, source, kServicePath, kService, QStringLiteral("Collections")))) {
        // A wallet whose state cannot be read counts as locked: nothing final is concluded from it.
        const QVariant lockedValue = dbusProperty(m_bus, source, collection.path(), kCollection, QStringLiteral("Locked"));
        const bool locked = !lockedValue.isValid() || lockedValue.toBool();
        listing.locked = listing.locked || locked;
        for (const QDBusObjectPath &item : paths(dbusProperty(m_bus, source, collection.path(), kCollection, QStringLiteral("Items")))) {
            const auto attributes = unwrap<Attributes>(dbusProperty(m_bus, source, item.path(), kItem, QStringLiteral("Attributes")));
            if (!isFindable(attributes)) {
                ++listing.unfindable;
                continue;
            }
            const Candidate candidate{item, collection, attributes,
                                      dbusProperty(m_bus, source, item.path(), kItem, QStringLiteral("Label")).toString(),
                                      dbusProperty(m_bus, source, item.path(), kItem, QStringLiteral("Modified")).toULongLong(), locked};
            // Items with the same attributes (two wallets, or a client that saved twice) are one entry for every lookup: only
            // the most recently changed one moves; the others stay in KWallet and count as kept (decision 2c-8).
            const auto same = std::find_if(listing.candidates.begin(), listing.candidates.end(),
                                           [&](const Candidate &other) { return other.attributes == attributes; });
            if (same == listing.candidates.end()) {
                listing.candidates.append(candidate);
                continue;
            }
            ++listing.duplicates;
            if (candidate.modified > same->modified)
                *same = candidate;
        }
    }
    return listing;
}

bool Handover::absentFrom(const QString &keychain, const QList<Candidate> &candidates, QList<Candidate> &absent, int &present)
{
    for (const Candidate &candidate : candidates) {
        const QDBusMessage found = call(m_bus, keychain, kServicePath, kService, QStringLiteral("SearchItems"),
                                        {QVariant::fromValue(candidate.attributes)});
        if (!ok(found) || found.signature() != QLatin1String("aoao"))
            return false;
        if (!paths(found.arguments().at(0)).isEmpty() || !paths(found.arguments().at(1)).isEmpty())
            ++present;
        else
            absent.append(candidate);
    }
    return true;
}

QDBusObjectPath Handover::keychainCollection(const QString &service, PromptResult &result)
{
    result = PromptResult::Accepted;
    const QDBusMessage alias = call(m_bus, service, kServicePath, kService, QStringLiteral("ReadAlias"), {QStringLiteral("default")});
    if (!ok(alias) || alias.signature() != QLatin1String("o"))
        return QDBusObjectPath(kNoObject);
    auto existing = alias.arguments().constFirst().value<QDBusObjectPath>();
    if (existing.path() != kNoObject)
        return existing;
    // No default keychain yet: create it as libsecret does for a first saved password (gnome-keyring asks for its password).
    const QVariantMap properties{{QStringLiteral("org.freedesktop.Secret.Collection.Label"), QStringLiteral("Default keyring")}};
    const QDBusMessage created = call(m_bus, service, kServicePath, kService, QStringLiteral("CreateCollection"),
                                      {properties, QStringLiteral("default")});
    if (!ok(created) || created.signature() != QLatin1String("oo"))
        return QDBusObjectPath(kNoObject);
    auto collection = created.arguments().at(0).value<QDBusObjectPath>();
    const auto prompt = created.arguments().at(1).value<QDBusObjectPath>();
    if (prompt.path() == kNoObject)
        return collection;
    result = waitPrompt(service, prompt);
    if (result != PromptResult::Accepted)
        return QDBusObjectPath(kNoObject);
    return m_promptResult.value<QDBusObjectPath>();
}

PromptResult Handover::unlock(const QString &service, const QList<QDBusObjectPath> &objects)
{
    QList<QDBusObjectPath> locked;
    for (const QDBusObjectPath &object : objects) {
        const QVariant lockedValue = dbusProperty(m_bus, service, object.path(), kCollection, QStringLiteral("Locked"));
        if (!lockedValue.isValid() || lockedValue.toBool())
            locked.append(object);
    }
    if (locked.isEmpty())
        return PromptResult::Accepted;
    const QDBusMessage reply = call(m_bus, service, kServicePath, kService, QStringLiteral("Unlock"), {QVariant::fromValue(locked)});
    if (!ok(reply) || reply.signature() != QLatin1String("aoo"))
        return PromptResult::Failed;
    const auto prompt = reply.arguments().at(1).value<QDBusObjectPath>();
    if (prompt.path() == kNoObject)
        return paths(reply.arguments().at(0)).size() == locked.size() ? PromptResult::Accepted : PromptResult::Failed;
    return waitPrompt(service, prompt);
}

PromptResult Handover::waitPrompt(const QString &service, const QDBusObjectPath &prompt)
{
    // At most once, ever: the marker says a question was asked before the first one is shown, so neither a refusal nor an
    // error after it brings KWallet's or the keychain's question back at a later login (decision 2c-9).
    if (!m_asked) {
        if (!writeMarker(QStringLiteral("asked")))
            return PromptResult::Failed;
        m_asked = true;
    }
    m_promptDone = false;
    m_promptDismissed = true;
    m_promptResult = QVariant();
    // The answer comes as a signal from the service's own connection (the unique name), on that prompt's path.
    m_bus.connect(service, prompt.path(), kPrompt, QStringLiteral("Completed"), this, SLOT(promptCompleted(bool, QDBusVariant)));
    QEventLoop loop;
    QTimer timer;
    timer.setSingleShot(true);
    connect(&timer, &QTimer::timeout, &loop, &QEventLoop::quit);
    connect(this, &Handover::promptFinished, &loop, &QEventLoop::quit);
    const QDBusMessage shown = call(m_bus, service, prompt.path(), kPrompt, QStringLiteral("Prompt"), {QString()});
    if (ok(shown) && !m_promptDone) {
        timer.start(m_config.promptTimeoutMs);
        loop.exec();
    }
    m_bus.disconnect(service, prompt.path(), kPrompt, QStringLiteral("Completed"), this, SLOT(promptCompleted(bool, QDBusVariant)));
    if (!ok(shown))
        return PromptResult::Failed;
    if (!m_promptDone) {
        // Not answered in time: the question goes away, and counts as refused.
        call(m_bus, service, prompt.path(), kPrompt, QStringLiteral("Dismiss"));
        return PromptResult::Declined;
    }
    return m_promptDismissed ? PromptResult::Declined : PromptResult::Accepted;
}

void Handover::promptCompleted(bool dismissed, const QDBusVariant &result)
{
    m_promptDone = true;
    m_promptDismissed = dismissed;
    m_promptResult = result.variant();
    Q_EMIT promptFinished();
}

QString Handover::finish(const QString &outcome)
{
    return writeMarker(outcome) ? outcome : QStringLiteral("deferred");
}

QString Handover::stop()
{
    return m_asked ? finish(QStringLiteral("incomplete")) : QStringLiteral("deferred");
}

QString Handover::declined()
{
    const QString outcome = finish(QStringLiteral("declined"));
    notice(QCoreApplication::translate("SecretsHandover", "Saved passwords not moved"),
           QCoreApplication::translate("SecretsHandover",
                                       "Passwords that apps had saved elsewhere on this computer stay where they were. Apps that used "
                                       "them may ask you to sign in again."));
    return outcome;
}

void Handover::notice(const QString &summary, const QString &body)
{
    // The shell's notification server, once it runs: never started by D-Bus (another server could be activatable).
    QElapsedTimer timer;
    timer.start();
    const QString name = QStringLiteral("org.freedesktop.Notifications");
    while (!m_bus.interface()->isServiceRegistered(name).value()) {
        if (timer.elapsed() >= m_config.notifyWaitMs)
            return;
        QThread::msleep(500);
    }
    QDBusMessage message = QDBusMessage::createMethodCall(name, QStringLiteral("/org/freedesktop/Notifications"), name, QStringLiteral("Notify"));
    message.setAutoStartService(false);
    message.setArguments({QStringLiteral("Grassfield"), uint(0), QStringLiteral("dialog-password"), summary, body, QStringList(),
                          QVariantMap(), int(-1)});
    m_bus.call(message, QDBus::Block, 5000);
}

bool Handover::writeMarker(const QString &outcome)
{
    const QString path = markerPath(m_config.stateDir);
    if (!QDir().mkpath(QFileInfo(path).absolutePath()))
        return false;
    QSaveFile file(path);
    if (!file.open(QIODevice::WriteOnly))
        return false;
    file.write(markerLine(outcome, m_moved, m_kept, m_skipped).toUtf8());
    return file.commit();
}

} // namespace grassfield::handover
