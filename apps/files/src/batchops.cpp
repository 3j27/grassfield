#include "batchops.h"

#include <QFile>

#include <cerrno>
#include <cstdio>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace BatchOps
{
namespace
{
bool g_forceFallback = false;
std::function<void(int)> g_stepHook;

// 0 or errno.
int run(const Step &step)
{
    const QByteArray from = QFile::encodeName(step.from);
    const QByteArray to = QFile::encodeName(step.to);
    switch (step.kind) {
    case Step::Kind::Rename: {
        if (!g_forceFallback) {
            if (::renameat2(AT_FDCWD, from.constData(), AT_FDCWD, to.constData(), RENAME_NOREPLACE) == 0)
                return 0;
            if (errno != EINVAL && errno != ENOSYS)
                return errno;
        }
        // A filesystem without RENAME_NOREPLACE: look first, then rename. The window between the two is a few
        // microseconds in the user's own folder, and it is what gnulib's renameatu does too; the look is what keeps a name
        // that exists from being replaced in every other case.
        struct stat st;
        if (::lstat(to.constData(), &st) == 0)
            return EEXIST;
        return ::rename(from.constData(), to.constData()) == 0 ? 0 : errno;
    }
    case Step::Kind::Link:
        return ::symlink(from.constData(), to.constData()) == 0 ? 0 : errno;
    case Step::Kind::Unlink: {
        char buffer[4096];
        const ssize_t n = ::readlink(to.constData(), buffer, sizeof buffer - 1);
        if (n < 0)
            return errno == EINVAL ? EEXIST : errno; // not a link any more: it is not ours to remove
        if (QByteArray(buffer, int(n)) != from)
            return EEXIST;
        return ::unlink(to.constData()) == 0 ? 0 : errno;
    }
    case Step::Kind::Mkdir:
        return ::mkdir(to.constData(), 0777) == 0 ? 0 : errno;
    case Step::Kind::Rmdir:
        return ::rmdir(to.constData()) == 0 ? 0 : errno;
    }
    return EINVAL;
}

Step inverted(const Step &step)
{
    switch (step.kind) {
    case Step::Kind::Rename:
        return {Step::Kind::Rename, step.to, step.from};
    case Step::Kind::Link:
        return {Step::Kind::Unlink, step.from, step.to};
    case Step::Kind::Unlink:
        return {Step::Kind::Link, step.from, step.to};
    case Step::Kind::Mkdir:
        return {Step::Kind::Rmdir, step.from, step.to};
    case Step::Kind::Rmdir:
        return {Step::Kind::Mkdir, step.from, step.to};
    }
    return step;
}

// The item a step is about, for a message: what it makes or removes (a rename: its source).
QString itemOf(const Step &step)
{
    return step.kind == Step::Kind::Rename ? step.from : step.to;
}
} // namespace

Steps inverse(const Steps &steps)
{
    Steps out;
    out.reserve(steps.size());
    for (auto it = steps.crbegin(); it != steps.crend(); ++it)
        out.append(inverted(*it));
    return out;
}

void forceNoReplaceFallback(bool on)
{
    g_forceFallback = on;
}

void setStepHook(const std::function<void(int)> &hook)
{
    g_stepHook = hook;
}

bool apply(const Steps &steps, Failure *failure)
{
    for (int i = 0; i < steps.size(); ++i) {
        const int error = run(steps.at(i));
        if (error == 0) {
            if (g_stepHook)
                g_stepHook(i);
            continue;
        }
        // Revert what was done, newest first; a revert that fails stops there (nothing is forced) and what is still in
        // effect is reported.
        int stillDone = i; // steps [0, stillDone) are in effect
        while (stillDone > 0 && run(inverted(steps.at(stillDone - 1))) == 0)
            --stillDone;
        if (failure) {
            *failure = {i, itemOf(steps.at(i)), error, steps.mid(0, stillDone)};
        }
        return false;
    }
    return true;
}

} // namespace BatchOps
