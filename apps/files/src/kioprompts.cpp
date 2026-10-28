#include "kioprompts.h"

#include "filelogic.h"
#include "kiopromptlogic.h"

#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDateTime>
#include <QPointer>
#include <QSslCertificate>
#include <QSslError>
#include <QTimer>

#include <KFileUtils>
#include <KIO/CopyJob>
#include <KIO/Job>

#include <memory>

using namespace KioPromptLogic;

namespace
{
const QString kKind = QStringLiteral("kind");
const QString kButton = QStringLiteral("button");

// KDE's mnemonic markers ("&Forever"): "&&" is a literal "&".
QString withoutMnemonic(const QString &text)
{
    QString out;
    out.reserve(text.size());
    for (qsizetype i = 0; i < text.size(); ++i) {
        if (text.at(i) == QLatin1Char('&')) {
            if (i + 1 < text.size() && text.at(i + 1) == QLatin1Char('&')) {
                out += QLatin1Char('&');
                ++i;
            }
            continue;
        }
        out += text.at(i);
    }
    return out;
}

// The name a sheet shows for a URL: its file name, else the whole location.
QString itemName(const QUrl &url)
{
    const QString name = url.adjusted(QUrl::StripTrailingSlash).fileName();
    return FileLogic::displayName(name.isEmpty() ? url.toDisplayString(QUrl::PreferLocalFile) : name);
}

// KIO's unknown size is (filesize_t)-1.
qint64 knownSize(KIO::filesize_t size)
{
    return size == static_cast<KIO::filesize_t>(-1) ? -1 : static_cast<qint64>(size);
}

// The certificate chain, for the sheet's details: one entry per certificate, with the problems KIO's worker found in it
// (sslErrorData's "certificateErrors": per certificate, QSslError codes separated by tabs).
QVariantList describeChain(const QVariantMap &sslErrorData)
{
    const QStringList pems = sslErrorData.value(QStringLiteral("peerCertChain")).toStringList();
    const QStringList errors = sslErrorData.value(QStringLiteral("certificateErrors")).toStringList();
    QVariantList out;
    for (qsizetype i = 0; i < pems.size(); ++i) {
        const QSslCertificate cert(pems.at(i).toUtf8());
        QStringList problems;
        if (i < errors.size()) {
            for (const QString &code : errors.at(i).split(QLatin1Char('\t'), Qt::SkipEmptyParts))
                problems << QSslError(static_cast<QSslError::SslError>(code.toInt())).errorString();
        }
        if (cert.isNull()) {
            out << QVariantMap{{QStringLiteral("readable"), false}, {QStringLiteral("problems"), problems}};
            continue;
        }
        out << QVariantMap{{QStringLiteral("readable"), true},
                           // A certificate names what its maker chose: shown as a name is (no bidi override, no line break).
                           {QStringLiteral("subject"), FileLogic::displayName(cert.subjectDisplayName())},
                           {QStringLiteral("issuer"), FileLogic::displayName(cert.issuerDisplayName())},
                           {QStringLiteral("validFrom"), cert.effectiveDate()},
                           {QStringLiteral("validUntil"), cert.expiryDate()},
                           {QStringLiteral("sha256"), QString::fromLatin1(cert.digest(QCryptographicHash::Sha256).toHex(':').toUpper())},
                           {QStringLiteral("problems"), problems}};
    }
    return out;
}

KioPrompts *s_prompts = nullptr;

class GrassfieldJobUiDelegateFactory : public KIO::JobUiDelegateFactory
{
public:
    explicit GrassfieldJobUiDelegateFactory(KioPrompts *prompts)
        : m_prompts(prompts)
    {
    }

    KJobUiDelegate *createDelegate() const override
    {
        return new GrassfieldJobUiDelegate(m_prompts);
    }

    KJobUiDelegate *createDelegate(KJobUiDelegate::Flags flags, QWidget *window) const override
    {
        return new GrassfieldJobUiDelegate(m_prompts, flags, window);
    }

private:
    KioPrompts *m_prompts;
};

QList<QObject *> extensions(KioPrompts *prompts)
{
    return {new GrassfieldAskUserAction(prompts), new GrassfieldOpenWithHandler(prompts), new GrassfieldUntrustedProgramHandler(prompts)};
}
} // namespace

