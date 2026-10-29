// TCP counters per socket without privileges (apps/activity/src/netdiag.cpp, the sampler's network part; ADR-0038 A5;
// docs/specs/activity.md AM43, acceptance A-S5): a reply built by hand, then the real kernel with loopback connections of
// this test: the bytes sent and received are found by inode, given to the process that holds the sockets, and kept after
// the sockets close.
#include "netdiag.h"
#include "sampler.h"

#include <algorithm>
#include <cstring>
#include <vector>

#include <arpa/inet.h>
#include <linux/inet_diag.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <linux/sock_diag.h>
#include <linux/tcp.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

#include <gtest/gtest.h>

using namespace activity;

namespace
{

// One SOCK_DIAG_BY_FAMILY message with an INET_DIAG_INFO attribute of `infoLen` bytes, then NLMSG_DONE.
std::vector<unsigned char> reply(uint32_t inode, uint32_t uid, uint64_t acked, uint64_t received, size_t infoLen)
{
    tcp_info info{};
    info.tcpi_bytes_acked = acked;
    info.tcpi_bytes_received = received;
    info.tcpi_segs_out = 7;
    info.tcpi_segs_in = 9;
    const size_t attrLen = RTA_LENGTH(infoLen);
    const size_t msgLen = NLMSG_LENGTH(sizeof(inet_diag_msg) + RTA_ALIGN(attrLen));
    std::vector<unsigned char> buf(NLMSG_ALIGN(msgLen) + NLMSG_LENGTH(0), 0);
    auto *h = reinterpret_cast<nlmsghdr *>(buf.data());
    h->nlmsg_len = static_cast<uint32_t>(msgLen);
    h->nlmsg_type = SOCK_DIAG_BY_FAMILY;
    auto *m = static_cast<inet_diag_msg *>(NLMSG_DATA(h));
    m->idiag_inode = inode;
    m->idiag_uid = uid;
    auto *a = reinterpret_cast<rtattr *>(m + 1);
    a->rta_type = INET_DIAG_INFO;
    a->rta_len = static_cast<unsigned short>(attrLen);
    std::memcpy(RTA_DATA(a), &info, std::min(infoLen, sizeof info));
    auto *done = reinterpret_cast<nlmsghdr *>(buf.data() + NLMSG_ALIGN(msgLen));
    done->nlmsg_len = NLMSG_LENGTH(0);
    done->nlmsg_type = NLMSG_DONE;
    return buf;
}

uint64_t inodeOf(int fd)
{
    struct stat st{};
    fstat(fd, &st);
    return st.st_ino;
}

struct Loopback {
    int server = -1, client = -1, peer = -1;
    explicit Loopback(size_t bytes)
    {
        server = socket(AF_INET, SOCK_STREAM, 0);
        sockaddr_in a{};
        a.sin_family = AF_INET;
        a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        bind(server, reinterpret_cast<sockaddr *>(&a), sizeof a);
        listen(server, 1);
        socklen_t len = sizeof a;
        getsockname(server, reinterpret_cast<sockaddr *>(&a), &len);
        client = socket(AF_INET, SOCK_STREAM, 0);
        connect(client, reinterpret_cast<sockaddr *>(&a), sizeof a);
        peer = accept(server, nullptr, nullptr);
        std::vector<char> data(bytes, 'x');
        size_t sent = 0;
        while (sent < bytes) {
            const ssize_t n = write(client, data.data() + sent, bytes - sent);
            if (n <= 0)
                break;
            sent += static_cast<size_t>(n);
            size_t got = 0;
            while (got < static_cast<size_t>(n)) {
                const ssize_t r = read(peer, data.data(), data.size());
                if (r <= 0)
                    break;
                got += static_cast<size_t>(r);
            }
        }
    }
    ~Loopback() { closeAll(); }
    void closeAll()
    {
        for (int *fd : {&client, &peer, &server}) {
            if (*fd >= 0)
                close(*fd);
            *fd = -1;
        }
    }
};

} // namespace

