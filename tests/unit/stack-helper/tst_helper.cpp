// The watching half of grassfield-stack-helper (apps/stack-helper/src/helper.cpp) against a real folder, with short timings.
// The property: after any sequence of creates, renames in and out, temp-file-then-rename downloads, deletes, touches, bursts and
// overflows of the kernel's queue, once the folder is quiet the window the helper wrote is the first K entries of a full sort of the
// folder, in every order, and the helper never wrote a window that was short or empty on the way (what it wrote before stays).
#include "helper.h"

#include <QCoreApplication>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QRandomGenerator>
#include <QSet>
#include <QTemporaryDir>
#include <QThread>

#include <algorithm>
#include <memory>

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <gtest/gtest.h>

using namespace StackLogic;

namespace
{
void ensureApp()
{
    static int argc = 1;
    static char arg0[] = "tst_helper";
    static char *argv[] = {arg0, nullptr};
    static QCoreApplication app(argc, argv);
}

Timing fastTiming()
{
    Timing t;
    t.readMs = 2;
    t.batchMs = 8;
    t.emitMs = 5;
    t.relistGapMs = 40;
    t.duty = 1000; // no credit limit: this is about what is written, not how often
    t.creditMaxMs = 1000000;
    t.quietMs = 25;
    t.quietMaxMs = 400;
    t.identityMs = 200;
    t.linkIdentityMs = 200;
    t.rearmMinMs = 40;
    t.rearmMaxMs = 200;
    t.modifyCoalesceMs = 60;
    t.overflowPollMs = 300;
    return t;
}

void touchFile(const QString &path, double seconds = -1)
{
    const int fd = ::open(path.toUtf8().constData(), O_CREAT | O_WRONLY, 0600);
    ASSERT_GE(fd, 0) << path.toStdString();
    ASSERT_EQ(::write(fd, "x", 1), 1);
    ::close(fd);
    if (seconds >= 0) {
        struct timespec ts[2];
        ts[0].tv_sec = time_t(seconds);
        ts[0].tv_nsec = long((seconds - double(time_t(seconds))) * 1e9);
        ts[1] = ts[0];
        ::utimensat(AT_FDCWD, path.toUtf8().constData(), ts, 0);
    }
}

QStringList splitNames(const QByteArray &line)
{
    // W US seq US total US n { US name US isDir US modified US added US created }; the names here hold no escapes
    const QList<QByteArray> f = line.trimmed().split('\x1f');
    QStringList out;
    if (f.size() < 4)
        return out;
    const int n = f[3].toInt();
    for (int i = 0; i < n && 4 + 5 * i < f.size(); i++)
        out.append(QString::fromUtf8(f[4 + 5 * i]));
    return out;
}

// One helper on one real folder.
struct Rig {
    QTemporaryDir tmp;
    QString dir; // the stack folder
    QString ext; // a sibling folder (names renamed in and out)
    Sort sort;
    int limit;
    QCollator collator = makeCollator();
    QList<QByteArray> lines; // everything the helper wrote
    QStringList written; // the names of the last window written
    int lowArg = 0; // the helper's `low` (0: half of K)
    Timing timing = fastTiming();
    std::unique_ptr<Helper> helper;

    Rig(Sort s, int k)
        : sort(s)
        , limit(k)
    {
        ensureApp();
        EXPECT_TRUE(tmp.isValid());
        dir = tmp.path() + "/stack";
        ext = tmp.path() + "/ext";
        QDir().mkpath(dir);
        QDir().mkpath(ext);
    }

    void start()
    {
        helper = std::make_unique<Helper>(dir.toUtf8(), sort, limit, lowArg, [this](const QByteArray &bytes) {
            lines.append(bytes);
            if (bytes.startsWith("W"))
                written = splitNames(bytes);
            else if (bytes.startsWith("G"))
                written.clear();
        }, timing);
    }