KioPrompts::KioPrompts(QObject *parent)
    : QObject(parent)
{
}

int KioPrompts::ask(const QVariantMap &request, QObject *owner, const Answer &answer)
{
    const int id = m_next++;
    QVariantMap r = request;
    r.insert(QStringLiteral("id"), id);
    auto *job = qobject_cast<KJob *>(owner);
    if (m_responder) {
        // As a sheet would: after the call that asked returns, and only while its owner exists (and its job runs).
        const auto responder = m_responder;
        const QPointer<QObject> guard(owner);
        const bool owned = owner != nullptr;
        const auto ended = std::make_shared<bool>(false);
        if (job) {
            connect(job, &KJob::finished, this, [ended] {
                *ended = true;
            });
        }
        QTimer::singleShot(0, this, [r, answer, responder, guard, owned, ended] {
            if (owned && (!guard || *ended))
                return;
            answer(responder(r));
        });
        return id;
    }
    Pending pending{id, r, answer, owner, owner != nullptr, {}};
    if (owner) {
        pending.connections << connect(owner, &QObject::destroyed, this, [this, id] {
            withdraw(id);
        });
    }
    if (job) {
        pending.connections << connect(job, &KJob::finished, this, [this, id] {
            withdraw(id);
        });
    }
    m_queue.append(pending);
    if (m_queue.size() == 1)
        emit currentChanged();
    return id;
}

void KioPrompts::tell(const QString &title, const QString &text)
{
    ask({{kKind, QStringLiteral("notice")}, {QStringLiteral("title"), title}, {QStringLiteral("text"), text}}, nullptr, [](const QVariantMap &) {});
}

void KioPrompts::reply(int id, const QVariantMap &reply)
{
    for (qsizetype i = 0; i < m_queue.size(); ++i) {
        if (m_queue.at(i).id != id)
            continue;
        const Pending p = m_queue.takeAt(i);
        forget(p);
        if (i == 0)
            emit currentChanged();
        // After the caller returns: KIO connects to some answers only once it has asked (the certificate's,
        // usernotificationhandler.cpp:136-140), and a sheet may answer as it opens (a kind it does not know).
        QTimer::singleShot(0, this, [p, reply] {
            if (!p.owned || p.owner)
                p.answer(reply);
        });
        return;
    }
}

void KioPrompts::withdraw(int id)
{
    for (qsizetype i = 0; i < m_queue.size(); ++i) {
        if (m_queue.at(i).id != id)
            continue;
        forget(m_queue.takeAt(i));
        if (i == 0)
            emit currentChanged();
        return;
    }
}

void KioPrompts::forget(const Pending &pending)
{
    for (const QMetaObject::Connection &c : pending.connections)
        disconnect(c);
}

QVariantMap KioPrompts::current() const
{
    return m_queue.isEmpty() ? QVariantMap{} : m_queue.first().request;
}

void KioPrompts::setResponder(const std::function<QVariantMap(const QVariantMap &)> &responder)
{
    m_responder = responder;
}

GrassfieldAskUserAction::GrassfieldAskUserAction(KioPrompts *prompts, QObject *parent)
    : KIO::AskUserActionInterface(parent)
    , m_prompts(prompts)
{
}

