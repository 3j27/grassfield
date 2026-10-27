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
    if (peer.owner.isEmpty() || !is(peer, m_config.ksecretd)) {
        close(peer); // nobody, gnome-keyring, or a process that is not known for sure: left alone
        return false;
    }
    qInfo("grassfield-secrets-handover: a ksecretd from an earlier session holds the Secret Service; asking it to quit");
    // KDBusService exports the application at /MainApplication; quit() is its own, orderly exit.
    call(m_bus, peer.owner, QStringLiteral("/MainApplication"), QStringLiteral("org.qtproject.Qt.QCoreApplication"),
         QStringLiteral("quit"), {}, 2000);
    bool released = releasedBy(m_bus, kSecrets, peer.owner, 5000);
    if (!released && alive(peer.pidfd)) {
        // Through the pidfd: the signal can only reach that process, never one that reused its PID.
        ::syscall(SYS_pidfd_send_signal, peer.pidfd, SIGTERM, nullptr, 0);
        released = releasedBy(m_bus, kSecrets, peer.owner, 3000);
    }
    close(peer);
    qInfo(released ? "grassfield-secrets-handover: the Secret Service is free" : "grassfield-secrets-handover: ksecretd did not quit");
    return released;
}

QString Handover::verifiedOwner(const QString &name, const QString &expected)
{
    // Started by D-Bus when nobody runs it yet (the package's service file), then identified.
    const QDBusReply<void> started = m_bus.interface()->startService(name);
    if (!started.isValid())
        return {};
    Peer peer = identify(m_bus, name);
    const QString owner = is(peer, expected) ? peer.owner : QString();
    close(peer);
    return owner;
}

Outcome Handover::move()
{
    if (QFileInfo::exists(markerPath(m_config.stateHome)))
        return Outcome::Done;
    if (!hasWallet(m_config.dataHome))
        return writeMarker(QStringLiteral("nothing")) ? Outcome::Done : Outcome::Deferred;
    const QDBusReply<QStringList> activatable = m_bus.interface()->activatableServiceNames();
    if (!m_bus.interface()->isServiceRegistered(kCompat).value() && !(activatable.isValid() && activatable.value().contains(kCompat)))
        return writeMarker(QStringLiteral("no-kwallet")) ? Outcome::Done : Outcome::Deferred;

    // The source: KWallet's own name, never org.freedesktop.secrets (the session keeps that one for gnome-keyring). Item
    // attributes are readable while the wallet is locked (ksecretd keeps them in <wallet>_attributes.json), so nothing is asked
    // unless there is something to move.
    const QString source = verifiedOwner(kCompat, m_config.ksecretd);
    if (source.isEmpty()) {
        qWarning("grassfield-secrets-handover: KWallet's name is not held by ksecretd; not now");
        return Outcome::Deferred;
    }
    struct Candidate {
        QDBusObjectPath item;
        QDBusObjectPath collection;
        Attributes attributes;
        QString label;
    };
    QList<Candidate> candidates;
    for (const QDBusObjectPath &collection : paths(dbusProperty(m_bus, source, kServicePath, kService, QStringLiteral("Collections")))) {
        for (const QDBusObjectPath &item : paths(dbusProperty(m_bus, source, collection.path(), kCollection, QStringLiteral("Items")))) {
            const auto attributes = unwrap<Attributes>(dbusProperty(m_bus, source, item.path(), kItem, QStringLiteral("Attributes")));
            if (!isLibsecretItem(attributes))
                continue;
            candidates.append(Candidate{item, collection, attributes,
                                        dbusProperty(m_bus, source, item.path(), kItem, QStringLiteral("Label")).toString()});
        }
    }
    if (candidates.isEmpty())
        return writeMarker(QStringLiteral("nothing")) ? Outcome::Done : Outcome::Deferred;

    // The destination: gnome-keyring, started by D-Bus when it does not run yet, and nobody else.
    const QString keychain = verifiedOwner(kSecrets, m_config.keyring);
    if (keychain.isEmpty()) {
        qWarning("grassfield-secrets-handover: the Secret Service is not held by gnome-keyring; not now");
        return Outcome::Deferred;
    }
    // What the keychain already holds (the same attributes find an item) stays as it is: never overwritten. A Chromium that
    // already made a new key keeps it.
    QList<Candidate> toMove;
    for (const Candidate &candidate : candidates) {
        const QDBusMessage found = call(m_bus, keychain, kServicePath, kService, QStringLiteral("SearchItems"),
                                        {QVariant::fromValue(candidate.attributes)});
        if (!ok(found) || found.arguments().size() < 2)
            return Outcome::Deferred;
        if (!paths(found.arguments().at(0)).isEmpty() || !paths(found.arguments().at(1)).isEmpty())
            ++m_kept;
        else
            toMove.append(candidate);
    }
    if (toMove.isEmpty())
        return writeMarker(QStringLiteral("present")) ? Outcome::Done : Outcome::Deferred;

    // Both sides open, each with its own question when it is locked; a refusal defers to the next session.
    const QDBusObjectPath target = keychainCollection(keychain);
    if (target.path() == kNoObject || !unlock(keychain, {target}))
        return Outcome::Deferred;
    QList<QDBusObjectPath> sourceCollections;
    for (const Candidate &candidate : toMove) {
        if (!sourceCollections.contains(candidate.collection))
            sourceCollections.append(candidate.collection);
    }
    if (!unlock(source, sourceCollections))
        return Outcome::Deferred;

    // "plain" sessions: the value crosses the user's own session bus between two of the user's processes, as with any
    // Secret Service client that does not negotiate a key.
    const auto openSession = [this](const QString &service) {
        const QDBusMessage opened = call(m_bus, service, kServicePath, kService, QStringLiteral("OpenSession"),
                                         {QStringLiteral("plain"), QVariant::fromValue(QDBusVariant(QString()))});
        return ok(opened) && opened.arguments().size() >= 2 ? opened.arguments().at(1).value<QDBusObjectPath>() : QDBusObjectPath(kNoObject);
    };
    const QDBusObjectPath readSession = openSession(source);
    const QDBusObjectPath writeSession = openSession(keychain);
    bool failed = readSession.path() == kNoObject || writeSession.path() == kNoObject;
    for (const Candidate &candidate : toMove) {
        if (failed)
            break;
        const QDBusMessage read = call(m_bus, source, candidate.item.path(), kItem, QStringLiteral("GetSecret"),
                                       {QVariant::fromValue(readSession)});
        if (!ok(read) || read.arguments().isEmpty()) {
            failed = true;
            break;
        }
        auto secret = unwrap<SecretValue>(read.arguments().constFirst());
        secret.session = writeSession;
        const QVariantMap properties{{QStringLiteral("org.freedesktop.Secret.Item.Label"), candidate.label},
                                     {QStringLiteral("org.freedesktop.Secret.Item.Attributes"), QVariant::fromValue(candidate.attributes)}};
        const QDBusMessage written = call(m_bus, keychain, target.path(), kCollection, QStringLiteral("CreateItem"),
                                          {properties, QVariant::fromValue(secret), false});
        // Our copy only: copies inside the bus library's message buffers cannot be reached from here (known limitation).
        secret.value.fill('\0');
        if (!ok(written) || written.arguments().size() < 2) {
            failed = true;
            break;
        }
        const auto prompt = written.arguments().at(1).value<QDBusObjectPath>();
        if (prompt.path() != kNoObject && !waitPrompt(keychain, prompt)) {
            failed = true;
            break;
        }
        ++m_moved;
    }
    for (const auto &[service, session] : {std::pair{source, readSession}, std::pair{keychain, writeSession}}) {
        if (session.path() != kNoObject)
            call(m_bus, service, session.path(), kSession, QStringLiteral("Close"));
    }
    // A partial move is safe: what moved is found in the keychain next time and kept; the rest moves then.
    if (failed)
        return Outcome::Deferred;
    notice();
    return writeMarker(QStringLiteral("moved")) ? Outcome::Done : Outcome::Deferred;
}