    void pump(int ms)
    {
        QElapsedTimer t;
        t.start();
        while (t.elapsed() < ms) {
            QCoreApplication::processEvents(QEventLoop::AllEvents, 5);
            QThread::msleep(1);
        }
    }

    // The first `limit` names of a full sort of the folder, made here: a listing, a statx per entry, std::sort with the order's
    // own comparison (which tst_stacklogic checks against Files' and against a full sort).
    QStringList expected() const
    {
        std::vector<Entry> all;
        const QByteArray d = dir.toUtf8();
        const QStringList names = QDir(dir).entryList(QDir::AllEntries | QDir::NoDotAndDotDot | QDir::System | QDir::Hidden);
        for (const QString &n : names) {
            if (n.startsWith(QLatin1Char('.')))
                continue;
            Entry e;
            e.raw = QFile::encodeName(n);
            e.se.name = n;
            if (!statEntry(d, e.raw, &e))
                continue;
            e.kind = kindKey(n, e.se.isDir);
            all.push_back(e);
        }
        std::stable_sort(all.begin(), all.end(), [this](const Entry &a, const Entry &b) { return compare(a, b, sort, collator) < 0; });
        QStringList out;
        for (size_t i = 0; i < all.size() && int(i) < limit; i++)
            out.append(all[i].se.name);
        return out;
    }

    // What the helper may have written once the folder is quiet: the first n entries of a full sort, with n the whole folder or the
    // size of the window or at least `low` (the margin: removals shorten the window until fewer than `low` are left, then a scan
    // refills it).
    bool valid(const QStringList &e) const
    {
        const int lowEff = lowArg > 0 ? qMin(lowArg, limit) : qMax(1, limit / 2);
        return written == e.mid(0, int(written.size())) && (written.size() == e.size() || written.size() >= lowEff);
    }

    // Waits until the folder is quiet and the helper has written a valid window (see valid()); false when it never does.
    bool settle(int timeoutMs, QStringList *want = nullptr)
    {
        QElapsedTimer t;
        t.start();
        QStringList e;
        while (t.elapsed() < timeoutMs) {
            pump(15);
            e = expected();
            if (valid(e) && !helper->stale()) {
                pump(120); // and it stays so: nothing wrong is written after
                e = expected();
                if (valid(e) && !helper->stale())
                    return true;
            }
        }
        if (want)
            *want = e;
        return false;
    }

    void report(const char *what, QStringList want)
    {
        const QStringList got = written;
        int at = 0;
        while (at < got.size() && at < want.size() && got[at] == want[at])
            at++;
        ADD_FAILURE() << what << ": order " << int(sort) << " K " << limit << ": the window differs from a full sort at " << at << " (written "
                      << got.size() << " names, a full sort gives " << want.size() << "); written [" << got.mid(at, 4).join(" | ").toStdString()
                      << "] full sort [" << want.mid(at, 4).join(" | ").toStdString() << "]";
    }
};

const Sort kOrders[] = {Sort::Name, Sort::DateAdded, Sort::DateModified, Sort::DateCreated, Sort::Kind};

// the random sequences
class Chaos
{
public:
    Chaos(Rig *run, quint32 seed)
        : m_run(run)
        , m_rng(seed)
    {
    }

    void populate(int files)
    {
        for (int i = 0; i < files; i++)
            touchFile(m_run->dir + "/" + fresh(), double(1700000000 + m_rng.bounded(100000)));
        if (files > 5) {
            // a few sub-folders, made at random moments of the population so that their dates are spread among the files'
            for (int i = 0; i < 3; i++)
                QDir(m_run->dir).mkdir(QStringLiteral("Folder%1").arg(m_rng.bounded(1000)));
        }
    }

    void ops(int count)
    {
        for (int i = 0; i < count; i++) {
            op();
            // no pause: the next one lands in the same batch; a short one: another batch; a long one: a scan may run between
            const int r = int(m_rng.bounded(10));
            if (r >= 5 && r < 8)
                m_run->pump(int(m_rng.bounded(12)));
            else if (r >= 8)
                m_run->pump(int(m_rng.bounded(60)));
        }
    }

