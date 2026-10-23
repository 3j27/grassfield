#include "Stages.hpp"

#include "Json.hpp"
#include "Protocol.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <format>
#include <limits>
#include <utility>

namespace gf::stages {

    namespace {
        StageId allocate(StageId& nextId) {
            if (nextId == 0)
                nextId = 1; // 0 means "none"; wraps after 2^32 stages
            return nextId++;
        }

        bool holds(const Stage& stage, WindowId window) {
            return std::ranges::find(stage.windows, window) != stage.windows.end();
        }
    } // namespace

    // ---- model ----

    const std::string* CWorkspaceStages::appOf(WindowId window) const {
        const auto it = std::ranges::find_if(m_known, [window](const WindowInfo& w) { return w.id == window; });
        return it == m_known.end() ? nullptr : &it->app;
    }

    Stage* CWorkspaceStages::find(StageId stage) {
        const auto it = std::ranges::find_if(m_stages, [stage](const Stage& s) { return s.id == stage; });
        return it == m_stages.end() ? nullptr : &*it;
    }

    void CWorkspaceStages::pruneEmpty() {
        std::erase_if(m_stages, [](const Stage& s) { return s.windows.empty(); });
    }

    void CWorkspaceStages::reset(std::span<const WindowInfo> backToFront, std::optional<WindowId> focused, StageId& nextId) {
        m_stages.clear();
        m_known.clear();
        std::vector<size_t> frontIndex; // per stage: index in backToFront of its front-most window
        for (size_t i = 0; i < backToFront.size() && m_known.size() < kMaxWindowsPerWorkspace; ++i) {
            const auto& w = backToFront[i];
            if (contains(w.id))
                continue;
            m_known.push_back(w);
            const auto same = std::ranges::find_if(m_stages, [&](const Stage& s) {
                return std::ranges::any_of(s.windows, [&](WindowId id) {
                    const auto* app = appOf(id);
                    return app && *app == w.app;
                });
            });
            if (same == m_stages.end()) {
                m_stages.push_back(Stage{.id = allocate(nextId), .windows = {w.id}});
                frontIndex.push_back(i);
            } else {
                same->windows.push_back(w.id);
                frontIndex[static_cast<size_t>(same - m_stages.begin())] = i;
            }
        }
        // Most recent (front-most window highest in the stack) first.
        std::vector<size_t> order(m_stages.size());
        for (size_t i = 0; i < order.size(); ++i)
            order[i] = i;
        std::ranges::stable_sort(order, [&frontIndex](size_t a, size_t b) { return frontIndex[a] > frontIndex[b]; });
        std::vector<Stage> sorted;
        sorted.reserve(m_stages.size());
        for (const size_t i : order)
            sorted.push_back(std::move(m_stages[i]));
        m_stages = std::move(sorted);
        if (focused) {
            if (const auto stage = stageOf(*focused))
                activate(*stage);
        }
    }

    bool CWorkspaceStages::add(const WindowInfo& window, StageId& nextId) {
        if (contains(window.id) || m_known.size() >= kMaxWindowsPerWorkspace)
            return false;
        m_known.push_back(window);
        const auto same = std::ranges::find_if(m_stages, [&](const Stage& s) {
            return std::ranges::any_of(s.windows, [&](WindowId id) {
                const auto* app = id == window.id ? nullptr : appOf(id);
                return app && *app == window.app;
            });
        });
        if (same == m_stages.end()) {
            m_stages.insert(m_stages.begin(), Stage{.id = allocate(nextId), .windows = {window.id}});
            return true;
        }
        same->windows.push_back(window.id);
        std::rotate(m_stages.begin(), same, same + 1); // that stage comes forward
        return true;
    }

    bool CWorkspaceStages::remove(WindowId window) {
        if (!contains(window))
            return false;
        for (auto& s : m_stages)
            std::erase(s.windows, window);
        std::erase_if(m_known, [window](const WindowInfo& w) { return w.id == window; });
        pruneEmpty();
        return true;
    }

    bool CWorkspaceStages::activate(StageId stage) {
        const auto it = std::ranges::find_if(m_stages, [stage](const Stage& s) { return s.id == stage; });
        if (it == m_stages.end() || it == m_stages.begin())
            return false;
        std::rotate(m_stages.begin(), it, it + 1); // the previous active stage becomes the front of the strip
        return true;
    }