QDBusObjectPath Handover::keychainCollection(const QString &service)
{
    const QDBusMessage alias = call(m_bus, service, kServicePath, kService, QStringLiteral("ReadAlias"), {QStringLiteral("default")});
    if (!ok(alias) || alias.arguments().isEmpty())
        return QDBusObjectPath(kNoObject);
    const auto existing = alias.arguments().constFirst().value<QDBusObjectPath>();
    if (existing.path() != kNoObject)
        return existing;
    // No default keychain yet: create it as libsecret does for a first saved password (gnome-keyring asks for its password).
    const QVariantMap properties{{QStringLiteral("org.freedesktop.Secret.Collection.Label"), QStringLiteral("Default keyring")}};
    const QDBusMessage created = call(m_bus, service, kServicePath, kService, QStringLiteral("CreateCollection"),
                                      {properties, QStringLiteral("default")});
    if (!ok(created) || created.arguments().size() < 2)
        return QDBusObjectPath(kNoObject);
    const auto collection = created.arguments().at(0).value<QDBusObjectPath>();
    const auto prompt = created.arguments().at(1).value<QDBusObjectPath>();
    if (prompt.path() == kNoObject)
        return collection;
    if (!waitPrompt(service, prompt))
        return QDBusObjectPath(kNoObject);
    return m_promptResult.value<QDBusObjectPath>();
}

bool Handover::unlock(const QString &service, const QList<QDBusObjectPath> &objects)
{
    QList<QDBusObjectPath> locked;
    for (const QDBusObjectPath &object : objects) {
        if (dbusProperty(m_bus, service, object.path(), kCollection, QStringLiteral("Locked")).toBool())
            locked.append(object);
    }
    if (locked.isEmpty())
        return true;
    const QDBusMessage reply = call(m_bus, service, kServicePath, kService, QStringLiteral("Unlock"), {QVariant::fromValue(locked)});
    if (!ok(reply) || reply.arguments().size() < 2)
        return false;
    const auto prompt = reply.arguments().at(1).value<QDBusObjectPath>();
    if (prompt.path() == kNoObject)
        return paths(reply.arguments().at(0)).size() == locked.size();
    return waitPrompt(service, prompt);
}

bool Handover::waitPrompt(const QString &service, const QDBusObjectPath &prompt)
{
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
    if (!m_promptDone) {
        call(m_bus, service, prompt.path(), kPrompt, QStringLiteral("Dismiss"));
        return false;
    }
    return !m_promptDismissed;
}

void Handover::promptCompleted(bool dismissed, const QDBusVariant &result)
{
    m_promptDone = true;
    m_promptDismissed = dismissed;
    m_promptResult = result.variant();
    Q_EMIT promptFinished();
}

void Handover::notice()
{
    if (m_moved == 0)
        return;
    const QString summary = QCoreApplication::translate("SecretsHandover", "Saved passwords moved");
    const QString body = QCoreApplication::translate(
        "SecretsHandover", "Passwords that apps had saved elsewhere on this computer are now kept with your other saved passwords.");
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
    const QString path = markerPath(m_config.stateHome);
    if (!QDir().mkpath(QFileInfo(path).absolutePath()))
        return false;
    QSaveFile file(path);
    if (!file.open(QIODevice::WriteOnly))
        return false;
    file.write(markerLine(outcome, m_moved, m_kept).toUtf8());
    return file.commit();
}

} // namespace grassfield::handover
