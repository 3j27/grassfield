#include "Tiling.hpp"

#include "Json.hpp"
#include "Minimize.hpp"
#include "Protocol.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <format>
#include <limits>
#include <numeric>
#include <utility>

namespace gf::tiling {

    namespace tokens = gf::theme::tokens;

    std::optional<Place> placeForPointer(double x, double y, const Output& output, const DragOptions& options) {
        const Rect& o = output.box;
        if (o.w <= 0 || o.h <= 0 || x < o.x || x >= o.x + o.w || y < o.y || y >= o.y + o.h)
            return std::nullopt;
        if (options.edges) {
            const bool left  = output.leftFree && x <= o.x + kEdge;
            const bool right = output.rightFree && x >= o.x + o.w - 1 - kEdge;
            if (left || right) {
                const bool top    = y <= o.y + kCorner;
                const bool bottom = y >= o.y + o.h - 1 - kCorner;
                if (top)
                    return left ? Place::TopLeft : Place::TopRight;
                if (bottom)
                    return left ? Place::BottomLeft : Place::BottomRight;
                return left ? Place::Left : Place::Right;
            }
        }
        // The menu bar: the pointer stops at the output's top edge; the strip is the output's top reserved area.
        if (options.menuBar && y < std::max(o.y + kEdge, output.menuBarBottom))
            return Place::Fill;
        return std::nullopt;
    }

    Place placeForAltPointer(double x, double y, const Rect& area) {
        const auto cell = [](double v, double start, double len) { return v < start + len / 3 ? 0 : (v < start + 2 * len / 3 ? 1 : 2); };
        const int  col  = cell(x, area.x, area.w);
        const int  row  = cell(y, area.y, area.h);
        const bool left = x < area.x + area.w / 2;
        if (row == 0)
            return col == 0 ? Place::TopLeft : (col == 2 ? Place::TopRight : Place::Fill);
        if (row == 2 && col != 1)
            return col == 0 ? Place::BottomLeft : Place::BottomRight;
        if (col == 1)
            return left ? Place::Left : Place::Right;
        return col == 0 ? Place::Left : Place::Right;
    }

    std::optional<Place> dragPlace(double x, double y, const Output& output, const Rect& area, const DragOptions& options, bool alt) {
        const Rect& o = output.box;
        if (o.w <= 0 || o.h <= 0 || x < o.x || x >= o.x + o.w || y < o.y || y >= o.y + o.h)
            return std::nullopt;
        if (alt && options.altDrag && area.w > 0 && area.h > 0)
            return placeForAltPointer(x, y, area);
        return placeForPointer(x, y, output, options);
    }

    bool CDwell::update(std::optional<Place> place, std::string_view output, uint64_t nowMs, bool immediate) {
        if (place != m_place || (place && output != m_output)) {
            m_place  = place;
            m_output = place ? std::string{output} : std::string{};
            m_since  = nowMs;
            m_shown  = false;
        }
        if (m_place && !m_shown && (immediate || nowMs - m_since >= kPreviewDelay))
            m_shown = true;
        return m_shown;
    }

    std::optional<uint64_t> CDwell::remaining(uint64_t nowMs) const {
        if (!m_place || m_shown)
            return std::nullopt;
        const uint64_t waited = nowMs - m_since;
        return waited >= kPreviewDelay ? 0 : kPreviewDelay - waited;
    }

    bool CDwell::shown() const {
        return m_shown; // never without a place: update() clears it whenever the place changes
    }

    void CDwell::reset() {
        m_place.reset();
        m_output.clear();
        m_since = 0;
        m_shown = false;
    }

    HoverChange CHoverDwell::update(std::optional<uint64_t> window, uint64_t nowMs) {
        HoverChange change;
        if (window != m_window) {
            if (m_entered)
                change.leave = m_window;
            m_window  = window;
            m_since   = nowMs;
            m_entered = false;
            m_held    = false;
        }
        if (m_window && !m_entered && !m_held && nowMs - m_since >= kHoverDelay) {
            m_entered    = true;
            change.enter = m_window;
        }
        return change;
    }

    HoverChange CHoverDwell::press() {
        HoverChange change;
        if (m_entered)
            change.leave = m_window;
        m_entered = false;
        m_held    = m_window.has_value();
        return change;
    }

    std::optional<uint64_t> CHoverDwell::remaining(uint64_t nowMs) const {
        if (!m_window || m_entered || m_held)
            return std::nullopt;
        const uint64_t waited = nowMs - m_since;
        return waited >= kHoverDelay ? 0 : kHoverDelay - waited;
    }

    std::optional<uint64_t> CHoverDwell::entered() const {
        return m_entered ? m_window : std::nullopt;
    }

    void CHoverDwell::reset() {
        m_window.reset();
        m_since   = 0;
        m_entered = false;
        m_held    = false;
    }

    HoverCoverEffect hoverCoverEffect(const HoverCover& cover) {
        if (cover.locked || std::ranges::any_of(cover.exclusiveNamespaces, [](const std::string& name) { return name != kShellPopupNamespace; }))
            return HoverCoverEffect::Away;
        return cover.layerUnderPointer ? HoverCoverEffect::Over : HoverCoverEffect::None;
    }

    // ---- geometry ----

    std::optional<Zone> zoneOf(Place place) {
        switch (place) {
            case Place::Left: return Zone{0, 0, 6, 12};
            case Place::Right: return Zone{6, 0, 6, 12};
            case Place::Top: return Zone{0, 0, 12, 6};
            case Place::Bottom: return Zone{0, 6, 12, 6};
            case Place::TopLeft: return Zone{0, 0, 6, 6};
            case Place::TopRight: return Zone{6, 0, 6, 6};
            case Place::BottomLeft: return Zone{0, 6, 6, 6};
            case Place::BottomRight: return Zone{6, 6, 6, 6};
            case Place::Fill: return Zone{0, 0, 12, 12};
            case Place::Center: return std::nullopt;
            case Place::LeftThird: return Zone{0, 0, 4, 12};
            case Place::MiddleThird: return Zone{4, 0, 4, 12};
            case Place::RightThird: return Zone{8, 0, 4, 12};
            case Place::LeftTwoThirds: return Zone{0, 0, 8, 12};
            case Place::RightTwoThirds: return Zone{4, 0, 8, 12};
        }
        return std::nullopt;
    }

