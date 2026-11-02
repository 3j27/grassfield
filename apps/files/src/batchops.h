#pragma once

#include <QList>
#include <QString>

// Several local file operations that are ONE command for the user (Rename N Items, Make Alias of several items, New Folder
// with Selection): applied all together or not at all, and reverted or applied again as one undo or redo step (the Finder
// records one step per command; KIO's FileUndoManager records one per job, so Files keeps these commands itself and orders
// them against KIO's by serial number, FilesApp::undo). Qt Core and system calls only; unit tested.
//
// Nothing is ever replaced: a rename uses RENAME_NOREPLACE, a link and a folder fail when the name exists, a folder is only
// removed empty and a link only when it still points where it did.
namespace BatchOps
{

struct Step {
    enum class Kind {
        Rename, // `from` becomes `to`
        Link,   // a symbolic link named `to` that points to `from`
        Unlink, // removes the link `to` when it still points to `from`
        Mkdir,  // a folder named `to`
        Rmdir,  // removes the folder `to` when it is empty
    };
    Kind kind = Kind::Rename;
    QString from;
    QString to;
};
using Steps = QList<Step>;

struct Failure {
    // The step that could not be done (index in the list given to apply()), its item's path and errno.
    int step = -1;
    QString path;
    int error = 0;
};

// The steps that revert `steps`: each inverted, in reverse order.
Steps inverse(const Steps &steps);

// Applies the steps in order. When one fails, the ones done are reverted (in reverse order) and false is returned with
// `failure` naming the step; nothing is left half done unless a revert itself fails (then `failure.step` stays and the
// disk is as far along as the revert got). True: all done.
bool apply(const Steps &steps, Failure *failure = nullptr);

} // namespace BatchOps
