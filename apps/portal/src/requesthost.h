// The request lifecycle every interface of grassfield-portal shares (ADR-0035 D-4, D-5): each call of the frontend gets a
// delayed reply and a Request object at the frontend's handle (Close ends it); at most maxPending are open at once; the UI is
// made at the first request; a window that has not drawn its first frame uiDeadlineMs after the call is dropped and the same
// call goes to x-d-p-gtk's backend, whose answer is relayed (FC7: never block, never lose); a process without a usable UI
// forwards every call at once; idle() follows idleQuitMs after the last request ended. FileChooser and Access build on it.
#pragma once

#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusObjectPath>
#include <QElapsedTimer>
#include <QHash>
#include <QObject>
#include <QTimer>
#include <QVariantMap>

#include <functional>
#include <memory>

namespace grassfield::portal {

class RequestHost : public QObject
{
    Q_OBJECT
    // Requests not yet answered (shown, being made, or forwarded).
    Q_PROPERTY(int pending READ pending NOTIFY pendingChanged)

public:
    struct Limits {
        // The backend x-d-p-gtk serves the interface under (the forward of FC7).
        QString gtkService;
        int uiDeadlineMs = 3000;
        int idleQuitMs = 60000;
        // At most this many requests at once; one more ends at once (an app that loops cannot pile up windows).
        int maxPending = 16;
        // How a request ends without the user's answer (refused, closed, its forward failed, the process going): response 2,
        // or a D-Bus error (Access: the frontend keeps any response but 0 as "no" for a permission not decided yet, and
        // nothing after an error; ADR-0035 5a-3).
        bool failAsError = false;
    };

    // `interface`: the D-Bus interface the calls came on, and the one they are forwarded on.
    RequestHost(const QDBusConnection &bus, const QString &interface, const Limits &limits, QObject *parent = nullptr);
    ~RequestHost() override;

    // How the UI is made (the QML on a working Qt platform): once, at the first request, so that an idle start costs nothing.
    // Its result is kept: false, or no loader, and every call is forwarded.
    void setUiLoader(std::function<bool()> loader) { m_uiLoader = std::move(loader); }
    bool uiReady() const { return m_uiReady; }
    int pending() const { return int(m_requests.size()); }

    // org.freedesktop.impl.portal.Request.Close at `handle`.
    void close(const QString &handle);
    // How long no request has been open, in ms (0 while one is).
    qint64 quietFor() const;
    // Every host has had no request for `ms` (the process may quit).
    static bool quiet(const QList<const RequestHost *> &hosts, int ms);
    // For the QML: the window made for request `id`, before it is shown. It is given the application's id, made the child of
    // the application's window (xdg-foreign v2, "wayland:" handles only) and shown; its first frame cancels the forward.
    Q_INVOKABLE void present(int id, QObject *window);
    // The window for `id` cannot be made: the call goes to x-d-p-gtk now.
    Q_INVOKABLE void fail(int id);
    // The application's name as its desktop entry gives it in the UI language, "" when the frontend could not name it or it
    // has no entry.
    Q_INVOKABLE QString appName(const QString &appId) const;

    // The Wayland app id a window of `appId` gets (exposed for the tests): the application's own when the frontend named it
    // (a desktop id), so the window counts as that application's (Dock, menu bar, Force Quit), as a macOS sheet does;
    // org.grassfield.Files otherwise.
    static QString windowAppId(const QString &appId);

signals:
    // Request `id` ended without the window's answer (Close, the deadline, the forward): its window goes.
    void closed(int id);
    void pendingChanged();
    // Nothing happened for idleQuitMs: the process may quit.
    void idle();

protected:
    // A new request at `handle` for `message` (made a delayed reply here). Refused with response 2 (and 0 returned) when the
    // limit is reached, the handle is already open or its object cannot be exported; else its id.
    int begin(const QDBusObjectPath &handle, const QDBusMessage &message, const QString &appId, const QString &parentWindow);
    // After begin(): makes the UI at the first request; without one the call is forwarded and false returned; else the
    // deadline runs and true is returned (the caller then asks the QML for the window).
    bool startUi(int id);
    // Answers request `id` (an answer for a request that is gone or forwarded is ignored).
    void finish(int id, uint response, const QVariantMap &results);
    // Sends the call to x-d-p-gtk; its window, if any, goes.
    void forward(int id);
    // The request is open and its window not shown yet / open and not forwarded.
    bool isMaking(int id) const;
    bool isOpen(int id) const;
    // Ends the call at once without an answer (response 2, or a D-Bus error with failAsError), the reason logged.
    void refuse(const QDBusMessage &message, const char *why);
    // The results of a forwarded call, relayed with their D-Bus types (only what the interface defines).
    virtual QVariantMap relayed(const QVariantMap &gtkResults) const = 0;
    // Request `id` is gone (answered, or its forward answered): what the subclass kept of it can go.
    virtual void ended(int id) { Q_UNUSED(id) }

    QDBusConnection m_bus;

private:
    struct Request;
    void closeForwarded(int id, int tries);
    void armIdle();
    // Ends request `id` without the user's answer (see Limits::failAsError).
    void endWithoutAnswer(int id);
    void replyFailed(const QDBusMessage &message, const char *why);

    QString m_interface;
    Limits m_limits;
    QElapsedTimer m_quiet;
    std::function<bool()> m_uiLoader;
    bool m_uiReady = false;
    int m_nextId = 1;
    QHash<int, std::shared_ptr<Request>> m_requests;
    QTimer m_idle;
};

// org.freedesktop.impl.portal.Request at a request's handle: Close() ends it (the application went away or cancelled).
class RequestObject : public QObject
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.freedesktop.impl.portal.Request")

public:
    RequestObject(RequestHost *host, const QString &handle)
        : m_host(host)
        , m_handle(handle)
    {
    }

public Q_SLOTS:
    Q_SCRIPTABLE void Close() { m_host->close(m_handle); }

private:
    RequestHost *m_host;
    QString m_handle;
};

} // namespace grassfield::portal