void GrassfieldAskUserAction::askUserRename(KJob *job,
                                            const QString &,
                                            const QUrl &src,
                                            const QUrl &dest,
                                            KIO::RenameDialog_Options options,
                                            KIO::filesize_t sizeSrc,
                                            KIO::filesize_t sizeDest,
                                            const QDateTime &,
                                            const QDateTime &,
                                            const QDateTime &mtimeSrc,
                                            const QDateTime &mtimeDest)
{
    m_alwaysTrust.reset();
    const ConflictButtons b = conflictButtons(options);
    QString mode;
    if (auto *copyJob = qobject_cast<KIO::CopyJob *>(job)) {
        if (copyJob->operationMode() == KIO::CopyJob::Move)
            mode = QStringLiteral("move");
        else if (copyJob->operationMode() == KIO::CopyJob::Copy)
            mode = QStringLiteral("copy");
    }
    const QUrl folder = dest.adjusted(QUrl::RemoveFilename | QUrl::StripTrailingSlash);
    const QVariantMap request{
        {kKind, QStringLiteral("conflict")},
        {QStringLiteral("name"), itemName(dest)},
        {QStringLiteral("folder"), itemName(folder)},
        {QStringLiteral("mode"), mode},
        // Overwrite onto a folder: KIO writes into it (a merge), it does not replace it (RenameDialog's "Write Into",
        // renamedialog.cpp:304-312). KIO never offers Overwrite for a file onto a folder (copyjob.cpp:2521-2524), and a move
        // within one file system asks without SourceIsDirectory (copyjob.cpp:2521-2533).
        {QStringLiteral("merge"), options.testFlag(KIO::RenameDialog_Overwrite) && options.testFlag(KIO::RenameDialog_DestIsDirectory)},
        {QStringLiteral("destIsFolder"), options.testFlag(KIO::RenameDialog_DestIsDirectory)},
        {QStringLiteral("itself"), options.testFlag(KIO::RenameDialog_OverwriteItself)},
        {QStringLiteral("replace"), b.replace},
        {QStringLiteral("keepBoth"), b.keepBoth},
        {QStringLiteral("skip"), b.skip},
        {QStringLiteral("applyToAll"), b.applyToAll},
        {QStringLiteral("srcSize"), knownSize(sizeSrc)},
        {QStringLiteral("destSize"), knownSize(sizeDest)},
        {QStringLiteral("srcModified"), mtimeSrc},
        {QStringLiteral("destModified"), mtimeDest},
        {QStringLiteral("srcName"), itemName(src)},
    };
    m_prompts->ask(request, job, [self = QPointer<GrassfieldAskUserAction>(this), job, options, dest](const QVariantMap &reply) {
        if (!self)
            return;
        const QString button = reply.value(kButton).toString();
        const ConflictChoice choice = button == QLatin1String("keepBoth") ? ConflictChoice::KeepBoth
            : button == QLatin1String("skip")                             ? ConflictChoice::Skip
            : button == QLatin1String("replace")                          ? ConflictChoice::Replace
                                                                          : ConflictChoice::Stop;
        const KIO::RenameDialog_Result result = conflictResult(options, choice, reply.value(QStringLiteral("applyToAll")).toBool());
        QUrl newUrl;
        if (result == KIO::Result_Rename || result == KIO::Result_AutoRename) {
            // KIO's own suggestion (RenameDialog's "Suggest New Name", and what it names the next ones under Apply to All).
            const QUrl dir = dest.adjusted(QUrl::RemoveFilename);
            newUrl = dir;
            newUrl.setPath(dir.path() + KFileUtils::suggestName(dir, dest.fileName()));
        }
        Q_EMIT self->askUserRenameResult(result, newUrl, job);
    });
}

void GrassfieldAskUserAction::askUserSkip(KJob *job, KIO::SkipDialog_Options options, const QString &errorText)
{
    m_alwaysTrust.reset();
    const SkipButtons b = skipButtons(options);
    const QVariantMap request{
        {kKind, QStringLiteral("skip")},
        {QStringLiteral("text"), plainText(errorText)},
        {QStringLiteral("rename"), b.rename},
        {QStringLiteral("retry"), b.retry},
        {QStringLiteral("skip"), b.skip},
        {QStringLiteral("applyToAll"), b.applyToAll},
    };
    m_prompts->ask(request, job, [self = QPointer<GrassfieldAskUserAction>(this), job, options](const QVariantMap &reply) {
        if (!self)
            return;
        const QString button = reply.value(kButton).toString();
        const SkipChoice choice = button == QLatin1String("skip") ? SkipChoice::Skip
            : button == QLatin1String("rename")                   ? SkipChoice::Rename
            : button == QLatin1String("retry")                    ? SkipChoice::Retry
                                                                  : SkipChoice::Stop;
        Q_EMIT self->askUserSkipResult(skipResult(options, choice, reply.value(QStringLiteral("applyToAll")).toBool()), job);
    });
}

