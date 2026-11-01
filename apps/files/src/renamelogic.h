#pragma once

#include <QDateTime>
#include <QList>
#include <QString>
#include <QStringList>

// Rename several items at once (docs/specs/files.md FP-57, the Finder's "Rename N Items…" sheet): Replace Text, Add
// Text, Format. Pure: the new names of a list of names; the window shows the first as its example and FilesApp renames
// through KIO. Unit-tested in tests/unit/files/tst_renamelogic.cpp.
namespace RenameLogic
{

enum class Mode { Replace = 0, Add = 1, Format = 2 };
// Add Text: before or after the name (after the name means before its extension, as the Finder).
enum class Where { AfterName = 0, BeforeName = 1 };
// Format: the custom text and an index (1, 2…), a counter (00001…) or the date and time.
enum class Format { NameAndIndex = 0, NameAndCounter = 1, NameAndDate = 2 };

struct Options {
    Mode mode = Mode::Replace;
    QString find;
    QString replaceWith;
    QString addText;
    Where where = Where::AfterName;
    Format format = Format::NameAndIndex;
    QString customFormat;
    int startAt = 1;
};

// The new names of `names` (in their order; `isDir` says which are folders, whose whole name is the name). Replace
// changes every occurrence of `find` in the name without its extension (case-sensitive, as the Finder); Add puts the text
// before the name or before the extension; Format replaces the name with the custom text and the index, counter or date,
// keeping the extension. `now` dates Name and Date.
QStringList newNames(const QStringList &names, const QList<bool> &isDir, const Options &options, const QDateTime &now);

// Why these new names can't be applied ("" when they can): a name a file can't take, two items given one name in a
// folder, or a new name taken by another item of the batch (renaming in turn would overwrite it). `folders` holds each
// item's folder (items of a search come from several). The texts are translated by the caller from the code.
enum class Problem { None = 0, InvalidName, Duplicate, TakenInBatch, NothingChanges };
Problem check(const QStringList &oldNames, const QStringList &newNames, const QStringList &folders, QString *name = nullptr);

} // namespace RenameLogic