    void op()
    {
        const QString d = m_run->dir;
        const QString x = m_run->ext;
        switch (m_rng.bounded(12)) {
        case 0:
        case 1: // create
            touchFile(d + "/" + fresh(), m_rng.bounded(2) ? double(1700000000 + m_rng.bounded(100000)) : -1);
            break;
        case 2: // delete: from the window when it can be, else any
            QFile::remove(d + "/" + victim(m_rng.bounded(3) != 0));
            break;
        case 3: { // rename in: made outside, moved in
            const QString n = fresh();
            touchFile(x + "/" + n, double(1700000000 + m_rng.bounded(100000)));
            QFile::rename(x + "/" + n, d + "/" + n);
            break;
        }
        case 4: { // rename out
            const QString v = victim(m_rng.bounded(2) != 0);
            if (!v.isEmpty())
                QFile::rename(d + "/" + v, x + "/" + v + QString::number(m_rng.bounded(1000000)));
            break;
        }
        case 5:
        case 6: { // temp file then rename, the way a browser downloads (a visible and a hidden temporary name)
            const QString fin = fresh();
            const QString tmp = m_rng.bounded(2) ? fin + ".part" : QStringLiteral(".com.tmp.") + fin;
            touchFile(d + "/" + tmp);
            QFile::rename(d + "/" + tmp, d + "/" + fin);
            break;
        }
        case 7: { // created and removed at once (never there when looked at)
            const QString n = fresh();
            touchFile(d + "/" + n);
            QFile::remove(d + "/" + n);
            break;
        }
        case 8: { // touch: dates change
            const QString v = victim(m_rng.bounded(2) != 0);
            if (!v.isEmpty()) {
                struct timespec ts[2];
                ts[0].tv_sec = time_t(1700000000 + m_rng.bounded(100000));
                ts[0].tv_nsec = 0;
                ts[1] = ts[0];
                ::utimensat(AT_FDCWD, (d + "/" + v).toUtf8().constData(), ts, 0);
            }
            break;
        }
        case 9: // a burst
            for (int i = 0, n = int(m_rng.bounded(60)); i < n; i++)
                touchFile(d + "/" + fresh());
            break;
        case 10: { // something is created or removed inside a sub-folder: the sub-folder's own dates move
            const QStringList dirs = QDir(d).entryList(QDir::Dirs | QDir::NoDotAndDotDot);
            if (!dirs.isEmpty()) {
                const QString sub = d + "/" + dirs[m_rng.bounded(quint32(dirs.size()))];
                const QString inner = sub + "/in" + QString::number(m_rng.bounded(5));
                if (QFile::exists(inner))
                    QFile::remove(inner);
                else
                    touchFile(inner);
            }
            break;
        }
        default: // the kernel's queue overflowed
            m_run->helper->simulateOverflow();
        }
    }

private:
    QString fresh()
    {
        static const char *stems[] = {"a", "B", "file", "File", "x", "é", "z", "10", "9", "report", "Ａ", "中", "doc.", "photo.png", "note.txt", "Data.TAR.gz", "b."};
        for (;;) {
            const QString n = QString::fromUtf8(stems[m_rng.bounded(17)]) + QString::number(m_serial++ * 7 + int(m_rng.bounded(7)));
            return n;
        }
    }

    // a name that is there: from the helper's own window, or from the folder
    QString victim(bool fromWindow)
    {
        if (fromWindow) {
            const auto &entries = m_run->helper->window().entries();
            if (!entries.empty()) {
                const QString n = entries[m_rng.bounded(quint32(entries.size()))].se.name;
                if (QFile::exists(m_run->dir + "/" + n))
                    return n;
            }
        }
        const QStringList all = QDir(m_run->dir).entryList(QDir::Files | QDir::NoDotAndDotDot);
        return all.isEmpty() ? QString() : all[m_rng.bounded(quint32(all.size()))];
    }