void GrassfieldAskUserAction::askUserDelete(const QList<QUrl> &urls, DeletionType deletionType, ConfirmationType confirmationType, QWidget *parent)
{
    m_alwaysTrust.reset();
    if (!deleteNeedsAsking(deletionType, confirmationType)) {
        Q_EMIT askUserDeleteResult(true, urls, deletionType, parent);
        return;
    }
    QString type;
    switch (deletionType) {
    case Delete:
        type = QStringLiteral("delete");
        break;
    case Trash:
        type = QStringLiteral("trash");
        break;
    case EmptyTrash:
        type = QStringLiteral("emptyTrash");
        break;
    case DeleteInsteadOfTrash:
        type = QStringLiteral("trashFull");
        break;
    case DeleteNoTrashAvailable:
        type = QStringLiteral("noTrash");
        break;
    }
    const QVariantMap request{
        {kKind, QStringLiteral("delete")},
        {QStringLiteral("type"), type},
        {QStringLiteral("count"), urls.size()},
        {QStringLiteral("name"), urls.isEmpty() ? QString() : itemName(urls.first())},
    };
    const QPointer<QWidget> window(parent);
    m_prompts->ask(request, this, [this, urls, deletionType, window](const QVariantMap &reply) {
        Q_EMIT askUserDeleteResult(reply.value(kButton).toString() == QLatin1String("delete"), urls, deletionType, window.data());
    });
}

void GrassfieldAskUserAction::requestUserMessageBox(MessageDialogType type,
                                                    const QString &text,
                                                    const QString &title,
                                                    const QString &primaryActionText,
                                                    const QString &secondaryActionText,
                                                    const QString &,
                                                    const QString &,
                                                    const QString &,
                                                    const QString &details,
                                                    QWidget *)
{
    // The question KIO's http worker asks next after "Continue" on the certificate sheet, on the same job (it may wait
    // behind another worker's message box: KIO asks them one at a time).
    const bool followUp = m_alwaysTrust.has_value() && type == WarningTwoActionsCancel;
    if (followUp) {
        const int answer = certificateFollowUpAnswer(*m_alwaysTrust);
        m_alwaysTrust.reset();
        QTimer::singleShot(0, this, [this, answer] {
            Q_EMIT messageBoxResult(answer);
        });
        return;
    }
    m_alwaysTrust.reset();
    const MessageButtons b = messageButtons(type);
    const QVariantMap request{
        {kKind, QStringLiteral("message")},
        {QStringLiteral("title"), plainText(title)},
        {QStringLiteral("text"), plainText(text)},
        {QStringLiteral("details"), plainText(details)},
        {QStringLiteral("primary"), withoutMnemonic(primaryActionText)},
        {QStringLiteral("secondary"), b.secondary ? withoutMnemonic(secondaryActionText) : QString()},
        {QStringLiteral("cancel"), b.cancel},
        {QStringLiteral("okOnly"), b.okOnly},
        {QStringLiteral("warning"), b.warning},
    };
    m_prompts->ask(request, this, [this, type](const QVariantMap &reply) {
        const QString button = reply.value(kButton).toString();
        const MessageButton choice = button == QLatin1String("primary") ? MessageButton::Primary
            : button == QLatin1String("secondary")                      ? MessageButton::Secondary
            : button == QLatin1String("ok")                             ? MessageButton::Ok
                                                                        : MessageButton::Cancel;
        int code = messageResult(type, choice);
        // A sheet closed another way: Cancel where the type has it, else the safe answer (OK, or the secondary action).
        if (code == 0)
            code = messageResult(type, MessageButton::Cancel);
        if (code == 0)
            code = messageResult(type, MessageButton::Ok);
        if (code == 0)
            code = messageResult(type, MessageButton::Secondary);
        Q_EMIT messageBoxResult(code);
    });
}

void GrassfieldAskUserAction::askIgnoreSslErrors(const QVariantMap &sslErrorData, QWidget *)
{
    m_alwaysTrust.reset();
    const QVariantMap request{
        {kKind, QStringLiteral("certificate")},
        {QStringLiteral("host"), FileLogic::displayName(sslErrorData.value(QStringLiteral("hostname")).toString())},
        {QStringLiteral("error"), plainText(sslErrorData.value(QStringLiteral("sslError")).toString())},
        {QStringLiteral("chain"), describeChain(sslErrorData)},
    };
    m_prompts->ask(request, this, [this](const QVariantMap &reply) {
        if (reply.value(kButton).toString() == QLatin1String("continue")) {
            m_alwaysTrust = reply.value(QStringLiteral("alwaysTrust")).toBool();
            Q_EMIT askIgnoreSslErrorsResult(1);
        } else {
            m_alwaysTrust.reset();
            Q_EMIT askIgnoreSslErrorsResult(0);
        }
    });
}

