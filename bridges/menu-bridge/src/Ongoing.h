#pragma once

// Ongoing activities (ADR-0052): org.grassfield.Ongoing1, the pure part (QtCore + the a{sv} conversion). Applications publish
// the state of something in progress (a timer, a transfer, a recording, an install, a call, a generic progress) and at most
// three actions; the shell draws everything (menu bar item, popover). Unit-tested in tests/unit/menu-bridge/tst_ongoing.cpp.
//
// Nothing an application sends is trusted:
//  - its identity comes from the kernel (resolveApp: the caller's uid, Flatpak's /.flatpak-info or its systemd app unit, then
//    an installed desktop entry), never from a field;
//  - every field is type- and range-checked (checkState); text is reduced to one plain line; unknown keys are refused;
//  - limits per app, in all, per sender (calls per second), and an activity ends when its publisher leaves the bus.
// While the session is locked the shell is sent a redacted form (no app, no text, no action).

#include <QByteArray>
#include <QHash>
#include <QList>
#include <QSet>
#include <QString>
#include <QStringList>
#include <QVariantMap>

#include <deque>
#include <functional>
#include <optional>

class QVariant;

namespace gf::menubridge::ongoing {

    inline constexpr char kService[]   = "org.grassfield.Ongoing1";
    inline constexpr char kInterface[] = "org.grassfield.Ongoing1";
    inline constexpr char kPath[]      = "/org/grassfield/Ongoing1";

    inline constexpr int    kMaxId          = 64;  // characters of an application's own activity id
    inline constexpr int    kMaxTitle       = 64;  // characters of a title after cleaning
    inline constexpr int    kMaxSubtitle    = 128; // characters of a subtitle after cleaning
    inline constexpr int    kMaxActions     = 3;
    inline constexpr int    kMaxActionId    = 32;
    inline constexpr int    kMaxLabel       = 24;  // characters of a button label after cleaning
    inline constexpr int    kMaxRawText     = 4096; // characters read of any text field before cleaning
    inline constexpr int    kMaxFields      = 16;  // entries of one state a{sv}
    inline constexpr int    kMaxPerApp      = 3;   // activities of one verified app (all its connections)
    inline constexpr int    kMaxTotal       = 16;  // activities in all
    inline constexpr int    kMaxSenders     = 64;  // connections the host keeps track of
    inline constexpr int    kRateCalls      = 10;  // calls of one connection ...
    inline constexpr qint64 kRateWindowMs   = 1000; // ... within this window
    inline constexpr int    kMaxQueued      = 4;   // calls of one connection waiting for its identity
    inline constexpr int    kIdentityTimeoutMs = 2000;
    inline constexpr qint64 kFutureSlackMs  = 60 * 1000;               // clocks of two processes differ a little
    inline constexpr qint64 kStartedPastMs  = 7LL * 24 * 60 * 60 * 1000; // an elapsed time older than this is refused
    inline constexpr qint64 kEndsAheadMs    = 24LL * 60 * 60 * 1000;     // a countdown longer than this is refused
    inline constexpr qint64 kExpireAfterEndsMs = 10 * 60 * 1000;         // an activity outlives its end time this long
    inline constexpr qint64 kMaxAppId       = 255;

    enum class Kind { Timer, Transfer, Recording, Install, Call, Progress };
    QString             kindName(Kind kind);
    std::optional<Kind> kindFromName(const QString& name);

    struct Action {
        QString id;
        QString label;
        bool    operator==(const Action&) const = default;
    };

    struct State {
        Kind                  kind = Kind::Progress;
        QString               title;
        QString               subtitle;
        std::optional<double> progress; // 0..1; nullopt: indeterminate
        std::optional<qint64> started;  // Unix ms: elapsed time shown
        std::optional<qint64> ends;     // Unix ms: countdown shown
        QList<Action>         actions;
        bool                  operator==(const State&) const = default;
    };

    // One plain line: C0/C1 controls and bidirectional formatting characters removed, white space collapsed, trimmed, at most
    // `max` characters (never cutting a surrogate pair).
    QString cleanText(const QString& raw, int max);
    bool    isValidActivityId(const QString& id); // [A-Za-z0-9_-]{1,64}
    bool    isValidActionId(const QString& id);   // [a-z][a-z0-9-]{0,31}
    bool    isValidAppId(const QString& id);      // a desktop id: [A-Za-z0-9._-]{1,255}, not starting with '.' or '-'
    bool    isValidKey(const QString& key);       // the host's own key of an activity: 16 lowercase hex digits

