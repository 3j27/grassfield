#include "FrameLog.hpp"

#include "Protocol.hpp"

#include <cmath>
#include <format>

namespace gf::frames {

    bool CRing::push(uint64_t us) {
        if (m_total > 0 && us <= m_last)
            return false;
        m_slots[m_next] = us;
        m_next          = (m_next + 1) % kCapacity;
        if (m_size < kCapacity)
            ++m_size;
        ++m_total;
        m_last = us;
        return true;
    }

    std::vector<uint64_t> CRing::snapshot() const {
        std::vector<uint64_t> out;
        out.reserve(m_size);
        const size_t first = (m_next + kCapacity - m_size) % kCapacity;
        for (size_t i = 0; i < m_size; ++i)
            out.push_back(m_slots[(first + i) % kCapacity]);
        return out;
    }

    namespace {
        // At most `max` bytes, never ending inside a UTF-8 sequence (continuation bytes 10xxxxxx are dropped with their
        // lead byte).
        std::string_view cut(std::string_view s, size_t max) {
            if (s.size() <= max)
                return s;
            size_t n = max;
            while (n > 0 && (static_cast<unsigned char>(s[n]) & 0xC0) == 0x80)
                --n;
            return s.substr(0, n);
        }
    } // namespace

    std::string framesJson(std::span<const MonitorFrames> monitors) {
        std::string out = R"({"v":"gfc/1","type":"frames","clock":"monotonic","unit":"us","monitors":[)";
        size_t      written = 0;
        for (const auto& m : monitors) {
            if (written == kMaxMonitors)
                break;
            if (written > 0)
                out += ',';
            const double hz = std::isfinite(m.refreshHz) && m.refreshHz > 0 ? m.refreshHz : 0.0;
            out += std::format(R"({{"name":"{}","refreshHz":{:.3f},"total":{},"presented":[)", gfc::jsonEscape(cut(m.name, kMaxNameBytes)), hz, m.total);
            for (size_t i = 0; i < m.presentedUs.size(); ++i) {
                if (i > 0)
                    out += ',';
                out += std::to_string(m.presentedUs[i]);
            }
            out += "]}";
            ++written;
        }
        out += "]}";
        return out;
    }

} // namespace gf::frames
