#include "busjobs.h"

#include <QCoreApplication>
#include <QMetaObject>
#include <QTimer>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <thread>

namespace grassfield::settings {

struct BusJobs::State {
    std::mutex mutex; // guards alive, mailbox, inFlight; held while posting to the mailbox and while deleting it
    std::condition_variable idle;
    bool alive = true;
    int inFlight = 0;
    QObject *mailbox = nullptr;
    CallerFactory factory;
    std::mutex factoryMutex; // one connect at a time
};

BusJobs::BusJobs(CallerFactory factory, int shutdownWaitMs, std::function<void()> onAbandon)
    : m_state(std::make_shared<State>())
    , m_shutdownWaitMs(shutdownWaitMs)
    , m_onAbandon(onAbandon ? std::move(onAbandon) : [] {
        std::fflush(nullptr);
        std::_Exit(0);
    })
{
    m_state->factory = std::move(factory);
    m_state->mailbox = new QObject; // lives in the thread that constructs the BusJobs
}

BusJobs::~BusJobs()
{
    std::unique_lock<std::mutex> lock(m_state->mutex);
    m_state->alive = false;
    delete m_state->mailbox; // pending events and timers of the mailbox go with it: no `done` runs after this
    m_state->mailbox = nullptr;
    const bool finished = m_state->idle.wait_for(lock, std::chrono::milliseconds(m_shutdownWaitMs), [this] { return m_state->inFlight == 0; });
    lock.unlock();
    if (!finished)
        m_onAbandon();
}

void BusJobs::start(Job job, Done done, int timeoutMs)
{
    const auto doneShared = std::make_shared<Done>(std::move(done));
    const auto settled = std::make_shared<std::atomic<bool>>(false);
    const auto settle = [doneShared, settled](const QString &reason, const QString &output) {
        if (!settled->exchange(true))
            (*doneShared)(reason, output);
    };
    const QString timedOut = QCoreApplication::translate("SystemBus", "timed out");
    {
        std::lock_guard<std::mutex> lock(m_state->mutex);
        if (m_state->inFlight >= kMaxInFlight) {
            QTimer::singleShot(0, m_state->mailbox, [settle, timedOut] { settle(timedOut, QString()); });
            return;
        }
        ++m_state->inFlight;
        QTimer::singleShot(timeoutMs, m_state->mailbox, [settle, timedOut] { settle(timedOut, QString()); });
    }
    const QString noBus = QCoreApplication::translate("SystemBus", "no connection to the system bus");
    std::thread([state = m_state, job = std::move(job), settle, noBus] {
        QString output;
        QString reason;
        std::shared_ptr<BusCaller> caller;
        {
            std::lock_guard<std::mutex> factoryLock(state->factoryMutex);
            caller = state->factory();
        }
        reason = caller ? job(*caller, &output) : noBus;
        caller.reset();
        std::lock_guard<std::mutex> lock(state->mutex);
        if (state->alive && state->mailbox)
            QMetaObject::invokeMethod(state->mailbox, [settle, reason, output] { settle(reason, output); }, Qt::QueuedConnection);
        --state->inFlight;
        state->idle.notify_all();
    }).detach();
}

} // namespace grassfield::settings