TEST(NetDiag, ParsesAReply)
{
    const auto buf = reply(4242, 1000, 123456, 654321, sizeof(tcp_info));
    std::vector<TcpCounters> out;
    bool done = false;
    ASSERT_TRUE(parseInetDiagReply(buf.data(), buf.size(), out, done));
    EXPECT_TRUE(done);
    ASSERT_EQ(out.size(), 1u);
    EXPECT_EQ(out[0].inode, 4242u);
    EXPECT_EQ(out[0].uid, 1000u);
    EXPECT_EQ(out[0].bytesAcked, 123456u);
    EXPECT_EQ(out[0].bytesReceived, 654321u);
    EXPECT_EQ(out[0].segsOut, 7u);
    EXPECT_EQ(out[0].segsIn, 9u);
}

TEST(NetDiag, AShortTcpInfoLeavesTheFieldsItLacksAtZero)
{
    // An older kernel's tcp_info ends before tcpi_bytes_acked.
    const auto buf = reply(7, 0, 999, 888, offsetof(tcp_info, tcpi_bytes_acked));
    std::vector<TcpCounters> out;
    bool done = false;
    ASSERT_TRUE(parseInetDiagReply(buf.data(), buf.size(), out, done));
    ASSERT_EQ(out.size(), 1u);
    EXPECT_EQ(out[0].bytesAcked, 0u);
    EXPECT_EQ(out[0].bytesReceived, 0u);
}

TEST(NetDiag, AnErrorReplyFails)
{
    std::vector<unsigned char> buf(NLMSG_LENGTH(sizeof(nlmsgerr)), 0);
    auto *h = reinterpret_cast<nlmsghdr *>(buf.data());
    h->nlmsg_len = static_cast<uint32_t>(buf.size());
    h->nlmsg_type = NLMSG_ERROR;
    std::vector<TcpCounters> out;
    bool done = false;
    EXPECT_FALSE(parseInetDiagReply(buf.data(), buf.size(), out, done));
}

TEST(NetDiag, TheKernelGivesTheCountersOfThisProcessSockets)
{
    Loopback lo(200000);
    std::vector<TcpCounters> dump;
    ASSERT_TRUE(dumpTcpSockets(dump));
    const uint64_t client = inodeOf(lo.client), peer = inodeOf(lo.peer), listener = inodeOf(lo.server);
    bool sawClient = false, sawPeer = false;
    for (const TcpCounters &c : dump) {
        EXPECT_NE(c.inode, listener); // listeners, TIME_WAIT and closed sockets are left out of the dump (review of f68789c)
        if (c.inode == client) {
            sawClient = true;
            EXPECT_GE(c.bytesAcked, 200000u);
            EXPECT_EQ(c.uid, getuid());
        }
        if (c.inode == peer) {
            sawPeer = true;
            EXPECT_GE(c.bytesReceived, 200000u);
        }
    }
    EXPECT_TRUE(sawClient);
    EXPECT_TRUE(sawPeer);
}

TEST(NetDiag, TheSamplerGivesTheBytesToTheProcessAndKeepsThemAfterTheSocketsClose)
{
    Options o = defaultOptions();
    o.descriptorTurns = 1; // every own process's descriptors at every sample
    Sampler s(o);
    const unsigned reads = ReadProcesses | ReadDescriptors | ReadSockets;
    auto mine = [](const Snapshot &snap) -> const ProcessRow * {
        for (const ProcessRow &r : snap.rows) {
            if (r.pid == getpid())
                return &r;
        }
        return nullptr;
    };
    uint64_t sentBefore = 0;
    {
        const Snapshot first = s.sample(reads, 1.0);
        const ProcessRow *r = mine(first);
        ASSERT_NE(r, nullptr);
        sentBefore = r->tcpSent; // sockets other tests of this process left open, if any
    }
    Loopback lo(300000);
    const Snapshot open = s.sample(reads, 2.0);
    const ProcessRow *r = mine(open);
    ASSERT_NE(r, nullptr);
    EXPECT_TRUE(r->hasNet);
    EXPECT_GE(r->tcpSent, sentBefore + 300000);    // the client socket's bytes acknowledged
    EXPECT_GE(r->tcpReceived, 300000u);           // the peer socket's bytes received
    EXPECT_GT(r->tcpSegsOut, 0u);
    const uint64_t sent = r->tcpSent;
    lo.closeAll();
    const Snapshot closed = s.sample(reads, 3.0);
    r = mine(closed);
    ASSERT_NE(r, nullptr);
    EXPECT_GE(r->tcpSent, sent); // a socket that closed keeps its last counters with its process (AM43)
}
