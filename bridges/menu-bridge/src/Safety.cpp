#include "Safety.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QStringList>

#include <cerrno>
#include <cstring>
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

    int nsPidDepth(const QByteArray& statusText) {
        for (const QByteArray& raw : statusText.split('\n')) {
            if (!raw.startsWith("NSpid:"))
                continue;
            const QList<QByteArray> pids = raw.mid(6).simplified().split(' ');
            int                     n    = 0;
            for (const QByteArray& p : pids) {
                bool ok = false;
                if (p.toLongLong(&ok) <= 0 || !ok)
                    return 0;
                ++n;
            }
            return n;
        }
        return 0;
    }

    bool inBridgePidNamespace(qint64 pid) {
        if (pid <= 0)
            return false;
        auto read = [](const QString& path) {
            QFile f(path);
            return f.open(QIODevice::ReadOnly) ? f.read(16384) : QByteArray();
        };
        const int theirs = nsPidDepth(read(QStringLiteral("/proc/%1/status").arg(pid)));
        const int mine   = nsPidDepth(read(QStringLiteral("/proc/self/status")));
        return theirs > 0 && theirs == mine;
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
