// org.freedesktop.impl.portal.Access for the Grassfield session (ADR-0035 D-5; docs/specs/system-dialogs.md section 2,
// AC1-AC3): xdg-desktop-portal's permission questions (the camera, location, screenshots, the wallpaper, running in the
// background) become a Grassfield alert (apps/files/qml/AccessAlerts.qml), answered 0 (grant) or 1 (deny) with the
// choices. The frontend keeps the answer in its permission store, which Settings > Privacy & Security reads.
//
// The request lifecycle is RequestHost's: a Request object at the frontend's handle, the 3-s forward to x-d-p-gtk's Access
// when the alert cannot show, and the idle quit. The frontend waits on this call without a timeout, so an alert asked while
// the session is locked opens under the lock and waits there for the user (5a-3): nothing is answered for them. A request
// that ends without the user's answer (refused, closed, its forward failed) ends with a D-Bus error, never a response the
// frontend would keep as "no".
#pragma once

#include "chooserlogic.h"
#include "requesthost.h"

#include <QDBusAbstractAdaptor>
#include <QHash>
#include <QVariantList>
#include <QVariantMap>

namespace grassfield::portal {

class Access : public RequestHost
{
    Q_OBJECT

public:
    struct Options {
        // The backend x-d-p-gtk serves Access under (the forward of FC7).
        QString gtkService = QStringLiteral("org.freedesktop.impl.portal.desktop.gtk");
        int uiDeadlineMs = 3000;
        int idleQuitMs = 60000;
        int maxPending = 16;
    };

    Access(const QDBusConnection &bus, const Options &options, QObject *parent = nullptr);

    // The D-Bus method (AccessAdaptor): a delayed reply, sent when the request ends.
    void handle(const QDBusObjectPath &handle, const QString &appId, const QString &parentWindow, const QString &title,
                const QString &subtitle, const QString &body, const QVariantMap &options, const QDBusMessage &message);
    // The user's answer: grant (response 0) or deny (1), with the choices' values ([{id, value}]). An answer for a request
    // that is no longer shown is ignored.
    Q_INVOKABLE void answer(int id, bool grant, const QVariantList &choices = {});

    // What the alert shows, checked (pure; the tests read it): {appId, title, subtitle, body (the frontend's own wording in
    // Grassfield's language), denyLabel, grantLabel ("" for Grassfield's own, also in place of the frontend's own labels), icon
    // (a symbolic icon name, "" when none or not one), modal, parented, noDefault (the camera and screen capture: neither
    // button is the default, AC2), choices (chooser::choicesToQml)}.
    static QVariantMap toQml(const QString &appId, const QString &parentWindow, const QString &title, const QString &subtitle,
                             const QString &body, const QVariantMap &options);

signals:
    // An alert to make for request `id` (toQml, with the application's icon as appIcon).
    void opened(int id, const QVariantMap &alert);

protected:
    QVariantMap relayed(const QVariantMap &gtkResults) const override;
    void ended(int id) override { m_choices.remove(id); }

private:
    // The choices each open request asked (answer() checks the values against them).
    QHash<int, QList<chooser::Choice>> m_choices;
};

// The interface on /org/freedesktop/portal/desktop (the object FileChooser is exported as; this adaptor is its child and
// calls into Access).
class AccessAdaptor : public QDBusAbstractAdaptor
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.freedesktop.impl.portal.Access")

public:
    AccessAdaptor(QObject *exported, Access *access);

public Q_SLOTS:
    uint AccessDialog(const QDBusObjectPath &handle, const QString &app_id, const QString &parent_window, const QString &title,
                      const QString &subtitle, const QString &body, const QVariantMap &options, const QDBusMessage &message,
                      QVariantMap &results);

private:
    Access *m_access;
};

} // namespace grassfield::portal
