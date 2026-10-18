#include "tagstore.h"

#include "taglogic.h"

#include <QByteArray>
#include <QFile>

#include <cerrno>
#include <cstring>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>

namespace TagStore
{

namespace
{
// The kernel's limit for one attribute value (XATTR_SIZE_MAX).
constexpr ssize_t kMaxValue = 64 * 1024;

bool unsupported(int error)
{
    return error == ENOTSUP || error == EOPNOTSUPP;
}
} // namespace

Support support(const QString &path)
{
    const QByteArray p = QFile::encodeName(path);
    struct stat st;
    if (p.isEmpty() || ::lstat(p.constData(), &st) != 0)
        return Support::Missing;
    if (S_ISLNK(st.st_mode))
        return Support::Link;
    if (!S_ISREG(st.st_mode) && !S_ISDIR(st.st_mode))
        return Support::NotRegular;
    if (::access(p.constData(), W_OK) != 0)
        return Support::ReadOnly;
    if (::lgetxattr(p.constData(), TagLogic::attributeName(), nullptr, 0) < 0 && unsupported(errno))
        return Support::NoXattr;
    return Support::Supported;
}

QByteArray readRaw(const QString &path)
{
    const QByteArray p = QFile::encodeName(path);
    if (p.isEmpty())
        return {};
    char small[1024];
    ssize_t n = ::lgetxattr(p.constData(), TagLogic::attributeName(), small, sizeof small);
    if (n >= 0)
        return QByteArray(small, int(n));
    if (errno != ERANGE)
        return {};
    // Longer than the stack buffer: ask for the size (it may change in between: one retry).
    for (int attempt = 0; attempt < 2; ++attempt) {
        const ssize_t size = ::lgetxattr(p.constData(), TagLogic::attributeName(), nullptr, 0);
        if (size <= 0 || size > kMaxValue)
            return {};
        QByteArray value(int(size), Qt::Uninitialized);
        n = ::lgetxattr(p.constData(), TagLogic::attributeName(), value.data(), size_t(value.size()));
        if (n >= 0)
            return value.left(int(n));
        if (errno != ERANGE)
            return {};
    }
    return {};
}

QStringList read(const QString &path)
{
    return TagLogic::parse(readRaw(path));
}

bool writeRaw(const QString &path, const QByteArray &value, QString *error)
{
    const QByteArray p = QFile::encodeName(path);
    int rc = 0;
    if (value.isEmpty()) {
        rc = ::lremovexattr(p.constData(), TagLogic::attributeName());
        if (rc != 0 && errno == ENODATA)
            rc = 0;
    } else {
        rc = ::lsetxattr(p.constData(), TagLogic::attributeName(), value.constData(), size_t(value.size()), 0);
    }
    if (rc != 0 && error)
        *error = QString::fromLocal8Bit(std::strerror(errno));
    return rc == 0;
}

bool write(const QString &path, const QStringList &tags, QString *error)
{
    return writeRaw(path, TagLogic::serialize(tags), error);
}

} // namespace TagStore
