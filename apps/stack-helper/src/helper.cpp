#include "helper.h"

#include <QCoreApplication>
#include <QFile>
#include <QSet>

#include <cerrno>
#include <ctime>

#include <sys/inotify.h>
#include <sys/stat.h>
#include <unistd.h>

namespace StackLogic
{

namespace
{
// CPU time of this thread, in milliseconds (a scan is paid for with the CPU it used, not with the time a busy machine made it last)
qint64 cpuMs()
{
    struct timespec ts;
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts);
    return qint64(ts.tv_sec) * 1000 + qint64(ts.tv_nsec / 1000000);
}
} // namespace

Helper::Helper(const QByteArray &dir, Sort sort, int limit, int low, Sink sink, Timing timing, QObject *parent)
    : QObject(parent)
    , m_dir(dir)
    , m_sink(std::move(sink))
    , m_t(timing)
    , m_collator(makeCollator())
    , m_window(sort, qBound(1, limit, kMaxLimit), &m_collator)
    , m_low(low)
{
    m_clock.start();
    m_credit = double(m_t.creditMaxMs);
    m_lastRelist = -m_t.relistGapMs;
    for (QTimer *t : {&m_batch, &m_emit, &m_relist, &m_rearm, &m_read, &m_modify})
        t->setSingleShot(true);
    connect(&m_modify, &QTimer::timeout, this, [this] {
        for (auto it = m_modifyHold.constBegin(); it != m_modifyHold.constEnd(); ++it)
            m_dirty[it.key()] |= Touched;
        m_modifyHold.clear();
        if (!m_dirty.isEmpty() && !m_batch.isActive())
            m_batch.start(m_t.batchMs);
    });
    connect(&m_poll, &QTimer::timeout, this, [this] { requestRelist(false); });
    connect(&m_read, &QTimer::timeout, this, [this] {
        readEvents();
        if (m_notifier)
            m_notifier->setEnabled(true);
    });
    connect(&m_batch, &QTimer::timeout, this, [this] { processBatch(); });
    connect(&m_emit, &QTimer::timeout, this, [this] { emitWindow(); });
    connect(&m_relist, &QTimer::timeout, this, [this] { relist(); });
    connect(&m_rearm, &QTimer::timeout, this, [this] { arm(); });
    connect(&m_identity, &QTimer::timeout, this, [this] { checkIdentity(); });
    m_backoff = m_t.rearmMinMs;
    arm();
}

int Helper::low() const
{
    const int limit = m_window.limit();
    return m_low > 0 ? qMin(m_low, limit) : qMax(1, limit / 2);
}

bool Helper::dateOrder() const
{
    return m_window.sort() == Sort::DateAdded || m_window.sort() == Sort::DateModified;
}

uint32_t Helper::mainMask() const
{
    uint32_t mask = IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO | IN_CLOSE_WRITE | IN_ATTRIB | IN_DELETE_SELF | IN_MOVE_SELF | IN_UNMOUNT | IN_ONLYDIR;
    if (dateOrder())
        mask |= IN_MODIFY; // a file that is written to and not closed yet (a download) has a new date at every write
    return mask;
}

void Helper::command(const QByteArray &line)
{
    const QList<QByteArray> parts = line.trimmed().split(' ');
    if (parts.isEmpty())
        return;
    if (parts[0] == "K" && (parts.size() == 2 || parts.size() == 3)) {
        bool ok = false;
        const int k = parts[1].toInt(&ok);
        if (!ok || k < 1)
            return;
        if (parts.size() == 3) {
            bool lowOk = false;
            const int l = parts[2].toInt(&lowOk);
            if (lowOk && l >= 0)
                m_low = l;
        }
        const int before = m_window.limit();
        m_window.setLimit(qMin(k, kMaxLimit));
        if (m_window.limit() > before) {
            m_outside = true;
            markStale(true); // the window asked for is not the window held: not written short
        } else if (m_window.limit() < before) {
            m_outside = true;
            setBoundary();
            scheduleEmit();
        }
    } else if (parts[0] == "SORT" && parts.size() == 2) {
        Sort sort;
        if (parseSort(QString::fromUtf8(parts[1]), &sort) && sort != m_window.sort()) {
            m_window.setSort(sort);
            m_outside = true;
            if (m_inotify >= 0 && m_mainWd >= 0)
                inotify_add_watch(m_inotify, m_dir.constData(), mainMask()); // the same watch with the mask of the new order
            markStale(true); // at once, not when a pending scan timer runs out
        }
    } else if (parts[0] == "RELIST") {
        markStale(true);
    }
}

void Helper::simulateOverflow()
{
    markStale(false);
}

// ---- the watch ----