    // Publish's state after the D-Bus layer took it apart: the a{sv} without "actions", and the a(ss) actions when given.
    struct Input {
        QVariantMap   fields;
        bool          hasActions    = false;
        bool          actionsTypeOk = true; // "actions" was an a(ss)
        QList<Action> actions;
        int           entries = 0; // entries of the a{sv}, "actions" included
    };
    // From the Publish argument as QtDBus delivers it (a QDBusArgument of a{sv}, or an already converted QVariantMap).
    // nullopt when the argument is not an a{sv}.
    std::optional<Input> inputFromDBus(const QVariant& argument);

    struct Checked {
        std::optional<State> state;
        QString              error; // why it was refused (InvalidArgs message) when !state
    };
    // Validates and normalizes a Publish state at `nowMs` (Unix ms).
    Checked checkState(const Input& input, qint64 nowMs);

    // ---- identity ------------------------------------------------------------------------------------------------------

    // Installed desktop entries: id (file name without ".desktop", subdirectories joined with '-') -> Exec binary's name.
    class DesktopIndex {
      public:
        void        clear();
        void        add(const QString& id, const QString& execBinary);
        bool        has(const QString& id) const;
        QStringList withExec(const QString& binary) const;
        int         size() const {
            return static_cast<int>(m_exec.size());
        }
        // Reads `<dir>/*.desktop` and one level of subdirectories of each dir (at most `maxFiles` files of 64 KiB). Entries of
        // an earlier dir win (XDG precedence); a Hidden=true entry hides the id.
        void        scan(const QStringList& dirs, int maxFiles = 4096);
        // The [Desktop Entry] Exec's program name ("env VAR=x /usr/bin/foo --a" -> "foo"), "" when none; *hidden set from
        // Hidden=true.
        static QString execBinaryOf(const QByteArray& desktopText, bool* hidden = nullptr);
        // $XDG_DATA_HOME (or ~/.local/share) and $XDG_DATA_DIRS (or /usr/local/share:/usr/share), each + "/applications".
        static QStringList applicationDirs();

      private:
        QHash<QString, QString> m_exec;   // id -> binary
        QSet<QString>           m_hidden; // ids hidden by an earlier dir
    };

    // The app id of the systemd app unit in a /proc/<pid>/cgroup text: app-[<launcher>-]<id>-<instance>.scope or
    // app-[<launcher>-]<id>@<instance>.service, \xNN escapes decoded. "" when there is none or the name is ambiguous.
    QString unitAppId(const QString& cgroupText);
    // [Application] name= of a /.flatpak-info, "" when malformed.
    QString flatpakAppId(const QByteArray& info);

    struct ProcFacts {
        uint       uid = 0;
        QString    cgroup;
        bool       flatpak = false; // /proc/<pid>/root/.flatpak-info exists
        QByteArray flatpakInfo;
    };
    struct Verdict {
        QString appId; // the verified desktop id, "" when refused
        QString error; // why not
    };
    Verdict resolveApp(const ProcFacts& facts, uint ownUid, const DesktopIndex& index);

    // ---- the book of activities ------------------------------------------------------------------------------------------

    struct Activity {
        QString key;     // the host's own id (what the shell sees)
        QString appId;   // verified
        QString localId; // the application's id
        QString owner;   // unique bus name that created it
        State   state;
        quint64 seq = 0; // creation order
    };

    class Book {
      public:
        explicit Book(std::function<QString()> newKey = {});

        struct Result {
            bool    ok = false;
            QString error;   // D-Bus error name when !ok
            QString message;
            QString key;     // the activity created or replaced
            bool    changed = false; // something the shell sees changed
        };
        Result              publish(const QString& sender, const QString& appId, const QString& localId, const State& state);
        // The key of the ended activity, nullopt when `sender` owns none called `localId` of `appId`.
        std::optional<QString> end(const QString& sender, const QString& appId, const QString& localId);
        QStringList         senderGone(const QString& sender);
        QStringList         expire(qint64 nowMs);
        const Activity*     byKey(const QString& key) const;
        QList<Activity>     all() const; // creation order
        bool                hasEnds() const;
        int                 count() const {
            return static_cast<int>(m_items.size());
        }
        int                 countFor(const QString& appId) const;

      private:
        std::function<QString()> m_newKey;
        QHash<QString, Activity> m_items; // key -> activity
        quint64                  m_seq = 0;
    };

    // Calls per connection within a sliding window.
    class RateLimiter {
      public:
        bool allow(const QString& sender, qint64 nowMs);
        void forget(const QString& sender);
        int  size() const { // connections with calls remembered
            return static_cast<int>(m_calls.size());
        }