    Rig *m_run;
    QRandomGenerator m_rng;
    int m_serial = 0;
};

void property(int files, int ops, const QList<quint32> &seeds, const QList<int> &limits)
{
    for (const Sort sort : kOrders) {
        for (const int k : limits) {
            for (const quint32 seed : seeds) {
                SCOPED_TRACE(testing::Message() << "order " << int(sort) << " K " << k << " seed " << seed << " files " << files);
                Rig run(sort, k);
                Chaos chaos(&run, seed);
                chaos.populate(files);
                run.start();
                ASSERT_TRUE(run.settle(20000)) << "the first window never matched a full sort";
                chaos.ops(ops);
                QStringList want;
                if (!run.settle(30000, &want))
                    run.report("after the sequence", want);
            }
        }
    }
}
} // namespace

TEST(HelperProperty, FourHundredFilesAllOrders)
{
    // two fixed seeds and one random one (printed with the failure)
    const quint32 random = QRandomGenerator::global()->generate();
    property(400, 160, {1, 2, random}, {30});
    property(400, 160, {4}, {5}); // a small window: entries are pushed out and refilled all the time
}

TEST(HelperProperty, FiveThousandFilesAllOrders)
{
    const quint32 random = QRandomGenerator::global()->generate();
    property(5000, 120, {3, random}, {30});
}

// The review's repro: 10 files, 40 downloads that were written under a temporary name and renamed (created and renamed away within a
// batch: the old helper's count went 10 instead of 50), the 30 shown files deleted: the window was empty with 20 files left.
TEST(HelperProperty, ReviewRepro_TempFileThenRenameThenDeleteTheWindow)
{
    for (const Sort sort : kOrders) {
        SCOPED_TRACE(testing::Message() << "order " << int(sort));
        Rig run(sort, 30);
        for (int i = 0; i < 10; i++)
            touchFile(QStringLiteral("%1/seed%2.txt").arg(run.dir).arg(i), double(1700000000 + i * 100));
        run.start();
        ASSERT_TRUE(run.settle(10000));
        for (int i = 0; i < 40; i++) {
            const QString tmp = QStringLiteral("%1/dl%2.crdownload").arg(run.dir).arg(i);
            touchFile(tmp);
            QFile::rename(tmp, QStringLiteral("%1/dl%2.bin").arg(run.dir).arg(i)); // no pause: the same batch
        }
        QStringList want;
        ASSERT_TRUE(run.settle(15000, &want)) << "50 files, window of 30";
        ASSERT_EQ(run.written.size(), 30);
        // delete the 30 shown files
        const QStringList shown = run.written;
        for (const QString &n : shown)
            QFile::remove(run.dir + "/" + n);
        if (!run.settle(30000, &want))
            run.report("after the 30 shown files were deleted", want);
        EXPECT_EQ(run.written.size(), 20) << "20 files are left and all of them must show";
        // never an empty or short window on the way: every window written after the first full one held 30 or 20 names
        for (const QByteArray &l : run.lines) {
            if (!l.startsWith("W"))
                continue;
            const int n = splitNames(l).size();
            EXPECT_TRUE(n == 10 || n == 30 || n == 20) << "a window of " << n << " names was written (10 files, then 50, then 20 left)";
        }
    }
}

// A real overflow of the kernel's queue: 20,000 creates while nothing reads it (16,384 events fit).
TEST(HelperProperty, RealOverflowOfTheKernelQueue)
{
    for (const Sort sort : {Sort::Name, Sort::DateAdded}) {
        SCOPED_TRACE(testing::Message() << "order " << int(sort));
        Rig run(sort, 30);
        for (int i = 0; i < 20; i++)
            touchFile(QStringLiteral("%1/start%2").arg(run.dir).arg(i), double(1700000000 + i));
        run.start();
        ASSERT_TRUE(run.settle(10000));
        // no event loop runs here: the queue fills and overflows
        for (int i = 0; i < 20000; i++)
            touchFile(QStringLiteral("%1/zz%2").arg(run.dir).arg(i, 6, 10, QLatin1Char('0')));
        touchFile(run.dir + "/0first");
        touchFile(run.dir + "/last-created", 1900000000);
        QStringList want;
        if (!run.settle(60000, &want))
            run.report("after the overflow", want);
    }
}