    bool CWorkspaceStages::moveWindow(WindowId window, std::optional<StageId> to, StageId& nextId) {
        const auto from = stageOf(window);
        if (!from)
            return false;
        Stage* src = find(*from);
        if (to) {
            Stage* dst = find(*to);
            if (!dst || *to == *from)
                return false;
            std::erase(src->windows, window);
            dst->windows.push_back(window);
            pruneEmpty();
            return true;
        }
        if (src->windows.size() == 1)
            return false; // already alone in a stage
        std::erase(src->windows, window);
        m_stages.insert(m_stages.begin() + 1, Stage{.id = allocate(nextId), .windows = {window}}); // src exists: size >= 1
        return true;
    }

    bool CWorkspaceStages::merge(StageId stage) {
        const auto it = std::ranges::find_if(m_stages, [stage](const Stage& s) { return s.id == stage; });
        if (it == m_stages.end() || it == m_stages.begin())
            return false;
        auto moved = std::move(it->windows);
        m_stages.erase(it);
        auto& active = m_stages.front().windows;
        active.insert(active.end(), moved.begin(), moved.end());
        return true;
    }

    bool CWorkspaceStages::raise(WindowId window) {
        for (auto& s : m_stages) {
            const auto it = std::ranges::find(s.windows, window);
            if (it == s.windows.end())
                continue;
            if (it + 1 == s.windows.end())
                return false;
            std::rotate(it, it + 1, s.windows.end());
            return true;
        }
        return false;
    }

    std::optional<StageId> CWorkspaceStages::stageOf(WindowId window) const {
        for (const auto& s : m_stages) {
            if (holds(s, window))
                return s.id;
        }
        return std::nullopt;
    }

    StageId CWorkspaceStages::active() const {
        return m_stages.empty() ? 0 : m_stages.front().id;
    }

    bool CWorkspaceStages::isActive(WindowId window) const {
        return !m_stages.empty() && holds(m_stages.front(), window);
    }

    const std::vector<Stage>& CWorkspaceStages::stages() const {
        return m_stages;
    }

    size_t CWorkspaceStages::windowCount() const {
        return m_known.size();
    }

    bool CWorkspaceStages::contains(WindowId window) const {
        return appOf(window) != nullptr;
    }

    // ---- requests ----

    namespace {
        using Error  = std::unexpected<std::string>;
        using Reader = gf::json::CReader;

        constexpr size_t kMaxStringBytes = 256;
        constexpr int    kMaxDepth       = 16;