void Helper::closeWatch()
{
    m_read.stop();
    delete m_notifier;
    m_notifier = nullptr;
    if (m_inotify >= 0)
        ::close(m_inotify);
    m_inotify = -1;
    m_mainWd = -1;
    m_subs.clear();
    m_subWd.clear();
    m_identity.stop();
    m_modify.stop();
    m_modifyHold.clear();
    m_poll.stop();
}

void Helper::arm()
{
    closeWatch();
    struct stat st;
    if (::stat(m_dir.constData(), &st) != 0 || !S_ISDIR(st.st_mode)) {
        gone();
        return;
    }
    m_inotify = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
    if (m_inotify < 0) {
        gone();
        return;
    }
    m_mainWd = inotify_add_watch(m_inotify, m_dir.constData(), mainMask());
    if (m_mainWd < 0) {
        gone();
        return;
    }
    m_armedDev = st.st_dev;
    m_armedIno = st.st_ino;
    m_notifier = new QSocketNotifier(m_inotify, QSocketNotifier::Read, this);
    // not one wake-up per event: the notifier sleeps while the events pile up in the kernel's queue for a few milliseconds
    connect(m_notifier, &QSocketNotifier::activated, this, [this] {
        m_notifier->setEnabled(false);
        m_read.start(m_t.readMs);
    });
    m_goneReported = false;
    m_backoff = m_t.rearmMinMs;
    // the folder's identity (what its path leads to) is looked at for every folder: a file system mounted over it, or a link pointed
    // elsewhere, says nothing to inotify
    struct stat link;
    const bool isLink = ::lstat(m_dir.constData(), &link) == 0 && S_ISLNK(link.st_mode);
    m_identity.start(isLink ? m_t.linkIdentityMs : m_t.identityMs);
    m_sink("A\n");
    m_window.clear();
    m_outside = true;
    m_stale = true;
    m_urgent = true;
    m_relistWanted = true;
    m_wantedSince = m_clock.elapsed();
    relist();
}

void Helper::gone()
{
    closeWatch();
    m_window.clear();
    m_total = 0;
    m_outside = true;
    m_stale = true;
    m_relist.stop();
    m_relistWanted = false;
    m_dirty.clear();
    if (!m_goneReported) {
        m_goneReported = true;
        m_sink("G\n");
        m_lastPayload.clear();
    }
    m_rearm.start(m_backoff);
    m_backoff = qMin(m_backoff * 2, m_t.rearmMaxMs);
}

void Helper::checkIdentity()
{
    struct stat st;
    if (::stat(m_dir.constData(), &st) != 0 || st.st_dev != m_armedDev || st.st_ino != m_armedIno)
        arm();
}

void Helper::readEvents()
{
    if (m_inotify < 0)
        return;
    char buffer[65536] __attribute__((aligned(__alignof__(struct inotify_event))));
    for (;;) {
        const ssize_t n = ::read(m_inotify, buffer, sizeof buffer);
        if (n <= 0)
            break;
        for (const char *p = buffer; p < buffer + n;) {
            const auto *ev = reinterpret_cast<const struct inotify_event *>(p);
            p += sizeof(struct inotify_event) + ev->len;
            if (ev->mask & IN_Q_OVERFLOW) {
                markStale(false);
                continue;
            }
            if (ev->wd != m_mainWd) {
                // something in a sub-folder (date orders): the sub-folder's own date moved, look at its entry in this folder
                const auto sub = m_subs.constFind(ev->wd);
                if (sub == m_subs.constEnd())
                    continue;
                if (ev->mask & IN_IGNORED) {
                    m_subWd.remove(sub.value());
                    m_subs.erase(sub);
                    continue;
                }
                m_lastEvent = m_clock.elapsed();
                m_dirty[sub.value()] |= Touched;
                continue;
            }
            if (ev->mask & (IN_DELETE_SELF | IN_MOVE_SELF | IN_UNMOUNT | IN_IGNORED)) {
                gone();
                return;
            }
            if (ev->len == 0 || ev->name[0] == '.' || ev->name[0] == '\0')
                continue;
            m_lastEvent = m_clock.elapsed();
            int flags = Touched;
            if (ev->mask & (IN_CREATE | IN_MOVED_TO))
                flags |= Appeared;
            if (ev->mask & (IN_DELETE | IN_MOVED_FROM))
                flags |= Vanished;
            if ((ev->mask & ~uint32_t(IN_ISDIR)) == IN_MODIFY) {
                // only written to (a download in place): at most one look per modifyCoalesceMs, the last state counts
                m_modifyHold[QByteArray(ev->name)] |= Written;
                if (!m_modify.isActive())
                    m_modify.start(m_t.modifyCoalesceMs);
                continue;
            }
            m_dirty[QByteArray(ev->name)] |= flags;
        }
    }
    if (m_dirty.size() > m_t.stormNames) {
        m_dirty.clear();
        markStale(false); // too many names to look at one by one: one scan
    }
    if (!m_dirty.isEmpty() && !m_batch.isActive())
        m_batch.start(m_t.batchMs);
}

