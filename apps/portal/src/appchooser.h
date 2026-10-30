// org.freedesktop.impl.portal.AppChooser for the Grassfield session (ADR-0035 D-5, step 5b; docs/specs/system-dialogs.md
// section 2, OW1): xdg-desktop-portal's Open With question (an application opens a document through the OpenURI portal and the
// frontend cannot pick the application itself: several candidates and no choice made often enough, src/open-uri.c) becomes
// the macOS Choose Application panel: the Open panel (apps/files/qml/FilePanel.qml) in the Applications location, the
// frontend's candidates enabled ("Recommended Applications"), the others dimmed until "All Applications" is chosen. The answer
// is the chosen application's desktop id; the frontend starts it with the document and counts the choice (its own rule: the
// same application chosen often enough for the type, and it stops asking).
//
// The request lifecycle is RequestHost's (a Request object at the frontend's handle, Close, the 3-s forward to x-d-p-gtk's
// AppChooser when the panel cannot show, the idle quit). UpdateChoices changes the candidates of an open panel, or goes on to
// x-d-p-gtk for a forwarded request.
#pragma once

#include "requesthost.h"

#include <QDBusAbstractAdaptor>
#include <QHash>
#include <QStringList>
#include <QVariantMap>

namespace grassfield::portal {

class AppChooser : public RequestHost
{
    Q_OBJECT

public:
    struct Options {
        // The backend x-d-p-gtk serves AppChooser under (the forward of FC7).
        QString gtkService = QStringLiteral("org.freedesktop.impl.portal.desktop.gtk");
        int uiDeadlineMs = 3000;
        int idleQuitMs = 60000;
        int maxPending = 16;
    };

    AppChooser(const QDBusConnection &bus, const Options &options, QObject *parent = nullptr);

    // The D-Bus methods (AppChooserAdaptor). handle(): a delayed reply, sent when the request ends.
    void handle(const QDBusObjectPath &handle, const QString &appId, const QString &parentWindow, const QStringList &choices,
                const QVariantMap &options, const QDBusMessage &message);
    // From the caller of the request's ChooseApplication only (`sender`: the frontend's unique name); any other is ignored.
    void updateChoices(const QDBusObjectPath &handle, const QStringList &choices, const QString &sender);

    // The panel's answer: response 0 with {choice: a desktop id}, or 1 (Cancel). An answer for a request that is no longer
    // shown is ignored; a choice that is not a desktop id ends the request with response 2.
    Q_INVOKABLE void answer(int id, int response, const QVariantMap &answer = {});

    // What the panel is given, checked (pure; the tests read it): FilePanel's request map with kind "application":
    // {kind, appId, title, acceptLabel, modal, parented, multiple, directory, filters, currentFilter, choices, currentName,
    // files, currentFolder, applications (the candidates: desktop ids, at most kMaxApplications, each once, from the first
    // 4 * kMaxApplications given), lastChoice (a desktop id or ""), filename (a plain name or ""), uri (one line)}.
    static QVariantMap toQml(const QString &appId, const QString &parentWindow, const QStringList &choices,
                             const QVariantMap &options);
    // The desktop ids among `ids` (isDesktopId), each once, in order.
    static QStringList desktopIds(const QStringList &ids);
    static bool isDesktopId(const QString &id);

    static constexpr int kMaxApplications = 512;

signals:
    // A panel to make for request `id` (toQml).
    void opened(int id, const QVariantMap &request);
    // The frontend's new candidates for the open panel of request `id` (desktopIds).
    void applicationsChanged(int id, const QStringList &applications);

protected:
    QVariantMap relayed(const QVariantMap &gtkResults) const override;
    void ended(int id) override;
    void forwarded(int id) override;

private:
    void sendUpdate(const QDBusObjectPath &handle, const QStringList &choices);

    QString m_gtkService;
    // The activation token each open request came with: given back with the choice (the frontend starts the application
    // with it).
    QHash<int, QString> m_tokens;
    // Who called each open request's ChooseApplication (its UpdateChoices must come from there too), and the last candidates
    // an UpdateChoices gave while the panel was open: they follow the request if it goes to x-d-p-gtk (integrator review of
    // f9a25ce, NITs).
    QHash<int, QString> m_callers;
    QHash<int, QPair<QDBusObjectPath, QStringList>> m_updated;
};

// The interface on /org/freedesktop/portal/desktop (the object FileChooser is exported as; this adaptor is its child and
// calls into AppChooser).
class AppChooserAdaptor : public QDBusAbstractAdaptor
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.freedesktop.impl.portal.AppChooser")

public:
    AppChooserAdaptor(QObject *exported, AppChooser *chooser);

public Q_SLOTS:
    uint ChooseApplication(const QDBusObjectPath &handle, const QString &app_id, const QString &parent_window,
                           const QStringList &choices, const QVariantMap &options, const QDBusMessage &message,
                           QVariantMap &results);
    void UpdateChoices(const QDBusObjectPath &handle, const QStringList &choices, const QDBusMessage &message);

private:
    AppChooser *m_chooser;
};

} // namespace grassfield::portal
