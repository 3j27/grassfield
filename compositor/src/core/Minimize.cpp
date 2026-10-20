#include "Minimize.hpp"

#include <algorithm>
#include <charconv>
#include <cmath>

namespace gf::minimize {

    std::optional<uint64_t> parseAddress(std::string_view text) {
        if (text.starts_with("0x") || text.starts_with("0X"))
            text.remove_prefix(2);
        if (text.empty() || text.size() > 16)
            return std::nullopt;
        for (const char c : text) {
            const bool hex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
            if (!hex)
                return std::nullopt;
        }
        uint64_t value = 0;
        const auto [end, ec] = std::from_chars(text.data(), text.data() + text.size(), value, 16);
        if (ec != std::errc{} || end != text.data() + text.size() || value == 0)
            return std::nullopt;
        return value;
    }

    bool isFinite(const Box& b) {
        return std::isfinite(b.x) && std::isfinite(b.y) && std::isfinite(b.w) && std::isfinite(b.h);
    }

    bool isValidTarget(const Box& target, std::span<const Box> monitors) {
        if (!isFinite(target) || target.w < 1.0 || target.h < 1.0 || target.w > kMaxTargetSide || target.h > kMaxTargetSide)
            return false;
        return std::ranges::any_of(monitors, [&target](const Box& m) {
            if (!isFinite(m) || m.w <= 0 || m.h <= 0)
                return false;
            return target.x >= m.x - kLayoutTolerance && target.y >= m.y - kLayoutTolerance && target.x + target.w <= m.x + m.w + kLayoutTolerance &&
                target.y + target.h <= m.y + m.h + kLayoutTolerance;
        });
    }

    Box fitInside(const Box& source, const Box& target) {
        if (source.w <= 0 || source.h <= 0 || target.w <= 0 || target.h <= 0)
            return target;
        const double scale = std::min(target.w / source.w, target.h / source.h);
        const double w     = source.w * scale;
        const double h     = source.h * scale;
        return Box{target.x + ((target.w - w) / 2.0), target.y + ((target.h - h) / 2.0), w, h};
    }

    Box lerp(const Box& a, const Box& b, double t) {
        const auto mix = [t](double p, double q) { return p + ((q - p) * t); };
        return Box{mix(a.x, b.x), mix(a.y, b.y), mix(a.w, b.w), mix(a.h, b.h)};
    }

    double CCubicBezier::operator()(double t) const {
        t = std::clamp(t, 0.0, 1.0);
        if (t == 0.0 || t == 1.0)
            return t;

        const auto bez  = [](double p1, double p2, double s) { return (3.0 * (1.0 - s) * (1.0 - s) * s * p1) + (3.0 * (1.0 - s) * s * s * p2) + (s * s * s); };
        const auto dbez = [](double p1, double p2, double s) { return (3.0 * (1.0 - s) * (1.0 - s) * p1) + (6.0 * (1.0 - s) * s * (p2 - p1)) + (3.0 * s * s * (1.0 - p2)); };

        // x(s) is monotonic on [0, 1] (x1, x2 clamped): Newton steps, bisection when the slope is flat.
        double s  = t;
        double lo = 0.0;
        double hi = 1.0;
        for (int i = 0; i < 32; ++i) {
            const double x = bez(m_x1, m_x2, s) - t;
            if (std::abs(x) < 1e-9)
                break;
            if (x > 0)
                hi = s;
            else
                lo = s;
            const double d = dbez(m_x1, m_x2, s);
            double       next = std::abs(d) > 1e-6 ? s - (x / d) : (lo + hi) / 2.0;
            if (next <= lo || next >= hi)
                next = (lo + hi) / 2.0;
            s = next;
        }
        return bez(m_y1, m_y2, s);
    }

    double durationMs(Kind kind) {
        return kind == Kind::Minimize ? kMinimizeDurationMs : kRestoreDurationMs;
    }

    CCubicBezier curve(Kind kind) {
        // Ease-in (motion token "accelerate": 0.4, 0, 1, 1) and its time-reverse for the way back.
        return kind == Kind::Minimize ? CCubicBezier{0.4, 0.0, 1.0, 1.0} : CCubicBezier{0.0, 0.0, 0.6, 1.0};
    }

    Frame frameAt(Kind kind, const Box& from, const Box& to, double elapsedMs) {
        const double duration = durationMs(kind);
        const double t        = duration > 0 && std::isfinite(elapsedMs) ? std::clamp(elapsedMs / duration, 0.0, 1.0) : 1.0;

        Frame        frame;
        frame.box  = lerp(from, to, curve(kind)(t));
        frame.done = t >= 1.0;
        if (kind == Kind::Minimize)
            frame.alpha = t <= 1.0 - kFadeFraction ? 1.F : static_cast<float>((1.0 - t) / kFadeFraction);
        else
            frame.alpha = t >= kFadeFraction ? 1.F : static_cast<float>(t / kFadeFraction);
        frame.alpha = std::clamp(frame.alpha, 0.F, 1.F);
        return frame;
    }

    std::optional<Effect> parseEffect(std::string_view key, std::string_view value) {
        if (key != kConfigMinimizeEffect)
            return std::nullopt;
        if (value == "genie")
            return Effect::Genie;
        if (value == "scale")
            return Effect::Scale;
        if (value == "fade")
            return Effect::Fade;
        return std::nullopt;
    }

    Frame fadeFrameAt(Kind kind, const Box& box, double elapsedMs) {
        const double t = std::isfinite(elapsedMs) ? std::clamp(elapsedMs / kFadeDurationMs, 0.0, 1.0) : 1.0;
        Frame        frame;
        frame.box   = box;
        frame.done  = t >= 1.0;
        frame.alpha = std::clamp(static_cast<float>(kind == Kind::Minimize ? 1.0 - t : t), 0.F, 1.F);
        return frame;
    }

    Box mapBox(const Box& inner, const Box& src, const Box& dst) {
        const double sx = src.w > 0 ? dst.w / src.w : 1.0;
        const double sy = src.h > 0 ? dst.h / src.h : 1.0;
        return Box{dst.x + ((inner.x - src.x) * sx), dst.y + ((inner.y - src.y) * sy), inner.w * sx, inner.h * sy};
    }

    Box textureBox(const SSnapshotGeometry& snapshot, const Box& dst, double monX, double monY, double monScale) {
        const Box&   v  = snapshot.visible;
        const double kx = v.w > 0 && snapshot.monitorScale > 0 ? (dst.w * monScale) / (v.w * snapshot.monitorScale) : 1.0;
        const double ky = v.h > 0 && snapshot.monitorScale > 0 ? (dst.h * monScale) / (v.h * snapshot.monitorScale) : 1.0;
        return Box{((dst.x - monX) * monScale) - ((v.x - snapshot.monitorX) * snapshot.monitorScale * kx),
                   ((dst.y - monY) * monScale) - ((v.y - snapshot.monitorY) * snapshot.monitorScale * ky), snapshot.texW * kx, snapshot.texH * ky};
    }

    bool intersects(const Box& a, const Box& b) {
        return a.w > 0 && a.h > 0 && b.w > 0 && b.h > 0 && a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;
    }

} // namespace gf::minimize