// ---- the sub-folders (date orders) ----

void Helper::addSubFolder(const QByteArray &name)
{
    if (m_inotify < 0 || m_subWd.contains(name))
        return;
    const QByteArray path = m_dir + '/' + name;
    const int wd = inotify_add_watch(m_inotify, path.constData(), IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO | IN_ATTRIB | IN_ONLYDIR | IN_DONT_FOLLOW);
    if (wd < 0)
        return;
    // The kernel gives the same descriptor for the same inode: a sub-folder that was renamed is filed under its old name. It is filed
    // under the new one now (one descriptor, one name), so that dealing with the old name, before or after this, never removes it.
    const auto filed = m_subs.find(wd);
    if (filed != m_subs.end()) {
        if (filed.value() == name)
            return;
        m_subWd.remove(filed.value());
        filed.value() = name;
        m_subWd.insert(name, wd);
        return;
    }
    if (m_subs.size() >= int(kMaxDirs)) {
        inotify_rm_watch(m_inotify, wd);
        noteDirsOverflow(true); // not watched: the periodic scan keeps the pile right
        return;
    }
    m_subs.insert(wd, name);
    m_subWd.insert(name, wd);
}

void Helper::removeSubFolder(const QByteArray &name)
{
    const auto it = m_subWd.find(name);
    if (it == m_subWd.end())
        return;
    const int wd = it.value();
    m_subWd.erase(it);
    m_subs.remove(wd);
    if (m_inotify >= 0)
        inotify_rm_watch(m_inotify, wd);
}

void Helper::noteDirsOverflow(bool overflow)
{
    m_dirsOverflow = overflow && dateOrder();
    if (m_dirsOverflow) {
        if (!m_poll.isActive())
            m_poll.start(m_t.overflowPollMs);
    } else {
        m_poll.stop();
    }
}

void Helper::syncSubFolders(const std::vector<QByteArray> &dirs, bool overflow)
{
    noteDirsOverflow(overflow);
    if (m_inotify < 0)
        return;
    QSet<QByteArray> want;
    if (dateOrder()) {
        for (const QByteArray &d : dirs)
            want.insert(d);
    }
    const QList<QByteArray> have = m_subWd.keys();
    for (const QByteArray &name : have) {
        if (!want.contains(name))
            removeSubFolder(name);
    }
    for (const QByteArray &name : want)
        addSubFolder(name);
}

// ---- the window ----

void Helper::processNamesForTest(const QList<QByteArray> &names, int flags)
{
    m_batch.stop();
    m_dirty.clear();
    m_modify.stop();
    m_modifyHold.clear();
    for (const QByteArray &n : names)
        handle(n, flags);
    scheduleEmit();
}

void Helper::flushForTest()
{
    m_modify.stop();
    for (auto it = m_modifyHold.constBegin(); it != m_modifyHold.constEnd(); ++it)
        m_dirty[it.key()] |= Touched;
    m_modifyHold.clear();
    m_batch.stop();
    processBatch();
}

void Helper::processBatch()
{
    checkIdentity(); // one stat: the batch is the moment a mount over the folder would show
    if (m_inotify < 0)
        return;
    const QHash<QByteArray, int> dirty = m_dirty;
    m_dirty.clear();
    for (auto it = dirty.constBegin(); it != dirty.constEnd(); ++it)
        handle(it.key(), it.value());
    if (!m_outside)
        m_total = qint64(m_window.entries().size()); // the window is the whole folder: the count is exact
    scheduleEmit();
}

void Helper::setBoundary()
{
    if (!m_window.entries().empty())
        m_boundary = m_window.entries().back();
}

// The window got shorter (an entry left it) while entries of the folder are outside: the margin takes it. Fewer than `low` left: a
// scan is asked for (it can take seconds on a busy machine); the window is still a correct prefix of the full sort, and keeps being
// written meanwhile (what was written before holds entries that are gone), until fewer than half of `low` are left: that one is held.
void Helper::shortened()
{
    if (!m_outside)
        return;
    const int n = int(m_window.entries().size());
    if (n >= low())
        return;
    if (n < qMax(1, low() / 2))
        m_stale = true;
    requestRelist(false);
}

