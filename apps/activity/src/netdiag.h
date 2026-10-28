// TCP byte and segment counters per socket without privileges (ADR-0038 A5, docs/specs/activity.md AM43): one
// NETLINK_SOCK_DIAG dump per address family with tcp_info, what `ss -ti` asks for. The kernel answers for every socket; the
// sampler keeps those whose inode it finds in the user's own /proc/<pid>/fd. UDP has no such counters (A5).
#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

namespace activity
{

struct TcpCounters {
    uint64_t inode = 0;
    uint32_t uid = 0;
    uint64_t bytesAcked = 0;    // tcpi_bytes_acked: sent and acknowledged
    uint64_t bytesReceived = 0; // tcpi_bytes_received
    uint64_t segsOut = 0, segsIn = 0;
};

// One reply buffer of the dump (several netlink messages). Appends what it finds; `done` turns true at NLMSG_DONE. False on
// NLMSG_ERROR or a malformed message. A socket whose tcp_info is shorter than the kernel's own (an older kernel) keeps 0
// in the fields it does not cover.
bool parseInetDiagReply(const void *data, size_t length, std::vector<TcpCounters> &out, bool &done);

// The dump itself, IPv4 then IPv6. False when the netlink socket cannot be opened or answers with an error.
bool dumpTcpSockets(std::vector<TcpCounters> &out);

} // namespace activity
