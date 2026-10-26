#pragma once

// The watching half of grassfield-stack-helper (ADR-0025): one folder, the window of its first K entries in the stack's order,
// inotify, and the lines written when the window changed. A class of its own (main.cpp only wires stdin and stdout) so that the
// unit tests can run it against a real folder with short timings.
//
// Correctness rules.
//  - No decision rests on a count of the folder. Every changed name is looked at in the folder as it is NOW (a name created and
//    removed within one batch is simply not there).
//  - The window is always a correct prefix of the full sort: when entries of the folder may be outside it ("outside"), a boundary
//    entry B says that every entry up to B is in the window and every other entry sorts after B. A name goes into the window only
//    when it sorts up to B; a name of the window that now sorts after B leaves it; a removal just shortens it. That is the MARGIN:
//    the pile shows 3 of the 30 entries kept, so removals (a browser download is a visible temporary name that is renamed) cost
//    nothing until fewer than `low` entries are left; only then is a scan asked for, and the window (still a correct prefix) is written
//    meanwhile until fewer than half of `low` are left.
//  - A scan is also asked for by an overflow of the kernel's queue, a storm of names, a change of order or of K. Until it is done the
//    window is "stale" and is not written (what was written before stays on show), and a scan that could not be completed (a file
//    kept vanishing) is thrown away.
//  - In the date orders the sub-folders are watched too (their own dates move when something is created or removed in them).

#include "stacklogic.h"

#include <QElapsedTimer>
#include <QHash>
#include <QObject>
#include <QSocketNotifier>
#include <QTimer>

#include <functional>

namespace StackLogic
{

struct Timing {
    int readMs = 40; // the inotify queue is read this often at most
    int batchMs = 100; // events are gathered this long before they are looked at
    int emitMs = 100; // the window is written at most this often
    int relistGapMs = 1000; // two scans are at least this far apart
    double duty = 0.2; // scans may use this share of the CPU time...
    qint64 creditMaxMs = 8000; // ...with this much saved up (a quiet folder's first re-list is never held back)
    int quietMs = 300; // a scan that is not urgent waits for the folder to be quiet this long...
    int quietMaxMs = 5000; // ...for at most this long (a stream that never stops is still looked at)
    int stormNames = 4000; // more changed names than this in a batch: one scan instead
    int identityMs = 30000; // the folder's identity (device and inode of its path) is looked at this often while quiet
    int linkIdentityMs = 5000; // ...and this often when the stack folder is a symbolic link
    int rearmMinMs = 2000; // a folder that is gone is looked for again after this long, growing to rearmMaxMs
    int rearmMaxMs = 15000;
    int modifyCoalesceMs = 500; // a file that is written to without a pause is looked at once per this long (trailing edge)
    int overflowPollMs = 60000; // with more sub-folders than can be watched, the folder is scanned again this often
};

class Helper : public QObject
{
public:
    using Sink = std::function<void(const QByteArray &)>;
    static constexpr int kMaxLimit = 1000;

    // `low`: with entries outside the window, a scan is asked for when fewer than this many are left (0: half of the limit)
    Helper(const QByteArray &dir, Sort sort, int limit, int low, Sink sink, Timing timing = {}, QObject *parent = nullptr);

    // One line of stdin: "K <n> [<low>]", "SORT <order>", "RELIST".
    void command(const QByteArray &line);
    // Test hook: what an overflow of the kernel's queue does.
    void simulateOverflow();
    // Test hooks: look at these names now, in this order, as a batch would (events pending are dropped); and make the pending batch run.
    void processNamesForTest(const QList<QByteArray> &names, int flags);
    void flushForTest();
    bool dirsOverflow() const { return m_dirsOverflow; }
    // The window as it would be written now, whether a scan is due, and how many scans ran (test hooks).
    const Window &window() const { return m_window; }
    bool stale() const { return m_stale; }
    qint64 scans() const { return m_scans; }
    int watchedFolders() const { return int(m_subs.size()); }

private:
    enum Flag { Touched = 1, Appeared = 2, Vanished = 4, Written = 8 };

    void closeWatch();
    void arm();
    void gone();
    void checkIdentity();
    void readEvents();
    void processBatch();
    void handle(const QByteArray &raw, int flags);
    void markStale(bool now);
    void requestRelist(bool now);
    double credit() const;
    void relist();
    void scheduleEmit(bool soon = false);
    void emitWindow();
    uint32_t mainMask() const;
    bool dateOrder() const;
    void syncSubFolders(const std::vector<QByteArray> &dirs, bool overflow);
    void noteDirsOverflow(bool overflow);
    void addSubFolder(const QByteArray &name);
    void removeSubFolder(const QByteArray &name);
    void setBoundary();
    void shortened();
    int low() const;

    QByteArray m_dir;
    Sink m_sink;
    Timing m_t;
    QCollator m_collator;
    Window m_window;
    QElapsedTimer m_clock;
    QTimer m_read;
    QTimer m_batch;
    QTimer m_emit;
    QTimer m_relist;
    QTimer m_rearm;
    QTimer m_identity;
    QTimer m_modify; // trailing edge for names that were only written to
    QTimer m_poll; // scans again while there are more sub-folders than can be watched
    QHash<QByteArray, int> m_modifyHold;
    QHash<QByteArray, int> m_dirty;
    QHash<int, QByteArray> m_subs; // watch descriptor of a sub-folder -> its name
    QHash<QByteArray, int> m_subWd; // and back
    QSocketNotifier *m_notifier = nullptr;
    QByteArray m_lastPayload;
    Entry m_boundary; // valid when m_outside: everything up to it is in the window, everything else sorts after it
    qint64 m_total = 0; // exact after a scan, an estimate between two: written, never decided on
    qint64 m_sequence = 0;
    qint64 m_scans = 0;
    qint64 m_lastRelist = 0;
    qint64 m_lastEvent = -1000000;
    qint64 m_wantedSince = 0;
    qint64 m_lastScanCpuMs = 0;
    double m_credit = 0;
    qint64 m_creditAt = 0;
    int m_inotify = -1;
    int m_mainWd = -1;
    int m_backoff = 0;
    int m_low = 0;
    bool m_urgent = false;
    bool m_relistWanted = false;
    bool m_outside = true; // entries of the folder may be outside the window
    bool m_stale = true; // a scan is due: the window is not written
    bool m_goneReported = false;
    bool m_dirsOverflow = false; // more sub-folders than the watch cap (date orders)
    dev_t m_armedDev = 0;
    ino_t m_armedIno = 0;
};

} // namespace StackLogic
