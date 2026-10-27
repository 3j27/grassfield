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
        const int slash = current.lastIndexOf('/');
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
    // Read the executable, then check that the pidfd's process still runs: the PID was not reused in between.
    if (!exe.isEmpty() && alive(peer.pidfd))
        peer.exe = exe;
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
    return !peer.exe.isEmpty() && peer.exe == expected && peer.uid == ::getuid() && trustedExecutable(expected) && alive(peer.pidfd);
}

} // namespace grassfield::handover
