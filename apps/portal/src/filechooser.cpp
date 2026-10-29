#include "filechooser.h"

#include "panelstate.h"

#include <KService>
#include <KWindowSystem>

#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDir>
#include <QElapsedTimer>
#include <QFileInfo>
#include <QGuiApplication>
#include <QQuickWindow>
#include <QRegularExpression>
#include <QStandardPaths>
#include <QUrl>
#include <QWindow>

#include <limits>
#include <utility>

namespace grassfield::portal {

namespace {
constexpr auto kPath = "/org/freedesktop/portal/desktop";
constexpr auto kInterface = "org.freedesktop.impl.portal.FileChooser";
constexpr auto kRequestInterface = "org.freedesktop.impl.portal.Request";
// A Close to x-d-p-gtk that finds no Request object yet is sent again this often, this many times (closeForwarded).
constexpr int kCloseRetryMs = 100;
constexpr int kCloseTries = 50;
} // namespace

struct FileChooser::Request {
    enum class State { Making, Shown, Forwarded };
    int id = 0;
    QString handle;
    chooser::Request request;
    QDBusMessage message;
    State state = State::Making;
    QTimer deadline;
    QElapsedTimer since;
    QPointer<QWindow> window;
    std::unique_ptr<RequestObject> object;
};

FileChooser::FileChooser(const QDBusConnection &bus, const Options &options, QObject *parent)
    : QObject(parent)
    , m_bus(bus)
    , m_options(options)
    , m_disk(DiskProbe::Options{options.probeDeadlineMs, options.probeTotalMs, options.statPath})
{
    connect(&m_disk, &DiskProbe::answered, this, [this](int token, const QHash<QString, int> &kinds) {
        if (const auto done = m_diskAsked.take(token))
            done(kinds);
    });
    chooser::registerTypes();
    m_idle.setSingleShot(true);
    m_idle.setInterval(m_options.idleQuitMs);
    connect(&m_idle, &QTimer::timeout, this, &FileChooser::idle);
    armIdle();
}

FileChooser::~FileChooser()
{
    // A process that goes with requests in flight answers them: the frontend never waits on a backend that left.
    const QList<int> ids = m_requests.keys();
    for (int id : ids)
        finish(id, 2, {});
}

QString FileChooser::windowAppId(const QString &appId)
{
    QString id = appId;
    if (id.endsWith(QLatin1String(".desktop")))
        id.chop(8);
    static const QRegularExpression valid(QStringLiteral("^[A-Za-z0-9_-][A-Za-z0-9._-]{0,254}$"));
    return valid.match(id).hasMatch() ? id : QStringLiteral("org.grassfield.Files");
}

void FileChooser::handle(chooser::Kind kind, const QDBusObjectPath &handle, const QString &appId, const QString &parentWindow,
                         const QString &title, const QVariantMap &options, const QDBusMessage &message)
{
    message.setDelayedReply(true);
    const QString path = handle.path();
    const auto refuse = [&](const char *why) {
        qWarning("grassfield-portal: %s: %s", qPrintable(message.member()), why);
        m_bus.send(message.createReply(QVariantList{QVariant::fromValue(uint(2)), QVariantMap()}));
    };
    chooser::Request parsed = chooser::parse(kind, appId, parentWindow, title, options);
    if (!parsed.error.isEmpty())
        return refuse(qPrintable(parsed.error));
    if (m_requests.size() >= m_options.maxPending)
        return refuse("too many requests at once");
    for (const auto &r : std::as_const(m_requests))
        if (r->handle == path)
            return refuse("a request with this handle is open");

    auto r = std::make_shared<Request>();
    r->id = m_nextId++;
    r->handle = path;
    r->request = parsed;
    r->message = message;
    r->since.start();
    r->object = std::make_unique<RequestObject>(this, path);
    if (path.isEmpty() || !m_bus.registerObject(path, r->object.get(), QDBusConnection::ExportScriptableSlots))
        return refuse("cannot export the request object");
    m_requests.insert(r->id, r);
    m_idle.stop();
    emit pendingChanged();

    if (m_uiLoader) {
        const auto load = std::exchange(m_uiLoader, nullptr);
        m_uiReady = load();
    }
    if (!m_uiReady) {
        forward(r->id);
        return;
    }
    // FC7: no first frame within the deadline, and the call goes to x-d-p-gtk.
    r->deadline.setSingleShot(true);
    r->deadline.setInterval(m_options.uiDeadlineMs);
    const int id = r->id;
    connect(&r->deadline, &QTimer::timeout, this, [this, id] {
        qWarning("grassfield-portal: the panel did not show within %d ms; the request goes to x-d-p-gtk", m_options.uiDeadlineMs);
        forward(id);
    });
    r->deadline.start();
    // The folders the panel may start in are asked about off the GUI thread first (FC7): the application's, the remembered
    // one and each place, a call each at once, so that none, hung, keeps the others from answering (re-reviews of 65311e0
    // and 24bdf58, MAJOR 1). One that does not answer in time is passed over, as one that does not exist is.
    QVariantMap qml = chooser::toQml(parsed);
    const QVariantMap places = placeUrls();
    QStringList placeList;
    for (const char *place : {"home", "documents", "desktop", "downloads"})
        placeList << places.value(QLatin1String(place)).toString();
    placeList.removeAll(QString());
    struct Gathered {
        int waiting = 0;
        QVariantMap kinds;
    };
    auto gathered = std::make_shared<Gathered>();
    const auto gather = [this, id, qml, places, gathered](const QVariantMap &kinds) mutable {
        mergeKinds(gathered->kinds, kinds);
        if (--gathered->waiting > 0)
            return;
        const auto shown = m_requests.value(id);
        if (!shown || shown->state != Request::State::Making)
            return;
        QVariantMap answered;
        for (auto it = places.cbegin(); it != places.cend(); ++it) {
            const bool folder = gathered->kinds.value(it.value().toString()).toInt() == 2 || it.key() == QLatin1String("home");
            answered.insert(it.key(), folder ? it.value() : QString());
        }
        qml.insert(QStringLiteral("places"), answered);
        qml.insert(QStringLiteral("folderKinds"), gathered->kinds);
        emit opened(id, qml);
    };
    QStringList calls{qml.value(QStringLiteral("currentFolder")).toString(), memory(parsed.appId).value(QStringLiteral("folder")).toString()};
    calls << placeList;
    calls.removeAll(QString());
    calls.removeDuplicates();
    gathered->waiting = int(calls.size());
    for (const QString &url : std::as_const(calls))
        askDisk({url}, gather);
}

void FileChooser::present(int id, QObject *object)
{
    const auto r = m_requests.value(id);
    auto *window = qobject_cast<QWindow *>(object);
    if (!r || r->state != Request::State::Making || r->window)
        return;
    if (!window) {
        fail(id);
        return;
    }
    r->window = window;
    if (auto *quick = qobject_cast<QQuickWindow *>(window)) {
        connect(quick, &QQuickWindow::frameSwapped, this, [this, id] {
            const auto shown = m_requests.value(id);
            if (!shown || shown->state != Request::State::Making)
                return;
            shown->state = Request::State::Shown;
            shown->deadline.stop();
            qInfo("grassfield-portal: panel shown in %lld ms", static_cast<long long>(shown->since.elapsed()));
        });
    }
    // The toplevel takes the application's id when Qt makes it (QWindow::show), and the application's window as its
    // parent through xdg-foreign v2 (KWindowSystem waits for the toplevel). Hyprland then centres the panel over that
    // window, and xdg-dialog's modal (the window's modality, set by the QML) dims and blocks it.
    const QString own = QGuiApplication::desktopFileName();
    QGuiApplication::setDesktopFileName(windowAppId(r->request.appId));
    if (QGuiApplication::platformName() == QLatin1String("wayland") && r->request.parentWindow.startsWith(QLatin1String("wayland:"))
        && r->request.parentWindow.size() > 8)
        KWindowSystem::setMainWindow(window, r->request.parentWindow.mid(8));
    window->show();
    QGuiApplication::setDesktopFileName(own);
}

void FileChooser::answer(int id, int response, const QVariantMap &given)
{
    const auto r = m_requests.value(id);
    if (!r || r->state == Request::State::Forwarded)
        return;
    if (response == 1) {
        finish(id, 1, {});
        return;
    }
    const chooser::Results results = response == 0 ? chooser::results(r->request, given) : chooser::Results{};
    if (!results.ok) {
        qWarning("grassfield-portal: %s: the panel's answer breaks the interface; the request ends with an error",
                 qPrintable(r->message.member()));
        finish(id, 2, {});
        return;
    }
    finish(id, 0, results.map);
}

void FileChooser::fail(int id)
{
    const auto r = m_requests.value(id);
    if (!r || r->state == Request::State::Forwarded)
        return;
    qWarning("grassfield-portal: the panel could not be made; the request goes to x-d-p-gtk");
    forward(id);
}

void FileChooser::close(const QString &handle)
{
    for (const auto &r : std::as_const(m_requests)) {
        if (r->handle != handle)
            continue;
        if (r->state == Request::State::Forwarded) {
            closeForwarded(r->id, kCloseTries);
            return;
        }
        finish(r->id, 2, {});
        return;
    }
}

// x-d-p-gtk ends its own dialog; its answer comes back through the forwarded call. GDBus routes a call to an object path as
// soon as it reads it, which can be before x-d-p-gtk's handler of the forwarded call has exported that call's Request
// object (both queued while D-Bus activation starts it): a Close that finds no object is sent again shortly, while the
// request is still forwarded (counter-review of step 4b, NIT-4).
void FileChooser::closeForwarded(int id, int tries)
{
    const auto r = m_requests.value(id);
    if (!r || r->state != Request::State::Forwarded)
        return;
    const QDBusMessage close = QDBusMessage::createMethodCall(m_options.gtkService, r->handle, QString::fromLatin1(kRequestInterface),
                                                              QStringLiteral("Close"));
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(close), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, id, tries](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const QDBusError::ErrorType error = w->error().type();
        if (tries > 1 && (error == QDBusError::UnknownMethod || error == QDBusError::UnknownObject || error == QDBusError::UnknownInterface))
            QTimer::singleShot(kCloseRetryMs, this, [this, id, tries] { closeForwarded(id, tries - 1); });
    });
}

