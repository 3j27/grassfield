#include "Identity.h"

#include "Peer.h"
#include "Text.h"

#include <QDir>
#include <QFile>

#include <climits>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef STATX_MNT_ID
#define STATX_MNT_ID 0x00001000U // Linux 5.8
#endif

namespace gf::prompter {

    namespace {
        bool ownedNotWritable(const QByteArray& path, bool directory, uid_t owner) {
            struct stat st{};
            if (::lstat(path.constData(), &st) != 0)
                return false;
            if (directory ? !S_ISDIR(st.st_mode) : !S_ISREG(st.st_mode))
                return false;
            return st.st_uid == owner && !(st.st_mode & (S_IWGRP | S_IWOTH));
        }

        QString unescapeValue(const QString& value) {
            QString out;
            out.reserve(value.size());
            for (qsizetype i = 0; i < value.size(); ++i) {
                const QChar ch = value.at(i);
                if (ch != u'\\' || i + 1 >= value.size()) {
                    out.append(ch);
                    continue;
                }
                const QChar next = value.at(++i);
                if (next == u's')
                    out.append(u' ');
                else if (next == u'n')
                    out.append(u'\n');
                else if (next == u't')
                    out.append(u'\t');
                else if (next == u'r')
                    out.append(u'\r');
                else if (next == u'\\')
                    out.append(u'\\');
                else
                    out.append(u'\\').append(next);
            }
            return out;
        }

        bool fieldCode(const QString& token) {
            static const QStringList codes{QStringLiteral("%f"), QStringLiteral("%F"), QStringLiteral("%u"), QStringLiteral("%U"),
                                           QStringLiteral("%i"), QStringLiteral("%c"), QStringLiteral("%k")};
            return codes.contains(token);
        }

        // The Exec line's arguments (the desktop entry specification's quoting); false on any quoting error or reserved
        // character outside quotes.
        bool splitExec(const QString& exec, QStringList* tokens) {
            static const QString reserved = QStringLiteral("\t\n\"'\\><~|&;$*?#()`");
            qsizetype            i        = 0;
            while (i < exec.size()) {
                while (i < exec.size() && exec.at(i) == u' ')
                    ++i;
                if (i >= exec.size())
                    break;
                QString token;
                if (exec.at(i) == u'"') {
                    ++i;
                    bool closed = false;
                    while (i < exec.size()) {
                        const QChar ch = exec.at(i);
                        if (ch == u'"') {
                            closed = true;
                            ++i;
                            break;
                        }
                        if (ch == u'\\') {
                            if (i + 1 >= exec.size())
                                return false;
                            const QChar next = exec.at(i + 1);
                            if (next != u'"' && next != u'`' && next != u'$' && next != u'\\')
                                return false;
                            token.append(next);
                            i += 2;
                            continue;
                        }
                        if (ch == u'`' || ch == u'$')
                            return false;
                        token.append(ch);
                        ++i;
                    }
                    if (!closed || (i < exec.size() && exec.at(i) != u' '))
                        return false;
                } else {
                    while (i < exec.size() && exec.at(i) != u' ') {
                        if (reserved.contains(exec.at(i)))
                            return false;
                        token.append(exec.at(i));
                        ++i;
                    }
                }
                tokens->append(token);
            }
            return true;
        }

        // A program of an Exec line, made absolute: an absolute path as it is (clean), a bare name in `dirs`.
        QString resolveProgram(const QString& program, const QStringList& dirs) {
            if (program.startsWith(u'/'))
                return QDir::cleanPath(program) == program ? program : QString();
            if (program.contains(u'/'))
                return {};
            for (const QString& dir : dirs) {
                const QString candidate = dir + u'/' + program;
                if (fileIdOf(candidate).valid)
                    return candidate;
            }
            return {};
        }
    } // namespace

    FileId fileIdOf(const QString& path) {
        struct stat st{};
        if (path.isEmpty() || ::stat(QFile::encodeName(path).constData(), &st) != 0)
            return {};
        return {true, st.st_dev, st.st_ino};
    }

