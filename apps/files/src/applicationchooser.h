#pragma once

#include <QHash>
#include <QList>
#include <QObject>
#include <QPointer>
#include <QStringList>
#include <QUrl>
#include <QVariantMap>

#include <functional>
#include <memory>

// Files' own Choose Application panels (ADR-0035 D-5, step 5c; docs/specs/system-dialogs.md section 2, OW2): Open With >
// Other… and KIO's question when a document's type has no application set (GrassfieldOpenWithHandler, once its sheet's
// Choose Application… is pressed) open grassfield-portal's Choose Application panel (qml/FilePanel.qml, kind "application")
// over the Files window the user works in (qml/Main.qml). The panel answers here as it answers AppChooser in the portal:
// answer(id, 0, {choice: a desktop id}) or answer(id, 1).
class ApplicationChooser : public QObject
{
    Q_OBJECT

public:
    // The chosen application's desktop id (its desktop file's id without ".desktop", as the Applications location names
    // it), or "" for none (Cancel, Esc, the panel closed, an application that is no longer installed).
    using Answer = std::function<void(const QString &desktopId)>;

    explicit ApplicationChooser(QObject *parent = nullptr);

    // A panel to open `urls` with an application (their type: `mimeType`, or the first item's when empty). `answer` runs
    // once, after the panel has gone and the call that answered has returned. The panel stands while `owner` exists and,
    // when the owner is a job, while it runs (KIO closes its own dialog when the job ends); then it closes and `answer`
    // never runs. No owner: it waits for the user. With nothing connected to opened(), the answer is none at once.
    int ask(const QList<QUrl> &urls, const QString &mimeType, QObject *owner, const Answer &answer);
    // The panel's answer: response 0 with {choice: an installed application's desktop id}; anything else is none. An answer
    // for a panel that is gone is ignored.
    Q_INVOKABLE void answer(int id, int response, const QVariantMap &answer = {});

    // What the panel is given (pure; the tests read it): FilePanel's request map with kind "application", the keys
    // grassfield-portal's AppChooser::toQml gives, and `count`, the number of documents: {kind, appId "", title "",
    // acceptLabel "", modal, parented, multiple, directory, filters, currentFilter, choices, currentName, files,
    // currentFolder, applications (the candidates), lastChoice (the type's default application, or ""), filename (the one
    // document's name, or ""), uri "", count}.
    static QVariantMap request(const QString &filename, int count, const QStringList &candidates, const QString &lastChoice);
    // The desktop ids of the applications that open `mimeType` (KDE's associations, the user's own first), Files left out,
    // and the type's default one.
    static QStringList candidates(const QString &mimeType);
    static QString defaultApplication(const QString &mimeType);

signals:
    // A panel to make for request `id` (request()).
    void opened(int id, const QVariantMap &request);
    // Request `id` ended (answered, or its owner went): its panel goes.
    void closed(int id);

private:
    struct Pending {
        Answer answer;
        QPointer<QObject> owner;
        bool owned = false;
        // Set when the job ends, and kept by the answer that may still be on its way.
        std::shared_ptr<bool> ended;
        QList<QMetaObject::Connection> connections;
    };
    void withdraw(int id);

    QHash<int, Pending> m_pending;
    int m_next = 1;
};
