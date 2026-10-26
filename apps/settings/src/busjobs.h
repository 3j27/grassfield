#pragma once

#include <QObject>
#include <QString>

#include <functional>
#include <memory>

#include "systembus.h"

// Runs the blocking D-Bus work of the Wi-Fi and Bluetooth pages off the GUI thread, and hands the result back on it (GF-049).
// What it guarantees:
//  - `done` runs on the thread that called start() (it needs an event loop), exactly once per job: with the job's own result,
//    or with "timed out" when the job did not finish within timeoutMs (a late result is dropped), or with "timed out" at once
//    when kMaxInFlight jobs are already stuck (a stalled bus never piles up threads).
//  - The jobs hold no pointer to their owner: they only post to a mailbox that ~BusJobs deletes under a lock, so a result that
//    arrives after destruction is dropped (the `done` callbacks never run after ~BusJobs).
//  - ~BusJobs waits at most shutdownWaitMs for jobs in flight; a job still stuck after that is abandoned: `onAbandon` runs
//    (default: flush and _Exit(0), because a thread blocked inside Qt D-Bus must not meet the teardown of the application, and
//    the process must not stay alive until the call times out). Nothing the window holds is unsaved.
//  - The caller comes from `factory`, called on the worker (it may connect: a slow bus never blocks the GUI thread); a null
//    caller fails the job.
// Qt Core only; the factory brings the bus.
namespace grassfield::settings {

class BusJobs
{
public:
    using CallerFactory = std::function<std::shared_ptr<BusCaller>()>;
    // Returns "" on success, else the reason; the second argument receives the job's output (JSON).
    using Job = std::function<QString(BusCaller &, QString *)>;
    // Reason ("" on success) and output; runs on the starting thread.
    using Done = std::function<void(const QString &, const QString &)>;

    static constexpr int kMaxInFlight = 4;

    explicit BusJobs(CallerFactory factory, int shutdownWaitMs = 300, std::function<void()> onAbandon = {});
    ~BusJobs();
    BusJobs(const BusJobs &) = delete;
    BusJobs &operator=(const BusJobs &) = delete;

    void start(Job job, Done done, int timeoutMs);

private:
    struct State;
    std::shared_ptr<State> m_state;
    int m_shutdownWaitMs;
    std::function<void()> m_onAbandon;
};

} // namespace grassfield::settings
