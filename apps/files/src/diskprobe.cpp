#include "diskprobe.h"

#include <QElapsedTimer>
#include <QFileInfo>
#include <QMutex>
#include <QTimer>

#include <thread>

// What the threads share with the DiskProbe, under the mutex: a thread posts an answer only while the DiskProbe lives (the
// mutex orders that against its destructor); a thread stuck on a hung mount outlives it harmlessly.
struct DiskProbe::Shared {
    QMutex mutex;
    DiskProbe *receiver = nullptr;
    // The paths a thread is reading now: one read per path.
    QSet<QString> reading;
    int threads = 0;
};

// A call's thread state: whether the call ended (the thread then reads nothing more).
struct DiskProbe::Job {
    bool ended = false;
};

struct DiskProbe::Call {
    QHash<QString, int> kinds;
    QSet<QString> waiting;
    QElapsedTimer since;
    QElapsedTimer quiet;
    std::shared_ptr<Job> job;
};

DiskProbe::DiskProbe(const Options &options, QObject *parent)
    : QObject(parent)
    , m_options(options)
    , m_shared(std::make_shared<Shared>())
{
    m_shared->receiver = this;
}

DiskProbe::DiskProbe(QObject *parent)
    : DiskProbe(Options{}, parent)
{
}

DiskProbe::~DiskProbe()
{
    const QMutexLocker lock(&m_shared->mutex);
    m_shared->receiver = nullptr;
}

int DiskProbe::kindOf(const QString &path)
{
    const QFileInfo info(path);
    if (!info.exists() && !info.isSymLink())
        return 0;
    return info.isDir() ? 2 : 1;
}

int DiskProbe::threads() const
{
    const QMutexLocker lock(&m_shared->mutex);
    return m_shared->threads;
}

int DiskProbe::probe(const QStringList &paths)
{
    const int token = m_next++;
    auto call = std::make_shared<Call>();
    QStringList toRead;
    for (const QString &path : paths) {
        if (call->kinds.contains(path))
            continue;
        call->kinds.insert(path, kNotResponding);
        // A read that hangs is not started again, nor waited for.
        if (m_stuck.contains(path))
            continue;
        toRead << path;
    }
    if (!toRead.isEmpty()) {
        const QMutexLocker lock(&m_shared->mutex);
        if (m_shared->threads >= kMaxThreads)
            toRead.clear();
        else
            ++m_shared->threads;
    }
    call->waiting = QSet<QString>(toRead.cbegin(), toRead.cend());
    call->since.start();
    call->quiet.start();
    m_calls.insert(token, call);
    if (!toRead.isEmpty()) {
        call->job = std::make_shared<Job>();
        std::thread([shared = m_shared, job = call->job, toRead, stat = m_options.stat] {
            for (const QString &path : toRead) {
                {
                    const QMutexLocker lock(&shared->mutex);
                    if (job->ended || !shared->receiver)
                        break;
                    // Another call's thread is reading it: that read answers this call too.
                    if (shared->reading.contains(path))
                        continue;
                    shared->reading.insert(path);
                }
                const int kind = stat ? stat(path) : kindOf(path);
                const QMutexLocker lock(&shared->mutex);
                shared->reading.remove(path);
                if (DiskProbe *receiver = shared->receiver)
                    QMetaObject::invokeMethod(receiver, [receiver, path, kind] { receiver->readDone(path, kind); }, Qt::QueuedConnection);
            }
            const QMutexLocker lock(&shared->mutex);
            --shared->threads;
        }).detach();
    }
    // Always answered later, never from inside probe(): the asker connects to answered before it can arrive.
    QTimer::singleShot(toRead.isEmpty() ? 0 : qMin(m_options.quietMs, m_options.totalMs), this, [this, token] { check(token); });
    return token;
}

void DiskProbe::readDone(const QString &path, int kind)
{
    // The read returned: the path is no longer stuck, and every call waiting for it has its answer.
    const bool late = m_stuck.remove(path);
    QList<int> done;
    for (auto it = m_calls.cbegin(); it != m_calls.cend(); ++it) {
        Call &call = *it.value();
        if (!call.waiting.remove(path))
            continue;
        call.kinds.insert(path, kind);
        call.quiet.restart();
        if (call.waiting.isEmpty())
            done << it.key();
    }
    for (const int token : std::as_const(done))
        finish(token);
    if (late)
        emit answeredLate(path, kind);
}

void DiskProbe::check(int token)
{
    const auto call = m_calls.value(token);
    if (!call)
        return;
    const qint64 quietLeft = m_options.quietMs - call->quiet.elapsed();
    const qint64 totalLeft = m_options.totalMs - call->since.elapsed();
    if (!call->waiting.isEmpty() && quietLeft > 0 && totalLeft > 0) {
        QTimer::singleShot(int(qMin(quietLeft, totalLeft)), this, [this, token] { check(token); });
        return;
    }
    finish(token);
}

void DiskProbe::finish(int token)
{
    const auto call = m_calls.take(token);
    if (!call)
        return;
    {
        // The thread reads nothing more for this call; a path it waited for that a thread is reading now is stuck.
        const QMutexLocker lock(&m_shared->mutex);
        if (call->job)
            call->job->ended = true;
        for (const QString &path : std::as_const(call->waiting))
            if (m_shared->reading.contains(path))
                m_stuck.insert(path);
    }
    emit answered(token, call->kinds);
}
