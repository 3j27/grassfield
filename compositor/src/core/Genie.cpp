#include "Genie.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <limits>

namespace gf::minimize {

    namespace {
        double clamp01(double t) {
            return std::isfinite(t) ? std::clamp(t, 0.0, 1.0) : 1.0;
        }

        double mix(double p, double q, double t) {
            return p + ((q - p) * t);
        }

        // 3t^2 - 2t^3: zero slope at both ends (the funnel's sides leave the window and enter the tile vertically).
        double smoothstep(double t) {
            t = clamp01(t);
            return t * t * (3.0 - (2.0 * t));
        }

        double easeInOutCubic(double t) {
            t = clamp01(t);
            return t < 0.5 ? 4.0 * t * t * t : 1.0 - (std::pow((-2.0 * t) + 2.0, 3.0) / 2.0);
        }

        // The window's top accelerates into the Dock (and, played backwards for a restore, leaves it fast and settles).
        double easeInQuad(double t) {
            t = clamp01(t);
            return t * t;
        }

        // Source fractions (u over x, v over y) <-> Dock-frame fractions (alpha across, beta along toward the Dock).
        struct SFractions {
            double first  = 0;
            double second = 0;
        };

        SFractions toFrameFractions(double u, double v, Edge edge) {
            switch (edge) {
                case Edge::Bottom: return {u, v};
                case Edge::Top: return {u, 1.0 - v};
                case Edge::Right: return {v, u};
                case Edge::Left: return {v, 1.0 - u};
            }
            return {u, v};
        }

        SFractions fromFrameFractions(double alpha, double beta, Edge edge) {
            switch (edge) {
                case Edge::Bottom: return {alpha, beta};
                case Edge::Top: return {alpha, 1.0 - beta};
                case Edge::Right: return {beta, alpha};
                case Edge::Left: return {1.0 - beta, alpha};
            }
            return {alpha, beta};
        }

        // Dock-frame point (a across, b along) back to layout coordinates (the inverse of toFrame's axis map).
        Point fromFrame(double a, double b, Edge edge) {
            switch (edge) {
                case Edge::Bottom: return {a, b};
                case Edge::Top: return {a, -b};
                case Edge::Right: return {b, a};
                case Edge::Left: return {-b, a};
            }
            return {a, b};
        }

        bool hasArea(const Box& b) {
            return isFinite(b) && b.w > 0 && b.h > 0;
        }
    } // namespace

    Edge dockEdge(const Box& tile, const Box& monitor) {
        if (!isFinite(tile) || !isFinite(monitor) || monitor.w <= 0 || monitor.h <= 0)
            return Edge::Bottom;
        // In priority order for ties: Bottom, Left, Right, Top.
        const std::array<std::pair<Edge, double>, 4> distances = {{
            {Edge::Bottom, (monitor.y + monitor.h) - (tile.y + tile.h)},
            {Edge::Left, tile.x - monitor.x},
            {Edge::Right, (monitor.x + monitor.w) - (tile.x + tile.w)},
            {Edge::Top, tile.y - monitor.y},
        }};
        Edge   best     = Edge::Bottom;
        double bestDist = std::numeric_limits<double>::infinity();
        for (const auto& [edge, dist] : distances) {
            const double d = std::abs(dist);
            if (d < bestDist) {
                best     = edge;
                bestDist = d;
            }
        }
        return best;
    }

    CGenie::SFrameBox CGenie::toFrame(const Box& box, Edge edge) {
        switch (edge) {
            case Edge::Bottom: return SFrameBox{.a0 = box.x, .a1 = box.x + box.w, .b0 = box.y, .b1 = box.y + box.h};
            case Edge::Top: return SFrameBox{.a0 = box.x, .a1 = box.x + box.w, .b0 = -(box.y + box.h), .b1 = -box.y};
            case Edge::Right: return SFrameBox{.a0 = box.y, .a1 = box.y + box.h, .b0 = box.x, .b1 = box.x + box.w};
            case Edge::Left: return SFrameBox{.a0 = box.y, .a1 = box.y + box.h, .b0 = -(box.x + box.w), .b1 = -box.x};
        }
        return SFrameBox{.a0 = box.x, .a1 = box.x + box.w, .b0 = box.y, .b1 = box.y + box.h};
    }

    CGenie::CGenie(const Box& source, const Box& target, Edge edge) : m_src(toFrame(source, edge)), m_dst(toFrame(target, edge)), m_edge(edge) {}

    Point CGenie::at(double u, double v, double progress) const {
        const double p = clamp01(progress);
        const auto [alpha, beta] = toFrameFractions(u, v, m_edge);

        const double bend  = smoothstep(p / kGenieBendEnd);
        const double nearT = easeInOutCubic(p / kGenieNearEnd);
        const double farT  = easeInQuad((p - kGenieFarStart) / (1.0 - kGenieFarStart));

        // Along the Dock axis: the row between the far and the near edge.
        const double bNear = mix(m_src.b1, m_dst.b1, nearT);
        const double bFar  = mix(m_src.b0, m_dst.b0, farT);
        const double b     = mix(bFar, bNear, beta);

        // Across: the funnel at that depth (window span above the window's far edge, tile span from the tile's near side).
        const double depth = m_dst.b0 - m_src.b0;
        const double s     = depth > 1e-6 ? smoothstep((b - m_src.b0) / depth) : 1.0;
        const double fa0   = mix(m_src.a0, m_dst.a0, s);
        const double fa1   = mix(m_src.a1, m_dst.a1, s);
        const double ra0   = mix(m_src.a0, fa0, bend);
        const double ra1   = mix(m_src.a1, fa1, bend);
        const double a     = mix(ra0, ra1, alpha);

        return fromFrame(a, b, m_edge);
    }