QVariantMap FileChooser::memory(const QString &appId) const
{
    if (!m_options.state)
        return {};
    const PanelState::Entry e = m_options.state->entry(appId);
    return {{QStringLiteral("folder"), e.folder}, {QStringLiteral("view"), e.view}, {QStringLiteral("expanded"), e.expanded}};
}

void FileChooser::remember(const QString &appId, const QVariantMap &entry)
{
    if (!m_options.state)
        return;
    PanelState::Entry e;
    e.folder = entry.value(QStringLiteral("folder")).toString();
    e.view = entry.value(QStringLiteral("view")).toString();
    e.expanded = entry.value(QStringLiteral("expanded")).toBool();
    m_options.state->remember(appId, e);
}

QVariantMap FileChooser::placeUrls() const
{
    // The addresses only: whether each is a folder is the probe's question.
    const auto folder = [](QStandardPaths::StandardLocation location) {
        const QString path = QStandardPaths::writableLocation(location);
        return path.isEmpty() || QDir::cleanPath(path) == QDir::cleanPath(QDir::homePath()) ? QString()
                                                                                            : QUrl::fromLocalFile(path).toString(QUrl::FullyEncoded);
    };
    return {{QStringLiteral("home"), QUrl::fromLocalFile(QDir::homePath()).toString(QUrl::FullyEncoded)},
            {QStringLiteral("desktop"), folder(QStandardPaths::DesktopLocation)},
            {QStringLiteral("documents"), folder(QStandardPaths::DocumentsLocation)},
            {QStringLiteral("downloads"), folder(QStandardPaths::DownloadLocation)}};
}