// SORT and K apply at once, whatever the scan timer was waiting for, and a short window is never written for them.
TEST(HelperProperty, SortAndSizeChangeAtOnce)
{
    Rig run(Sort::Name, 5);
    for (int i = 0; i < 300; i++)
        touchFile(QStringLiteral("%1/f%2").arg(run.dir).arg(i, 3, 10, QLatin1Char('0')), double(1700000000 + (i * 37) % 300));
    run.start();
    ASSERT_TRUE(run.settle(10000));
    run.helper->command("SORT dateModified");
    run.sort = Sort::DateModified;
    QElapsedTimer t;
    t.start();
    QStringList want;
    ASSERT_TRUE(run.settle(3000, &want)) << "the new order shows within 3 s";
    EXPECT_LT(t.elapsed(), 1500);
    run.helper->command("K 40");
    run.limit = 40;
    ASSERT_TRUE(run.settle(3000, &want));
    EXPECT_EQ(run.written.size(), 40);
    run.helper->command("K 7");
    run.limit = 7;
    ASSERT_TRUE(run.settle(3000, &want));
    EXPECT_EQ(run.written.size(), 7);
    for (const QByteArray &l : run.lines) {
        if (l.startsWith("W")) {
            EXPECT_GE(splitNames(l).size(), 5) << "no short window on the way";
        }
    }
}

// A different directory at the same path (the folder moved away and another made in its place) is listed afresh.
TEST(HelperProperty, FolderReplacedByAnotherAtTheSamePath)
{
    Rig run(Sort::Name, 30);
    touchFile(run.dir + "/old1");
    touchFile(run.dir + "/old2");
    run.start();
    ASSERT_TRUE(run.settle(10000));
    QDir().rename(run.dir, run.tmp.path() + "/moved");
    QDir().mkpath(run.dir);
    touchFile(run.dir + "/new1");
    QStringList want;
    ASSERT_TRUE(run.settle(10000, &want)) << "the new folder shows";
    EXPECT_EQ(run.written, (QStringList{"new1"}));
}

// The margin: with entries outside the window, removals (a download is a visible temporary name that is renamed) shorten it for free
// and a scan runs only when fewer than `low` entries are left.
TEST(HelperProperty, TheMarginTakesRemovalsWithoutAScan)
{
    for (const Sort sort : kOrders) {
        SCOPED_TRACE(testing::Message() << "order " << int(sort));
        Rig run(sort, 30);
        run.lowArg = 10;
        for (int i = 0; i < 200; i++)
            touchFile(QStringLiteral("%1/f%2").arg(run.dir).arg(i, 3, 10, QLatin1Char('0')), double(1700000000 + (i * 37) % 200));
        run.start();
        ASSERT_TRUE(run.settle(10000));
        const qint64 scans = run.helper->scans();
        // 15 of the 30 shown entries removed, one by one: 15 are left, the margin holds
        const QStringList shown = run.written;
        for (int i = 0; i < 15; i++) {
            QFile::remove(run.dir + "/" + shown[i * 2 % shown.size()]);
            run.pump(40);
        }
        run.pump(400);
        EXPECT_EQ(run.helper->scans(), scans) << "no scan while the margin lasts";
        EXPECT_FALSE(run.helper->stale());
        const QStringList want = run.expected();
        EXPECT_EQ(run.written, want.mid(0, run.written.size())) << "what is written is the first of a full sort";
        EXPECT_GE(run.written.size(), 10);
        // a download: a visible temporary name, renamed: at the front, no scan either
        touchFile(run.dir + "/zz.part");
        QFile::rename(run.dir + "/zz.part", run.dir + "/zz.bin");
        run.pump(400);
        EXPECT_EQ(run.helper->scans(), scans) << "a download costs no scan";
        EXPECT_EQ(run.written, run.expected().mid(0, run.written.size()));
        // the margin is used up: one scan, and the window is full again
        for (int i = 0; i < 12; i++) {
            const QStringList now = run.written;
            if (now.isEmpty())
                break;
            QFile::remove(run.dir + "/" + now.last());
            run.pump(40);
        }
        QStringList w;
        if (!run.settle(10000, &w))
            run.report("after the margin was used up", w);
        EXPECT_GT(run.helper->scans(), scans) << "a scan refilled the window";
        EXPECT_GE(run.written.size(), 10);
    }
}