    bool trustedPath(const QString& path, uid_t owner, const QString& top) {
        if (!path.startsWith(u'/') || QDir::cleanPath(path) != path || path == QLatin1String("/"))
            return false;
        const QString root = QDir::cleanPath(top);
        if (root != QLatin1String("/") && !path.startsWith(root + u'/'))
            return false;
        if (!ownedNotWritable(QFile::encodeName(path), false, owner))
            return false;
        QString current = path;
        while (true) {
            const qsizetype slash = current.lastIndexOf(u'/');
            current               = slash <= 0 ? QStringLiteral("/") : current.left(slash);
            if (!ownedNotWritable(QFile::encodeName(current), true, owner))
                return false;
            if (current == root)
                return true;
            if (current == QLatin1String("/"))
                return false;
        }
    }

    DesktopEntry parseDesktopEntry(const QByteArray& text) {
        DesktopEntry entry;
        bool         inGroup = false;
        for (const QByteArray& rawLine : text.split('\n')) {
            const QString line = QString::fromUtf8(rawLine).trimmed();
            if (line.isEmpty() || line.startsWith(u'#'))
                continue;
            if (line.startsWith(u'[')) {
                inGroup = line == QLatin1String("[Desktop Entry]");
                continue;
            }
            if (!inGroup)
                continue;
            const qsizetype eq = line.indexOf(u'=');
            if (eq <= 0)
                continue;
            const QString key   = line.left(eq).trimmed();
            const QString value = unescapeValue(line.mid(eq + 1).trimmed());
            if (key == QLatin1String("Name"))
                entry.name = value;
            else if (key == QLatin1String("Icon"))
                entry.icon = value;
            else if (key == QLatin1String("Exec"))
                entry.exec = value;
            else if (key == QLatin1String("Type"))
                entry.application = value == QLatin1String("Application");
            else if (key == QLatin1String("Hidden"))
                entry.hidden = value == QLatin1String("true");
        }
        return entry;
    }

    QString execProgramOnly(const QString& exec) {
        QStringList tokens;
        if (!splitExec(exec, &tokens) || tokens.isEmpty())
            return {};
        const QString program = tokens.constFirst();
        if (program.isEmpty() || program.contains(u'=') || program.contains(u'%') || program == QLatin1String("env"))
            return {};
        for (qsizetype i = 1; i < tokens.size(); ++i) {
            if (!fieldCode(tokens.at(i)))
                return {};
        }
        return program;
    }

    std::optional<DesktopEntry> desktopEntryFor(const FileId& exe, const QString& dir, const QStringList& programDirs, uid_t owner,
                                                const QString& top) {
        if (!exe.valid)
            return std::nullopt;
        const QStringList names = QDir(dir).entryList({QStringLiteral("*.desktop")}, QDir::Files | QDir::System, QDir::Name);
        std::optional<DesktopEntry> found;
        int                         read = 0;
        for (const QString& name : names) {
            if (++read > 4096)
                break;
            const QString path = dir + u'/' + name;
            if (!trustedPath(path, owner, top))
                continue;
            QFile file(path);
            if (!file.open(QIODevice::ReadOnly) || file.size() > 64 * 1024)
                continue;
            DesktopEntry entry = parseDesktopEntry(file.read(64 * 1024));
            if (!entry.application || entry.hidden)
                continue;
            const QString program = resolveProgram(execProgramOnly(entry.exec), programDirs);
            if (program.isEmpty() || !(fileIdOf(program) == exe))
                continue;
            if (found)
                return std::nullopt; // two entries run the same file: neither is shown
            entry.id = name;
            found    = entry;
        }
        return found;
    }

    const QList<KnownCaller>& knownCallers() {
        static const QList<KnownCaller> known{
            {QStringLiteral("/usr/bin/gnome-keyring-daemon"), QStringLiteral("keyring")},
            {QStringLiteral("/usr/bin/pinentry-gnome3"), QStringLiteral("gnupg")},
            {QStringLiteral("/usr/bin/gpg-agent"), QStringLiteral("gnupg")},
            {QStringLiteral("/usr/lib/gcr-ssh-agent"), QStringLiteral("ssh")},
            // udiskie's password command in grassfield-automount.service (step 9c): any program of the user can run it with a
            // disk name of its own, so its text is another program's too (onBehalf).
            {QStringLiteral("/usr/lib/grassfield/grassfield-askpass"), QStringLiteral("disk")},
            // KIO's worker executable (step 9e): KF6 apps start one per network location, and it runs whatever worker plugin
            // its command line names, so any program of the user can make it ask, with a server of its own (onBehalf).
            {QStringLiteral("/usr/lib/kf6/kioworker"), QStringLiteral("kio")},
        };
        return known;
    }

