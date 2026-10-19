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

qint64 changeStampOf(const struct stat &st)
{
    return qint64(st.st_ctim.tv_sec) * 1000000000 + st.st_ctim.tv_nsec;
}
} // namespace

Info probe(const QString &path)
{
    Info info;
    const QByteArray p = QFile::encodeName(path);
    struct stat st;
    if (p.isEmpty() || ::lstat(p.constData(), &st) != 0)
        return info;
    info.changeStamp = changeStampOf(st);
    if (S_ISLNK(st.st_mode)) {
        info.support = Support::Link;
        return info;
    }
    if (!S_ISREG(st.st_mode) && !S_ISDIR(st.st_mode)) {
        info.support = Support::NotRegular;
        return info;
    }
    info.support = ::access(p.constData(), W_OK) != 0 ? Support::ReadOnly : Support::Supported;
    char buffer[1024];
    const ssize_t n = ::lgetxattr(p.constData(), TagLogic::attributeName(), buffer, sizeof buffer);
    if (n >= 0) {
        info.raw = QByteArray(buffer, int(n));
    } else if (errno == ERANGE) {
        info.raw = readRaw(path);
    } else if (unsupported(errno) && info.support == Support::Supported) {
        info.support = Support::NoXattr;
    }
    info.tags = TagLogic::parse(info.raw);
    return info;
}

Support support(const QString &path)
{
    return probe(path).support;
}

Cache::Cache(qint64 ttlMs, int maxEntries)
    : m_ttlMs(ttlMs)
    , m_maxEntries(maxEntries)
{
    m_clock.start();
}

const Info &Cache::info(const QString &path)
{
    const qint64 now = m_clock.elapsed();
    const auto it = m_entries.constFind(path);
    if (it != m_entries.cend() && now - it->stamp < m_ttlMs) {
        // Another application's write moves the ctime: probe again then (one lstat instead of a full probe).
        struct stat st;
        const QByteArray p = QFile::encodeName(path);
        const bool gone = p.isEmpty() || ::lstat(p.constData(), &st) != 0;
        if (gone ? it->info.support == Support::Missing : changeStampOf(st) == it->info.changeStamp)
            return it->info;
    }
    if (m_entries.size() >= m_maxEntries)
        m_entries.clear();
    Entry &entry = m_entries[path];
    entry.info = probe(path);
    entry.stamp = now;
    return entry.info;
}

void Cache::invalidate(const QString &path)
{
    m_entries.remove(path);
}

void Cache::clear()
{
    m_entries.clear();
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

bool readRawChecked(const QString &path, QByteArray *value, QString *error)
{
    value->clear();
    const QByteArray p = QFile::encodeName(path);
    auto fail = [&](int e) {
        if (error)
            *error = QString::fromLocal8Bit(std::strerror(e));
        return false;
    };
    if (p.isEmpty())
        return fail(ENOENT);
    // Ask for the size, then read it; the value may change in between (ERANGE): a few tries.
    for (int attempt = 0; attempt < 3; ++attempt) {
        const ssize_t size = ::lgetxattr(p.constData(), TagLogic::attributeName(), nullptr, 0);
        if (size < 0) {
            if (errno == ENODATA)
                return true; // no tag attribute: no tags
            return fail(errno);
        }
        if (size == 0)
            return true;
        if (size > kMaxValue)
            return fail(E2BIG);
        QByteArray data(int(size), Qt::Uninitialized);
        const ssize_t n = ::lgetxattr(p.constData(), TagLogic::attributeName(), data.data(), size_t(data.size()));
        if (n >= 0) {
            *value = data.left(int(n));
            return true;
        }
        if (errno == ENODATA) // removed in between
            return true;
        if (errno != ERANGE)
            return fail(errno);
    }
    return fail(EAGAIN);
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

ReadResult readAttr(const QString &path, const char *attr, QByteArray *value, QString *error)
{
    value->clear();
    const QByteArray p = QFile::encodeName(path);
    auto fail = [&](int e) {
        if (error)
            *error = QString::fromLocal8Bit(std::strerror(e));
        return unsupported(e) ? ReadResult::Unsupported : ReadResult::Failed;
    };
    if (p.isEmpty())
        return fail(ENOENT);
    for (int attempt = 0; attempt < 3; ++attempt) {
        const ssize_t size = ::lgetxattr(p.constData(), attr, nullptr, 0);
        if (size < 0) {
            if (errno == ENODATA)
                return ReadResult::NoData;
            return fail(errno);
        }
        if (size == 0)
            return ReadResult::NoData;
        if (size > kMaxValue)
            return fail(E2BIG);
        QByteArray data(int(size), Qt::Uninitialized);
        const ssize_t n = ::lgetxattr(p.constData(), attr, data.data(), size_t(data.size()));
        if (n >= 0) {
            *value = data.left(int(n));
            return ReadResult::Ok;
        }
        if (errno == ENODATA)
            return ReadResult::NoData;
        if (errno != ERANGE)
            return fail(errno);
    }
    return fail(EAGAIN);
}

ReadResult quickReadAttr(const QString &path, const char *attr, QByteArray *value)
{
    value->clear();
    const QByteArray p = QFile::encodeName(path);
    char buffer[512];
    const ssize_t n = ::lgetxattr(p.constData(), attr, buffer, sizeof buffer);
    if (n > 0) {
        *value = QByteArray(buffer, int(n));
        return ReadResult::Ok;
    }
    if (n == 0 || errno == ENODATA)
        return ReadResult::NoData;
    if (errno == ERANGE)
        return readAttr(path, attr, value);
    return unsupported(errno) ? ReadResult::Unsupported : ReadResult::Failed;
}

bool writeAttr(const QString &path, const char *attr, const QByteArray &value, QString *error, int *errnoOut)
{
    const QByteArray p = QFile::encodeName(path);
    int rc = 0;
    if (value.isEmpty()) {
        rc = ::lremovexattr(p.constData(), attr);
        if (rc != 0 && errno == ENODATA)
            rc = 0;
    } else {
        rc = ::lsetxattr(p.constData(), attr, value.constData(), size_t(value.size()), 0);
    }
    if (rc != 0) {
        if (error)
            *error = QString::fromLocal8Bit(std::strerror(errno));
        if (errnoOut)
            *errnoOut = errno;
    }
    return rc == 0;
}

} // namespace TagStore
