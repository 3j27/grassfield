// Unit tests for apps/files/src/previewqueue.h (gtest). Built and run by scripts/dev/test.sh.
#include "previewqueue.h"

#include <gtest/gtest.h>

namespace
{
QUrl u(int i)
{
    return QUrl::fromLocalFile(QStringLiteral("/d/f%1.pdf").arg(i));
}
}

TEST(PreviewQueue, NewestRequestIsServedFirst)
{
    PreviewQueue q;
    for (int i = 0; i < 5; ++i)
        EXPECT_TRUE(q.request(u(i)));
    const QList<QUrl> batch = q.takeBatch(3);
    ASSERT_EQ(batch.size(), 3);
    EXPECT_EQ(batch[0], u(4));
    EXPECT_EQ(batch[2], u(2));
    EXPECT_EQ(q.pendingCount(), 2);
}

TEST(PreviewQueue, DuplicateRequestsAreIgnored)
{
    PreviewQueue q;
    EXPECT_TRUE(q.request(u(1)));
    EXPECT_FALSE(q.request(u(1)));
    EXPECT_EQ(q.pendingCount(), 1);
    q.takeBatch(10);
    EXPECT_FALSE(q.request(u(1))); // handed out: still asked
}

TEST(PreviewQueue, CancelDropsOnlyQueuedRequestsAndAllowsRerequest)
{
    PreviewQueue q;
    q.request(u(1));
    q.request(u(2));
    EXPECT_TRUE(q.cancel(u(1)));
    EXPECT_FALSE(q.cancel(u(1)));
    EXPECT_EQ(q.pendingCount(), 1);
    EXPECT_TRUE(q.request(u(1)));
    q.takeBatch(10);
    EXPECT_FALSE(q.cancel(u(2))); // already started
}

TEST(PreviewQueue, ForgetAllowsRequestAgain)
{
    PreviewQueue q;
    q.request(u(1));
    q.takeBatch(1);
    q.forget(u(1));
    EXPECT_TRUE(q.request(u(1)));
}

TEST(ThumbnailLru, EvictsOldestBeyondCapacity)
{
    ThumbnailLru lru(3);
    for (int i = 0; i < 3; ++i)
        EXPECT_TRUE(lru.add(u(i)).isEmpty());
    const QList<QUrl> gone = lru.add(u(3));
    ASSERT_EQ(gone.size(), 1);
    EXPECT_EQ(gone[0], u(0));
    EXPECT_EQ(lru.size(), 3);
}

TEST(ThumbnailLru, ReAddRefreshesAndRemoveFrees)
{
    ThumbnailLru lru(2);
    lru.add(u(0));
    lru.add(u(1));
    lru.add(u(0)); // u(1) is now the oldest
    EXPECT_EQ(lru.add(u(2)), QList<QUrl>{u(1)});
    lru.remove(u(0));
    EXPECT_EQ(lru.size(), 1);
    EXPECT_TRUE(lru.add(u(3)).isEmpty());
}
