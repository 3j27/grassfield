// Quit, Force Quit and signals (ADR-0038 e, AD30; spec AM50 to AM56): one process from the check to the signal, and the
// dev guard's roots. Plain C++17 and POSIX, as the sampler. The app reads the real /proc; the tests also read fixture trees
// for the checks (a fixture's descriptor is no pidfd: its signal fails, EBADF or EINVAL).
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace activity
{

// AM51: /proc/<pid> opened as a directory, its stat read through it (openat) and its start time matched with the row's.
// The same descriptor is the pidfd of the signal (pidfd_send_signal(2) takes a /proc/<pid> descriptor): it names that one
// process for good, so a process that ended fails with ESRCH and a new process that took its pid is never hit.
class ProcessHandle
{
public:
    ProcessHandle() = default;
    // Invalid when the directory or its stat cannot be read (the process ended) or the start time differs.
    static ProcessHandle open(const std::string &procRoot, int pid, uint64_t start);
    ~ProcessHandle();
    ProcessHandle(ProcessHandle &&other) noexcept;
    ProcessHandle &operator=(ProcessHandle &&other) noexcept;
    ProcessHandle(const ProcessHandle &) = delete;
    ProcessHandle &operator=(const ProcessHandle &) = delete;

    bool valid() const { return m_fd >= 0; }
    int pid() const { return m_pid; }
    uint64_t start() const { return m_start; }
    int ppid() const { return m_ppid; }
    // The process's cgroup v2 path, read through the descriptor when the action needs it (AM52, AM54: a row keeps none,
    // AD25); "" when it cannot be read.
    std::string cgroup() const;
    // 0, or the errno of pidfd_send_signal: ESRCH when the process ended, EBADF or EINVAL on a fixture's directory.
    int signal(int sig) const;

private:
    int m_fd = -1;
    int m_pid = 0;
    uint64_t m_start = 0;
    int m_ppid = 0;
};

// AM56: in a dev session, an action reaches only a process a root names or a descendant of one. A root is a pid record of
// scripts/dev/pidfile.sh: a file holding the pid, and "<file>.start" its start time (stat field 22). `list` holds the
// records' paths separated by ':'; a missing or malformed record names nothing.
struct DevRoot {
    int pid = 0;
    uint64_t start = 0;
};
std::vector<DevRoot> readDevRoots(const std::string &list);

// The process (pid, start, ppid) is a root, or one of its parents is: each read from its stat by path, a root matching
// by pid and start time (a record whose process ended, or whose pid was taken again, names nothing). The walk ends at
// pid 1, at a parent that cannot be read, or after 64 steps.
bool underDevRoot(const std::string &procRoot, int pid, uint64_t start, int ppid, const std::vector<DevRoot> &roots);

} // namespace activity