// In the date orders a folder's own date follows what is created and removed in it: it moves up the pile (macOS: a folder's date in a
// stack is its own modification date). The sub-folders are watched for it.
TEST(HelperProperty, ASubFolderMovesUpWhenSomethingIsCreatedInIt)
{
    for (const Sort sort : {Sort::DateModified, Sort::DateAdded}) {
        SCOPED_TRACE(testing::Message() << "order " << int(sort));
        Rig run(sort, 30);
        ASSERT_TRUE(QDir().mkpath(run.dir + "/Projects"));
        run.pump(30);
        for (int i = 0; i < 100; i++)
            touchFile(QStringLiteral("%1/f%2").arg(run.dir).arg(i, 3, 10, QLatin1Char('0')));
        run.start();
        ASSERT_TRUE(run.settle(10000));
        EXPECT_FALSE(run.written.contains("Projects")) << "the folder is the oldest: outside the window";
        EXPECT_GE(run.helper->watchedFolders(), 1);
        touchFile(run.dir + "/Projects/new.txt"); // the folder's own date is now the newest
        QStringList want;
        ASSERT_TRUE(run.settle(10000, &want)) << "the window follows a full sort";
        EXPECT_EQ(run.written.front(), "Projects");
        // and again, much later: removing it moves the folder's date too
        run.pump(50);
        touchFile(run.dir + "/f-new");
        run.pump(100);
        QFile::remove(run.dir + "/Projects/new.txt");
        ASSERT_TRUE(run.settle(10000, &want));
        EXPECT_EQ(run.written.front(), "Projects");
    }
}

// Name and Kind do not depend on dates: nothing is watched inside the sub-folders.
TEST(HelperProperty, TheNameOrderWatchesNoSubFolders)
{
    Rig run(Sort::Name, 30);
    ASSERT_TRUE(QDir().mkpath(run.dir + "/Projects"));
    touchFile(run.dir + "/a");
    run.start();
    ASSERT_TRUE(run.settle(10000));
    EXPECT_EQ(run.helper->watchedFolders(), 0);
}

// Round 10: a sub-folder that is renamed keeps its watch. The kernel gives the same descriptor for the same inode, which the helper
// had filed under the old name; the new name found it filed and returned, and dealing with the old name then removed the folder's only
// watch. Which of the two names comes first in a batch is a hash order: here each order is forced (the natural events are dropped, the
// names are dealt with in the order given), and moves inside the folder must still be seen afterwards.
TEST(HelperProperty, ARenamedSubFolderKeepsItsWatchInEitherOrder)
{
    for (const Sort sort : {Sort::DateModified, Sort::DateAdded}) {
        for (const bool oldFirst : {true, false}) {
            SCOPED_TRACE(testing::Message() << "order " << int(sort) << (oldFirst ? ", old name first" : ", new name first"));
            Rig run(sort, 30);
            run.timing.batchMs = 5000; // nothing is dealt with but what the test says
            ASSERT_TRUE(QDir().mkpath(run.dir + "/Projects"));
            run.pump(30);
            for (int i = 0; i < 100; i++)
                touchFile(QStringLiteral("%1/f%2").arg(run.dir).arg(i, 3, 10, QLatin1Char('0')));
            run.start();
            ASSERT_TRUE(run.settle(10000));
            ASSERT_EQ(run.helper->watchedFolders(), 1);
            ASSERT_TRUE(QDir().rename(run.dir + "/Projects", run.dir + "/Work"));
            run.pump(100);
            const QByteArray oldName = "Projects", newName = "Work";
            if (oldFirst)
                run.helper->processNamesForTest({oldName, newName}, 1 | 4 | 2);
            else
                run.helper->processNamesForTest({newName, oldName}, 1 | 4 | 2);
            EXPECT_EQ(run.helper->watchedFolders(), 1) << "the renamed folder is watched under its new name, once";
            // two later moves inside it
            for (int round = 0; round < 2; round++) {
                touchFile(run.dir + "/f-between" + QString::number(round));
                run.pump(40);
                if (round == 0)
                    touchFile(run.dir + "/Work/new.txt");
                else
                    QFile::remove(run.dir + "/Work/new.txt");
                run.pump(100);
                run.helper->flushForTest();
                run.pump(100);
                EXPECT_EQ(run.written.front(), "Work") << "round " << round << ": a change in the renamed folder moves it to the top";
            }
        }
    }
}

