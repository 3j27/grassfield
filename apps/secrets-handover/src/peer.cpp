#include "peer.h"

#include <QDBusConnectionInterface>
#include <QDBusMessage>
#include <QDBusReply>
#include <QDBusUnixFileDescriptor>
#include <QFile>
#include <QVariantMap>

#include <climits>
#include <fcntl.h>
#include <poll.h>
#include <sys/stat.h>
#include <unistd.h>

namespace grassfield::handover {

namespace {

// The PID behind a pidfd ("Pid:" of its fdinfo; -1 once the process is gone).
pid_t pidOf(int pidfd)
{
    QFile info(QStringLiteral("/proc/self/fdinfo/%1").arg(pidfd));
    if (!info.open(QIODevice::ReadOnly))
        return 0;
    const QList<QByteArray> lines = info.readAll().split('\n');
    for (const QByteArray &line : lines) {
        if (line.startsWith("Pid:")) {
            bool ok = false;
            const long value = line.mid(4).trimmed().toLong(&ok);
            return ok && value > 0 ? pid_t(value) : 0;
        }
    }
    return 0;
}

QString exeOf(pid_t pid)
{
    char buffer[PATH_MAX];
    const QByteArray link = QByteArrayLiteral("/proc/") + QByteArray::number(pid) + QByteArrayLiteral("/exe");
    const ssize_t length = ::readlink(link.constData(), buffer, sizeof buffer - 1);
    if (length <= 0)
        return {};
    return QString::fromLocal8Bit(buffer, int(length));
}

// The file /proc/<pid>/exe leads to, wherever it is mounted for that process.
bool exeFile(pid_t pid, struct stat &st)
{
    const QByteArray link = QByteArrayLiteral("/proc/") + QByteArray::number(pid) + QByteArrayLiteral("/exe");
    const int fd = ::open(link.constData(), O_PATH | O_CLOEXEC);
    if (fd < 0)
        return false;
    const bool ok = ::fstat(fd, &st) == 0;
    ::close(fd);
    return ok;
}

bool rootOwnedNotWritable(const QByteArray &path, bool directory)
{
    struct stat st {};
    if (::lstat(path.constData(), &st) != 0)
        return false;
    if (directory ? !S_ISDIR(st.st_mode) : !S_ISREG(st.st_mode))
        return false;
    return st.st_uid == 0 && !(st.st_mode & (S_IWGRP | S_IWOTH));
}

} // namespace

bool alive(int pidfd)
{
    if (pidfd < 0)
        return false;
    pollfd entry{pidfd, POLLIN, 0};
    return ::poll(&entry, 1, 0) == 0;
}

bool trustedExecutable(const QString &path)
{
    if (!path.startsWith(QLatin1Char('/')) || path.contains(QLatin1String("/../")) || path.contains(QLatin1String("/./")))
        return false;
    QByteArray current = QFile::encodeName(path);
    if (!rootOwnedNotWritable(current, false))
        return false;
    while (true) {
        const qsizetype slash = current.lastIndexOf('/');
        current = slash <= 0 ? QByteArrayLiteral("/") : current.left(slash);
        if (!rootOwnedNotWritable(current, true))
            return false;
        if (current == "/")
            return true;
    }
}

Peer identify(const QDBusConnection &bus, const QString &name)
{
    Peer peer;
    const QDBusReply<QString> owner = bus.interface()->serviceOwner(name);
    if (!owner.isValid() || owner.value().isEmpty())
        return peer;
    peer.owner = owner.value();

    QDBusMessage call = QDBusMessage::createMethodCall(QStringLiteral("org.freedesktop.DBus"), QStringLiteral("/org/freedesktop/DBus"),
                                                       QStringLiteral("org.freedesktop.DBus"), QStringLiteral("GetConnectionCredentials"));
    call << peer.owner;
    const QDBusMessage reply = bus.call(call, QDBus::Block, 5000);
    if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().isEmpty())
        return peer;
    const QVariantMap credentials = qdbus_cast<QVariantMap>(reply.arguments().constFirst());
    peer.uid = credentials.value(QStringLiteral("UnixUserID")).toUInt();
    const QVariant processFd = credentials.value(QStringLiteral("ProcessFD"));
    if (!processFd.canConvert<QDBusUnixFileDescriptor>())
        return peer;
    const auto descriptor = processFd.value<QDBusUnixFileDescriptor>();
    if (!descriptor.isValid())
        return peer;
    peer.pidfd = ::fcntl(descriptor.fileDescriptor(), F_DUPFD_CLOEXEC, 3);
    if (peer.pidfd < 0)
        return peer;
    peer.pid = pidOf(peer.pidfd);
    if (peer.pid <= 0)
        return peer;
    const QString exe = exeOf(peer.pid);
    struct stat st {};
    const bool hasFile = exeFile(peer.pid, st);
    // Read the executable, then check that the pidfd's process still runs: the PID was not reused in between.
    if (exe.isEmpty() || !hasFile || !alive(peer.pidfd))
        return peer;
    peer.exe = exe;
    peer.hasFile = true;
    peer.fileDev = st.st_dev;
    peer.fileIno = st.st_ino;
    peer.fileUid = st.st_uid;
    peer.fileMode = st.st_mode;
    peer.fileLinks = st.st_nlink;
    return peer;
}

void close(Peer &peer)
{
    if (peer.pidfd >= 0)
        ::close(peer.pidfd);
    peer = Peer();
}

bool is(const Peer &peer, const QString &expected)
{
    struct stat st {};
    if (!peer.hasFile || peer.uid != ::getuid() || !trustedExecutable(expected) || ::stat(QFile::encodeName(expected).constData(), &st) != 0)
        return false;
    return st.st_dev == peer.fileDev && st.st_ino == peer.fileIno && alive(peer.pidfd);
}

bool ranFrom(const Peer &peer, const QString &expected)
{
    if (is(peer, expected))
        return true;
    // Replaced since it started: the old file has no name left, was root's, and its path is a trusted one today.
    return peer.hasFile && peer.uid == ::getuid() && peer.exe == expected + QStringLiteral(" (deleted)") && peer.fileLinks == 0
        && S_ISREG(peer.fileMode) && peer.fileUid == 0 && !(peer.fileMode & (S_IWGRP | S_IWOTH)) && trustedExecutable(expected)
        && alive(peer.pidfd);
}

} // namespace grassfield::handover