int FileChooser::askDisk(const QStringList &urls, std::function<void(const QVariantMap &)> done)
{
    // Tolerant, as the panels' answers: QML prints a URL with its spaces as they are.
    // The paths in the order given (re-review of 24bdf58: a hash's order changes from one process to the next).
    QVariantMap kinds;
    QStringList paths;
    QHash<QString, QStringList> urlsOf;
    for (const QString &text : urls) {
        const QUrl url(text);
        const QString path = url.isLocalFile() ? QDir::cleanPath(url.toLocalFile()) : QString();
        if (!url.isValid() || !url.host().isEmpty() || url.hasQuery() || url.hasFragment() || !path.startsWith(u'/')) {
            kinds.insert(text, -1);
            continue;
        }
        if (!urlsOf.contains(path))
            paths << path;
        urlsOf[path].append(text);
    }
    const int token = m_disk.probe(paths);
    m_diskAsked.insert(token, [kinds, urlsOf, done = std::move(done)](const QHash<QString, int> &answered) mutable {
        for (auto it = urlsOf.cbegin(); it != urlsOf.cend(); ++it)
            for (const QString &url : it.value())
                kinds.insert(url, answered.value(it.key(), kNotResponding));
        done(kinds);
    });
    return token;
}

void FileChooser::mergeKinds(QVariantMap &into, const QVariantMap &from)
{
    for (auto it = from.cbegin(); it != from.cend(); ++it)
        if (it.value().toInt() != kNotResponding || !into.contains(it.key()))
            into.insert(it.key(), it.value());
}

