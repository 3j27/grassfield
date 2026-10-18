#pragma once

#include <QString>
#include <QStringList>

// user.xdg.tags (TagLogic) on local files, through the Linux extended attribute calls. Symbolic links are never
// followed: Linux keeps no user attributes on a link, and tagging a link must not tag its target. Unit tested on a
// file under the test sandbox (tests/unit/files/tst_tags.cpp). Thread-safe (the tag search reads from a worker thread).
namespace TagStore
{

enum class Support {
    Supported, // a local file or folder on a filesystem with user attributes
    Missing, // no such file
    Link, // a symbolic link
    NoXattr, // the filesystem has no user extended attributes (or they are disabled)
};

Support support(const QString &path);

// The stored tags; empty when there are none, or the attribute cannot be read.
QStringList read(const QString &path);

// Stores `tags` (removes the attribute when the list is empty). False, with the system's reason in `error`, when the
// filesystem or the permissions refuse it.
bool write(const QString &path, const QStringList &tags, QString *error = nullptr);

} // namespace TagStore