        bool validMonitorName(std::string_view name) {
            if (name.empty() || name.size() > kMaxMonitorName)
                return false;
            return std::ranges::all_of(name, [](char c) { return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-'; });
        }

        // A member key, or an error. Duplicate keys are refused by the callers (`once`).
        bool once(bool& seen) {
            const bool first = !seen;
            seen             = true;
            return first;
        }

        std::expected<Box, std::string> parseTile(Reader& in, size_t strip, size_t index) {
            const auto where = std::format("strips[{}].tiles[{}]", strip, index);
            if (!in.take('{'))
                return Error{where + ": not an object"};
            static constexpr std::array<std::string_view, 4> NAMES = {"x", "y", "w", "h"};
            std::array<bool, 4>                              have{};
            std::array<double, 4>                            values{};
            if (!in.take('}')) {
                do {
                    const auto key = in.string();
                    if (!key || !in.take(':'))
                        return Error{where + ": malformed member"};
                    const auto it = std::ranges::find(NAMES, *key);
                    if (it == NAMES.end()) {
                        if (!in.skipValue())
                            return Error{std::format("{}: malformed value of {}", where, *key)};
                        continue;
                    }
                    const auto slot = static_cast<size_t>(it - NAMES.begin());
                    if (!once(have[slot]))
                        return Error{std::format("{}: {} given twice", where, *key)};
                    const auto value = in.number();
                    if (!value)
                        return Error{std::format("{}: {} is not a finite number", where, *key)};
                    values[slot] = *value;
                } while (in.take(','));
                if (!in.take('}'))
                    return Error{where + ": malformed object"};
            }
            if (!std::ranges::all_of(have, [](bool b) { return b; }))
                return Error{where + ": x, y, w and h are required"};
            const Box tile{values[0], values[1], values[2], values[3]};
            if (tile.w < kMinTileSide || tile.h < kMinTileSide || tile.w > kMaxTileSide || tile.h > kMaxTileSide)
                return Error{std::format("{}: w and h must be in {:.0f}..{:.0f}", where, kMinTileSide, kMaxTileSide)};
            return tile;
        }

        std::expected<Strip, std::string> parseStrip(Reader& in, size_t index) {
            const auto where = std::format("strips[{}]", index);
            if (!in.take('{'))
                return Error{where + ": not an object"};
            Strip strip;
            bool  haveMonitor = false, haveTiles = false, haveHidden = false;
            if (!in.take('}')) {
                do {
                    const auto key = in.string();
                    if (!key || !in.take(':'))
                        return Error{where + ": malformed member"};
                    if (*key == "monitor") {
                        if (!once(haveMonitor))
                            return Error{where + ": monitor given twice"};
                        const auto name = in.string();
                        if (!name || !validMonitorName(*name))
                            return Error{std::format("{}: monitor is not an output name ([A-Za-z0-9._-], 1..{} bytes)", where, kMaxMonitorName)};
                        strip.monitor = *name;
                    } else if (*key == "hidden") {
                        if (!once(haveHidden))
                            return Error{where + ": hidden given twice"};
                        const auto hidden = in.boolean();
                        if (!hidden)
                            return Error{where + ": hidden is not a boolean"};
                        strip.hidden = *hidden;
                    } else if (*key == "tiles") {
                        if (!once(haveTiles))
                            return Error{where + ": tiles given twice"};
                        if (!in.take('['))
                            return Error{where + ": tiles is not an array"};
                        if (!in.take(']')) {
                            do {
                                if (strip.tiles.size() >= kMaxTiles)
                                    return Error{std::format("{}: more than {} tiles", where, kMaxTiles)};
                                auto tile = parseTile(in, index, strip.tiles.size());
                                if (!tile)
                                    return Error{tile.error()};
                                strip.tiles.push_back(*tile);
                            } while (in.take(','));
                            if (!in.take(']'))
                                return Error{where + ": malformed tiles array"};
                        }
                    } else if (!in.skipValue())
                        return Error{std::format("{}: malformed value of {}", where, *key)};
                } while (in.take(','));
                if (!in.take('}'))
                    return Error{where + ": malformed object"};
            }
            if (!haveMonitor || !haveTiles || strip.tiles.empty())
                return Error{where + ": monitor and at least one tile are required"};
            for (size_t i = 0; i < strip.tiles.size(); ++i) {
                for (size_t j = i + 1; j < strip.tiles.size(); ++j) {
                    if (gf::minimize::intersects(strip.tiles[i], strip.tiles[j]))
                        return Error{std::format("{}: tiles {} and {} overlap", where, i, j)};
                }
            }
            return strip;
        }

        std::expected<Curve, std::string> parseCurve(Reader& in) {
            std::array<double, 4> v{};
            if (!in.take('['))
                return Error{"curve: not an array"};
            for (size_t i = 0; i < v.size(); ++i) {
                if (i > 0 && !in.take(','))
                    return Error{"curve: 4 numbers expected"};
                const auto n = in.number();
                if (!n)
                    return Error{"curve: 4 finite numbers expected"};
                v[i] = *n;
            }
            if (!in.take(']'))
                return Error{"curve: 4 numbers expected"};
            const auto xOk = [](double x) { return x >= 0.0 && x <= 1.0; };
            const auto yOk = [](double y) { return y >= gf::overview::kMinCurveY && y <= gf::overview::kMaxCurveY; };
            if (!xOk(v[0]) || !xOk(v[2]) || !yOk(v[1]) || !yOk(v[3]))
                return Error{"curve: control points out of range"};
            return Curve{v[0], v[1], v[2], v[3]};
        }

        std::optional<StageId> asStageId(double n) {
            if (n != std::floor(n) || n < 1 || n > static_cast<double>(std::numeric_limits<StageId>::max()))
                return std::nullopt;
            return static_cast<StageId>(n);
        }
    } // namespace

    std::expected<Request, std::string> parseRequest(std::string_view json) {
        if (json.size() > kMaxPayloadBytes)
            return Error{std::format("payload larger than {} bytes", kMaxPayloadBytes)};
        Reader  in{json, kMaxStringBytes, kMaxDepth};
        Request r;
        bool    haveOp = false, haveDuration = false, haveCurve = false, haveStrips = false, haveStage = false, haveAddress = false;
        std::string op;
        if (!in.take('{'))
            return Error{"not a JSON object"};
        if (!in.take('}')) {
            do {
                const auto key = in.string();
                if (!key || !in.take(':'))
                    return Error{"malformed member"};
                if (*key == "op") {
                    if (!once(haveOp))
                        return Error{"op given twice"};
                    const auto value = in.string();
                    if (!value)
                        return Error{"op is not a string"};
                    op = *value;
                } else if (*key == "durationMs") {
                    if (!once(haveDuration))
                        return Error{"durationMs given twice"};
                    const auto d = in.number();
                    if (!d || *d != std::floor(*d) || *d < 0 || *d > kMaxDurationMs)
                        return Error{std::format("durationMs is not an integer in 0..{:.0f}", kMaxDurationMs)};
                    r.durationMs = *d;
                } else if (*key == "curve") {
                    if (!once(haveCurve))
                        return Error{"curve given twice"};
                    auto curve = parseCurve(in);
                    if (!curve)
                        return Error{curve.error()};
                    r.curve = *curve;
                } else if (*key == "strips") {
                    if (!once(haveStrips))
                        return Error{"strips given twice"};
                    if (!in.take('['))
                        return Error{"strips is not an array"};
                    if (!in.take(']')) {
                        do {
                            if (r.strips.size() >= kMaxStrips)
                                return Error{std::format("strips: more than {}", kMaxStrips)};
                            auto strip = parseStrip(in, r.strips.size());
                            if (!strip)
                                return Error{strip.error()};
                            if (std::ranges::any_of(r.strips, [&](const Strip& s) { return s.monitor == strip->monitor; }))
                                return Error{std::format("strips[{}]: monitor {} listed twice", r.strips.size(), strip->monitor)};
                            r.strips.push_back(std::move(*strip));
                        } while (in.take(','));
                        if (!in.take(']'))
                            return Error{"strips: malformed array"};
                    }
                } else if (*key == "stage") {
                    if (!once(haveStage))
                        return Error{"stage given twice"};
                    if (in.peek() == '"') {
                        const auto text = in.string();
                        if (!text || *text != "new")
                            return Error{"stage is not a positive integer or \"new\""};
                        r.newStage = true;
                    } else {
                        const auto n  = in.number();
                        const auto id = n ? asStageId(*n) : std::nullopt;
                        if (!id)
                            return Error{"stage is not a positive integer or \"new\""};
                        r.stage = *id;
                    }
                } else if (*key == "address") {
                    if (!once(haveAddress))
                        return Error{"address given twice"};
                    const auto text    = in.string();
                    const auto address = text ? gf::minimize::parseAddress(*text) : std::nullopt;
                    if (!address)
                        return Error{"address is not \"0x\" + 1-16 hex digits"};
                    r.window = *address;
                } else if (!in.skipValue())
                    return Error{std::format("malformed value of {}", *key)};
            } while (in.take(','));
            if (!in.take('}'))
                return Error{"malformed object"};
        }
        if (!in.atEnd())
            return Error{"trailing characters after the object"};
        if (!haveOp)
            return Error{"op is required"};

        // Known keys that do not belong to the op are refused (no silent misuse).
        const auto only = [&](std::string_view name, bool allowDuration, bool allowCurve, bool allowStrips, bool allowStage, bool allowAddress) -> std::optional<std::string> {
            if ((haveDuration && !allowDuration) || (haveCurve && !allowCurve) || (haveStrips && !allowStrips) || (haveStage && !allowStage) || (haveAddress && !allowAddress))
                return std::format("a member given is not allowed with op {}", name);
            return std::nullopt;
        };
        if (op == "on") {
            r.op = Op::On;
            if (const auto e = only(op, true, true, true, false, false))
                return Error{*e};
            if (!haveDuration || !haveStrips || r.strips.empty())
                return Error{"op on needs durationMs and at least one strip"};
        } else if (op == "off") {
            r.op = Op::Off;
            if (const auto e = only(op, true, true, false, false, false))
                return Error{*e};
        } else if (op == "activate" || op == "merge") {
            r.op = op == "activate" ? Op::Activate : Op::Merge;
            if (const auto e = only(op, false, false, false, true, false))
                return Error{*e};
            if (!haveStage || r.newStage)
                return Error{std::format("op {} needs a stage id", op)};
        } else if (op == "move") {
            r.op = Op::Move;
            if (const auto e = only(op, false, false, false, true, true))
                return Error{*e};
            if (!haveStage || !haveAddress)
                return Error{"op move needs address and stage"};
        } else
            return Error{"op is not on, off, activate, move or merge"};
        return r;
    }

    // ---- geometry ----

    std::vector<Box> thumbRects(const Box& tile, std::span<const Box> surfacesBackToFront) {
        std::vector<Box> out;
        const size_t     n = surfacesBackToFront.size();
        if (n == 0)
            return out;
        const size_t positions = std::min(n, kStackDepth);
        double       step      = kStackStep;
        double       spread    = static_cast<double>(positions - 1) * step;
        if (tile.w - spread <= 1 || tile.h - spread <= 1) {
            step   = 0; // a tile too small to stack in: every window at the same place
            spread = 0;
        }
        const double slotW = tile.w - spread;
        const double slotH = tile.h - spread;
        out.reserve(n);
        for (size_t i = 0; i < n; ++i) {
            const size_t fromFront = n - 1 - i;
            const size_t pos       = std::min(fromFront, positions - 1); // 0 = front (bottom-right)
            const double offset    = static_cast<double>(positions - 1 - pos) * step;
            const Box    slot{tile.x + offset, tile.y + offset, slotW, slotH};
            const Box&   s = surfacesBackToFront[i];
            if (!gf::minimize::isFinite(s) || s.w <= 0 || s.h <= 0) {
                out.push_back(slot);
                continue;
            }
            const double scale = std::min({1.0, slot.w / s.w, slot.h / (s.h + kTitlebarHeight)});
            const double w     = s.w * scale;
            const double h     = s.h * scale;
            const double bar   = kTitlebarHeight * scale;
            out.push_back(Box{slot.x + ((slot.w - w) / 2), slot.y + ((slot.h - (h + bar)) / 2) + bar, w, h});
        }
        return out;
    }

    double hiddenShift(std::span<const Box> tiles, const Box& monitor) {
        if (tiles.empty())
            return 0;
        const Box band = stripBand(tiles, 0);
        return (monitor.x - kHiddenMargin) - (band.x + band.w);
    }

    bool tilesCovered(std::span<const Box> tiles, const Box& surface, const Box& monitor) {
        if (tiles.empty())
            return false;
        return std::ranges::all_of(tiles, [&](const Box& t) { return gf::overview::insideMonitor(t, surface) && gf::overview::insideMonitor(t, monitor); });
    }

    Box stripBand(std::span<const Box> tiles, double margin) {
        if (tiles.empty())
            return {};
        double x0 = tiles[0].x, y0 = tiles[0].y, x1 = tiles[0].x + tiles[0].w, y1 = tiles[0].y + tiles[0].h;
        for (const auto& t : tiles) {
            x0 = std::min(x0, t.x);
            y0 = std::min(y0, t.y);
            x1 = std::max(x1, t.x + t.w);
            y1 = std::max(y1, t.y + t.h);
        }
        return Box{x0 - margin, y0 - margin, (x1 - x0) + (2 * margin), (y1 - y0) + (2 * margin)};
    }

    std::vector<StripTarget> stripTargets(size_t slot, std::span<const Box> tiles, bool hidden, bool fullscreen, const Box& monitor,
                                          std::span<const Box> surfacesBackToFront) {
        std::vector<StripTarget> out;
        if (tiles.empty())
            return out;
        const bool   hasTile = slot < tiles.size();
        const auto   rects   = thumbRects(hasTile ? tiles[slot] : tiles.back(), surfacesBackToFront);
        const double shift   = (hidden || !hasTile || fullscreen) ? hiddenShift(tiles, monitor) : 0.0;
        out.reserve(rects.size());
        for (const auto& r : rects)
            out.push_back(StripTarget{.to = Box{r.x + shift, r.y, r.w, r.h}, .thumb = hasTile ? std::optional<Box>{r} : std::nullopt});
        return out;
    }

    bool stripAccepted(bool hidden, bool layerOk, bool boxCovers, bool inputCovers) {
        return layerOk && (hidden || (boxCovers && inputCovers));
    }

    bool inDropZone(double x, double y, std::span<const Box> tiles, const Box& monitor) {
        if (tiles.empty() || !std::isfinite(x) || !std::isfinite(y))
            return false;
        if (x < monitor.x || x >= monitor.x + monitor.w || y < monitor.y || y >= monitor.y + monitor.h)
            return false;
        double right = tiles[0].x + tiles[0].w;
        for (const auto& t : tiles)
            right = std::max(right, t.x + t.w);
        return x <= right + kStripDropMargin;
    }

    DropAction dropAction(const DropFacts& f) {
        const bool drop = f.on && f.hasStrip && f.inZone && f.managed && f.active && !f.alone && !f.tiling;
        return drop ? DropAction::NewStage : DropAction::None;
    }

    // ---- events ----

    std::string_view reasonName(Reason reason) {
        switch (reason) {
            case Reason::None: return "";
            case Reason::Invalid: return "invalid";
            case Reason::Disabled: return "disabled";
            case Reason::NoStrip: return "no-strip";
            case Reason::Unknown: return "unknown";
            case Reason::Unavailable: return "unavailable";
            case Reason::Interrupted: return "interrupted";
        }
        return "";
    }

    namespace {
        std::string num(double v) {
            const double r = std::round(v * 10.0) / 10.0;
            return std::format("{}", r == 0.0 ? 0.0 : r); // no "-0"
        }

        bool continuation(unsigned char c) {
            return (c & 0xC0U) == 0x80U;
        }

        // Length of the valid UTF-8 sequence at `at` (RFC 3629: no overlong forms, no surrogates, at most U+10FFFF), or 0.
        size_t utf8Length(std::string_view s, size_t at) {
            const auto byte = [&s](size_t i) { return static_cast<unsigned char>(s[i]); };
            const auto c0   = byte(at);
            const size_t left = s.size() - at;
            if (c0 < 0x80U)
                return 1;
            if (c0 >= 0xC2U && c0 <= 0xDFU)
                return left >= 2 && continuation(byte(at + 1)) ? 2 : 0;
            if (c0 >= 0xE0U && c0 <= 0xEFU) {
                if (left < 3 || !continuation(byte(at + 1)) || !continuation(byte(at + 2)))
                    return 0;
                const auto c1 = byte(at + 1);
                if ((c0 == 0xE0U && c1 < 0xA0U) || (c0 == 0xEDU && c1 > 0x9FU))
                    return 0;
                return 3;
            }
            if (c0 >= 0xF0U && c0 <= 0xF4U) {
                if (left < 4 || !continuation(byte(at + 1)) || !continuation(byte(at + 2)) || !continuation(byte(at + 3)))
                    return 0;
                const auto c1 = byte(at + 1);
                if ((c0 == 0xF0U && c1 < 0x90U) || (c0 == 0xF4U && c1 > 0x8FU))
                    return 0;
                return 4;
            }
            return 0;
        }
    } // namespace

    std::string sanitizedText(std::string_view in, size_t maxBytes) {
        static constexpr std::string_view REPLACEMENT = "\xEF\xBF\xBD"; // U+FFFD
        std::string                       out;
        out.reserve(std::min(in.size(), maxBytes));
        size_t at = 0;
        while (at < in.size()) {
            const size_t           n     = utf8Length(in, at);
            const std::string_view piece = n > 0 ? in.substr(at, n) : REPLACEMENT;
            if (out.size() + piece.size() > maxBytes)
                break;
            out += piece;
            at += n > 0 ? n : 1;
        }
        return out;
    }

    std::string eventJson(bool on, std::span<const EventMonitor> monitors, Reason reason) {
        std::string out{R"({"v":")"};
        out += gf::gfc::jsonEscape(gf::gfc::kVersion);
        out += R"(","type":"stages","on":)";
        out += on ? "true" : "false";
        if (reason != Reason::None) {
            out += R"(,"reason":")";
            out += reasonName(reason);
            out += '"';
        }
        out += R"(,"monitors":[)";
        bool firstMonitor = true;
        for (const auto& m : monitors) {
            if (!firstMonitor)
                out += ',';
            firstMonitor = false;
            out += R"({"monitor":")";
            out += gf::gfc::jsonEscape(m.monitor);
            out += std::format(R"(","workspace":{},"active":{},"hidden":{},"overlap":{},)", m.workspace, m.active, m.hidden ? "true" : "false", m.overlap ? "true" : "false");
            if (m.front) {
                out += std::format(R"("front":{{"address":"{:x}","app":")", m.front->id);
                out += gf::gfc::jsonEscape(sanitizedText(m.front->app, kMaxAppBytes));
                out += R"("},)";
            }
            out += R"("stages":[)";
            bool firstStage = true;
            for (const auto& s : m.stages) {
                if (!firstStage)
                    out += ',';
                firstStage = false;
                out += std::format(R"({{"id":{},"slot":{},"windows":[)", s.id, s.slot);
                bool firstWindow = true;
                for (const auto& w : s.windows) {
                    if (!firstWindow)
                        out += ',';
                    firstWindow = false;
                    out += std::format(R"({{"address":"{:x}")", w.id);
                    if (w.thumb)
                        out += std::format(R"(,"x":{},"y":{},"w":{},"h":{})", num(w.thumb->x), num(w.thumb->y), num(w.thumb->w), num(w.thumb->h));
                    out += '}';
                }
                out += "]}";
            }
            out += "]}";
        }
        out += "]}";
        return out;
    }

    // ---- input on strip windows ----

    bool stripFocusBringsStage(FocusOrigin origin) {
        return origin == FocusOrigin::UserChoice;
    }

    KeyboardTarget keyboardAfterLeave(const KeyboardHolder& holder, bool hasFront) {
        if (holder.present && holder.eligible)
            return KeyboardTarget::Keep;
        if (hasFront)
            return KeyboardTarget::FrontOfActive;
        return KeyboardTarget::Nothing;
    }

    ActiveWindowAction activeWindowAction(const ActiveWindowState& state) {
        if (!state.hidden || state.locked)
            return ActiveWindowAction::None;
        if (state.hasFront && !state.exclusive)
            return ActiveWindowAction::FocusFront;
        if (state.layerKeyboard || state.exclusive)
            return ActiveWindowAction::Clear;
        return ActiveWindowAction::Unfocus;
    }

    PendingFocusAction pendingFocusAction(const PendingFocusState& state) {
        if (!state.remembered && !state.hasFront)
            return PendingFocusAction::Drop;
        if (gf::deferredfocus::mustWait({.locked = state.locked, .exclusive = state.exclusive, .holderKeeps = state.holderKeeps}))
            return PendingFocusAction::Wait;
        if (state.focused || !state.shown)
            return PendingFocusAction::Drop;
        return state.remembered ? PendingFocusAction::Focus : PendingFocusAction::FocusFront;
    }

    PointerAction beforePointerEvent(PointerEvent event, const PointerState& state) {
        switch (event) {
            case PointerEvent::Press: return state.onBlocked || (state.parked && !state.hasFocus) ? PointerAction::Refresh : PointerAction::None;
            case PointerEvent::Release: return state.onBlocked ? PointerAction::Park : PointerAction::None;
            case PointerEvent::Axis: return state.onBlocked ? PointerAction::Refresh : PointerAction::None;
        }
        return PointerAction::None;
    }

    std::optional<bool> parseStagesEnabled(std::string_view key, std::string_view value) {
        if (key != kConfigStagesEnabled)
            return std::nullopt;
        if (value == "true")
            return true;
        if (value == "false")
            return false;
        return std::nullopt;
    }

} // namespace gf::stages
