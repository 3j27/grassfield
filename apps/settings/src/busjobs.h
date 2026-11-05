#pragma once

#include <QMap>
#include <QObject>
#include <QString>
#include <QVariantMap>

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
//    (default: flush and _Exit(exit code), because a thread blocked inside Qt D-Bus must not meet the teardown of the application,
//    and the process must not stay alive until the call times out). The exit code is the application's own, given to
//    setExitCode() once exec() returned (0 until then). The owner of the jobs does its other cleanup (child processes) BEFORE
//    destroying them: the abandon path skips every destructor. Nothing the window holds is unsaved.
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

    // A function a job may call from its own thread, as often as it likes, to run `f` on the thread that made the BusJobs, in the
    // order posted (fprintd's enrolment statuses, ADR-0045 OC-0.7). Like `done`, `f` never runs after ~BusJobs: what it
    // captures of the owner stays valid while it can run.
    using Post = std::function<void(std::function<void()>)>;
    Post poster() const;

    // The exit code the default abandon path leaves with (the result of the application's exec()).
    static void setExitCode(int code);

private:
    struct State;
    std::shared_ptr<State> m_state;
    int m_shutdownWaitMs;
    std::function<void()> m_onAbandon;
};

// What runs per tag in the Backend, kept there and not in the pages, which every visit creates anew (integrator review of
// PR #6: a page shown again lost its "waiting" state and sent a second polkit request while the first dialog was up; four such
// blocked calls filled kMaxInFlight, and every read of the system bus then answered "timed out"):
//  - actions that may wait for a password (polkit, omarchy-language): one per tag until it finished; the next one of that tag
//    is refused, and the pages show their waiting state from map() (tag -> what);
//  - shared queries (Backend::query's `shared`, opt-in): a command already running under a tag is not started again; its answer
//    reaches whoever listens to that tag (Storage shown again gets the du and pacman counts in progress instead of starting two
//    more). Any other query gets its own process and its own answer.
class InFlight
{
public:
    // Starts `key` under `tag`; false when the tag runs something already (nothing changes then).
    bool begin(const QString &tag, const QString &key);
    // Whether `tag` runs exactly `key`.
    bool runs(const QString &tag, const QString &key) const;
    void end(const QString &tag);
    QVariantMap map() const;

private:
    QMap<QString, QString> m_items;
};

} // namespace grassfield::settings
