#include "netdiag.h"

#include <cstddef>
#include <cstring>

#include <linux/inet_diag.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <linux/sock_diag.h>
#include <linux/tcp.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

namespace activity
{
namespace
{

// A field of tcp_info, read only when the kernel's attribute covers it.
template <typename T>
bool infoField(const unsigned char *info, size_t len, size_t offset, T &out)
{
    if (offset + sizeof(T) > len)
        return false;
    std::memcpy(&out, info + offset, sizeof(T));
    return true;
}

bool dumpFamily(int family, std::vector<TcpCounters> &out)
{
    const int s = socket(AF_NETLINK, SOCK_DGRAM | SOCK_CLOEXEC, NETLINK_SOCK_DIAG);
    if (s < 0)
        return false;
    struct {
        nlmsghdr nlh;
        inet_diag_req_v2 req;
    } msg;
    std::memset(&msg, 0, sizeof msg);
    msg.nlh.nlmsg_len = sizeof msg;
    msg.nlh.nlmsg_type = SOCK_DIAG_BY_FAMILY;
    msg.nlh.nlmsg_flags = NLM_F_REQUEST | NLM_F_DUMP;
    msg.req.sdiag_family = static_cast<unsigned char>(family);
    msg.req.sdiag_protocol = IPPROTO_TCP;
    msg.req.idiag_states = ~0U;
    msg.req.idiag_ext = 1 << (INET_DIAG_INFO - 1);
    if (send(s, &msg, sizeof msg, 0) != static_cast<ssize_t>(sizeof msg)) {
        close(s);
        return false;
    }
    alignas(nlmsghdr) unsigned char buf[32768];
    bool done = false, ok = true;
    while (!done && ok) {
        const ssize_t n = recv(s, buf, sizeof buf, 0);
        if (n <= 0) {
            ok = false;
            break;
        }
        ok = parseInetDiagReply(buf, static_cast<size_t>(n), out, done);
    }
    close(s);
    return ok;
}

} // namespace

bool parseInetDiagReply(const void *data, size_t length, std::vector<TcpCounters> &out, bool &done)
{
    auto *h = static_cast<const nlmsghdr *>(data);
    int len = static_cast<int>(length);
    for (; NLMSG_OK(h, static_cast<unsigned>(len)); h = NLMSG_NEXT(h, len)) {
        if (h->nlmsg_type == NLMSG_DONE) {
            done = true;
            return true;
        }
        if (h->nlmsg_type == NLMSG_ERROR)
            return false;
        if (h->nlmsg_type != SOCK_DIAG_BY_FAMILY || h->nlmsg_len < NLMSG_LENGTH(sizeof(inet_diag_msg)))
            continue;
        auto *m = static_cast<const inet_diag_msg *>(NLMSG_DATA(h));
        TcpCounters c;
        c.inode = m->idiag_inode;
        c.uid = m->idiag_uid;
        int rtlen = static_cast<int>(h->nlmsg_len - NLMSG_LENGTH(sizeof(inet_diag_msg)));
        for (auto *a = reinterpret_cast<const rtattr *>(m + 1); RTA_OK(a, rtlen); a = RTA_NEXT(a, rtlen)) {
            if (a->rta_type != INET_DIAG_INFO)
                continue;
            auto *info = static_cast<const unsigned char *>(RTA_DATA(a));
            const size_t ilen = RTA_PAYLOAD(a);
            infoField(info, ilen, offsetof(tcp_info, tcpi_bytes_acked), c.bytesAcked);
            infoField(info, ilen, offsetof(tcp_info, tcpi_bytes_received), c.bytesReceived);
            uint32_t segs = 0;
            if (infoField(info, ilen, offsetof(tcp_info, tcpi_segs_out), segs))
                c.segsOut = segs;
            if (infoField(info, ilen, offsetof(tcp_info, tcpi_segs_in), segs))
                c.segsIn = segs;
        }
        if (c.inode != 0)
            out.push_back(c);
    }
    return true;
}

bool dumpTcpSockets(std::vector<TcpCounters> &out)
{
    out.clear();
    return dumpFamily(AF_INET, out) && dumpFamily(AF_INET6, out);
}

} // namespace activity
