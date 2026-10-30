// org.freedesktop.impl.portal.FileChooser for the Grassfield session (ADR-0035 D-4; docs/specs/system-dialogs.md section 1):
// every OpenFile, SaveFile and SaveFiles of xdg-desktop-portal becomes a Grassfield panel (the QML of apps/files/qml,
// FilePanels.qml), answered when the user is done. Each call is a Request object at the frontend's handle (Close ends it).
//
// Never block, never lose (D-4, FC7): a panel that has not drawn its first frame 3 s after the call (the QML failed, the Qt
// platform failed, a panel could not be made) is dropped and the same call goes to x-d-p-gtk's backend, whose answer is
// relayed as it is; a process without a usable UI forwards every call at once (RequestHost). The process quits 60 s after
// its last request ended (D-Bus activation starts it again at the next call).
#pragma once

#include "chooserlogic.h"
#include "diskprobe.h"
#include "requesthost.h"

#include <QDBusAbstractAdaptor>
#include <QHash>
#include <QStringList>
#include <QVariantMap>

#include <functional>

namespace grassfield::portal {

class PanelState;

class FileChooser : public RequestHost
{
    Q_OBJECT

public:
    struct Options {
        // The backend x-d-p-gtk serves FileChooser under (the forward of FC7).
        QString gtkService = QStringLiteral("org.freedesktop.impl.portal.desktop.gtk");
        int uiDeadlineMs = 3000;
        int idleQuitMs = 60000;
        // At most this many requests at once; one more ends with response 2 at once (an app that loops cannot pile up
        // windows).
        int maxPending = 16;
        // The per-application memory of the panels (null: none).
        PanelState *state = nullptr;
        // How long the panels wait on the disk (probe, DiskProbe): no answer for probeDeadlineMs, or probeTotalMs in all,
        // and a path not answered is "not responding".
        int probeDeadlineMs = 1000;
        int probeTotalMs = 5000;
        // What a local path names, read on a probe thread (empty: DiskProbe::kindOf; the tests give a slow one).
        std::function<int(const QString &path)> statPath;
    };

    FileChooser(const QDBusConnection &bus, const Options &options, QObject *parent = nullptr);

    // The D-Bus methods (FileChooserAdaptor): a delayed reply, sent when the request ends.
    void handle(chooser::Kind kind, const QDBusObjectPath &handle, const QString &appId, const QString &parentWindow,
                const QString &title, const QVariantMap &options, const QDBusMessage &message);

    // The user's answer: 0 (with `answer`, chooserlogic's results), 1 cancelled. An answer for a request that is no longer
    // shown is ignored.
    Q_INVOKABLE void answer(int id, int response, const QVariantMap &answer = {});
    // The panels' memory of an application: {folder, view, expanded} ("" fields when nothing is kept).
    Q_INVOKABLE QVariantMap memory(const QString &appId) const;
    Q_INVOKABLE void remember(const QString &appId, const QVariantMap &entry);
    // The panels' questions to the disk, never asked on the GUI thread (FC7; integrator review of bd78424, MAJOR 1): what each
    // URL names, answered by probed(token, {url: kind}) as DiskProbe answers its paths: kNotResponding for a path that has
    // not answered, -1 for anything but a local file URL, else DiskProbe::kindOf's. Returns the token.
    Q_INVOKABLE int probe(const QStringList &urls);
    static constexpr int kNotResponding = DiskProbe::kNotResponding;
    // Merges answers about the same URLs from several calls (the panel's start folders): a real answer wins over "not
    // responding", whichever comes first (re-review of 24bdf58, MAJOR 1).
    static void mergeKinds(QVariantMap &into, const QVariantMap &from);

signals:
    // A panel to make for request `id`: chooser::toQml, with `places` (the standard folders that answered as folders,
    // {home, desktop, documents, downloads}; "" for the others, home always) and `folderKinds` ({url: kind} of the folders
    // a panel may start in: the application's, the remembered one, the places), probed first.
    void opened(int id, const QVariantMap &request);
    // The answer to probe(urls).
    void probed(int token, const QVariantMap &kinds);

protected:
    QVariantMap relayed(const QVariantMap &gtkResults) const override { return chooser::relayed(gtkResults); }
    void ended(int id) override { m_parsed.remove(id); }

private:
    // Asks the disk about `urls` (file URLs as given, read in that order); done({url: kind}) when DiskProbe answers, never
    // from inside the call. Returns DiskProbe's token.
    int askDisk(const QStringList &urls, std::function<void(const QVariantMap &kinds)> done);
    QVariantMap placeUrls() const;

    Options m_options;
    // What each open request asked, checked (answer() reads it).
    QHash<int, chooser::Request> m_parsed;
    DiskProbe m_disk;
    QHash<int, std::function<void(const QHash<QString, int> &)>> m_diskAsked;
};

// The interface on /org/freedesktop/portal/desktop.
class FileChooserAdaptor : public QDBusAbstractAdaptor
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.freedesktop.impl.portal.FileChooser")

public:
    explicit FileChooserAdaptor(FileChooser *chooser);

public Q_SLOTS:
    uint OpenFile(const QDBusObjectPath &handle, const QString &app_id, const QString &parent_window, const QString &title,
                  const QVariantMap &options, const QDBusMessage &message, QVariantMap &results);
    uint SaveFile(const QDBusObjectPath &handle, const QString &app_id, const QString &parent_window, const QString &title,
                  const QVariantMap &options, const QDBusMessage &message, QVariantMap &results);
    uint SaveFiles(const QDBusObjectPath &handle, const QString &app_id, const QString &parent_window, const QString &title,
                   const QVariantMap &options, const QDBusMessage &message, QVariantMap &results);

private:
    FileChooser *m_chooser;
};

} // namespace grassfield::portal