    QString knownRole(const FileId& exe, const QList<KnownCaller>& known, uid_t owner, const QString& top) {
        for (const KnownCaller& k : known) {
            if (trustedPath(k.path, owner, top) && fileIdOf(k.path) == exe)
                return k.role;
        }
        return {};
    }

    QList<CodeMapping> executableMappings(const QByteArray& maps, bool* ok) {
        *ok = true;
        QList<CodeMapping> mappings;
        for (const QByteArray& line : maps.split('\n')) {
            if (line.isEmpty())
                continue;
            // address perms offset dev inode [path]: the path is everything after the fifth field (it may hold spaces).
            QByteArray fields[5];
            int        field = 0;
            qsizetype  i     = 0;
            while (field < 5 && i < line.size()) {
                const qsizetype start = i;
                while (i < line.size() && line.at(i) != ' ')
                    ++i;
                fields[field++] = line.mid(start, i - start);
                while (i < line.size() && line.at(i) == ' ')
                    ++i;
            }
            const qsizetype colon = fields[3].indexOf(':');
            bool            okMajor = false, okMinor = false, okInode = false;
            CodeMapping     m;
            m.major = fields[3].left(colon).toUInt(&okMajor, 16);
            m.minor = fields[3].mid(colon + 1).toUInt(&okMinor, 16);
            m.inode = fields[4].toULongLong(&okInode, 10);
            if (field < 5 || fields[1].size() != 4 || colon <= 0 || !okMajor || !okMinor || !okInode) {
                *ok = false;
                return {};
            }
            if (fields[1].at(2) != 'x')
                continue;
            const QByteArray path = line.mid(i);
            if (path.isEmpty() || path.startsWith('['))
                continue; // anonymous, or [vdso], [vsyscall]
            m.path = QFile::decodeName(path);
            if (!mappings.contains(m))
                mappings.append(m);
        }
        return mappings;
    }

    QHash<quint64, QPair<quint32, quint32>> mountDevices(const QByteArray& mountinfo) {
        // "<mount id> <parent id> <major>:<minor> <root> <mount point> ..." (proc(5)), the numbers in decimal.
        QHash<quint64, QPair<quint32, quint32>> devices;
        for (const QByteArray& line : mountinfo.split('\n')) {
            const QList<QByteArray> f = line.split(' ');
            if (f.size() < 3)
                continue;
            const qsizetype colon = f.at(2).indexOf(':');
            bool            okId = false, okMajor = false, okMinor = false;
            const quint64   id    = f.at(0).toULongLong(&okId);
            const quint32   major = f.at(2).left(colon).toUInt(&okMajor);
            const quint32   minor = f.at(2).mid(colon + 1).toUInt(&okMinor);
            if (okId && colon > 0 && okMajor && okMinor)
                devices.insert(id, {major, minor});
        }
        return devices;
    }

    QHash<quint64, QPair<quint32, quint32>> selfMountDevices() {
        QFile mountinfo(QStringLiteral("/proc/self/mountinfo"));
        return mountinfo.open(QIODevice::ReadOnly) ? mountDevices(mountinfo.read(4 * 1024 * 1024)) : QHash<quint64, QPair<quint32, quint32>>();
    }

    CodeMapping fileMapping(const QString& path, const QHash<quint64, QPair<quint32, quint32>>& devices) {
        CodeMapping  m;
        m.path = path;
        struct statx stx{};
        if (::statx(AT_FDCWD, QFile::encodeName(path).constData(), AT_SYMLINK_NOFOLLOW | AT_STATX_SYNC_AS_STAT, STATX_INO | STATX_MNT_ID, &stx) != 0
            || !(stx.stx_mask & STATX_INO) || !(stx.stx_mask & STATX_MNT_ID) || !devices.contains(stx.stx_mnt_id))
            return m;
        const auto device = devices.value(stx.stx_mnt_id);
        m.major           = device.first;
        m.minor           = device.second;
        m.inode           = stx.stx_ino;
        return m;
    }

    qint64 tracerPid(const QByteArray& status) {
        for (const QByteArray& line : status.split('\n')) {
            if (!line.startsWith("TracerPid:"))
                continue;
            bool         ok    = false;
            const qint64 value = line.mid(10).trimmed().toLongLong(&ok);
            return ok && value >= 0 ? value : -1;
        }
        return -1;
    }

