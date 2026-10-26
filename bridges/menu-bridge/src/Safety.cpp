#include "Safety.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QStringList>

#include <array>
#include <cerrno>
#include <cstring>
#include <limits>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

namespace gf::menubridge {

    bool devRun(const QByteArray& devValue, const QByteArray& sessionValue) {
        return devValue == "1" && !sessionRun(sessionValue);
    }

    bool sessionRun(const QByteArray& sessionValue) {
        return sessionValue == "1";
    }

    quint64 pidNamespaceInode(const QByteArray& linkTarget) {
        if (!linkTarget.startsWith("pid:[") || !linkTarget.endsWith(']'))
            return 0;
        const QByteArray digits = linkTarget.mid(5, linkTarget.size() - 6);
        if (digits.isEmpty() || digits.size() > 20)
            return 0;
        for (const char c : digits) {
            if (c < '0' || c > '9')
                return 0;
        }
        bool          ok    = false;
        const quint64 inode = digits.toULongLong(&ok);
        return ok ? inode : 0;
    }

    bool inBridgePidNamespace(qint64 pid) {
        if (pid <= 0 || pid > std::numeric_limits<pid_t>::max())
            return false;
        auto inode = [](const QByteArray& path) -> quint64 {
            std::array<char, 64> buf{};
            const ssize_t        n = ::readlink(path.constData(), buf.data(), buf.size() - 1);
            return n > 0 ? pidNamespaceInode(QByteArray(buf.data(), static_cast<qsizetype>(n))) : 0;
        };
        const quint64 theirs = inode(QByteArray("/proc/") + QByteArray::number(pid) + "/ns/pid");
        const quint64 mine   = inode(QByteArrayLiteral("/proc/self/ns/pid"));
        return theirs != 0 && theirs == mine;
    }

    bool isDefaultSessionBus(const QString& address, uint uid) {
        if (address.trimmed().isEmpty())
            return true;
        const QString defaultPath = QStringLiteral("/run/user/%1/bus").arg(uid);
        for (const QString& entry : address.split(u';', Qt::SkipEmptyParts)) {
            const qsizetype colon = entry.indexOf(u':');
            if (colon < 0)
                return true; // malformed: assume the worst
            const QString transport = entry.left(colon).trimmed();
            if (transport == QLatin1String("autolaunch"))
                return true;
            if (transport != QLatin1String("unix"))
                continue;
            for (const QString& kv : entry.mid(colon + 1).split(u',', Qt::SkipEmptyParts)) {
                const qsizetype eq    = kv.indexOf(u'=');
                const QString   key   = kv.left(eq).trimmed();
                const QString   value = eq < 0 ? QString() : kv.mid(eq + 1).trimmed();
                if (key == QLatin1String("runtime") && value == QLatin1String("yes"))
                    return true;
                if (key == QLatin1String("path") && QDir::cleanPath(value) == defaultPath)
                    return true;
            }
        }
        return false;
    }

    QString socketPath(const QString& overridePath, const QString& runtimeDir) {
        if (!overridePath.isEmpty())
            return QDir::isAbsolutePath(overridePath) ? QDir::cleanPath(overridePath) : QString();
        if (runtimeDir.isEmpty() || !QDir::isAbsolutePath(runtimeDir))
            return {};
        return QDir::cleanPath(runtimeDir + QStringLiteral("/grassfield/menu-bridge.sock"));
    }

    bool fitsSocketPath(const QString& path) {
        return !path.isEmpty() && path.toLocal8Bit().size() < static_cast<qsizetype>(sizeof(sockaddr_un::sun_path));
    }

    QString prepareSocketDirectory(const QString& socketPath) {
        const QString    dir   = QFileInfo(socketPath).absolutePath();
        const QByteArray local = QFile::encodeName(dir);
        struct stat      st{};
        if (::lstat(local.constData(), &st) != 0) {
            if (errno != ENOENT)
                return QStringLiteral("cannot inspect %1: %2").arg(dir, QString::fromLocal8Bit(std::strerror(errno)));
            // The parent (e.g. $XDG_RUNTIME_DIR) must exist; only the last component is created.
            if (::mkdir(local.constData(), 0700) != 0)
                return QStringLiteral("cannot create %1: %2").arg(dir, QString::fromLocal8Bit(std::strerror(errno)));
            if (::lstat(local.constData(), &st) != 0)
                return QStringLiteral("cannot inspect %1 after creating it").arg(dir);
        }
        if (!S_ISDIR(st.st_mode))
            return QStringLiteral("%1 is not a directory (symlinks are refused)").arg(dir);
        if (st.st_uid != ::getuid())
            return QStringLiteral("%1 is not owned by this user").arg(dir);
        if ((st.st_mode & 077) != 0 && ::chmod(local.constData(), 0700) != 0)
            return QStringLiteral("cannot restrict %1 to mode 0700").arg(dir);
        return {};
    }

} // namespace gf::menubridge
