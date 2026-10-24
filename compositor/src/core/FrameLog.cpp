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

    bool CSpanRing::push(const RenderSpan& span) {
        if (m_any && span.beginUs <= m_last)
            return false;
        m_slots[m_next] = span;
        m_next          = (m_next + 1) % kCapacity;
        if (m_size < kCapacity)
            ++m_size;
        m_last = span.beginUs;
        m_any  = true;
        return true;
    }

    std::vector<RenderSpan> CSpanRing::snapshot() const {
        std::vector<RenderSpan> out;
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

    bool CMarkRing::push(uint64_t us, std::string_view what) {
        if (m_size > 0 && us < m_last)
            return false;
        m_slots[m_next] = Mark{.us = us, .what = std::string{cut(what, kMaxMarkBytes)}};
        m_next          = (m_next + 1) % kMaxMarks;
        if (m_size < kMaxMarks)
            ++m_size;
        m_last = us;
        return true;
    }

    std::vector<Mark> CMarkRing::snapshot() const {
        std::vector<Mark> out;
        out.reserve(m_size);
        const size_t first = (m_next + kMaxMarks - m_size) % kMaxMarks;
        for (size_t i = 0; i < m_size; ++i)
            out.push_back(m_slots[(first + i) % kMaxMarks]);
        return out;
    }

    std::string framesJson(std::span<const MonitorFrames> monitors, std::span<const Mark> marks) {
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
            out += R"(],"renders":[)";
            for (size_t i = 0; i < m.renders.size(); ++i) {
                if (i > 0)
                    out += ',';
                out += std::format("[{},{}]", m.renders[i].beginUs, m.renders[i].cpuUs);
            }
            out += "]}";
            ++written;
        }
        out += R"(],"marks":[)";
        for (size_t i = 0; i < marks.size(); ++i) {
            if (i > 0)
                out += ',';
            out += std::format(R"({{"t":{},"what":"{}"}})", marks[i].us, gfc::jsonEscape(cut(marks[i].what, kMaxMarkBytes)));
        }
        out += "]}";
        return out;
    }

} // namespace gf::frames
