#include "kiopromptlogic.h"

#include <QTextDocumentFragment>

#include <kio/workerbase.h> // ButtonCode

namespace KioPromptLogic
{

ConflictButtons conflictButtons(KIO::RenameDialog_Options options)
{
    ConflictButtons b;
    b.replace = options.testFlag(KIO::RenameDialog_Overwrite) && !options.testFlag(KIO::RenameDialog_OverwriteItself);
    b.keepBoth = !options.testFlag(KIO::RenameDialog_NoRename);
    b.skip = options.testFlag(KIO::RenameDialog_Skip);
    b.resume = options.testFlag(KIO::RenameDialog_Resume);
    b.applyToAll = options.testFlag(KIO::RenameDialog_MultipleItems);
    return b;
}

KIO::RenameDialog_Result conflictResult(KIO::RenameDialog_Options options, ConflictChoice choice, bool applyToAll)
{
    const ConflictButtons b = conflictButtons(options);
    const bool all = applyToAll && b.applyToAll;
    switch (choice) {
    case ConflictChoice::KeepBoth:
        return b.keepBoth ? (all ? KIO::Result_AutoRename : KIO::Result_Rename) : KIO::Result_Cancel;
    case ConflictChoice::Skip:
        return b.skip ? (all ? KIO::Result_AutoSkip : KIO::Result_Skip) : KIO::Result_Cancel;
    case ConflictChoice::Replace:
        return b.replace ? (all ? KIO::Result_OverwriteAll : KIO::Result_Overwrite) : KIO::Result_Cancel;
    case ConflictChoice::Resume: // renamedialog.cpp:730-737
        return b.resume ? (all ? KIO::Result_ResumeAll : KIO::Result_Resume) : KIO::Result_Cancel;
    case ConflictChoice::Stop:
        break;
    }
    return KIO::Result_Cancel;
}

SkipButtons skipButtons(KIO::SkipDialog_Options options)
{
    SkipButtons b;
    b.rename = options.testFlag(KIO::SkipDialog_Replace_Invalid_Chars);
    b.retry = !options.testFlag(KIO::SkipDialog_Hide_Retry) && !b.rename;
    b.skip = options.testFlag(KIO::SkipDialog_MultipleItems);
    b.applyToAll = options.testFlag(KIO::SkipDialog_MultipleItems);
    return b;
}

KIO::SkipDialog_Result skipResult(KIO::SkipDialog_Options options, SkipChoice choice, bool applyToAll)
{
    const SkipButtons b = skipButtons(options);
    const bool all = applyToAll && b.applyToAll;
    switch (choice) {
    case SkipChoice::Skip:
        return b.skip ? (all ? KIO::Result_AutoSkip : KIO::Result_Skip) : KIO::Result_Cancel;
    case SkipChoice::Rename:
        return b.rename ? (all ? KIO::Result_ReplaceAllInvalidChars : KIO::Result_ReplaceInvalidChars) : KIO::Result_Cancel;
    case SkipChoice::Retry:
        return b.retry ? KIO::Result_Retry : KIO::Result_Cancel;
    case SkipChoice::Stop:
        break;
    }
    return KIO::Result_Cancel;
}

using Ask = KIO::AskUserActionInterface;

MessageButtons messageButtons(Ask::MessageDialogType type)
{
    MessageButtons b;
    switch (type) {
    case Ask::QuestionTwoActions:
        b.secondary = true;
        break;
    case Ask::QuestionTwoActionsCancel:
        b.secondary = true;
        b.cancel = true;
        break;
    case Ask::WarningTwoActions:
        b.secondary = true;
        b.warning = true;
        break;
    case Ask::WarningTwoActionsCancel:
        b.secondary = true;
        b.cancel = true;
        b.warning = true;
        break;
    case Ask::WarningContinueCancel:
        b.cancel = true;
        b.warning = true;
        break;
    case Ask::Information:
    case Ask::Error:
        b.okOnly = true;
        break;
    }
    return b;
}

// As KIO's WidgetsAskUserActionHandler::requestUserMessageBox maps KMessageDialog's buttons.
int messageResult(Ask::MessageDialogType type, MessageButton button)
{
    const MessageButtons b = messageButtons(type);
    switch (button) {
    case MessageButton::Ok:
        return b.okOnly ? KIO::WorkerBase::Ok : 0;
    case MessageButton::Primary:
        if (b.okOnly)
            return 0;
        return type == Ask::WarningContinueCancel ? KIO::WorkerBase::Continue : KIO::WorkerBase::PrimaryAction;
    case MessageButton::Secondary:
        return b.secondary ? KIO::WorkerBase::SecondaryAction : 0;
    case MessageButton::Cancel:
        return b.cancel ? KIO::WorkerBase::Cancel : 0;
    }
    return 0;
}

int certificateFollowUpAnswer(bool alwaysTrust)
{
    return alwaysTrust ? KIO::WorkerBase::PrimaryAction : KIO::WorkerBase::SecondaryAction;
}

bool deleteNeedsAsking(Ask::DeletionType deletionType, Ask::ConfirmationType confirmationType)
{
    if (confirmationType == Ask::ForceConfirmation)
        return true;
    return deletionType != Ask::Trash;
}

QString plainText(const QString &text)
{
    if (!Qt::mightBeRichText(text))
        return text;
    return QTextDocumentFragment::fromHtml(text).toPlainText();
}

} // namespace KioPromptLogic
