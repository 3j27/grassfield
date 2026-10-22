#include "Launcher.h"

#include <QMetaType>

#include <algorithm>
#include <cmath>

namespace gf::menubridge::launcher {

    namespace {
        constexpr QLatin1String kPrefix("application://");
        constexpr QLatin1String kSuffix(".desktop");

        bool idChar(QChar c) {
            const ushort u = c.unicode();
            return (u >= 'a' && u <= 'z') || (u >= 'A' && u <= 'Z') || (u >= '0' && u <= '9') || u == '.' || u == '_' || u == '-';
        }

        bool isType(const QVariant& v, QMetaType::Type t) {
            return v.typeId() == t;
        }

    } // namespace

    std::optional<QString> appFromUri(const QString& uri) {
        if (!uri.startsWith(kPrefix) || !uri.endsWith(kSuffix) || uri.size() < kPrefix.size() + kSuffix.size())
            return std::nullopt;
        const QString id = uri.mid(kPrefix.size(), uri.size() - kPrefix.size() - kSuffix.size());
        if (id.isEmpty() || id.size() > kMaxIdBytes || !std::all_of(id.cbegin(), id.cend(), idChar))
            return std::nullopt; // the charset is ASCII: characters equal bytes
        return id;
    }

    void Properties::merge(const Properties& later) {
        if (later.count)
            count = later.count;
        if (later.countVisible)
            countVisible = later.countVisible;
        if (later.progress)
            progress = later.progress;
        if (later.progressVisible)
            progressVisible = later.progressVisible;
        if (later.urgent)
            urgent = later.urgent;
    }

    Parsed parse(const QString& uri, const QVariantMap& properties) {
        Parsed out;
        const auto app = appFromUri(uri);
        if (!app)
            return out;
        out.valid = true;
        out.app   = *app;
        if (properties.size() > kMaxProperties) {
            out.dropped = true; // nothing is read from an absurd map
            return out;
        }
        for (auto it = properties.cbegin(); it != properties.cend(); ++it) {
            const QString&  key = it.key();
            const QVariant& v   = it.value();
            if (key == QLatin1String("count")) {
                if (isType(v, QMetaType::LongLong))
                    out.properties.count = std::clamp<qint64>(v.toLongLong(), 0, kMaxCount);
                else
                    out.dropped = true;
            } else if (key == QLatin1String("progress")) {
                if (isType(v, QMetaType::Double) && std::isfinite(v.toDouble()))
                    out.properties.progress = std::clamp(v.toDouble(), 0.0, 1.0);
                else
                    out.dropped = true;
            } else if (key == QLatin1String("count-visible")) {
                if (isType(v, QMetaType::Bool))
                    out.properties.countVisible = v.toBool();
                else
                    out.dropped = true;
            } else if (key == QLatin1String("progress-visible")) {
                if (isType(v, QMetaType::Bool))
                    out.properties.progressVisible = v.toBool();
                else
                    out.dropped = true;
            } else if (key == QLatin1String("urgent")) {
                if (isType(v, QMetaType::Bool))
                    out.properties.urgent = v.toBool();
                else
                    out.dropped = true;
            }
        }
        return out;
    }

    Update Book::apply(const QString& app, Entry& e, const Properties& p) {
        Update u;
        u.app = app;
        if (p.count)
            e.rawCount = p.count;
        if (p.countVisible)
            e.countVisible = *p.countVisible;
        if (p.progress)
            e.rawProgress = p.progress;
        if (p.progressVisible)
            e.progressVisible = *p.progressVisible;
        if (p.count || p.countVisible) {
            if (!e.countVisible)
                u.count = 0;
            else if (e.rawCount)
                u.count = *e.rawCount;
        }
        if (p.progress || p.progressVisible) {
            if (!e.progressVisible)
                u.progress = -1.0;
            else if (e.rawProgress)
                u.progress = *e.rawProgress;
        }
        if (p.urgent) {
            e.urgent = p.urgent;
            u.urgent = p.urgent;
        }
        if (!u.forget())
            e.hasState = true;
        return u;
    }