    RequesterView requesterFor(const ExeFacts& facts, const Where& where) {
        RequesterView r;
        r.path = flatten(facts.path, caps::kPath);
        if (!facts.alive || !facts.sameUser || facts.traced || facts.path.isEmpty() || !facts.file.valid)
            return r;
        if (!trustedPath(facts.path, where.owner, where.top) || !(fileIdOf(facts.path) == facts.file))
            return r;
        if (const QString role = knownRole(facts.file, where.known, where.owner, where.top); !role.isEmpty()) {
            r.role       = role;
            r.identified = true;
            r.onBehalf   = true;
            return r;
        }
        // An app's name is lent only to a process that runs nothing but trusted code (decision 9-14): it shares the bridge's
        // mount and user namespaces, and each file it maps executable is a trusted path that names, by device and inode,
        // the very file it maps (counter-review of step 9a, MINOR-C).
        if (!facts.sameNamespaces || !facts.codeKnown || facts.code.isEmpty())
            return r;
        for (const CodeMapping& code : facts.code) {
            if (!trustedPath(code.path, where.owner, where.top) || code.inode == 0 || !(fileMapping(code.path, where.devices) == code))
                return r;
        }
        if (const auto entry = desktopEntryFor(facts.file, where.applications, where.programDirs, where.owner, where.top)) {
            const QString name = flatten(entry->name, caps::kName);
            if (name.isEmpty())
                return r;
            r.role       = QStringLiteral("app");
            r.name       = name;
            r.icon       = flatten(entry->icon, caps::kIcon);
            r.desktopId  = flatten(entry->id, caps::kDesktopId);
            r.identified = true;
        }
        return r;
    }

    namespace {
        QByteArray namespaceOf(const QByteArray& proc, const char* kind) {
            char          buffer[64];
            const ssize_t n = ::readlink((proc + "/ns/" + kind).constData(), buffer, sizeof buffer - 1);
            return n > 0 ? QByteArray(buffer, n) : QByteArray();
        }
    } // namespace

    ExeFacts exeFactsOfPidfd(int pidfd, bool withCode) {
        ExeFacts     facts;
        const qint64 pid = pidOfPidfd(pidfd);
        if (pid <= 0)
            return facts;
        const QByteArray link = QByteArrayLiteral("/proc/") + QByteArray::number(pid) + QByteArrayLiteral("/exe");
        char             buffer[PATH_MAX];
        const ssize_t    length = ::readlink(link.constData(), buffer, sizeof buffer - 1);
        if (length > 0)
            facts.path = QFile::decodeName(QByteArray(buffer, static_cast<qsizetype>(length)));
        const int fd = ::open(link.constData(), O_PATH | O_CLOEXEC);
        if (fd >= 0) {
            struct stat st{};
            if (::fstat(fd, &st) == 0)
                facts.file = {true, st.st_dev, st.st_ino};
            ::close(fd);
        }
        const QByteArray proc = QByteArrayLiteral("/proc/") + QByteArray::number(pid);
        if (withCode) {
            QFile status(QString::fromLatin1(proc + "/status"));
            if (status.open(QIODevice::ReadOnly))
                facts.traced = tracerPid(status.read(64 * 1024)) != 0;
            const QByteArray self = QByteArrayLiteral("/proc/self");
            const QByteArray mnt  = namespaceOf(proc, "mnt");
            const QByteArray user = namespaceOf(proc, "user");
            facts.sameNamespaces  = !mnt.isEmpty() && !user.isEmpty() && mnt == namespaceOf(self, "mnt") && user == namespaceOf(self, "user");
            // At most 8 MiB of mappings (a large browser has a few thousand lines); more reads as unknown.
            QFile maps(QString::fromLatin1(proc + "/maps"));
            if (maps.open(QIODevice::ReadOnly)) {
                const QByteArray text = maps.read(8 * 1024 * 1024 + 1);
                bool             ok   = false;
                facts.code            = executableMappings(text, &ok);
                facts.codeKnown       = ok && text.size() <= 8 * 1024 * 1024;
            }
        }
        // Every read is of the pidfd's process only if it still runs now: otherwise the PID may have been reused.
        facts.alive = pidfdAlive(pidfd);
        if (!facts.alive) {
            facts.path.clear();
            facts.file = {};
            facts.code.clear();
            facts.codeKnown      = false;
            facts.sameNamespaces = false;
            facts.traced         = true;
        }
        return facts;
    }

} // namespace gf::prompter
