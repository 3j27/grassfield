#pragma once

#include <QString>
#include <QStringList>

#include <kio/askuseractioninterface.h> // MessageDialogType, DeletionType, ConfirmationType
#include <kio/jobuidelegateextension.h> // RenameDialog_Options, SkipDialog_Options, RenameDialog_Result

// The decisions of Grassfield's KIO dialogs in Files (ADR-0035 D-12 a; docs/specs/system-dialogs.md section 9): which
// buttons a sheet offers for the options KIO passes, and which KIO answer each choice gives. Every answer is the one KIO's
// own widget dialog gives for the same choice (KD2: RenameDialog, SkipDialog, KMessageDialog), so jobs behave as before.
// Pure: unit-tested by tests/unit/files/tst_kioprompts.cpp.
namespace KioPromptLogic
{

// The conflict sheet ("An item named “X” already exists in this location."): Keep Both / Skip / Stop / Replace, and
// Resume for a copy that stopped part way (KIO's FileCopyJob, filecopyjob.cpp:355-376).
struct ConflictButtons {
    bool replace = false; // RenameDialog_Overwrite and not the item itself
    bool keepBoth = false; // not RenameDialog_NoRename
    bool skip = false; // RenameDialog_Skip
    bool resume = false; // RenameDialog_Resume
    bool applyToAll = false; // RenameDialog_MultipleItems
};
ConflictButtons conflictButtons(KIO::RenameDialog_Options options);

enum class ConflictChoice { KeepBoth, Skip, Stop, Replace, Resume };
// KIO's answer; a choice the sheet did not offer is Stop (Result_Cancel).
KIO::RenameDialog_Result conflictResult(KIO::RenameDialog_Options options, ConflictChoice choice, bool applyToAll);

// The skip sheet ("The operation can’t be completed…"): Stop, Rename (characters the destination refuses) or Try Again,
// and Skip for several items (KIO's SkipDialog has no Skip for one: skipdialog.cpp:41-80).
struct SkipButtons {
    bool rename = false; // SkipDialog_Replace_Invalid_Chars: replace them with "_"
    bool retry = false; // not SkipDialog_Hide_Retry, and no Rename
    bool skip = false; // SkipDialog_MultipleItems
    bool applyToAll = false; // SkipDialog_MultipleItems
};
SkipButtons skipButtons(KIO::SkipDialog_Options options);

enum class SkipChoice { Skip, Stop, Rename, Retry };
KIO::SkipDialog_Result skipResult(KIO::SkipDialog_Options options, SkipChoice choice, bool applyToAll);

// A worker's message box (AskUserActionInterface::MessageDialogType): which buttons it shows and the KIO::WorkerBase
// button code each gives.
enum class MessageButton { Primary, Secondary, Cancel, Ok };
struct MessageButtons {
    bool secondary = false; // the two-action types
    bool cancel = false; // the *Cancel types and WarningContinueCancel
    bool okOnly = false; // Information and Error: one OK button
    bool warning = false; // a warning: the primary button is drawn destructive
};
MessageButtons messageButtons(KIO::AskUserActionInterface::MessageDialogType type);
// The KIO::WorkerBase::ButtonCode, or 0 for a button the type does not have.
int messageResult(KIO::AskUserActionInterface::MessageDialogType type, MessageButton button);

// The certificate sheet: Cancel is the default (Return and Esc cancel). KIO's http worker asks next, as its own question,
// whether to accept the certificate "Forever" (its primary action) or for the "Current Session only" (secondary: 30 minutes,
// kioworkers/http/http.cpp:310-336). Grassfield answers that question from the sheet's "Always trust" box.
int certificateFollowUpAnswer(bool alwaysTrust);

// Delete and trash confirmations KIO asks for (AskUserActionInterface::DeletionType, ConfirmationType). A move to the Trash
// is not asked (macOS) unless KIO forces the question; every permanent deletion is.
bool deleteNeedsAsking(KIO::AskUserActionInterface::DeletionType deletionType, KIO::AskUserActionInterface::ConfirmationType confirmationType);

// The text a sheet shows for a KIO message, which may be Qt rich text and names files and hosts others chose: its plain
// text (sheets never render markup), with the direction overrides and isolates and the line and paragraph separators
// shown as <U+XXXX> (as FileLogic::displayName shows them in names) and the other control characters dropped; line breaks
// and tabs stay.
QString plainText(const QString &text);

} // namespace KioPromptLogic