    std::optional<size_t> outputUnder(const Rect& box, std::span<const Rect> outputs) {
        const double mx = box.x + box.w / 2, my = box.y + box.h / 2;
        for (size_t i = 0; i < outputs.size(); ++i) {
            const Rect& o = outputs[i];
            if (mx >= o.x && mx < o.x + o.w && my >= o.y && my < o.y + o.h)
                return i;
        }
        return std::nullopt;
    }

    bool movable(const WindowFacts& w) {
        return w.mapped && w.onDesktop && w.inSpace;
    }

    bool shouldFollow(const WindowFacts& w, std::optional<size_t> output, bool sameSpace) {
        return movable(w) && w.floating && output.has_value() && !sameSpace;
    }

    int gridStep(double scale) {
        if (!std::isfinite(scale) || scale <= 0)
            return 1;
        const long steps = std::lround(scale * 120.0);
        if (steps <= 0)
            return 1;
        const long step = 120 / std::gcd(steps, 120L);
        return step <= kMaxGridStep ? static_cast<int>(step) : 1;
    }

    namespace {
        constexpr double kSlack = 1e-6; // floating-point noise around a grid line

        double snapNearest(double v, double origin, int step) {
            return origin + step * std::round((v - origin) / step);
        }
        double snapUp(double v, double origin, int step) {
            return origin + step * std::ceil((v - origin) / step - kSlack);
        }
        double snapDown(double v, double origin, int step) {
            return origin + step * std::floor((v - origin) / step + kSlack);
        }

        int stepOf(const Area& area) {
            return std::max(1, area.grid.step);
        }

        // An edge of a zone along one axis: `k` twelfths into the inner span [inner0, inner0 + innerLen]; `start` for the
        // left or top edge of the zone. Outer edges go to the nearest grid line inside; inner ones lose half a margin each
        // side of the exact boundary and go to the nearest grid line.
        double zoneEdge(int k, bool start, double inner0, double innerLen, double margin, double origin, int step) {
            if (k <= 0)
                return snapUp(inner0, origin, step);
            if (k >= kZoneGrid)
                return snapDown(inner0 + innerLen, origin, step);
            const double boundary = inner0 + innerLen * k / kZoneGrid;
            return snapNearest(start ? boundary + margin / 2 : boundary - margin / 2, origin, step);
        }

        bool overlaps(int a0, int a1, int b0, int b1) {
            return a0 < b1 && b0 < a1;
        }

        double ceilTo(double v, int step) {
            return step * std::ceil(v / step - kSlack);
        }
        double floorTo(double v, int step) {
            return step * std::floor(v / step + kSlack);
        }

        // One axis of fitFrames. pos/len/zonePos/zoneLen/otherPos/otherLen pick x or y from the structures.
        struct Axis {
            double& (*pos)(Rect&);
            double& (*len)(Rect&);
            int (*zoneStart)(const Zone&);
            int (*zoneSize)(const Zone&);
            int (*crossStart)(const Zone&);
            int (*crossSize)(const Zone&);
            double (*minOf)(const Constraints&);
            double (*maxOf)(const Constraints&);
            double areaStart;
            double areaLen;
        };

        void fitAxis(const Axis& ax, std::span<const Zone> zones, std::vector<Rect>& frames, std::span<const Constraints> cons, int step) {
            const size_t n = frames.size();
            for (size_t i = 0; i < n; ++i) {
                const Zone& zi   = zones[i];
                double      need = ax.minOf(cons[i]) - ax.len(frames[i]);
                if (need <= 0.5)
                    continue;
                need = ceilTo(need, step);
                const int far  = ax.zoneStart(zi) + ax.zoneSize(zi);
                const int near = ax.zoneStart(zi);
                // Room on the far side: the zones that start at this zone's far edge and lie beside it.
                const auto take = [&](bool farSide) {
                    double room   = std::numeric_limits<double>::infinity();
                    bool   shared = false;
                    for (size_t j = 0; j < n; ++j) {
                        if (j == i)
                            continue;
                        const Zone& zj    = zones[j];
                        const bool  touch = farSide ? ax.zoneStart(zj) == far : ax.zoneStart(zj) + ax.zoneSize(zj) == near;
                        if (!touch ||
                            !overlaps(ax.crossStart(zi), ax.crossStart(zi) + ax.crossSize(zi), ax.crossStart(zj), ax.crossStart(zj) + ax.crossSize(zj)))
                            continue;
                        shared = true;
                        room   = std::min(room, std::max(0.0, floorTo(ax.len(frames[j]) - ax.minOf(cons[j]), step)));
                    }
                    // Beside an empty zone (fewer windows than zones) the window may grow into it.
                    const double d = shared ? std::min(need, room) : need;
                    if (d <= 0)
                        return;
                    if (farSide) {
                        ax.len(frames[i]) += d;
                    } else {
                        ax.pos(frames[i]) -= d;
                        ax.len(frames[i]) += d;
                    }
                    std::vector<size_t> gave; // the zones across the edge that made room
                    for (size_t j = 0; j < n && shared; ++j) {
                        if (j == i)
                            continue;
                        const Zone& zj    = zones[j];
                        const bool  touch = farSide ? ax.zoneStart(zj) == far : ax.zoneStart(zj) + ax.zoneSize(zj) == near;
                        if (!touch ||
                            !overlaps(ax.crossStart(zi), ax.crossStart(zi) + ax.crossSize(zi), ax.crossStart(zj), ax.crossStart(zj) + ax.crossSize(zj)))
                            continue;
                        if (farSide)
                            ax.pos(frames[j]) += d;
                        ax.len(frames[j]) -= d;
                        gave.push_back(j);
                    }
                    // The other zones on this side of the same edge follow it when every zone facing them across the
                    // edge made room (Left & Quarters: the right column's other quarter meets the narrower left half;
                    // no hole between them).
                    for (size_t k = 0; k < n && !gave.empty(); ++k) {
                        const Zone& zk     = zones[k];
                        const bool  beside = farSide ? ax.zoneStart(zk) + ax.zoneSize(zk) == far : ax.zoneStart(zk) == near;
                        if (k == i || !beside)
                            continue;
                        bool faced = false, allGave = true;
                        for (size_t j = 0; j < n; ++j) {
                            const Zone& zj    = zones[j];
                            const bool  touch = farSide ? ax.zoneStart(zj) == far : ax.zoneStart(zj) + ax.zoneSize(zj) == near;
                            if (j == i || j == k || !touch ||
                                !overlaps(ax.crossStart(zk), ax.crossStart(zk) + ax.crossSize(zk), ax.crossStart(zj), ax.crossStart(zj) + ax.crossSize(zj)))
                                continue;
                            faced = true;
                            allGave = allGave && std::ranges::find(gave, j) != gave.end();
                        }
                        if (!faced || !allGave)
                            continue;
                        if (!farSide)
                            ax.pos(frames[k]) -= d;
                        ax.len(frames[k]) += d;
                    }
                    need -= d;
                };
                if (far < kZoneGrid)
                    take(true);
                if (need > 0 && near > 0)
                    take(false);
                if (need > 0) {
                    // Alone: from its edge on the work area's border, or both ways; it overlaps its neighbours.
                    const bool atNear = near == 0;
                    const bool atFar  = far == kZoneGrid;
                    if (atFar && !atNear)
                        ax.pos(frames[i]) -= need;
                    else if (!(atNear && !atFar))
                        ax.pos(frames[i]) -= floorTo(need / 2, step);
                    ax.len(frames[i]) += need;
                }
                // Never beyond the work area unless the minimum is larger than it.
                if (ax.pos(frames[i]) + ax.len(frames[i]) > ax.areaStart + ax.areaLen)
                    ax.pos(frames[i]) = ax.areaStart + ax.areaLen - ax.len(frames[i]);
                if (ax.pos(frames[i]) < ax.areaStart)
                    ax.pos(frames[i]) = ax.areaStart;
            }
            // A frame larger than the window's maximum: the maximum, centred in its zone.
            for (size_t i = 0; i < n; ++i) {
                const double max = ax.maxOf(cons[i]);
                if (max <= 0 || ax.len(frames[i]) <= max)
                    continue;
                ax.pos(frames[i]) += floorTo((ax.len(frames[i]) - max) / 2, step); // centred, on the grid
                ax.len(frames[i]) = max;
            }
        }

