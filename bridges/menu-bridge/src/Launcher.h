#pragma once

// com.canonical.Unity.LauncherEntry `Update(s app_uri, a{sv} properties)`: badge, progress and urgent hint an
// application sets on its own Dock tile (ADR-0018, docs/specs/menu-bridge.md "LauncherEntry"). Pure logic (QtCore
// only), unit-tested in tests/unit/menu-bridge/. Every client of the bus may emit the signal: nothing is trusted.
//
// Validation:
//  - app_uri is "application://" + an id of 1..kMaxIdBytes bytes of [A-Za-z0-9._-] + ".desktop"; the id (without the
//    suffix) names the app. Anything else is malformed.
//  - count (type x) is clamped to 0..kMaxCount, progress (type d) must be finite and is clamped to 0..1, count-visible,
//    progress-visible and urgent are booleans (b). A property of another type is dropped (the update goes on without
//    it); it counts as malformed input. Unknown properties (quicklist...) are ignored.
//  - count-visible:false is forwarded as count 0, progress-visible:false as progress -1 ("hide").
// Limits: at most kMaxApps apps tracked, at most kMaxPerSecond updates per second per sender (an excess update is not
// forwarded at once: the last properties per app win and go out as soon as the sender's budget allows, "coalescing"),
// and an app's entry is cleared when the sender that last updated it leaves the bus.
//
// Forwarded values (Update): nullopt = this update said nothing about it. An Update with every value nullopt means
// "forget this app" (its sender left): the shell falls back to the notification-derived badge.

#include <QHash>
#include <QString>
#include <QVariantMap>

#include <deque>
#include <optional>
#include <vector>

namespace gf::menubridge::launcher {

    inline constexpr int    kMaxIdBytes    = 255;
    inline constexpr int    kMaxApps       = 64;
    inline constexpr int    kMaxPerSecond  = 20;
    inline constexpr int    kMaxSenders    = 64;
    inline constexpr int    kMaxProperties = 32; // entries of one a{sv} (more is malformed)
    inline constexpr qint64 kMaxCount      = 99999;
    inline constexpr qint64 kWindowMs      = 1000;

    // "application://<id>.desktop" -> id, nullopt when it is not exactly that.
    std::optional<QString> appFromUri(const QString& uri);

    // The properties of one update, as the application sent them (valid types only).
    struct Properties {
        std::optional<qint64> count;
        std::optional<bool>   countVisible;
        std::optional<double> progress;
        std::optional<bool>   progressVisible;
        std::optional<bool>   urgent;

        bool empty() const {
            return !count && !countVisible && !progress && !progressVisible && !urgent;
        }
        // Later values win.
        void merge(const Properties& later);
    };

    struct Parsed {
        bool       valid = false; // the uri is acceptable
        QString    app;
        Properties properties;
        bool       dropped = false; // a property of a wrong type (or too many properties) was dropped
    };
    Parsed parse(const QString& uri, const QVariantMap& properties);

    // What the shell is told (launcher message of menu/1).
    struct Update {
        QString               app;
        std::optional<qint64> count;    // 0: hide the badge
        std::optional<double> progress; // -1: hide the bar
        std::optional<bool>   urgent;

        bool forget() const {
            return !count && !progress && !urgent;
        }
        bool operator==(const Update&) const = default;
    };

    class Book {
      public:
        struct Result {
            std::vector<Update> forward;           // to send now
            bool                malformed = false; // a penalty for the sender
            bool                throttled = false; // coalesced instead of forwarded at once
            bool                dropped   = false; // not tracked: a limit (apps, senders)
        };

        // One signal from `sender` (a unique bus name) at `nowMs` (any monotonic clock, in ms).
        Result              submit(const QString& sender, const QString& uri, const QVariantMap& properties, qint64 nowMs);
        // Coalesced updates whose sender has budget again.
        std::vector<Update> flush(qint64 nowMs);
        bool                hasPending() const;
        // The sender left the bus: "forget" updates for the apps it owned.
        std::vector<Update> senderGone(const QString& sender);
        // The current state of every app (for a shell that connects later), sorted by app.
        std::vector<Update> snapshot() const;
        int                 apps() const {
            return static_cast<int>(m_apps.size());
        }
        int                 senders() const {
            return static_cast<int>(m_senders.size());
        }

      private:
        struct Entry {
            QString               owner;
            std::optional<qint64> rawCount;
            bool                  countVisible = true;
            std::optional<double> rawProgress;
            bool                  progressVisible = true;
            std::optional<bool>   urgent;
            bool                  hasState = false; // something was forwarded for this app
            Properties            pending;          // coalesced, not forwarded yet
        };
        struct Sender {
            std::deque<qint64> times; // forwarding slots used within the last kWindowMs
        };

        static Update apply(const QString& app, Entry& e, const Properties& p);
        static bool   take(Sender& s, qint64 nowMs);

        QHash<QString, Entry>  m_apps;
        QHash<QString, Sender> m_senders;
    };

} // namespace gf::menubridge::launcher
