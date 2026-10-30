#include "signals.h"

#include "procparse.h"

#include <cerrno>
#include <charconv>
#include <fcntl.h>
#include <sys/syscall.h>
#include <unistd.h>

namespace activity
{
namespace
{

// A file opened through `dir` (or by path when dir is AT_FDCWD), read whole up to 4 KiB: stat and cgroup are one record
// each and far shorter.
bool readAt(int dir, const std::string &name, std::string &out)
{
    out.clear();
    const int fd = openat(dir, name.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return false;
    char buf[4096];
    ssize_t n = 0;
    while (out.size() < sizeof buf && (n = read(fd, buf, sizeof buf - out.size())) > 0)
        out.append(buf, static_cast<size_t>(n));
    const bool ok = n >= 0 && !out.empty();
    close(fd);
    return ok;
}

bool readStat(int dir, const std::string &name, StatFields &st)
{
    std::string text;
    return readAt(dir, name, text) && parseStat(text, st, false);
}

bool parseNumber(const std::string &text, uint64_t &out)
{
    size_t n = 0;
    while (n < text.size() && text[n] >= '0' && text[n] <= '9')
        ++n;
    if (n == 0)
        return false;
    const auto r = std::from_chars(text.data(), text.data() + n, out);
    return r.ec == std::errc();
}

bool readNumber(const std::string &path, uint64_t &out)
{
    std::string text;
    return readAt(AT_FDCWD, path, text) && parseNumber(text, out);
}

} // namespace

ProcessHandle ProcessHandle::open(const std::string &procRoot, int pid, uint64_t start)
{
    ProcessHandle h;
    if (pid <= 0)
        return h;
    const std::string path = procRoot + '/' + std::to_string(pid);
    const int fd = ::open(path.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0)
        return h;
    StatFields st;
    if (!readStat(fd, "stat", st) || st.pid != pid || st.starttime != start) {
        close(fd);
        return h;
    }
    h.m_fd = fd;
    h.m_pid = pid;
    h.m_start = start;
    h.m_ppid = st.ppid;
    return h;
}

ProcessHandle::~ProcessHandle()
{
    if (m_fd >= 0)
        close(m_fd);
}

ProcessHandle::ProcessHandle(ProcessHandle &&other) noexcept
    : m_fd(other.m_fd), m_pid(other.m_pid), m_start(other.m_start), m_ppid(other.m_ppid)
{
    other.m_fd = -1;
}

ProcessHandle &ProcessHandle::operator=(ProcessHandle &&other) noexcept
{
    if (this != &other) {
        if (m_fd >= 0)
            close(m_fd);
        m_fd = other.m_fd;
        m_pid = other.m_pid;
        m_start = other.m_start;
        m_ppid = other.m_ppid;
        other.m_fd = -1;
    }
    return *this;
}

std::string ProcessHandle::cgroup() const
{
    std::string text;
    if (m_fd < 0 || !readAt(m_fd, "cgroup", text))
        return {};
    return parseCgroupV2(text);
}

int ProcessHandle::signal(int sig) const
{
    if (m_fd < 0)
        return EBADF;
    // The system call itself: glibc's wrapper (sys/pidfd.h) is declared without C linkage in C++ here.
    return syscall(SYS_pidfd_send_signal, m_fd, sig, nullptr, 0U) == 0 ? 0 : errno;
}

std::vector<DevRoot> readDevRoots(const std::string &list)
{
    std::vector<DevRoot> roots;
    size_t pos = 0;
    while (pos <= list.size()) {
        size_t end = list.find(':', pos);
        if (end == std::string::npos)
            end = list.size();
        const std::string path = list.substr(pos, end - pos);
        pos = end + 1;
        uint64_t pid = 0, start = 0;
        // As scripts/dev/pidfile.sh's dev_live_pid: no pid 1 or 0, and an empty start time (the process ended before it
        // was read) names nothing.
        if (path.empty() || !readNumber(path, pid) || !readNumber(path + ".start", start) || pid <= 1 || pid > 0x7fffffff)
            continue;
        roots.push_back(DevRoot{static_cast<int>(pid), start});
    }
    return roots;
}

bool underDevRoot(const std::string &procRoot, int pid, uint64_t start, int ppid, const std::vector<DevRoot> &roots)
{
    auto isRoot = [&](int p, uint64_t s) {
        for (const DevRoot &r : roots) {
            if (r.pid == p && r.start == s)
                return true;
        }
        return false;
    };
    if (roots.empty())
        return false;
    if (isRoot(pid, start))
        return true;
    int parent = ppid;
    for (int step = 0; step < 64 && parent > 1; ++step) {
        StatFields st;
        if (!readStat(AT_FDCWD, procRoot + '/' + std::to_string(parent) + "/stat", st) || st.pid != parent)
            return false;
        if (isRoot(parent, st.starttime))
            return true;
        parent = st.ppid;
    }
    return false;
}

} // namespace activity