      private:
        QHash<QString, std::deque<qint64>> m_calls;
    };

    // menu/1 "ongoing" line of `a` (redacted: no app, no text, no action) and "ongoing-end".
    QByteArray ongoingMessage(const Activity& a, bool redacted);
    QByteArray ongoingEndMessage(const QString& key);

    // ---- the host without the bus (OngoingObject is its D-Bus adapter) -------------------------------------------------------

    // What the bridge read about a caller's process (OngoingObject::resolve), judged by judgeCaller.
    struct ProcReads {
        uint                  uid = 0;
        qint64                pid = 0;
        bool                  rootUnreadable = false; // /proc/<pid>/root/.flatpak-info failed with another error than ENOENT
        bool                  flatpak        = false;
        QByteArray            flatpakInfo;
        QString               cgroup;
        std::optional<qint64> pidfdPid; // the Pid of the bus's pidfd after the reads; nullopt when the bus gave none
    };
    // Why the reads cannot be trusted ("" when they can): an unreadable root (a Flatpak cannot be told from a native app),
    // no cgroup, or a pidfd that no longer pins `pid` (the process exited, its pid may be another's now). Fail closed.
    QString readProblem(const ProcReads& reads);
    // readProblem, then resolveApp.
    Verdict judgeCaller(const ProcReads& reads, uint ownUid, const DesktopIndex& index);

    inline constexpr qint64 kRefusalCacheMs = 5000; // a refused connection is answered from memory this long
    inline constexpr int    kMaxRefusals    = 256;  // refusals remembered

    // Who may call before anything else is done: a refusal remembered for kRefusalCacheMs (no credential look-up per call of
    // an unverified publisher), the cap on connections tracked (idle ones, verified but holding no activity, give their
    // place), and the rate limit (End is exempt: an end must never be lost). Pure.
    class Admission {
      public:
        enum class Outcome { Admit, Refused, TooManyConnections, RateLimited };
        struct Result {
            Outcome     outcome = Outcome::Admit;
            QString     message;
            QStringList evicted; // idle connections to forget before admitting
        };
        // A call of `member` (End is exempt from the rate limit). `tracked`: the connections the host tracks now, each with
        // whether its identity is verified yet; `holds`: whether a connection owns an activity. Only a verified connection
        // holding nothing is idle (evicted for a newcomer at the cap); one still being looked up, or holding an activity, never.
        Result admit(const QString& sender, const QString& member, qint64 nowMs, const QHash<QString, bool>& tracked, const std::function<bool(const QString&)>& holds);
        void   refused(const QString& sender, const QString& why, qint64 nowMs);
        void   forget(const QString& sender);
        int    refusals() const {
            return static_cast<int>(m_refusals.size());
        }
        int    rateEntries() const {
            return m_rate.size();
        }

      private:
        struct Refusal {
            qint64  untilMs = 0;
            QString why;
        };
        RateLimiter              m_rate;
        QHash<QString, Refusal>  m_refusals;
    };

    // The activities, the lock state and what the shell is sent. Every line goes through `send`.
    class Host {
      public:
        using Send = std::function<void(const QByteArray& line)>;
        explicit Host(Send send, std::function<QString()> newKey = {});

        struct Call {
            bool    ok = false;
            QString error; // D-Bus error name when !ok
            QString message;
        };
        // Publish from `sender`, whose verified application is `appId`.
        Call              publish(const QString& sender, const QString& appId, const QString& localId, const Input& input, qint64 nowMs);
        void              end(const QString& sender, const QString& appId, const QString& localId);
        void              senderGone(const QString& sender);
        void              expire(qint64 nowMs);
        bool              holds(const QString& sender) const; // `sender` owns an activity

        // A shell connected: the session counts as locked until it says otherwise.
        void              resetLock();
        // The shell's lock report: every activity is sent again in the matching form.
        void              setLocked(bool locked);
        bool              locked() const {
            return m_locked;
        }
        QList<QByteArray> snapshot() const;

        struct Invocation {
            QString error; // "locked", "unknown-activity", "unknown-action"; "" when the signal may go
            QString owner;
            QString localId;
            QString appId;
        };
        Invocation        invoke(const QString& key, const QString& action) const;
        const Book&       book() const {
            return m_book;
        }

      private:
        Send m_send;
        Book m_book;
        bool m_locked = true;
    };

    // The <interface> element served for introspection, identical to the one in dbus/org.grassfield.Ongoing1.xml.
    QString interfaceXml();

    // 16 random lowercase hex digits.
    QString randomKey();

} // namespace gf::menubridge::ongoing
