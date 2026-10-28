#pragma once

#include "folderstylestore.h"

#include <QSize>
#include <QString>

#include <functional>
#include <memory>

#include <sys/stat.h>

class QObject;

// The pixel size of a picture, the preview pane's Dimensions (docs/specs/files.md "Preview pane"), never read on the GUI
// thread. The type of a listed item comes from its name: a FIFO named "pipe.png" or a link to /dev/zero named "x.png" is
// "a picture" to KIO, and opening or reading it would never return. So the file is looked at only when it is a regular
// file on a local filesystem, decided without opening it, and its header is read by a worker thread with a byte budget.
namespace ImageSize
{
// The most bytes read from one file to find its size (a header; a huge file that is not what its name says stops here).
constexpr qint64 kReadBudget = 16 * 1024 * 1024;
// How long the Reader's destructor waits for a read in progress before abandoning it (milliseconds).
constexpr int kExitGraceMs = 150;

enum class Refusal {
    None,
    NotLocal,   // a component on a network, FUSE, pseudo or unknown filesystem: never looked at
    NotRegular, // a FIFO, a device, a socket or a folder: never opened
    Unreadable, // missing, a relative path, a broken or looping link, a lstat error
};

// Whether the picture at `path` may be opened: the path is walked one component at a time from the root, a symbolic
// link followed by its text, and every component's filesystem is checked against `mounts` BEFORE it is looked at (local
// disks, removable disks and memory only); the file at the end must be a regular file (lstat, nothing is opened). `st`
// (optional) receives its status and `resolved` (optional) the path that was reached: every link in `path` followed, no
// link left in it. A lstat: never on the GUI thread.
Refusal check(const QString &path, const FolderStyleStore::Mounts &mounts, struct stat *st = nullptr, QString *resolved = nullptr);

// Opens the file check() approved by the path check() reached (`resolved`), read only, without blocking (O_NONBLOCK,
// O_NOCTTY) and without following a link anywhere in that path (openat2 RESOLVE_NO_SYMLINKS: a link swapped in after the
// check, for the file or a folder above it, is refused, wherever it leads; where openat2 answers ENOSYS or EPERM, a kernel
// without it or a sandbox's seccomp filter, open() with O_NOFOLLOW refuses one at the end only); the descriptor is returned
// only when it is still the file checked (same device and inode, a regular file), -1 otherwise. Never on the GUI thread.
int openChecked(const QString &resolved, const struct stat &checked);

// Tests: the openat2 call openChecked() makes (`path` from the working directory, open flags, RESOLVE_* bits; a
// descriptor, or -1 with errno set). A stand-in answering ENOSYS or EPERM takes the fallback; null restores the system
// call.
using Openat2 = int (*)(const char *path, int flags, quint64 resolve);
void setOpenat2ForTests(Openat2 call);

// The size as shown (a picture turned by its EXIF orientation reports the turned size), invalid when unknown or refused.
// check() first, then openChecked(); the format is the content's, and at most kReadBudget bytes are read.
// Never on the GUI thread.
QSize read(const QString &path, const FolderStyleStore::Mounts &mounts);

// The worker of one owner (a FolderModel): request() returns at once, and `ready` runs later on the owner's thread with
// the path and its size (invalid when unknown), unless the owner is destroyed first. One thread at a time, started when
// there is work and ended when the queue is empty; the mount table is read by the thread. The destructor drops what is
// queued, waits up to kExitGraceMs for a read in progress, then abandons it (the thread owns what it uses and never
// calls back after that).
class Reader
{
public:
    using Ready = std::function<void(const QString &path, QSize size)>;
    Reader(QObject *owner, Ready ready);
    ~Reader();
    Reader(const Reader &) = delete;
    Reader &operator=(const Reader &) = delete;

    // Queues `path` (once while it waits).
    void request(const QString &path);
    // Tests: the mount table used instead of /proc/self/mountinfo.
    void setMountsForTests(const FolderStyleStore::Mounts &mounts);

private:
    struct Shared;
    // The thread's loop: it holds `s`, so what it uses outlives the Reader.
    static void run(const std::shared_ptr<Shared> &s);
    std::shared_ptr<Shared> m_shared;
};
} // namespace ImageSize