    bool isGenieGeometry(const Box& source, const Box& target, Edge edge) {
        if (!hasArea(source) || !hasArea(target))
            return false;
        // Far side of the target beyond the source's far edge in the Dock frame (CGenie::toFrame), 1 px margin: see the
        // header (rows could cross otherwise).
        switch (edge) {
            case Edge::Bottom: return target.y + target.h > source.y + 1.0;
            case Edge::Top: return target.y < source.y + source.h - 1.0;
            case Edge::Right: return target.x + target.w > source.x + 1.0;
            case Edge::Left: return target.x < source.x + source.w - 1.0;
        }
        return false;
    }

    void genieMesh(const CGenie& genie, const Box& source, const Box& region, double progress, int across, int along, std::vector<SMeshVertex>& out) {
        out.clear();
        if (!hasArea(source) || !hasArea(region) || across < 1 || along < 1)
            return;
        // The region in source fractions, then in Dock-frame fractions (ranges of alpha across, beta along).
        const double uMin = (region.x - source.x) / source.w;
        const double uMax = (region.x + region.w - source.x) / source.w;
        const double vMin = (region.y - source.y) / source.h;
        const double vMax = (region.y + region.h - source.y) / source.h;
        const auto   c0   = toFrameFractions(uMin, vMin, genie.edge());
        const auto   c1   = toFrameFractions(uMax, vMax, genie.edge());
        const double aLo = std::min(c0.first, c1.first), aHi = std::max(c0.first, c1.first);
        const double bLo = std::min(c0.second, c1.second), bHi = std::max(c0.second, c1.second);

        out.reserve(static_cast<size_t>(meshVertexCount(across, along)));
        for (int line = 0; line <= along; ++line) {
            const double beta = mix(bLo, bHi, static_cast<double>(line) / along);
            for (int col = 0; col <= across; ++col) {
                const double alpha  = mix(aLo, aHi, static_cast<double>(col) / across);
                const auto [u, v]   = fromFrameFractions(alpha, beta, genie.edge());
                const Point p       = genie.at(u, v, progress);
                out.push_back(SMeshVertex{.x = p.x, .y = p.y, .u = u, .v = v});
            }
        }
    }

    std::vector<uint16_t> meshIndices(int across, int along) {
        std::vector<uint16_t> out;
        if (across < 1 || along < 1 || meshVertexCount(across, along) > 65536)
            return out;
        out.reserve(static_cast<size_t>(across) * static_cast<size_t>(along) * 6);
        const int stride = across + 1;
        for (int line = 0; line < along; ++line) {
            for (int col = 0; col < across; ++col) {
                const auto i0 = static_cast<uint16_t>((line * stride) + col);
                const auto i1 = static_cast<uint16_t>(i0 + 1);
                const auto i2 = static_cast<uint16_t>(i0 + stride);
                const auto i3 = static_cast<uint16_t>(i2 + 1);
                out.insert(out.end(), {i0, i2, i1, i1, i2, i3});
            }
        }
        return out;
    }

    Box meshBounds(std::span<const SMeshVertex> mesh) {
        if (mesh.empty())
            return Box{};
        double x0 = mesh.front().x, x1 = x0, y0 = mesh.front().y, y1 = y0;
        for (const auto& m : mesh) {
            x0 = std::min(x0, m.x);
            x1 = std::max(x1, m.x);
            y0 = std::min(y0, m.y);
            y1 = std::max(y1, m.y);
        }
        return Box{x0, y0, x1 - x0, y1 - y0};
    }

    SGenieFrame genieFrameAt(Kind kind, double elapsedMs) {
        const double t = std::isfinite(elapsedMs) ? std::clamp(elapsedMs / kGenieDurationMs, 0.0, 1.0) : 1.0;
        SGenieFrame  frame;
        frame.done = t >= 1.0;
        if (kind == Kind::Minimize) {
            frame.progress = t;
            frame.alpha    = t <= 1.0 - kGenieFadeFraction ? 1.F : static_cast<float>((1.0 - t) / kGenieFadeFraction);
        } else {
            frame.progress = 1.0 - t;
            frame.alpha    = t >= kGenieFadeFraction ? 1.F : static_cast<float>(t / kGenieFadeFraction);
        }
        frame.alpha = std::clamp(frame.alpha, 0.F, 1.F);
        return frame;
    }

    double genieElapsedFor(Kind kind, double progress) {
        const double p = clamp01(progress);
        return (kind == Kind::Minimize ? p : 1.0 - p) * kGenieDurationMs;
    }

} // namespace gf::minimize