GrassfieldOpenWithHandler::GrassfieldOpenWithHandler(KioPrompts *prompts, QObject *parent)
    : KIO::OpenWithHandlerInterface(parent)
    , m_prompts(prompts)
{
}

void GrassfieldOpenWithHandler::promptUserForApplication(KJob *, const QList<QUrl> &urls, const QString &)
{
    m_prompts->tell(tr("There is no application set to open the document “%1”.").arg(urls.isEmpty() ? QString() : itemName(urls.first())),
                    tr("Choose one with Open With, in the File menu or the document’s menu."));
    QTimer::singleShot(0, this, [this] {
        Q_EMIT canceled();
    });
}

GrassfieldUntrustedProgramHandler::GrassfieldUntrustedProgramHandler(KioPrompts *prompts, QObject *parent)
    : KIO::UntrustedProgramHandlerInterface(parent)
    , m_prompts(prompts)
{
}

void GrassfieldUntrustedProgramHandler::showUntrustedProgramWarning(KJob *, const QString &programName)
{
    m_prompts->tell(tr("“%1” wasn’t opened.").arg(FileLogic::displayName(programName)), tr("Files doesn’t run programs. Open apps from the Dock or from Apps."));
    QTimer::singleShot(0, this, [this] {
        Q_EMIT result(false);
    });
}

GrassfieldJobUiDelegate::GrassfieldJobUiDelegate(KioPrompts *prompts, KJobUiDelegate::Flags flags, QWidget *window)
    : KIO::JobUiDelegate(flags, window, extensions(prompts))
    , m_prompts(prompts)
{
}

void GrassfieldJobUiDelegate::showErrorMessage()
{
    if (job() && job()->error() && job()->error() != KIO::ERR_USER_CANCELED)
        m_prompts->tell(tr("The operation can’t be completed."), plainText(job()->errorString()));
}

void GrassfieldJobUiDelegate::slotWarning(KJob *, const QString &message)
{
    if (isAutoWarningHandlingEnabled())
        m_prompts->tell(tr("The operation can’t be completed."), plainText(message));
}

GrassfieldUndoUi::GrassfieldUndoUi(const std::function<void(const QString &)> &reportError)
    : m_reportError(reportError)
{
    // An undo's progress would go to KIO's job tracker, which, with no KDE job server on the bus (a Grassfield session),
    // opens KIO's progress window (KWidgetJobTracker, src/widgets/kdynamicjobtracker.cpp:103-195). Files' own jobs hide it
    // the same way (KIO::HideProgressInfo).
    setShowProgressInfo(false);
}

void GrassfieldUndoUi::jobError(KIO::Job *job)
{
    if (job->error() != KIO::ERR_USER_CANCELED)
        m_reportError(job->errorString());
}

bool GrassfieldUndoUi::copiedFileWasModified(const QUrl &, const QUrl &dest, const QDateTime &, const QDateTime &)
{
    m_reportError(QCoreApplication::translate("GrassfieldUndoUi", "The copy “%1” was changed after it was made, so Undo stopped and kept it. Move it to the Trash if you no longer need it.")
                      .arg(itemName(dest)));
    return false;
}

namespace KioDialogs
{
void install(KioPrompts *prompts, const std::function<void(const QString &)> &reportError)
{
    s_prompts = prompts;
    KIO::JobUiDelegateFactory *previous = KIO::defaultJobUiDelegateFactory();
    auto *factory = new GrassfieldJobUiDelegateFactory(prompts);
    KIO::setDefaultJobUiDelegateFactory(factory);
    KIO::FileUndoManager::self()->setUiInterface(new GrassfieldUndoUi(reportError));
    QObject::connect(prompts, &QObject::destroyed, [previous, factory] {
        KIO::setDefaultJobUiDelegateFactory(previous);
        delete factory;
        s_prompts = nullptr;
        KIO::FileUndoManager::self()->setUiInterface(new KIO::FileUndoManager::UiInterface);
    });
}

KJobUiDelegate *createDelegate(KJobUiDelegate::Flags flags)
{
    if (!s_prompts)
        return KIO::createDefaultJobUiDelegate(flags, nullptr);
    return new GrassfieldJobUiDelegate(s_prompts, flags, nullptr);
}
} // namespace KioDialogs
