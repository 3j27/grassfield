#include "Penalties.h"

#include <QFile>
#include <QSaveFile>

#include <algorithm>
#include <cerrno>
#include <climits>
#include <cstring>
#include <ctime>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace gf::menubridge {

    namespace {
        constexpr const char* kHeader = "grassfield-menu-bridge-state 1";

        QByteArray encodeIdentity(const QString& id) {
            return id.toUtf8().toPercentEncoding(QByteArrayLiteral("/:"));
        }

        // The identity of a state-file token, empty if the token is not a valid identity.
        QString decodeIdentity(const QByteArray& token) {
            if (token.isEmpty() || token.size() > penalty::kMaxIdentity * 6)
                return {};
            const QString id = QString::fromUtf8(QByteArray::fromPercentEncoding(token));
            return validIdentity(id) ? id : QString();
        }

        bool parseInt(const QByteArray& token, qint64 min, qint64 max, qint64* out) {
            bool         ok = false;
            const qint64 v  = token.toLongLong(&ok);
            if (!ok || v < min || v > max)
                return false;
            *out = v;
            return true;
        }
    } // namespace

    qint64 nowSec() {
        timespec ts{};
        ::clock_gettime(CLOCK_BOOTTIME, &ts);
        return ts.tv_sec;
    }

    QString bootId() {
        QFile f(QStringLiteral("/proc/sys/kernel/random/boot_id"));
        if (!f.open(QIODevice::ReadOnly))
            return QStringLiteral("unknown");
        const QString id = QString::fromLatin1(f.read(64)).trimmed();
        return id.isEmpty() ? QStringLiteral("unknown") : id;
    }

    bool validIdentity(const QString& id) {
        if (id.startsWith(QLatin1String("pid:"))) {
            const QString digits = id.mid(4);
            if (digits.isEmpty() || digits.size() > 10)
                return false;
            return std::all_of(digits.cbegin(), digits.cend(), [](QChar c) { return c >= u'0' && c <= u'9'; });
        }
        if (!id.startsWith(QLatin1String("exe:/")) || id.size() > penalty::kMaxIdentity)
            return false;
        return std::none_of(id.cbegin(), id.cend(), [](QChar c) { return c.unicode() < 0x20 || c.unicode() == 0x7F; });
    }

    QString appIdentity(qint64 pid) {
        const QString fallback = QStringLiteral("pid:%1").arg(pid);
        char          buf[PATH_MAX + 1];
        const QByteArray link = QByteArrayLiteral("/proc/") + QByteArray::number(pid) + "/exe";
        const ssize_t    n    = ::readlink(link.constData(), buf, PATH_MAX);
        if (n <= 0)
            return fallback; // not readable (another user's or a non-dumpable process): the pid is all we have
        QString exe = QString::fromUtf8(buf, static_cast<qsizetype>(n));
        if (exe.endsWith(QLatin1String(" (deleted)")))
            exe.chop(10); // the binary was replaced while running (package upgrade): still the same application
        const QString id = QStringLiteral("exe:") + exe;
        return validIdentity(id) ? id : fallback;
    }

    PenaltyBook::Entry& PenaltyBook::entry(const QString& id) {
        auto it = m_entries.find(id);
        if (it == m_entries.end()) {
            if (m_entries.size() >= penalty::kMaxEntries)
                evictOne();
            it = m_entries.insert(id, Entry{});
        }
        it->touch = ++m_touch;
        return *it;
    }

    void PenaltyBook::evictOne() {
        const qint64 now    = m_clock();
        QString      victim;
        bool         victimDenied = true;
        quint64      victimTouch  = 0;
        for (auto it = m_entries.cbegin(); it != m_entries.cend(); ++it) {
            const bool denied = now < it->denyUntil;
            // Entries that are not refused right now go first; among equals the least recently used.
            if (victim.isEmpty() || (victimDenied && !denied) || (denied == victimDenied && it->touch < victimTouch)) {
                victim       = it.key();
                victimDenied = denied;
                victimTouch  = it->touch;
            }
        }
        if (!victim.isEmpty())
            m_entries.remove(victim);
    }

    void PenaltyBook::strike(Entry& e) {
        const qint64 now = m_clock();
        ++e.strikes;
        qint64 span = penalty::kDenyBaseSec;
        for (int i = 1; i < e.strikes && span < penalty::kDenyMaxSec; ++i)
            span *= 2;
        e.denyUntil  = now + std::min(span, penalty::kDenyMaxSec);
        e.lastStrike = now;
    }

    bool PenaltyBook::refused(const QString& id, QString* why) {
        const auto it = m_entries.find(id);
        if (it == m_entries.end())
            return false;
        const qint64 now = m_clock();
        // Decay: no strike for kForgiveSec after the last refusal ended.
        if (now >= it->denyUntil && now >= it->layoutUntil && now - it->lastStrike >= penalty::kForgiveSec) {
            m_entries.erase(it);
            return false;
        }
        it->touch = ++m_touch;
        if (now < it->denyUntil) {
            *why = QStringLiteral("this application's menu was refused (it crashed the bridge or sent an oversized menu), retrying in %1 min").arg((it->denyUntil - now + 59) / 60);
            return true;
        }
        if (now < it->layoutUntil) {
            *why = QStringLiteral("this application's menu failed %1 times, retrying in %2 s").arg(it->layoutFailures).arg(it->layoutUntil - now);
            return true;
        }
        return false;
    }

    void PenaltyBook::record(const QString& id, Offence what) {
        Entry& e = entry(id);
        if (what == Offence::LayoutFailed) {
            ++e.layoutFailures;
            qint64 span = 1;
            for (int i = 0; i < e.layoutFailures && span < penalty::kLayoutMaxSec; ++i)
                span *= 2;
            e.layoutUntil = m_clock() + std::min(span, penalty::kLayoutMaxSec);
            if (e.lastStrike == 0)
                e.lastStrike = m_clock(); // starts the decay clock of an entry without a strike
            return;
        }
        strike(e);
    }

    void PenaltyBook::delivered(const QString& id) {
        const auto it = m_entries.find(id);
        if (it == m_entries.end())
            return;
        it->layoutFailures = 0;
        it->layoutUntil    = 0;
        if (it->strikes == 0)
            m_entries.erase(it);
    }

    void PenaltyBook::leftCleanly(const QString& id) {
        const auto it = m_entries.find(id);
        if (it == m_entries.end())
            return;
        const qint64 now = m_clock();
        if (now < it->denyUntil)
            return; // refused right now: leaving does not clear anything (a refused application has no open menu anyway)
        if (it->strikes > 0)
            --it->strikes;
        it->layoutFailures = 0;
        it->layoutUntil    = 0;
        if (it->strikes == 0)
            m_entries.erase(it);
    }

    QByteArray PenaltyBook::serialize(const QStringList& inflight, const QString& boot) const {
        QByteArray out = QByteArray(kHeader) + '\n' + "boot " + boot.toLatin1() + '\n';
        for (const QString& id : inflight) {
            if (validIdentity(id))
                out += "inflight " + encodeIdentity(id) + '\n';
        }
        for (auto it = m_entries.cbegin(); it != m_entries.cend(); ++it) {
            if (it->strikes <= 0)
                continue;
            out += "deny " + QByteArray::number(it->strikes) + ' ' + QByteArray::number(it->denyUntil) + ' ' + QByteArray::number(it->lastStrike) + ' ' + encodeIdentity(it.key()) + '\n';
        }
        return out;
    }

    bool PenaltyBook::load(const QByteArray& data, const QString& boot, QString* why, QStringList* crashed) {
        if (data.size() > penalty::kMaxStateBytes) {
            *why = QStringLiteral("state file too large");
            return false;
        }
        const QList<QByteArray> lines = data.split('\n');
        if (lines.size() < 2 || lines.at(0) != kHeader) {
            *why = QStringLiteral("unknown header");
            return false;
        }
        if (lines.at(1) != "boot " + boot.toLatin1()) {
            *why = QStringLiteral("written in another boot");
            return false;
        }
        struct Deny {
            QString id;
            int     strikes;
            qint64  until;
            qint64  last;
        };
        QList<Deny>   denies;
        QStringList   inflight;
        const qint64  now = m_clock();
        for (qsizetype i = 2; i < lines.size(); ++i) {
            const QByteArray& line = lines.at(i);
            if (line.isEmpty())
                continue;
            if (denies.size() + inflight.size() >= penalty::kMaxEntries * 2) {
                *why = QStringLiteral("too many entries");
                return false;
            }
            const QList<QByteArray> f = line.split(' ');
            if (f.at(0) == "inflight" && f.size() == 2) {
                const QString id = decodeIdentity(f.at(1));
                if (id.isEmpty()) {
                    *why = QStringLiteral("invalid inflight identity");
                    return false;
                }
                inflight.append(id);
            } else if (f.at(0) == "deny" && f.size() == 5) {
                qint64 strikes = 0, until = 0, last = 0;
                const QString id = decodeIdentity(f.at(4));
                // Times are boot-relative seconds: not in the future by more than the longest refusal.
                if (id.isEmpty() || !parseInt(f.at(1), 1, 64, &strikes) || !parseInt(f.at(2), 0, now + penalty::kDenyMaxSec, &until) || !parseInt(f.at(3), 0, now, &last)) {
                    *why = QStringLiteral("invalid deny line");
                    return false;
                }
                denies.append({id, static_cast<int>(strikes), until, last});
            } else {
                *why = QStringLiteral("unknown line");
                return false;
            }
        }
        for (const Deny& d : denies) {
            Entry& e     = entry(d.id);
            e.strikes    = d.strikes;
            e.denyUntil  = d.until;
            e.lastStrike = d.last;
        }
        for (const QString& id : inflight) {
            record(id, Offence::Crash);
            if (crashed && !crashed->contains(id))
                crashed->append(id);
        }
        return true;
    }

    bool readStateFile(const QString& path, QByteArray* data, QString* why) {
        why->clear();
        const QByteArray local = QFile::encodeName(path);
        const int        fd    = ::open(local.constData(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | O_NOCTTY);
        if (fd < 0) {
            if (errno != ENOENT)
                *why = errno == ELOOP ? QStringLiteral("a symlink") : QString::fromLocal8Bit(std::strerror(errno));
            return false;
        }
        struct stat st{};
        if (::fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_uid != ::getuid() || st.st_size > penalty::kMaxStateBytes) {
            ::close(fd);
            *why = QStringLiteral("not a regular file of this user within %1 bytes").arg(penalty::kMaxStateBytes);
            return false;
        }
        data->clear();
        data->resize(static_cast<qsizetype>(st.st_size));
        qsizetype got = 0;
        while (got < data->size()) {
            const ssize_t n = ::read(fd, data->data() + got, static_cast<size_t>(data->size() - got));
            if (n <= 0)
                break;
            got += n;
        }
        ::close(fd);
        data->resize(got);
        return true;
    }

    bool writeStateFile(const QString& path, const QByteArray& data) {
        // QSaveFile writes through a symlink to its target: a link in the file's place is removed first (unlink never
        // follows it), so the rename below replaces the link itself.
        struct stat st{};
        if (::lstat(QFile::encodeName(path).constData(), &st) == 0 && S_ISLNK(st.st_mode))
            QFile::remove(path);
        QSaveFile f(path);
        if (!f.open(QIODevice::WriteOnly))
            return false;
        f.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
        if (f.write(data) != data.size()) {
            f.cancelWriting();
            return false;
        }
        return f.commit();
    }

} // namespace gf::menubridge