        double& rx(Rect& r) {
            return r.x;
        }
        double& ry(Rect& r) {
            return r.y;
        }
        double& rw(Rect& r) {
            return r.w;
        }
        double& rh(Rect& r) {
            return r.h;
        }
        int zx(const Zone& z) {
            return z.x;
        }
        int zy(const Zone& z) {
            return z.y;
        }
        int zw(const Zone& z) {
            return z.w;
        }
        int zh(const Zone& z) {
            return z.h;
        }
        double minWidth(const Constraints& c) {
            return std::max(1.0, c.minW);
        }
        double minHeight(const Constraints& c) {
            return std::max(1.0, c.minH) + c.band;
        }
        double maxWidth(const Constraints& c) {
            return c.maxW > 0 ? std::max(c.maxW, minWidth(c)) : 0.0;
        }
        double maxHeight(const Constraints& c) {
            return c.maxH > 0 ? std::max(c.maxH + c.band, minHeight(c)) : 0.0;
        }

        // X11 resize increments: the surface size rounded down to base + k * inc, never below the minimum.
        double incremented(double size, double inc, double base, double min) {
            if (inc <= 0 || size <= base)
                return size;
            double out = base + std::floor((size - base) / inc) * inc;
            if (out < min)
                out = std::min(size, out + inc);
            return out;
        }
    } // namespace

    Rect zoneFrame(const Zone& zone, const Area& area) {
        const double m    = std::max(0.0, area.margin);
        const int    step = stepOf(area);
        const double ix = area.box.x + m, iy = area.box.y + m;
        const double iw = area.box.w - 2 * m, ih = area.box.h - 2 * m;
        const double left   = zoneEdge(zone.x, true, ix, iw, m, area.grid.originX, step);
        const double right  = zoneEdge(zone.x + zone.w, false, ix, iw, m, area.grid.originX, step);
        const double top    = zoneEdge(zone.y, true, iy, ih, m, area.grid.originY, step);
        const double bottom = zoneEdge(zone.y + zone.h, false, iy, ih, m, area.grid.originY, step);
        return Rect{left, top, std::max(1.0, right - left), std::max(1.0, bottom - top)};
    }

    std::vector<Rect> fitFrames(std::span<const Zone> zones, std::span<const Rect> frames, std::span<const Constraints> constraints, const Area& area) {
        std::vector<Rect> out(frames.begin(), frames.end());
        if (zones.size() != frames.size() || constraints.size() != frames.size())
            return out;
        const int  step = stepOf(area);
        const Axis x{rx, rw, zx, zw, zy, zh, minWidth, maxWidth, area.box.x, area.box.w};
        const Axis y{ry, rh, zy, zh, zx, zw, minHeight, maxHeight, area.box.y, area.box.h};
        fitAxis(x, zones, out, constraints, step);
        fitAxis(y, zones, out, constraints, step);
        for (size_t i = 0; i < out.size(); ++i) {
            const auto& c = constraints[i];
            out[i].w      = incremented(out[i].w, c.incW, c.baseW, minWidth(c));
            const double surfaceH = incremented(out[i].h - c.band, c.incH, c.baseH, std::max(1.0, c.minH));
            out[i].h              = surfaceH + c.band;
        }
        return out;
    }