    bool Book::take(Sender& s, qint64 nowMs) {
        while (!s.times.empty() && s.times.front() <= nowMs - kWindowMs)
            s.times.pop_front();
        if (static_cast<int>(s.times.size()) >= kMaxPerSecond)
            return false;
        s.times.push_back(nowMs);
        return true;
    }

    Book::Result Book::submit(const QString& sender, const QString& uri, const QVariantMap& properties, qint64 nowMs) {
        Result r;
        auto   sit = m_senders.find(sender);
        if (sit == m_senders.end()) {
            if (static_cast<int>(m_senders.size()) >= kMaxSenders) {
                r.dropped = true;
                return r;
            }
            sit = m_senders.insert(sender, Sender{});
        }
        const Parsed p      = parse(uri, properties);
        const bool   budget = take(sit.value(), nowMs);
        if (!budget) {
            r.throttled = true;
            if (!p.valid || p.properties.empty())
                return r;
        } else if (!p.valid) {
            r.malformed = true;
            return r;
        } else {
            r.malformed = p.dropped;
        }

        auto it = m_apps.find(p.app);
        if (it == m_apps.end()) {
            if (static_cast<int>(m_apps.size()) >= kMaxApps) {
                r.dropped = true;
                return r;
            }
            it = m_apps.insert(p.app, Entry{});
        }
        Entry& e = it.value();
        e.owner  = sender;
        if (!budget) {
            e.pending.merge(p.properties); // the last properties per app win
            return r;
        }
        Properties props = e.pending;
        props.merge(p.properties);
        e.pending = {};
        const Update u = apply(p.app, e, props);
        if (!u.forget())
            r.forward.push_back(u);
        if (!e.hasState && e.pending.empty())
            m_apps.erase(it);
        return r;
    }

    std::vector<Update> Book::flush(qint64 nowMs) {
        std::vector<Update> out;
        QStringList         apps = m_apps.keys();
        apps.sort();
        for (const QString& app : apps) {
            Entry& e = m_apps[app];
            if (e.pending.empty())
                continue;
            auto sit = m_senders.find(e.owner);
            if (sit == m_senders.end() || !take(sit.value(), nowMs))
                continue;
            const Properties props = e.pending;
            e.pending              = {};
            const Update u         = apply(app, e, props);
            if (!u.forget())
                out.push_back(u);
            if (!e.hasState)
                m_apps.remove(app);
        }
        return out;
    }

    bool Book::hasPending() const {
        return std::any_of(m_apps.cbegin(), m_apps.cend(), [](const Entry& e) { return !e.pending.empty(); });
    }

    std::vector<Update> Book::senderGone(const QString& sender) {
        std::vector<Update> out;
        m_senders.remove(sender);
        QStringList apps = m_apps.keys();
        apps.sort();
        for (const QString& app : apps) {
            const Entry& e = m_apps[app];
            if (e.owner != sender)
                continue;
            if (e.hasState) {
                Update u;
                u.app = app;
                out.push_back(u); // every value empty: forget
            }
            m_apps.remove(app);
        }
        return out;
    }

    std::vector<Update> Book::snapshot() const {
        std::vector<Update> out;
        QStringList         apps = m_apps.keys();
        apps.sort();
        for (const QString& app : apps) {
            const Entry& e = m_apps.value(app);
            if (!e.hasState)
                continue;
            Update u;
            u.app = app;
            if (!e.countVisible)
                u.count = 0;
            else if (e.rawCount)
                u.count = *e.rawCount;
            if (!e.progressVisible)
                u.progress = -1.0;
            else if (e.rawProgress)
                u.progress = *e.rawProgress;
            u.urgent = e.urgent;
            if (!u.forget())
                out.push_back(u);
        }
        return out;
    }

} // namespace gf::menubridge::launcher
