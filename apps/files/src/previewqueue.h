#pragma once

#include <QHash>
#include <QList>
#include <QSet>
#include <QUrl>

// Thumbnail scheduling without KIO (Qt Core only, unit tested in tests/unit/files/).
//
// PreviewQueue: delegates request a thumbnail when they are created and cancel when they are
// destroyed, so a request that scrolled off screen before it was started never costs a job. The
// newest request is served first (LIFO): while scrolling, the items now on screen come before the
// ones that were visible a moment ago. Batches are capped so one job never holds a long backlog.
class PreviewQueue
{
public:
    // False when the url was already asked for (queued, running or done).
    bool request(const QUrl &url)
    {
        if (m_asked.contains(url))
            return false;
        m_asked.insert(url);
        m_pending.prepend(url);
        return true;
    }

    // Drops a queued request (the delegate is gone). A request already handed out stays asked.
    bool cancel(const QUrl &url)
    {
        if (!m_pending.removeOne(url))
            return false;
        m_asked.remove(url);
        return true;
    }

    // Forget that the url was asked for (thumbnail evicted or file changed): it may be requested again.
    void forget(const QUrl &url) { m_asked.remove(url); }

    QList<QUrl> takeBatch(int max)
    {
        const QList<QUrl> batch = m_pending.mid(0, max);
        m_pending.remove(0, batch.size());
        return batch;
    }

    bool isEmpty() const { return m_pending.isEmpty(); }
    int pendingCount() const { return m_pending.size(); }
    bool asked(const QUrl &url) const { return m_asked.contains(url); }

    void clear()
    {
        m_pending.clear();
        m_asked.clear();
    }

private:
    QList<QUrl> m_pending; // front = newest
    QSet<QUrl> m_asked;
};

// Least-recently-added order with a capacity: add() returns the urls pushed out.
class ThumbnailLru
{
public:
    explicit ThumbnailLru(int capacity = 512)
        : m_capacity(capacity)
    {
    }

    QList<QUrl> add(const QUrl &url)
    {
        m_order.removeOne(url);
        m_order.append(url);
        QList<QUrl> evicted;
        while (m_order.size() > m_capacity)
            evicted.append(m_order.takeFirst());
        return evicted;
    }

    void remove(const QUrl &url) { m_order.removeOne(url); }
    void clear() { m_order.clear(); }
    int size() const { return m_order.size(); }
    int capacity() const { return m_capacity; }

private:
    QList<QUrl> m_order;
    int m_capacity;
};