// A changed name is looked at in the folder as it is now: it is there (and goes into the window if it sorts up to the boundary) or it
// is not (and leaves it). What order the events came in, and a name that was created and removed within the batch, do not matter.
void Helper::handle(const QByteArray &raw, int flags)
{
    Entry e;
    e.raw = raw;
    e.se.name = QFile::decodeName(raw);
    if (!statEntry(m_dir, raw, &e)) {
        removeSubFolder(raw);
        if (m_window.remove(raw)) {
            m_total = qMax<qint64>(0, m_total - 1);
            shortened();
        }
        return;
    }
    if (m_window.sort() == Sort::Kind)
        e.kind = kindKey(e.se.name, e.se.isDir);
    if (dateOrder() && e.se.isDir && (flags & Appeared)) {
        removeSubFolder(raw); // a folder made again under the same name is another inode
        addSubFolder(raw);
    }
    const bool was = m_window.remove(raw);
    if (!was && (flags & Appeared))
        m_total++;
    // every entry that is not in the window sorts after the boundary: this one goes in only if it sorts up to it
    const bool belongs = !m_outside || compare(e, m_boundary, m_window.sort(), m_collator) <= 0;
    if (belongs) {
        const bool crowded = m_window.full(); // an entry that goes in now pushes another out, or is itself left out
        m_window.offer(e);
        if (crowded) {
            m_outside = true;
            setBoundary();
        }
    } else if (was) {
        shortened(); // it sorts after the boundary now: out of the window, the margin takes it
    }
}

// ---- scans ----

void Helper::markStale(bool now)
{
    m_stale = true;
    requestRelist(now);
}

void Helper::requestRelist(bool now)
{
    if (m_inotify < 0)
        return; // gone: the re-arm scans
    if (!m_relistWanted)
        m_wantedSince = m_clock.elapsed();
    m_relistWanted = true;
    m_urgent = m_urgent || now;
    if (m_relist.isActive() && !now)
        return;
    // two scans are at least a second apart, and together they use a fifth of the CPU time at most: the CPU time a scan took is
    // paid back from a credit that fills at that rate (8 s at the start, so that a re-list after a quiet time is never held back)
    qint64 wait = 0;
    if (!now) {
        wait = qMax<qint64>(0, m_t.relistGapMs - (m_clock.elapsed() - m_lastRelist));
        const double have = credit();
        if (have < double(m_lastScanCpuMs))
            wait = qMax<qint64>(wait, qint64((double(m_lastScanCpuMs) - have) / m_t.duty));
    }
    m_relist.start(int(qMax<qint64>(wait, 1)));
}

double Helper::credit() const
{
    return qMin<double>(double(m_t.creditMaxMs), m_credit + m_t.duty * double(m_clock.elapsed() - m_creditAt));
}

void Helper::relist()
{
    if (m_inotify < 0) {
        m_relistWanted = false;
        return;
    }
    // events are still coming (a burst, a stream): the scan would be stale as it ends; wait for a quiet moment, not for ever
    const qint64 nowMs = m_clock.elapsed();
    if (!m_urgent && m_relistWanted && nowMs - m_lastEvent < m_t.quietMs && nowMs - m_wantedSince < m_t.quietMaxMs) {
        m_relist.start(m_t.quietMs);
        return;
    }
    m_relistWanted = false;
    m_urgent = false;
    // scanned into a window of its own: one that cannot be completed is thrown away and the one held stays
    Window fresh(m_window.sort(), m_window.limit(), &m_collator);
    const qint64 cpu0 = cpuMs();
    const ScanResult r = scanFolder(m_dir, &fresh);
    m_lastScanCpuMs = qMax<qint64>(1, cpuMs() - cpu0);
    m_credit = credit() - double(m_lastScanCpuMs);
    m_creditAt = m_clock.elapsed();
    m_lastRelist = m_creditAt;
    m_scans++;
    if (!r.ok) {
        gone();
        return;
    }
    if (!r.complete) {
        requestRelist(false); // a file kept vanishing under the scan: again, shortly
        return;
    }
    m_window = fresh;
    m_total = r.total;
    m_outside = r.total > qint64(m_window.entries().size());
    if (m_outside)
        setBoundary();
    m_stale = false;
    syncSubFolders(r.dirs, r.dirsOverflow);
    // what was queued before the scan began is older than what the scan read; what comes during and after it stays in the kernel's
    // queue and is looked at next
    m_dirty.clear();
    scheduleEmit(true);
}

void Helper::scheduleEmit(bool soon)
{
    if (!m_emit.isActive())
        m_emit.start(soon ? 0 : m_t.emitMs);
}

void Helper::emitWindow()
{
    // a window that may be wrong or short (a scan is due: the margin is used up, an overflow, a storm, a new order or size) is not
    // written: what was written before stays on show until the scan has made the new one complete
    if (m_stale)
        return;
    // the payload without the sequence: a window that did not change is not written again
    const QByteArray payload = encodeWindow(0, m_total, m_window.entries());
    if (payload == m_lastPayload)
        return;
    m_lastPayload = payload;
    m_sink(encodeWindow(++m_sequence, m_total, m_window.entries()));
}

} // namespace StackLogic
