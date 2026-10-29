#include "diskprobe.h"

#include <QElapsedTimer>
#include <QFileInfo>
#include <QMutex>
#include <QTimer>

#include <thread>

// What a call's thread shares with the DiskProbe: the thread posts an answer only while the DiskProbe lives (the mutex
// orders that against its destructor); a thread stuck on a hung mount outlives it harmlessly.
struct DiskProbe::Shared {
    QMutex mutex;
    DiskProbe *receiver = nullptr;
};

// A call's thread state: the path being read, and whether the call ended (the thread then reads nothing more).
struct DiskProbe::Job {
    QString reading;
    bool ended = false;
};

struct DiskProbe::Call {
    QHash<QString, int> kinds;
    int waiting = 0;
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

int DiskProbe::probe(const QStringList &paths)
{
    const int token = m_next++;
    auto call = std::make_shared<Call>();
    QStringList toRead;
    for (const QString &path : paths) {
        if (call->kinds.contains(path))
            continue;
        call->kinds.insert(path, kNotResponding);
        // A read that hangs is not started again; with kMaxStuck of them, no new read starts.
        if (m_stuck.contains(path) || m_stuck.size() >= kMaxStuck)
            continue;
        toRead << path;
    }
    call->waiting = int(toRead.size());
    call->since.start();
    call->quiet.start();
    m_calls.insert(token, call);
    if (!toRead.isEmpty()) {
        call->job = std::make_shared<Job>();
        std::thread([shared = m_shared, job = call->job, token, toRead, stat = m_options.stat] {
            for (const QString &path : toRead) {
                {
                    const QMutexLocker lock(&shared->mutex);
                    if (job->ended || !shared->receiver)
                        return;
                    job->reading = path;
                }
                const int kind = stat ? stat(path) : kindOf(path);
                const QMutexLocker lock(&shared->mutex);
                job->reading.clear();
                if (DiskProbe *receiver = shared->receiver)
                    QMetaObject::invokeMethod(receiver, [receiver, token, path, kind] { receiver->readDone(token, path, kind); }, Qt::QueuedConnection);
            }
        }).detach();
    }
    // Always answered later, never from inside probe(): the asker connects to answered before it can arrive.
    QTimer::singleShot(toRead.isEmpty() ? 0 : qMin(m_options.quietMs, m_options.totalMs), this, [this, token] { check(token); });
    return token;
}

void DiskProbe::readDone(int token, const QString &path, int kind)
{
    // The read returned: the path is no longer stuck, whether or not its call is still waiting.
    const auto stuck = m_stuck.constFind(path);
    if (stuck != m_stuck.cend() && *stuck == token)
        m_stuck.erase(stuck);
    const auto call = m_calls.value(token);
    if (!call)
        return;
    call->kinds.insert(path, kind);
    call->quiet.restart();
    if (--call->waiting == 0)
        finish(token);
}

void DiskProbe::check(int token)
{
    const auto call = m_calls.value(token);
    if (!call)
        return;
    const qint64 quietLeft = m_options.quietMs - call->quiet.elapsed();
    const qint64 totalLeft = m_options.totalMs - call->since.elapsed();
    if (call->waiting > 0 && quietLeft > 0 && totalLeft > 0) {
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
    if (call->job) {
        // The thread reads nothing more for this call; the path it is reading now, if any, is stuck.
        const QMutexLocker lock(&m_shared->mutex);
        call->job->ended = true;
        if (!call->job->reading.isEmpty())
            m_stuck.insert(call->job->reading, token);
    }
    emit answered(token, call->kinds);
}
