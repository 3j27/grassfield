#include "imagesize.h"

#include <QDir>
#include <QFile>
#include <QImageReader>
#include <QMetaObject>
#include <QObject>

#include <algorithm>

#include <chrono>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <optional>
#include <thread>

#include <fcntl.h>
#include <unistd.h>

namespace ImageSize
{
namespace
{
// The filesystems a header is read from: local and removable disks, and memory. Never a network filesystem (a server
// that does not answer), FUSE (its daemon can stall; "fuseblk" too) or a kernel pseudo filesystem (/proc, /sys, /dev),
// where an open or a read can block or never end.
bool readableType(const QString &type)
{
    static const QStringList types = {
        QStringLiteral("ext2"),    QStringLiteral("ext3"),     QStringLiteral("ext4"),    QStringLiteral("btrfs"),   QStringLiteral("xfs"),
        QStringLiteral("f2fs"),    QStringLiteral("zfs"),      QStringLiteral("jfs"),     QStringLiteral("bcachefs"), QStringLiteral("reiserfs"),
        QStringLiteral("nilfs2"),  QStringLiteral("tmpfs"),    QStringLiteral("ramfs"),   QStringLiteral("overlay"), QStringLiteral("vfat"),
        QStringLiteral("msdos"),   QStringLiteral("exfat"),    QStringLiteral("ntfs3"),   QStringLiteral("ntfs"),    QStringLiteral("hfsplus"),
        QStringLiteral("hfs"),     QStringLiteral("iso9660"),  QStringLiteral("udf"),     QStringLiteral("squashfs"), QStringLiteral("erofs"),
    };
    return types.contains(type);
}

// The type of the filesystem `path` lies on: its longest covering mount point ("" when none covers it).
QString mountTypeOf(const QString &path, const FolderStyleStore::Mounts &mounts)
{
    const FolderStyleStore::Mounts::Mount *covering = nullptr;
    for (const FolderStyleStore::Mounts::Mount &m : mounts.mounted) {
        const bool under = m.point == QLatin1String("/") || path == m.point || path.startsWith(m.point + QLatin1Char('/'));
        if (under && (!covering || m.point.size() >= covering->point.size()))
            covering = &m;
    }
    return covering ? covering->type : QString();
}

// A file that reads at most kReadBudget bytes (QImageReader keeps asking while a handler looks for what it needs).
class BudgetFile : public QFile
{
protected:
    qint64 readData(char *data, qint64 maxlen) override
    {
        if (m_spent >= kReadBudget)
            return -1;
        const qint64 n = QFile::readData(data, qMin(maxlen, kReadBudget - m_spent));
        if (n > 0)
            m_spent += n;
        return n;
    }

private:
    qint64 m_spent = 0;
};
} // namespace

Refusal check(const QString &path, const FolderStyleStore::Mounts &mounts, struct stat *out, QString *resolved)
{
    if (!QDir::isAbsolutePath(path))
        return Refusal::Unreadable;
    QStringList pending = QDir::cleanPath(path).split(QLatin1Char('/'), Qt::SkipEmptyParts);
    QString cur = QStringLiteral("/");
    int links = 0;
    while (!pending.isEmpty()) {
        const QString part = pending.takeFirst();
        if (part == QLatin1String("."))
            continue;
        if (part == QLatin1String("..")) {
            cur = QDir::cleanPath(cur + QLatin1String("/.."));
            continue;
        }
        const QString next = cur == QLatin1String("/") ? cur + part : cur + QLatin1Char('/') + part;
        // Before the lstat: a mount point of a network share is that share.
        if (!readableType(mountTypeOf(next, mounts)))
            return Refusal::NotLocal;
        struct stat st {};
        const QByteArray encoded = QFile::encodeName(next);
        if (::lstat(encoded.constData(), &st) != 0)
            return Refusal::Unreadable;
        if (S_ISLNK(st.st_mode)) {
            char buffer[4096];
            const ssize_t n = ::readlink(encoded.constData(), buffer, sizeof buffer);
            if (n <= 0 || n == ssize_t(sizeof buffer) || ++links > 40)
                return Refusal::Unreadable;
            const QString target = QFile::decodeName(QByteArray(buffer, int(n)));
            pending = (target.startsWith(QLatin1Char('/')) ? target : cur + QLatin1Char('/') + target).split(QLatin1Char('/'), Qt::SkipEmptyParts) + pending;
            cur = QStringLiteral("/");
            continue;
        }
        if (pending.isEmpty()) {
            if (!S_ISREG(st.st_mode))
                return Refusal::NotRegular;
            if (out)
                *out = st;
            if (resolved)
                *resolved = next;
            return Refusal::None;
        }
        if (!S_ISDIR(st.st_mode))
            return Refusal::Unreadable;
        cur = next;
    }
    return Refusal::NotRegular; // the root folder itself
}

int openChecked(const QString &resolved, const struct stat &checked)
{
    // O_NOFOLLOW: a link swapped in at the checked path after the check is refused (ELOOP) instead of followed, wherever it
    // leads (a network share would block the open). O_NONBLOCK: a FIFO swapped in opens at once (and is refused below)
    // instead of waiting for a writer.
    const int fd = ::open(QFile::encodeName(resolved).constData(), O_RDONLY | O_NONBLOCK | O_NOCTTY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0)
        return -1;
    struct stat opened {};
    if (::fstat(fd, &opened) != 0 || !S_ISREG(opened.st_mode) || opened.st_dev != checked.st_dev || opened.st_ino != checked.st_ino) {
        ::close(fd);
        return -1;
    }
    return fd;
}

QSize read(const QString &path, const FolderStyleStore::Mounts &mounts)
{
    struct stat checked {};
    QString resolved;
    if (check(path, mounts, &checked, &resolved) != Refusal::None)
        return QSize();
    // The path check() reached (a link to a picture is read through its target), never a link any more.
    const int fd = openChecked(resolved, checked);
    if (fd < 0)
        return QSize();
    BudgetFile file;
    if (!file.open(fd, QIODevice::ReadOnly, QFileDevice::AutoCloseHandle)) {
        ::close(fd);
        return QSize();
    }
    // No file name: the format is the content's, whatever the name says.
    QImageReader reader(&file);
    reader.setAutoTransform(true);
    QSize pixels = reader.size();
    if (pixels.isValid() && (reader.transformation() & QImageIOHandler::TransformationRotate90))
        pixels.transpose();
    return pixels.isValid() ? pixels : QSize();
}

struct Reader::Shared {
    std::mutex mutex;
    std::condition_variable idle;
    std::deque<QString> queue;
    QObject *owner = nullptr; // null once the Reader is gone: nothing is delivered after that
    Ready ready;
    bool running = false;
    std::optional<FolderStyleStore::Mounts> mounts; // tests
};

void Reader::run(const std::shared_ptr<Shared> &s)
{
    std::optional<FolderStyleStore::Mounts> mounts;
    for (;;) {
        QString path;
        {
            std::lock_guard<std::mutex> lock(s->mutex);
            if (s->queue.empty() || !s->owner) {
                s->running = false;
                s->idle.notify_all();
                return;
            }
            path = s->queue.front();
            s->queue.pop_front();
            if (!mounts && s->mounts)
                mounts = s->mounts;
        }
        // Once per run: plain files, reading them never touches a mount.
        if (!mounts)
            mounts = FolderStyleStore::Mounts::system();
        const QSize size = read(path, *mounts);
        std::lock_guard<std::mutex> lock(s->mutex);
        // Posted under the lock: the owner cannot go meanwhile, and a call still queued when it goes is dropped with it.
        if (s->owner) {
            const Ready ready = s->ready;
            QMetaObject::invokeMethod(s->owner, [ready, path, size] { ready(path, size); }, Qt::QueuedConnection);
        }
    }
}

Reader::Reader(QObject *owner, Ready ready)
    : m_shared(std::make_shared<Shared>())
{
    m_shared->owner = owner;
    m_shared->ready = std::move(ready);
}

Reader::~Reader()
{
    std::unique_lock<std::mutex> lock(m_shared->mutex);
    m_shared->owner = nullptr;
    m_shared->queue.clear();
    // A local header takes milliseconds; a read that takes longer is abandoned (it ends on its own and delivers nothing).
    m_shared->idle.wait_for(lock, std::chrono::milliseconds(kExitGraceMs), [this] { return !m_shared->running; });
}

void Reader::request(const QString &path)
{
    std::lock_guard<std::mutex> lock(m_shared->mutex);
    if (std::find(m_shared->queue.cbegin(), m_shared->queue.cend(), path) != m_shared->queue.cend())
        return;
    m_shared->queue.push_back(path);
    if (m_shared->running)
        return;
    m_shared->running = true;
    const std::shared_ptr<Shared> s = m_shared;
    std::thread([s] { run(s); }).detach();
}

void Reader::setMountsForTests(const FolderStyleStore::Mounts &mounts)
{
    std::lock_guard<std::mutex> lock(m_shared->mutex);
    m_shared->mounts = mounts;
}
} // namespace ImageSize
