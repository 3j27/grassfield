#include "Identity.h"

#include "Peer.h"
#include "Text.h"

#include <QDir>
#include <QFile>

#include <climits>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

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

    RequesterView requesterFor(const ExeFacts& facts, const Where& where) {
        RequesterView r;
        r.path = flatten(facts.path, caps::kPath);
        if (!facts.alive || !facts.sameUser || facts.path.isEmpty() || !facts.file.valid)
            return r;
        if (!trustedPath(facts.path, where.owner, where.top) || !(fileIdOf(facts.path) == facts.file))
            return r;
        if (const QString role = knownRole(facts.file, where.known, where.owner, where.top); !role.isEmpty()) {
            r.role       = role;
            r.identified = true;
            r.onBehalf   = true;
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

    ExeFacts exeFactsOfPidfd(int pidfd) {
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
        // Both reads are of the pidfd's process only if it still runs now: otherwise the PID may have been reused.
        facts.alive = pidfdAlive(pidfd);
        if (!facts.alive) {
            facts.path.clear();
            facts.file = {};
        }
        return facts;
    }

} // namespace gf::prompter