// More sub-folders than can be watched (1,000): the pile still converges, by a periodic scan.
TEST(HelperProperty, MoreSubFoldersThanTheWatchCapConvergeByAPeriodicScan)
{
    Rig run(Sort::DateModified, 30);
    for (int i = 0; i < 1100; i++)
        ASSERT_TRUE(QDir().mkpath(QStringLiteral("%1/d%2").arg(run.dir).arg(i, 4, 10, QLatin1Char('0'))));
    run.start();
    ASSERT_TRUE(run.settle(20000));
    EXPECT_TRUE(run.helper->dirsOverflow());
    EXPECT_EQ(run.helper->watchedFolders(), 1000);
    // The ones that are not watched are the ones past the 1,000th in the order the directory is read (the helper's scan is that order).
    // Something is created in 40 of those, last: they are the newest now, and nothing tells the helper.
    const QStringList readOrder = QDir(run.dir).entryList(QDir::Dirs | QDir::NoDotAndDotDot, QDir::Unsorted);
    ASSERT_EQ(readOrder.size(), 1100);
    for (int i = 1000; i < 1040; i++)
        touchFile(run.dir + "/" + readOrder[i] + "/in");
    QStringList want;
    if (!run.settle(30000, &want))
        run.report("with more sub-folders than the watch cap", want);
}

// A file that is written to without a pause (a download in place): one look per modifyCoalesceMs, not one per batch.
TEST(HelperProperty, AFileWrittenToWithoutAPauseIsLookedAtOncePerCoalesceTime)
{
    Rig run(Sort::DateModified, 30);
    run.timing.modifyCoalesceMs = 400;
    for (int i = 0; i < 10; i++)
        touchFile(QStringLiteral("%1/f%2").arg(run.dir).arg(i, 2, 10, QLatin1Char('0')), double(1700000000 + i));
    const QString big = run.dir + "/download.part";
    touchFile(big, 1600000000);
    run.start();
    ASSERT_TRUE(run.settle(10000));
    const int windows = int(run.lines.size());
    QElapsedTimer t;
    t.start();
    const int fd = ::open(big.toUtf8().constData(), O_WRONLY | O_APPEND);
    ASSERT_GE(fd, 0);
    while (t.elapsed() < 2000) {
        ASSERT_EQ(::write(fd, "0123456789", 10), 10);
        run.pump(8);
    }
    ::close(fd);
    run.pump(100);
    const int written = int(run.lines.size()) - windows;
    EXPECT_LE(written, 8) << "2 s of writes: at most about one window per 400 ms, not one per 8 ms batch";
    EXPECT_GE(written, 1);
    ASSERT_TRUE(run.settle(10000));
    EXPECT_EQ(run.written.front(), "download.part") << "it is the newest by modification, once it was closed or looked at";
}
