// ADR-0035 D-12 a, docs/specs/system-dialogs.md section 9 (A-KD1, KD2): the buttons Grassfield's KIO sheets offer for the
// options KIO passes, and the KIO answer each choice gives, the one KIO's own widget dialog gives for the same choice
// (KIO 6.31 src/widgets/renamedialog.cpp:664-741, skipdialog.cpp:41-109, widgetsaskuseractionhandler.cpp:460-485).
#include <gtest/gtest.h>

#include "kiopromptlogic.h"

#include <kio/workerbase.h>

using namespace KioPromptLogic;
using Ask = KIO::AskUserActionInterface;

TEST(KioPrompts, TheConflictSheetOffersWhatKioAllows)
{
    const auto one = conflictButtons(KIO::RenameDialog_Overwrite);
    EXPECT_TRUE(one.replace);
    EXPECT_TRUE(one.keepBoth);
    EXPECT_FALSE(one.skip);
    EXPECT_FALSE(one.applyToAll);

    const auto many = conflictButtons(KIO::RenameDialog_Overwrite | KIO::RenameDialog_Skip | KIO::RenameDialog_MultipleItems);
    EXPECT_TRUE(many.replace && many.keepBoth && many.skip && many.applyToAll);

    // An item onto itself: never Replace. A destination that refuses a new name: never Keep Both.
    EXPECT_FALSE(conflictButtons(KIO::RenameDialog_Overwrite | KIO::RenameDialog_OverwriteItself).replace);
    EXPECT_FALSE(conflictButtons(KIO::RenameDialog_Overwrite | KIO::RenameDialog_NoRename).keepBoth);
    EXPECT_FALSE(conflictButtons({}).replace);
}

TEST(KioPrompts, EachConflictChoiceGivesKiosAnswer)
{
    const KIO::RenameDialog_Options all = KIO::RenameDialog_Overwrite | KIO::RenameDialog_Skip | KIO::RenameDialog_MultipleItems;
    struct Row {
        ConflictChoice choice;
        bool applyToAll;
        KIO::RenameDialog_Result expected;
    };
    const Row rows[] = {
        {ConflictChoice::Replace, false, KIO::Result_Overwrite},
        {ConflictChoice::Replace, true, KIO::Result_OverwriteAll},
        {ConflictChoice::KeepBoth, false, KIO::Result_Rename},
        {ConflictChoice::KeepBoth, true, KIO::Result_AutoRename},
        {ConflictChoice::Skip, false, KIO::Result_Skip},
        {ConflictChoice::Skip, true, KIO::Result_AutoSkip},
        {ConflictChoice::Stop, false, KIO::Result_Cancel},
        {ConflictChoice::Stop, true, KIO::Result_Cancel},
    };
    for (const Row &r : rows)
        EXPECT_EQ(conflictResult(all, r.choice, r.applyToAll), r.expected) << int(r.choice) << r.applyToAll;

    // Apply to All exists only for several items; a choice the sheet did not offer stops.
    EXPECT_EQ(conflictResult(KIO::RenameDialog_Overwrite, ConflictChoice::Replace, true), KIO::Result_Overwrite);
    EXPECT_EQ(conflictResult(KIO::RenameDialog_Overwrite, ConflictChoice::Skip, false), KIO::Result_Cancel);
    EXPECT_EQ(conflictResult(KIO::RenameDialog_Overwrite | KIO::RenameDialog_OverwriteItself, ConflictChoice::Replace, false), KIO::Result_Cancel);
    EXPECT_EQ(conflictResult(KIO::RenameDialog_Overwrite | KIO::RenameDialog_NoRename, ConflictChoice::KeepBoth, false), KIO::Result_Cancel);
}

TEST(KioPrompts, TheSkipSheetOffersWhatKioAllows)
{
    const auto plain = skipButtons({});
    EXPECT_TRUE(plain.retry);
    EXPECT_FALSE(plain.rename);
    // One item: no Skip (KIO's SkipDialog shows Skip and Skip All for several items only).
    EXPECT_FALSE(plain.skip);
    EXPECT_FALSE(plain.applyToAll);
    EXPECT_TRUE(skipButtons(KIO::SkipDialog_MultipleItems).skip);
    EXPECT_FALSE(skipButtons(KIO::SkipDialog_Hide_Retry).retry);
    // Characters the destination refuses: Rename (KIO's "Replace") takes Try Again's place.
    const auto chars = skipButtons(KIO::SkipDialog_Replace_Invalid_Chars | KIO::SkipDialog_MultipleItems);
    EXPECT_TRUE(chars.rename);
    EXPECT_FALSE(chars.retry);
    EXPECT_TRUE(chars.applyToAll);
}

