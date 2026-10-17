#pragma once

// Hostile or broken applications (a huge GetLayout reply costs the bridge several times its size in memory) and the
// state that survives a bridge restart (ADR-0008, docs/specs/menu-bridge.md "Crash attribution").
//
// An application is identified by what the bridge itself observed after the pid check: the resolved
// /proc/<pid>/exe ("exe:/usr/bin/foo"), or "pid:<pid>" when that link is unreadable. A new pid of the same
// executable is the same application, so forking a fresh process does not escape a refusal.
//
// Offences: LayoutFailed (short back-off, 2^n s up to 64 s), Oversized and Crash (the bridge died while a call to the
// application was outstanding): refused for 15 min, doubling per strike up to 6 h. Entries decay: a strike is
// forgiven when the application leaves the bus while in good standing, and an entry is dropped after 24 h without
// a new strike. At most kMaxEntries identities are remembered (least recently used first out).
//
// The state file `<socket>.state` mirrors the identities with a call outstanding ("inflight") and the refusals
// ("deny"). It lives in the socket's directory (mode 0700, owned by the user): only code running as the same user can
// write it, which can equally kill the bridge or pass the pid check for its own processes. It is written atomically,
// read without following symlinks, size-bounded and fully validated.

#include <QByteArray>
#include <QHash>
#include <QString>
#include <QStringList>

#include <functional>

namespace gf::menubridge {

    namespace penalty {
        inline constexpr int       kMaxEntries     = 128;          // identities remembered (LRU)
        inline constexpr qint64    kLayoutMaxSec   = 64;           // LayoutFailed back-off cap
        inline constexpr qint64    kDenyBaseSec    = 15 * 60;      // first Oversized/Crash refusal
        inline constexpr qint64    kDenyMaxSec     = 6 * 60 * 60;  // cap of the doubling
        inline constexpr qint64    kForgiveSec     = 24 * 60 * 60; // no strike for this long: forgotten
        inline constexpr qsizetype kMaxStateBytes  = 32 * 1024;    // larger files are refused
        inline constexpr qsizetype kMaxIdentity    = 512;          // characters of an identity
        // An application whose call kills the bridge costs one restart: the next run refuses it (kDenyBaseSec).
        inline constexpr int       kRestartsBeforeRefusal = 1;
    } // namespace penalty

    enum class Offence { LayoutFailed, Oversized, Crash };

    // CLOCK_BOOTTIME in seconds (counts across suspend, same value in every bridge run of this boot).
    qint64  nowSec();
    QString bootId();

    // "exe:<resolved /proc/pid/exe>" or "pid:<pid>".
    QString appIdentity(qint64 pid);
    // True for strings appIdentity can produce: "exe:/…" (no control characters, bounded) or "pid:<digits>".
    bool    validIdentity(const QString& id);

    class PenaltyBook {
      public:
        explicit PenaltyBook(std::function<qint64()> clock = nowSec) : m_clock(std::move(clock)) {}

        // False with *why set while the identity is refused.
        bool refused(const QString& id, QString* why);
        void record(const QString& id, Offence what);
        // A menu was delivered: ends a LayoutFailed back-off (long refusals are not touched).
        void delivered(const QString& id);
        // The application left the bus while in good standing: one strike is forgiven.
        void leftCleanly(const QString& id);
        qsizetype size() const {
            return m_entries.size();
        }
        bool has(const QString& id) const {
            return m_entries.contains(id);
        }

        // "grassfield-menu-bridge-state 1" text: header, boot id, one "inflight" per identity of `inflight`, one
        // "deny" per active refusal.
        QByteArray serialize(const QStringList& inflight, const QString& boot) const;
        // Validates `data` and merges it: each inflight identity becomes a Crash offence (listed in *crashed), deny
        // lines are restored. False (nothing merged, *why set) for a malformed file or one written in another boot.
        bool load(const QByteArray& data, const QString& boot, QString* why, QStringList* crashed);

      private:
        struct Entry {
            int     layoutFailures = 0;
            int     strikes        = 0;
            qint64  layoutUntil    = 0;
            qint64  denyUntil      = 0;
            qint64  lastStrike     = 0;
            quint64 touch          = 0;
        };
        Entry& entry(const QString& id);
        void   evictOne();
        void   strike(Entry& e);

        std::function<qint64()> m_clock;
        QHash<QString, Entry>   m_entries;
        quint64                 m_touch = 0;
    };

    // The state file. read: opens with O_NOFOLLOW, requires a regular file owned by this user, at most
    // penalty::kMaxStateBytes. Returns false with *why empty when the file does not exist, and *why set when it was
    // refused. write: QSaveFile (atomic rename).
    bool readStateFile(const QString& path, QByteArray* data, QString* why);
    bool writeStateFile(const QString& path, const QByteArray& data);

} // namespace gf::menubridge
