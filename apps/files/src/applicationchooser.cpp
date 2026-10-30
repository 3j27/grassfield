#include "applicationchooser.h"

#include "filelogic.h"

#include <QMetaMethod>
#include <QMimeDatabase>
#include <QTimer>

#include <KApplicationTrader>
#include <KJob>
#include <KService>

namespace
{
// A service's desktop id as the Applications location names it (its menu id without ".desktop"); "" for a service outside
// the applications folders (the location never lists it) and for Files itself (it opens no document "with").
QString desktopId(const KService::Ptr &service)
{
    if (!service)
        return {};
    QString id = service->menuId();
    if (!id.endsWith(QLatin1String(".desktop")))
        return {};
    id.chop(8);
    return id.compare(QLatin1String("org.grassfield.Files"), Qt::CaseInsensitive) == 0 ? QString() : id;
}
} // namespace

ApplicationChooser::ApplicationChooser(QObject *parent)
    : QObject(parent)
{
}

QStringList ApplicationChooser::candidates(const QString &mimeType)
{
    QStringList out;
    if (mimeType.isEmpty())
        return out;
    const KService::List services = KApplicationTrader::queryByMimeType(mimeType);
    for (const KService::Ptr &s : services) {
        const QString id = desktopId(s);
        if (!id.isEmpty() && !out.contains(id))
            out.append(id);
    }
    return out;
}

QString ApplicationChooser::defaultApplication(const QString &mimeType)
{
    return mimeType.isEmpty() ? QString() : desktopId(KApplicationTrader::preferredService(mimeType));
}

QVariantMap ApplicationChooser::request(const QString &filename, int count, const QStringList &candidates, const QString &lastChoice)
{
    return {
        {QStringLiteral("kind"), QStringLiteral("application")},
        {QStringLiteral("appId"), QString()},
        // The panel's own title and button (Choose Application, Open).
        {QStringLiteral("title"), QString()},
        {QStringLiteral("acceptLabel"), QString()},
        // Modal to the Files window it opens over (qml/Main.qml gives it that window).
        {QStringLiteral("modal"), true},
        {QStringLiteral("parented"), true},
        {QStringLiteral("multiple"), false},
        {QStringLiteral("directory"), false},
        {QStringLiteral("filters"), QVariantList()},
        {QStringLiteral("currentFilter"), -1},
        {QStringLiteral("choices"), QVariantList()},
        {QStringLiteral("currentName"), QString()},
        {QStringLiteral("files"), QVariantList()},
        {QStringLiteral("currentFolder"), QString()},
        {QStringLiteral("applications"), candidates},
        {QStringLiteral("lastChoice"), lastChoice},
        {QStringLiteral("filename"), count == 1 ? filename : QString()},
        {QStringLiteral("uri"), QString()},
        {QStringLiteral("count"), count},
    };
}

int ApplicationChooser::ask(const QList<QUrl> &urls, const QString &mimeType, QObject *owner, const Answer &answer)
{
    const int id = m_next++;
    QString type = mimeType;
    if (type.isEmpty() && !urls.isEmpty()) {
        const QMimeDatabase db;
        const QUrl &first = urls.first();
        type = (first.isLocalFile() ? db.mimeTypeForFile(first.toLocalFile()) : db.mimeTypeForUrl(first)).name();
    }
    const QString name = urls.isEmpty() ? QString() : urls.first().adjusted(QUrl::StripTrailingSlash).fileName();
    QVariantMap r = request(FileLogic::displayName(name), int(urls.size()), candidates(type), defaultApplication(type));
    // One document with no file name (a server's root): the panel names its address (review of step 5c, NIT), never its
    // password (integrator review of step 5c's PR, NIT 4).
    if (urls.size() == 1 && name.isEmpty())
        r.insert(QStringLiteral("uri"), urls.first().toDisplayString());

    Pending pending{answer, owner, owner != nullptr, std::make_shared<bool>(false), {}};
    if (owner) {
        pending.connections << connect(owner, &QObject::destroyed, this, [this, id] {
            withdraw(id);
        });
    }
    if (auto *job = qobject_cast<KJob *>(owner)) {
        // Kept past the answer: a job that ends before the answer is delivered gets none.
        const auto ended = pending.ended;
        connect(job, &KJob::finished, this, [ended] {
            *ended = true;
        });
        pending.connections << connect(job, &KJob::finished, this, [this, id] {
            withdraw(id);
        });
    }
    m_pending.insert(id, pending);
    // Nobody makes panels in this process (grassfield-portal's FilesApp): none, rather than a job waiting for ever (review
    // of step 5c, NIT).
    if (!isSignalConnected(QMetaMethod::fromSignal(&ApplicationChooser::opened))) {
        qWarning("grassfield-files: no Choose Application panel can show here; nothing is chosen");
        QTimer::singleShot(0, this, [this, id] {
            this->answer(id, 1);
        });
        return id;
    }
    emit opened(id, r);
    return id;
}

void ApplicationChooser::answer(int id, int response, const QVariantMap &answer)
{
    const auto it = m_pending.constFind(id);
    if (it == m_pending.constEnd())
        return;
    const Pending p = it.value();
    m_pending.remove(id);
    for (const QMetaObject::Connection &c : p.connections)
        disconnect(c);
    emit closed(id);
    QString chosen;
    if (response == 0) {
        const QVariant choice = answer.value(QStringLiteral("choice"));
        // An application the panel listed may have been removed since: none then, never another one.
        if (choice.metaType() == QMetaType::fromType<QString>() && !choice.toString().isEmpty() && !choice.toString().contains(QLatin1Char('/'))
            && KService::serviceByMenuId(choice.toString() + QLatin1String(".desktop")))
            chosen = choice.toString();
        else
            qWarning("grassfield-files: the chosen application is not installed; nothing opens");
    }
    // After the call that answered returns (the panel's), and only while the owner exists (and its job runs).
    QTimer::singleShot(0, this, [p, chosen] {
        if (!p.owned || (p.owner && !*p.ended))
            p.answer(chosen);
    });
}

void ApplicationChooser::withdraw(int id)
{
    const auto it = m_pending.constFind(id);
    if (it == m_pending.constEnd())
        return;
    for (const QMetaObject::Connection &c : it.value().connections)
        disconnect(c);
    m_pending.remove(id);
    emit closed(id);
}