TEST(KioPrompts, EachSkipChoiceGivesKiosAnswer)
{
    const KIO::SkipDialog_Options many = KIO::SkipDialog_MultipleItems;
    EXPECT_EQ(skipResult(many, SkipChoice::Skip, false), KIO::Result_Skip);
    EXPECT_EQ(skipResult(many, SkipChoice::Skip, true), KIO::Result_AutoSkip);
    EXPECT_EQ(skipResult(many, SkipChoice::Stop, true), KIO::Result_Cancel);
    EXPECT_EQ(skipResult(many, SkipChoice::Retry, false), KIO::Result_Retry);
    EXPECT_EQ(skipResult(KIO::SkipDialog_Hide_Retry, SkipChoice::Retry, false), KIO::Result_Cancel);
    const KIO::SkipDialog_Options chars = KIO::SkipDialog_Replace_Invalid_Chars | KIO::SkipDialog_MultipleItems;
    EXPECT_EQ(skipResult(chars, SkipChoice::Rename, false), KIO::Result_ReplaceInvalidChars);
    EXPECT_EQ(skipResult(chars, SkipChoice::Rename, true), KIO::Result_ReplaceAllInvalidChars);
    EXPECT_EQ(skipResult(many, SkipChoice::Rename, false), KIO::Result_Cancel);
    // One item has no Skip: a Skip that comes anyway stops.
    EXPECT_EQ(skipResult({}, SkipChoice::Skip, true), KIO::Result_Cancel);
    EXPECT_EQ(skipResult({}, SkipChoice::Stop, false), KIO::Result_Cancel);
}

TEST(KioPrompts, MessageBoxesAnswerWithKiosButtonCodes)
{
    EXPECT_EQ(messageResult(Ask::QuestionTwoActions, MessageButton::Primary), KIO::WorkerBase::PrimaryAction);
    EXPECT_EQ(messageResult(Ask::QuestionTwoActions, MessageButton::Secondary), KIO::WorkerBase::SecondaryAction);
    EXPECT_EQ(messageResult(Ask::QuestionTwoActions, MessageButton::Cancel), 0);
    EXPECT_EQ(messageResult(Ask::QuestionTwoActionsCancel, MessageButton::Cancel), KIO::WorkerBase::Cancel);
    EXPECT_EQ(messageResult(Ask::WarningTwoActionsCancel, MessageButton::Secondary), KIO::WorkerBase::SecondaryAction);
    // WarningContinueCancel's primary button is Continue (widgetsaskuseractionhandler.cpp:462-466).
    EXPECT_EQ(messageResult(Ask::WarningContinueCancel, MessageButton::Primary), KIO::WorkerBase::Continue);
    EXPECT_EQ(messageResult(Ask::WarningContinueCancel, MessageButton::Secondary), 0);
    EXPECT_EQ(messageResult(Ask::WarningContinueCancel, MessageButton::Cancel), KIO::WorkerBase::Cancel);
    EXPECT_EQ(messageResult(Ask::Information, MessageButton::Ok), KIO::WorkerBase::Ok);
    EXPECT_EQ(messageResult(Ask::Error, MessageButton::Ok), KIO::WorkerBase::Ok);
    EXPECT_EQ(messageResult(Ask::Error, MessageButton::Primary), 0);

    EXPECT_TRUE(messageButtons(Ask::Information).okOnly);
    EXPECT_TRUE(messageButtons(Ask::WarningTwoActions).warning);
    EXPECT_FALSE(messageButtons(Ask::QuestionTwoActions).warning);
    EXPECT_FALSE(messageButtons(Ask::WarningTwoActions).cancel);
}

TEST(KioPrompts, AlwaysTrustAnswersKiosForeverQuestion)
{
    // http.cpp:322-327: PrimaryAction "Forever" (1000 years), SecondaryAction "Current Session only" (30 minutes).
    EXPECT_EQ(certificateFollowUpAnswer(true), KIO::WorkerBase::PrimaryAction);
    EXPECT_EQ(certificateFollowUpAnswer(false), KIO::WorkerBase::SecondaryAction);
}

TEST(KioPrompts, OnlyPermanentDeletionsAreAsked)
{
    EXPECT_FALSE(deleteNeedsAsking(Ask::Trash, Ask::DefaultConfirmation));
    EXPECT_TRUE(deleteNeedsAsking(Ask::Trash, Ask::ForceConfirmation));
    for (const auto type : {Ask::Delete, Ask::EmptyTrash, Ask::DeleteInsteadOfTrash, Ask::DeleteNoTrashAvailable})
        EXPECT_TRUE(deleteNeedsAsking(type, Ask::DefaultConfirmation)) << type;
}

TEST(KioPrompts, SheetsShowPlainText)
{
    EXPECT_EQ(plainText(QStringLiteral("Disk full")), QStringLiteral("Disk full"));
    EXPECT_EQ(plainText(QStringLiteral("<qt>The host <b>example.org</b> refused</qt>")), QStringLiteral("The host example.org refused"));
    // A worker's text with "<" that is not markup stays as is.
    EXPECT_EQ(plainText(QStringLiteral("size < 4 GB")), QStringLiteral("size < 4 GB"));
}