int FileChooser::probe(const QStringList &urls)
{
    auto token = std::make_shared<int>(0);
    *token = askDisk(urls, [this, token](const QVariantMap &kinds) { emit probed(*token, kinds); });
    return *token;
}

QString FileChooser::appName(const QString &appId) const
{
    const QString id = windowAppId(appId);
    if (appId.isEmpty() || id == QLatin1String("org.grassfield.Files"))
        return {};
    const KService::Ptr service = KService::serviceByDesktopName(id);
    return service ? service->name() : QString();
}

void FileChooser::finish(int id, uint response, const QVariantMap &results)
{
    const auto r = m_requests.take(id);
    if (!r)
        return;
    m_bus.send(r->message.createReply(QVariantList{QVariant::fromValue(response), results}));
    m_bus.unregisterObject(r->handle);
    emit closed(id);
    emit pendingChanged();
    armIdle();
}

void FileChooser::forward(int id)
{
    const auto r = m_requests.value(id);
    if (!r || r->state == Request::State::Forwarded)
        return;
    r->state = Request::State::Forwarded;
    r->deadline.stop();
    // The panel, if any, goes; the same call, with the same handle and options, goes to x-d-p-gtk.
    emit closed(id);
    QDBusMessage call = QDBusMessage::createMethodCall(m_options.gtkService, QString::fromLatin1(kPath), QString::fromLatin1(kInterface),
                                                       r->message.member());
    call.setArguments(r->message.arguments());
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(call, std::numeric_limits<int>::max()), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, id](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        const auto forwarded = m_requests.take(id);
        if (!forwarded)
            return;
        const QDBusMessage reply = w->reply();
        const QVariantList args = reply.arguments();
        uint response = 2;
        QVariantMap results;
        if (reply.type() == QDBusMessage::ReplyMessage && reply.signature() == QLatin1String("ua{sv}")) {
            response = args.at(0).toUInt();
            results = chooser::relayed(qdbus_cast<QVariantMap>(args.at(1)));
        } else {
            qWarning("grassfield-portal: x-d-p-gtk did not answer the forwarded request; it ends with an error");
        }
        m_bus.send(forwarded->message.createReply(QVariantList{QVariant::fromValue(response), results}));
        m_bus.unregisterObject(forwarded->handle);
        emit pendingChanged();
        armIdle();
    });
}

void FileChooser::armIdle()
{
    if (m_requests.isEmpty())
        m_idle.start();
}

FileChooserAdaptor::FileChooserAdaptor(FileChooser *chooser)
    : QDBusAbstractAdaptor(chooser)
    , m_chooser(chooser)
{
}

uint FileChooserAdaptor::OpenFile(const QDBusObjectPath &handle, const QString &app_id, const QString &parent_window, const QString &title,
                                  const QVariantMap &options, const QDBusMessage &message, QVariantMap &results)
{
    Q_UNUSED(results)
    m_chooser->handle(chooser::Kind::Open, handle, app_id, parent_window, title, options, message);
    return 2;
}

uint FileChooserAdaptor::SaveFile(const QDBusObjectPath &handle, const QString &app_id, const QString &parent_window, const QString &title,
                                  const QVariantMap &options, const QDBusMessage &message, QVariantMap &results)
{
    Q_UNUSED(results)
    m_chooser->handle(chooser::Kind::Save, handle, app_id, parent_window, title, options, message);
    return 2;
}

uint FileChooserAdaptor::SaveFiles(const QDBusObjectPath &handle, const QString &app_id, const QString &parent_window, const QString &title,
                                   const QVariantMap &options, const QDBusMessage &message, QVariantMap &results)
{
    Q_UNUSED(results)
    m_chooser->handle(chooser::Kind::SaveFiles, handle, app_id, parent_window, title, options, message);
    return 2;
}

} // namespace grassfield::portal