    std::optional<Rect> halfBesideNeighbour(Place place, const Area& area, std::span<const Rect> neighbourFrames) {
        if (place != Place::Left && place != Place::Right && place != Place::Top && place != Place::Bottom)
            return std::nullopt;
        const double m    = std::max(0.0, area.margin);
        const int    step = stepOf(area);
        const double tol  = step + 0.5;
        const double ix = area.box.x + m, iy = area.box.y + m;
        const double ir = area.box.x + area.box.w - m, ib = area.box.y + area.box.h - m;
        const double iw = ir - ix, ih = ib - iy;
        const auto   near = [tol](double a, double b) { return std::abs(a - b) <= tol; };
        std::optional<double> edge;
        for (const auto& f : neighbourFrames) {
            const double fr = f.x + f.w, fb = f.y + f.h;
            switch (place) {
                case Place::Left:
                    if (near(fr, ir) && near(f.y, iy) && near(fb, ib) && f.x >= ix + iw / 4 && f.x < ir - 1)
                        edge = edge ? std::min(*edge, f.x) : f.x;
                    break;
                case Place::Right:
                    if (near(f.x, ix) && near(f.y, iy) && near(fb, ib) && fr <= ir - iw / 4 && fr > ix + 1)
                        edge = edge ? std::max(*edge, fr) : fr;
                    break;
                case Place::Top:
                    if (near(fb, ib) && near(f.x, ix) && near(fr, ir) && f.y >= iy + ih / 4 && f.y < ib - 1)
                        edge = edge ? std::min(*edge, f.y) : f.y;
                    break;
                case Place::Bottom:
                    if (near(f.y, iy) && near(f.x, ix) && near(fr, ir) && fb <= ib - ih / 4 && fb > iy + 1)
                        edge = edge ? std::max(*edge, fb) : fb;
                    break;
                default: break;
            }
        }
        if (!edge)
            return std::nullopt;
        const double ox = area.grid.originX, oy = area.grid.originY;
        double       left = snapUp(ix, ox, step), right = snapDown(ir, ox, step), top = snapUp(iy, oy, step), bottom = snapDown(ib, oy, step);
        switch (place) {
            case Place::Left: right = snapNearest(*edge - m, ox, step); break;
            case Place::Right: left = snapNearest(*edge + m, ox, step); break;
            case Place::Top: bottom = snapNearest(*edge - m, oy, step); break;
            case Place::Bottom: top = snapNearest(*edge + m, oy, step); break;
            default: break;
        }
        if (right - left < 1 || bottom - top < 1)
            return std::nullopt;
        return Rect{left, top, right - left, bottom - top};
    }

    Rect centerFrame(const Rect& currentSurface, double band, const Area& area) {
        const double w = std::round(std::max(1.0, std::min(currentSurface.w, area.box.w * kCenterMaxFraction)));
        const double h = std::round(std::max(1.0 + band, std::min(currentSurface.h + band, area.box.h * kCenterMaxFraction)));
        const int    step = stepOf(area);
        return Rect{snapNearest(area.box.x + (area.box.w - w) / 2, area.grid.originX, step), snapNearest(area.box.y + (area.box.h - h) / 2, area.grid.originY, step),
                    w, h};
    }

    uint8_t sidesAt(double x, double y, const Rect& surface) {
        uint8_t sides = 0;
        if (x < surface.x)
            sides |= kSideLeft;
        else if (x >= surface.x + surface.w)
            sides |= kSideRight;
        if (y < surface.y)
            sides |= kSideTop;
        else if (y >= surface.y + surface.h)
            sides |= kSideBottom;
        if (sides == 0)
            sides = (x < surface.x + surface.w / 2 ? kSideLeft : kSideRight) | (y < surface.y + surface.h / 2 ? kSideTop : kSideBottom);
        return sides;
    }

    uint8_t extendedSides(uint8_t sides, bool alt) {
        sides &= kAllSides;
        if (!alt)
            return sides;
        if (sides & (kSideLeft | kSideRight))
            sides |= kSideLeft | kSideRight;
        if (sides & (kSideTop | kSideBottom))
            sides |= kSideTop | kSideBottom;
        return sides;
    }

    namespace {
        // One axis of extendFrame: [start, start + len) with its low / high side moved to [full0, full0 + fullLen) when asked,
        // then fitted to [minLen, maxLen] (maxLen 0: none) and to the increments (sizes include `band`), the side that did not
        // move kept; both moved and capped by the maximum: centred, the offset on the grid.
        void extendAxis(double& start, double& len, bool low, bool high, double full0, double fullLen, const Constraints& c, bool vertical, int step) {
            if (!low && !high)
                return;
            const double end = high ? full0 + fullLen : start + len;
            if (low)
                start = full0;
            len                 = end - start;
            const double band   = vertical ? c.band : 0.0;
            const double minLen = vertical ? minHeight(c) : minWidth(c);
            const double maxLen = vertical ? maxHeight(c) : maxWidth(c);
            double       want   = std::max(len, minLen);
            const bool   capped = maxLen > 0 && want > maxLen;
            if (capped)
                want = maxLen;
            want = incremented(want - band, vertical ? c.incH : c.incW, vertical ? c.baseH : c.baseW, std::max(1.0, minLen - band)) + band;
            if (low && high) {
                if (capped)
                    start += floorTo((len - want) / 2, step);
            } else if (low) {
                start = end - want;
            }
            len = std::max(1.0, want);
        }
    } // namespace

    Rect extendFrame(const Rect& frame, uint8_t sides, const Constraints& constraints, const Area& area) {
        const Rect full = zoneFrame(Zone{}, area);
        const int  step = stepOf(area);
        Rect       r    = frame;
        extendAxis(r.x, r.w, (sides & kSideLeft) != 0, (sides & kSideRight) != 0, full.x, full.w, constraints, false, step);
        extendAxis(r.y, r.h, (sides & kSideTop) != 0, (sides & kSideBottom) != 0, full.y, full.h, constraints, true, step);
        return r;
    }

    std::string sidesName(uint8_t sides) {
        std::string out;
        for (const auto& [side, name] :
             {std::pair{kSideTop, "top"}, std::pair{kSideBottom, "bottom"}, std::pair{kSideLeft, "left"}, std::pair{kSideRight, "right"}}) {
            if ((sides & side) == 0)
                continue;
            if (!out.empty())
                out += '-';
            out += name;
        }
        return out;
    }

    Rect moveToArea(const Rect& frame, const Rect& from, const Rect& to) {
        const auto axis = [](double pos, double len, double fromStart, double fromLen, double toStart, double toLen) {
            const double size  = std::min(len, toLen);
            const double space = fromLen - len;
            const double share = space > 0 ? std::clamp((pos - fromStart) / space, 0.0, 1.0) : 0.5;
            return std::pair{std::round(toStart + (share * (toLen - size))), std::round(size)};
        };
        const auto [x, w] = axis(frame.x, frame.w, from.x, from.w, to.x, to.w);
        const auto [y, h] = axis(frame.y, frame.h, from.y, from.h, to.y, to.h);
        return Rect{x, y, std::max(1.0, w), std::max(1.0, h)};
    }

    Rect frameOf(const Rect& surface, double titlebar) {
        return Rect{surface.x, surface.y - titlebar, surface.w, surface.h + titlebar};
    }

    Rect surfaceOf(const Rect& frame, double titlebar) {
        return Rect{frame.x, frame.y + titlebar, std::max(1.0, frame.w), std::max(1.0, frame.h - titlebar)};
    }

    Rect surfaceFor(Place place, const Rect& area, double titlebar, bool margins, const Rect& current) {
        const Area a{area, margins ? kMargin : 0.0, Grid{area.x, area.y, 1}};
        if (const auto zone = zoneOf(place))
            return surfaceOf(zoneFrame(*zone, a), titlebar);
        return surfaceOf(centerFrame(current, titlebar, a), titlebar);
    }

    // ---- outputs and the catalogue ----

    OutputClass classify(double logicalWidth, double logicalHeight) {
        if (!(logicalWidth > 0) || !(logicalHeight > 0))
            return OutputClass::Small;
        if (logicalHeight > logicalWidth)
            return OutputClass::Portrait;
        if (logicalWidth / logicalHeight >= kUltraWideAspect - 1e-3)
            return OutputClass::UltraWide;
        if (logicalWidth >= kLargeWidth)
            return OutputClass::Large;
        return OutputClass::Small;
    }

    std::string_view nameOf(OutputClass outputClass) {
        switch (outputClass) {
            case OutputClass::Small: return "small";
            case OutputClass::Large: return "large";
            case OutputClass::UltraWide: return "ultrawide";
            case OutputClass::Portrait: return "portrait";
        }
        return "small";
    }

    namespace {
        template <size_t N>
        Layout layout(std::string_view id, const int (&zones)[N][4]) {
            Layout out{id, {}};
            for (const auto& z : zones)
                out.zones.push_back(Zone{z[0], z[1], z[2], z[3]});
            return out;
        }
    } // namespace

    std::span<const Layout> catalogue() {
        // The ids name the token arrays (tokens.json group tiling, generated into ThemeTokens.hpp); the classes refer to them.
        static const std::vector<Layout> all{
            layout("left-right", tokens::kTilingLayoutLeftRight),
            layout("right-left", tokens::kTilingLayoutRightLeft),
            layout("top-bottom", tokens::kTilingLayoutTopBottom),
            layout("bottom-top", tokens::kTilingLayoutBottomTop),
            layout("quarters", tokens::kTilingLayoutQuarters),
            layout("left-quarters", tokens::kTilingLayoutLeftQuarters),
            layout("right-quarters", tokens::kTilingLayoutRightQuarters),
            layout("top-quarters", tokens::kTilingLayoutTopQuarters),
            layout("bottom-quarters", tokens::kTilingLayoutBottomQuarters),
            layout("wide-left", tokens::kTilingLayoutWideLeft),
            layout("thirds", tokens::kTilingLayoutThirds),
            layout("wide-center", tokens::kTilingLayoutWideCenter),
            layout("four-columns", tokens::kTilingLayoutFourColumns),
            layout("stacked-thirds", tokens::kTilingLayoutStackedThirds),
        };
        return all;
    }

    const Layout* layoutById(std::string_view id) {
        for (const auto& l : catalogue()) {
            if (l.id == id)
                return &l;
        }
        return nullptr;
    }

    std::span<const std::string_view> layoutsFor(OutputClass outputClass) {
        switch (outputClass) {
            case OutputClass::Small: return tokens::kTilingClassSmall;
            case OutputClass::Large: return tokens::kTilingClassLarge;
            case OutputClass::UltraWide: return tokens::kTilingClassUltraWide;
            case OutputClass::Portrait: return tokens::kTilingClassPortrait;
        }
        return tokens::kTilingClassSmall;
    }

    // ---- the tile record ----

    std::string_view nameOf(TileState state) {
        switch (state) {
            case TileState::Tiled: return "tiled";
            case TileState::Moving: return "moving";
            case TileState::Resizing: return "resizing";
            case TileState::Suspended: return "suspended";
        }
        return "tiled";
    }

    namespace {
        // The window still has the box the record holds (1 px slack: rounding in the layout).
        bool sameBox(const Rect& a, const Rect& b) {
            return std::abs(a.x - b.x) <= 1.0 && std::abs(a.y - b.y) <= 1.0 && std::abs(a.w - b.w) <= 1.0 && std::abs(a.h - b.h) <= 1.0;
        }

        bool counts(TileState s) {
            return s == TileState::Tiled || s == TileState::Resizing || s == TileState::Suspended;
        }
    } // namespace

    TileRecord* CTileBook::get(uint64_t id) {
        for (auto& r : m_records) {
            if (r.id == id)
                return &r;
        }
        return nullptr;
    }

    const TileRecord* CTileBook::find(uint64_t id) const {
        for (const auto& r : m_records) {
            if (r.id == id)
                return &r;
        }
        return nullptr;
    }

    std::span<const TileRecord> CTileBook::records() const {
        return m_records;
    }

    uint64_t CTileBook::newGroup() {
        return m_nextGroup++;
    }

    uint64_t CTileBook::generation() const {
        return m_generation;
    }

    uint64_t CTileBook::joinGroup(uint64_t asker) {
        TileRecord* r = get(asker);
        if (!r)
            return 0;
        if (r->group == 0) {
            r->group = newGroup();
            changed();
        }
        return r->group;
    }

    void CTileBook::changed() {
        ++m_generation;
    }

    void CTileBook::leaveGroup(TileRecord& r) {
        const uint64_t old = r.group;
        r.group            = 0;
        dissolveIfSingle(old);
    }

    // A group of one dissolves (the last member's group goes back to none). Only a member leaving calls it: a group being
    // filled by an arrangement grows one placed() at a time.
    void CTileBook::dissolveIfSingle(uint64_t group) {
        if (group == 0)
            return;
        const auto members = std::ranges::count_if(m_records, [group](const TileRecord& o) { return o.group == group && counts(o.state); });
        if (members >= 2)
            return;
        for (auto& r : m_records) {
            if (r.group == group)
                r.group = 0;
        }
    }

    const TileRecord& CTileBook::placed(uint64_t id, const Rect& current, const Rect& box, double band, Placement where, std::string output, int64_t workspace,
                                        uint64_t group) {
        TileRecord* r = get(id);
        if (!r) {
            TileRecord fresh;
            fresh.id     = id;
            fresh.before = current;
            m_records.push_back(std::move(fresh));
            r = &m_records.back();
        }
        r->state     = TileState::Tiled;
        r->where     = std::move(where);
        r->box       = box;
        r->band      = band;
        r->output    = std::move(output);
        r->workspace = workspace;
        r->relayout  = false;
        r->deferred  = false;
        if (r->group != group) {
            leaveGroup(*r);
            r->group = group;
        }
        changed();
        return *get(id);
    }

    std::optional<Rect> CTileBook::beginMove(uint64_t id) {
        TileRecord* r = get(id);
        if (!r || r->state != TileState::Tiled)
            return std::nullopt;
        r->state = TileState::Moving;
        leaveGroup(*r);
        changed();
        return r->before;
    }

    void CTileBook::endMove(uint64_t id) {
        const TileRecord* r = find(id);
        if (r && r->state == TileState::Moving)
            forget(id);
    }

    bool CTileBook::beginResize(uint64_t id) {
        TileRecord* r = get(id);
        if (!r || r->state != TileState::Tiled)
            return false;
        r->state = TileState::Resizing;
        return true;
    }

    void CTileBook::endResize(uint64_t id, const Rect& box) {
        TileRecord* r = get(id);
        if (!r || r->state != TileState::Resizing)
            return;
        r->state = TileState::Tiled;
        r->box   = box;
        changed();
    }

    bool CTileBook::suspend(uint64_t id) {
        TileRecord* r = get(id);
        if (!r || (r->state != TileState::Tiled && r->state != TileState::Resizing))
            return false;
        r->state = TileState::Suspended;
        changed();
        return true;
    }

    const TileRecord* CTileBook::resume(uint64_t id) {
        TileRecord* r = get(id);
        if (!r || r->state != TileState::Suspended)
            return nullptr;
        r->state = TileState::Tiled;
        changed();
        return r;
    }

    bool CTileBook::check(uint64_t id, const Rect& current) {
        const TileRecord* r = find(id);
        if (!r)
            return false;
        if (r->state != TileState::Tiled || r->relayout)
            return true;
        if (sameBox(r->box, current))
            return true;
        forget(id);
        return false;
    }

    std::optional<Rect> CTileBook::takeBefore(uint64_t id) {
        const TileRecord* r = find(id);
        if (!r)
            return std::nullopt;
        const Rect before = r->before;
        forget(id);
        return before;
    }

    void CTileBook::forget(uint64_t id) {
        const TileRecord* r = find(id);
        if (!r)
            return;
        const uint64_t group = r->group;
        std::erase_if(m_records, [id](const TileRecord& o) { return o.id == id; });
        dissolveIfSingle(group);
        changed();
    }

    void CTileBook::clear() {
        if (m_records.empty())
            return;
        m_records.clear();
        changed();
    }

    void CTileBook::setBox(uint64_t id, const Rect& box, std::string output) {
        TileRecord* r = get(id);
        if (!r)
            return;
        r->box      = box;
        r->output   = std::move(output);
        r->relayout = false;
        r->deferred = false;
        changed();
    }

    void CTileBook::markRelayout(uint64_t id, bool on) {
        if (TileRecord* r = get(id))
            r->relayout = on;
    }

    void CTileBook::markDeferred(uint64_t id, bool on) {
        if (TileRecord* r = get(id))
            r->deferred = on;
    }

    void CTileBook::setWorkspace(uint64_t id, int64_t workspace) {
        TileRecord* r = get(id);
        if (!r || r->workspace == workspace)
            return;
        r->workspace = workspace;
        changed();
    }

    bool CTileBook::zoneFree(const Rect& frame, std::string_view output, int64_t workspace, uint64_t except, std::span<const uint64_t> ignore) const {
        for (const auto& r : m_records) {
            if (r.id == except || (r.state != TileState::Tiled && r.state != TileState::Resizing) || r.output != output || r.workspace != workspace)
                continue;
            if (std::ranges::find(ignore, r.id) != ignore.end())
                continue;
            const Rect   other = frameOf(r.box, r.band);
            const double ox    = std::min(frame.x + frame.w, other.x + other.w) - std::max(frame.x, other.x);
            const double oy    = std::min(frame.y + frame.h, other.y + other.h) - std::max(frame.y, other.y);
            if (ox > 1.0 && oy > 1.0)
                return false;
        }
        return true;
    }

    // ---- requests ----

    namespace {
        constexpr std::array<std::pair<Place, std::string_view>, 15> kNames{{
            {Place::Left, "left"},
            {Place::Right, "right"},
            {Place::Top, "top"},
            {Place::Bottom, "bottom"},
            {Place::TopLeft, "top-left"},
            {Place::TopRight, "top-right"},
            {Place::BottomLeft, "bottom-left"},
            {Place::BottomRight, "bottom-right"},
            {Place::Fill, "fill"},
            {Place::Center, "center"},
            {Place::LeftThird, "left-third"},
            {Place::MiddleThird, "middle-third"},
            {Place::RightThird, "right-third"},
            {Place::LeftTwoThirds, "left-two-thirds"},
            {Place::RightTwoThirds, "right-two-thirds"},
        }};
    }

    std::optional<Place> parsePlace(std::string_view name) {
        for (const auto& [place, text] : kNames) {
            if (text == name)
                return place;
        }
        return std::nullopt;
    }

    std::string_view nameOf(Place place) {
        for (const auto& [p, text] : kNames) {
            if (p == place)
                return text;
        }
        return "";
    }

    std::optional<bool> parseBool(std::string_view value) {
        if (value == "true")
            return true;
        if (value == "false")
            return false;
        return std::nullopt;
    }

    namespace {
        using Error = std::unexpected<std::string>;

        constexpr size_t kMaxStringBytes = 64;
        constexpr int    kMaxDepth       = 4;

    } // namespace

    bool outputNameOk(std::string_view name) {
        return !name.empty() && name.size() <= kMaxOutputName &&
            std::ranges::all_of(name, [](char c) { return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-'; });
    }

    std::expected<ArrangeRequest, std::string> parseArrange(std::string_view json) {
        if (json.size() > kMaxArrangeBytes)
            return Error{std::format("payload larger than {} bytes", kMaxArrangeBytes)};
        gf::json::CReader in{json, kMaxStringBytes, kMaxDepth};
        ArrangeRequest    request;
        bool              haveLayout = false, haveWindows = false, haveFill = false, haveZone = false, haveWith = false, haveOutput = false;
        const auto        once = [](bool& seen) {
            const bool first = !seen;
            seen             = true;
            return first;
        };
        if (!in.take('{'))
            return Error{"not a JSON object"};
        if (!in.take('}')) {
            do {
                const auto key = in.string();
                if (!key || !in.take(':'))
                    return Error{"malformed member"};
                if (*key == "layout") {
                    if (!once(haveLayout))
                        return Error{"layout given twice"};
                    const auto id = in.string();
                    if (!id || !layoutById(*id))
                        return Error{"layout is not an id of the catalogue"};
                    request.layout = *id;
                } else if (*key == "windows") {
                    if (!once(haveWindows))
                        return Error{"windows given twice"};
                    if (!in.take('['))
                        return Error{"windows is not an array"};
                    if (!in.take(']')) {
                        do {
                            const auto text    = in.string();
                            const auto address = text ? gf::minimize::parseAddress(*text) : std::nullopt;
                            if (!address || *address == 0)
                                return Error{"a window is not 1-16 hex digits (\"0x\" optional), not 0"};
                            if (std::ranges::find(request.windows, *address) != request.windows.end())
                                return Error{"a window is given twice"};
                            if (request.windows.size() >= kMaxZones)
                                return Error{std::format("more than {} windows", kMaxZones)};
                            request.windows.push_back(*address);
                        } while (in.take(','));
                        if (!in.take(']'))
                            return Error{"malformed windows array"};
                    }
                } else if (*key == "fill") {
                    if (!once(haveFill))
                        return Error{"fill given twice"};
                    const auto on = in.boolean();
                    if (!on)
                        return Error{"fill is not true or false"};
                    request.fill = *on;
                } else if (*key == "zone") {
                    if (!once(haveZone))
                        return Error{"zone given twice"};
                    const auto n = in.number();
                    if (!n || *n != std::floor(*n) || *n < 0 || *n >= static_cast<double>(kMaxZones))
                        return Error{std::format("zone is not an integer in 0..{}", kMaxZones - 1)};
                    request.zone = static_cast<int>(*n);
                } else if (*key == "with") {
                    if (!once(haveWith))
                        return Error{"with given twice"};
                    const auto text = in.string();
                    request.with    = text ? gf::minimize::parseAddress(*text) : std::nullopt; // never 0
                    if (!request.with)
                        return Error{"with is not 1-16 hex digits (\"0x\" optional), not 0"};
                } else if (*key == "output") {
                    if (!once(haveOutput))
                        return Error{"output given twice"};
                    const auto name = in.string();
                    if (!name || !outputNameOk(*name))
                        return Error{std::format("output is not 1-{} characters of [A-Za-z0-9._-]", kMaxOutputName)};
                    request.output = *name;
                } else if (!in.skipValue())
                    return Error{std::format("malformed value of {}", *key)};
            } while (in.take(','));
            if (!in.take('}'))
                return Error{"malformed object"};
        }
        if (!in.atEnd())
            return Error{"trailing characters after the object"};
        if (!haveLayout)
            return Error{"layout is required"};
        if (request.windows.empty())
            return Error{"windows needs at least one window"};
        const Layout* l = layoutById(request.layout);
        if (request.windows.size() > l->zones.size())
            return Error{std::format("layout {} has {} zones", request.layout, l->zones.size())};
        if (request.zone) {
            if (*request.zone >= static_cast<int>(l->zones.size()))
                return Error{std::format("layout {} has no zone {}", request.layout, *request.zone)};
            if (request.windows.size() != 1)
                return Error{"zone takes exactly one window"};
            if (haveFill && request.fill)
                return Error{"zone fills nothing (fill must be false or absent)"};
            request.fill = false;
        }
        if (request.with) {
            if (!request.zone)
                return Error{"with needs a zone"};
            if (*request.with == request.windows.front())
                return Error{"with names the window placed"};
        }
        return request;
    }

    // ---- tile groups ----

    std::vector<uint64_t> groupRaiseOrder(std::span<const TileRecord> records, uint64_t chosen, std::span<const uint64_t> stack) {
        std::vector<uint64_t> out;
        const auto            self = std::ranges::find_if(records, [chosen](const TileRecord& r) { return r.id == chosen; });
        if (self == records.end() || self->group == 0)
            return out;
        for (const auto id : stack) {
            if (id == chosen || std::ranges::find(out, id) != out.end())
                continue;
            const auto r = std::ranges::find_if(records, [id](const TileRecord& o) { return o.id == id; });
            if (r != records.end() && r->group == self->group && r->workspace == self->workspace &&
                (r->state == TileState::Tiled || r->state == TileState::Resizing))
                out.push_back(id);
        }
        // The chosen one last, over its group: the shell's activation can reach the compositor before this request.
        if (!out.empty() && (self->state == TileState::Tiled || self->state == TileState::Resizing) && std::ranges::find(stack, chosen) != stack.end())
            out.push_back(chosen);
        return out;
    }

    // ---- suggestions ----

    std::vector<int> zonesHeld(std::span<const TileRecord> records, const TileRecord& asker) {
        std::vector<int> held;
        const auto       inInstance = [&asker](const TileRecord& r) {
            if (r.id != asker.id && (asker.group == 0 || r.group != asker.group))
                return false;
            return counts(r.state) && r.where.layout == asker.where.layout && r.output == asker.output && r.workspace == asker.workspace;
        };
        for (const auto& r : records) { // a place or extended sides has no zone (-1)
            if (inInstance(r) && r.where.zone >= 0 && std::ranges::find(held, r.where.zone) == held.end())
                held.push_back(r.where.zone);
        }
        std::ranges::sort(held);
        return held;
    }

    std::vector<int> emptyZones(const Layout& layout, std::span<const int> held) {
        std::vector<int> out;
        for (int i = 0; i < static_cast<int>(layout.zones.size()); ++i) {
            if (std::ranges::find(held, i) == held.end())
                out.push_back(i);
        }
        return out;
    }

    // ---- the notice and the state ----

    std::string_view reasonName(Reason reason) {
        switch (reason) {
            case Reason::None: return "";
            case Reason::Placed: return "placed";
            case Reason::Moved: return "moved";
            case Reason::Resized: return "resized";
            case Reason::Suspended: return "suspended";
            case Reason::Restored: return "restored";
            case Reason::Forgotten: return "forgotten";
            case Reason::Relaid: return "relaid";
            case Reason::Invalid: return "invalid";
            case Reason::Locked: return "locked";
            case Reason::Unavailable: return "unavailable";
        }
        return "";
    }

    namespace {
        std::string num(double v) {
            const double r = std::round(v * 10.0) / 10.0;
            return std::format("{}", r == 0.0 ? 0.0 : r); // no "-0"
        }
    } // namespace

    std::string noticeJson(uint64_t generation, Reason reason) {
        std::string out{R"({"v":")"};
        out += gf::gfc::jsonEscape(gf::gfc::kVersion);
        out += std::format(R"(","type":"tiling","gen":{})", generation);
        if (reason != Reason::None) {
            out += R"(,"reason":")";
            out += reasonName(reason);
            out += '"';
        }
        out += '}';
        return out;
    }

    // gfc1-reply: grassfield-tiling
    // The state, the reply of `hyprctl grassfield-tiling` (tests/ci/gfc_parity.py checks it against the ADR's reply line).
    std::string stateJson(uint64_t generation, std::span<const StateOutput> outputs, const Suggestion* suggestion) {
        std::string out{R"({"v":")"};
        out += gf::gfc::jsonEscape(gf::gfc::kVersion);
        out += std::format(R"(","type":"tiling","gen":{},"outputs":[)", generation);
        bool firstOutput = true;
        for (const auto& o : outputs) {
            if (!firstOutput)
                out += ',';
            firstOutput = false;
            out += R"({"name":")";
            out += gf::gfc::jsonEscape(o.name);
            out += std::format(R"(","area":{{"x":{},"y":{},"w":{},"h":{}}},"class":"{}","grid":{},"windows":[)", num(o.area.x), num(o.area.y), num(o.area.w),
                               num(o.area.h), nameOf(o.outputClass), o.grid);
            bool firstWindow = true;
            for (const auto* r : o.windows) {
                if (!r)
                    continue;
                if (!firstWindow)
                    out += ',';
                firstWindow = false;
                out += std::format(R"({{"address":"{:x}","state":"{}","place":"{}","layout":")", r->id, nameOf(r->state), r->where.place ? nameOf(*r->where.place) : "");
                out += gf::gfc::jsonEscape(r->where.layout);
                out += std::format(R"(","zone":{},"sides":"{}","group":{},"x":{},"y":{},"w":{},"h":{}}})", r->where.zone, sidesName(r->where.sides), r->group,
                                   num(r->box.x), num(r->box.y), num(r->box.w), num(r->box.h));
            }
            out += "]}";
        }
        out += "]";
        if (!suggestion) {
            out += R"(,"suggestion":null})";
            return out;
        }
        out += std::format(R"(,"suggestion":{{"gen":{},"address":"{:x}","layout":")", suggestion->generation, suggestion->asker);
        out += gf::gfc::jsonEscape(suggestion->layout);
        out += R"(","output":")";
        out += gf::gfc::jsonEscape(suggestion->output);
        out += R"(","zones":[)";
        for (size_t i = 0; i < suggestion->zones.size() && i < suggestion->frames.size(); ++i) {
            const auto& f = suggestion->frames[i];
            out += std::format(R"({}{{"zone":{},"x":{},"y":{},"w":{},"h":{}}})", i == 0 ? "" : ",", suggestion->zones[i], num(f.x), num(f.y), num(f.w), num(f.h));
        }
        out += R"(],"windows":[)";
        for (size_t i = 0; i < suggestion->windows.size() && i < kMaxSuggested; ++i)
            out += std::format(R"({}"{:x}")", i == 0 ? "" : ",", suggestion->windows[i]);
        out += "]}}";
        return out;
    }

    std::string_view hoverStateName(HoverState state) {
        switch (state) {
            case HoverState::Enter: return "enter";
            case HoverState::Leave: return "leave";
            case HoverState::Open: return "open";
        }
        return "leave";
    }

    std::string tileHoverJson(uint64_t address, HoverState state, const Rect& light, bool tileable) {
        std::string out{R"({"v":")"};
        out += gf::gfc::jsonEscape(gf::gfc::kVersion);
        out += std::format(R"(","type":"tile-hover","address":"{:x}","state":"{}")", address, hoverStateName(state));
        if (state != HoverState::Leave)
            out += std::format(R"(,"x":{},"y":{},"w":{},"h":{},"tileable":{})", num(light.x), num(light.y), num(light.w), num(light.h), tileable);
        out += '}';
        return out;
    }

} // namespace gf::tiling
