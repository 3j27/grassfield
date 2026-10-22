#include "Tiling.hpp"

#include "Plugin.hpp"
#include "core/Minimize.hpp"
#include "core/Theme.hpp"

#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/layout/LayoutManager.hpp>
#include <hyprland/src/layout/target/Target.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/state/MonitorState.hpp>

#include <algorithm>
#include <cmath>
#include <vector>

namespace gf::tiler {

    namespace {
        struct STiled {
            PHLWINDOWREF window;
            CBox         before; // the floating surface box from before the first tiling
        };

        std::vector<STiled>& tiled() {
            static std::vector<STiled> list;
            return list;
        }

        void prune() {
            std::erase_if(tiled(), [](const STiled& t) { return !t.window.lock(); });
        }

        STiled* entryFor(const PHLWINDOW& w) {
            prune();
            for (auto& t : tiled()) {
                if (t.window.lock() == w)
                    return &t;
            }
            return nullptr;
        }

        tiling::Rect toRect(const CBox& b) {
            return tiling::Rect{b.x, b.y, b.w, b.h};
        }

        CBox toCBox(const tiling::Rect& r) {
            return CBox{r.x, r.y, r.w, r.h};
        }

        const std::vector<PHLMONITOR>* monitors() {
            const auto& state = State::monitorState();
            return state ? &state->monitors() : nullptr;
        }

        PHLMONITOR monitorAt(const Vector2D& p) {
            const auto* all = monitors();
            if (!all)
                return nullptr;
            for (const auto& m : *all) {
                if (m && m->logicalBox().containsPoint(p))
                    return m;
            }
            return nullptr;
        }

        // An edge of `m` is free when no other monitor touches it along an overlapping span: a shared edge leads to the
        // next output (dragging there moves the window over), it never tiles.
        bool edgeFree(const PHLMONITOR& m, bool left) {
            const CBox  box = m->logicalBox();
            const auto* all = monitors();
            if (!all)
                return true;
            for (const auto& o : *all) {
                if (!o || o == m)
                    continue;
                const CBox other = o->logicalBox();
                const bool overlaps = other.y < box.y + box.h && other.y + other.h > box.y;
                const double edge = left ? box.x : box.x + box.w;
                const double touch = left ? other.x + other.w : other.x;
                if (overlaps && std::abs(edge - touch) < 1.0)
                    return false;
            }
            return true;
        }

        bool placeable(const PHLWINDOW& w) {
            if (!w || !w->m_isFloating || w->m_pinned || !w->layoutTarget())
                return false;
            const auto& fs = Fullscreen::controller();
            return !fs || fs->getFullscreenModes(w).internal == Fullscreen::FSMODE_NONE;
        }
    } // namespace

    std::optional<Snap> snapFor(const PHLWINDOW& w, const Vector2D& pointer) {
        const auto& options = state().tilingDrag;
        if (!placeable(w) || (!options.edges && !options.menuBar))
            return std::nullopt;
        const auto m = monitorAt(pointer);
        if (!m)
            return std::nullopt;
        const CBox box = m->logicalBox();
        const tiling::Output output{toRect(box), box.y + m->m_reservedArea.top(), edgeFree(m, true), edgeFree(m, false)};
        const auto place = tiling::placeForPointer(pointer.x, pointer.y, output, options);
        if (!place)
            return std::nullopt;
        const auto current = w->layoutTarget()->position();
        const auto surface = tiling::surfaceFor(*place, toRect(m->logicalBoxMinusReserved()), theme::kTitlebarHeight, state().tilingMargins, toRect(current));
        return Snap{*place, toCBox(tiling::frameOf(surface, theme::kTitlebarHeight)), m};
    }

    bool tile(const PHLWINDOW& w, tiling::Place place, const PHLMONITOR& monitor) {
        if (!placeable(w) || !g_layoutManager)
            return false;
        const auto m = monitor ? monitor : w->m_monitor.lock();
        if (!m)
            return false;
        const auto target  = w->layoutTarget();
        const CBox current = target->position();
        const auto surface = tiling::surfaceFor(place, toRect(m->logicalBoxMinusReserved()), theme::kTitlebarHeight, state().tilingMargins, toRect(current));
        if (!entryFor(w))
            tiled().push_back(STiled{w, current});
        g_layoutManager->setTargetGeom(toCBox(surface), target);
        logRequest(Log::DEBUG, "tile {:x}: {} on {}", reinterpret_cast<uintptr_t>(w.get()), tiling::nameOf(place), m->m_name);
        return true;
    }

    bool isTiled(const PHLWINDOW& w) {
        return entryFor(w) != nullptr;
    }

    std::optional<CBox> takePrevious(const PHLWINDOW& w) {
        auto* entry = entryFor(w);
        if (!entry)
            return std::nullopt;
        const CBox before = entry->before;
        std::erase_if(tiled(), [&w](const STiled& t) { return t.window.lock() == w; });
        return before;
    }

    void tileRequest(std::string_view addressText, std::string_view placeName) {
        const auto address = minimize::parseAddress(addressText);
        PHLWINDOW  window;
        if (address && Desktop::windowState()) {
            for (const auto& w : Desktop::windowState()->windows()) {
                if (w && reinterpret_cast<uintptr_t>(w.get()) == *address)
                    window = w;
            }
        }
        if (!window) {
            logRequest(Log::WARN, "tile: rejected: no such window");
            return;
        }
        if (placeName == "previous") {
            const auto before = placeable(window) && g_layoutManager ? takePrevious(window) : std::nullopt;
            if (!before) {
                logRequest(Log::INFO, "tile {:x}: not tiled, nothing to return to", *address);
                return;
            }
            g_layoutManager->setTargetGeom(*before, window->layoutTarget());
            return;
        }
        const auto place = tiling::parsePlace(placeName);
        if (!place) {
            logRequest(Log::WARN, "tile: rejected: unknown place");
            return;
        }
        if (!tile(window, *place))
            logRequest(Log::INFO, "tile {:x}: not placeable (full screen, pinned or not floating)", *address);
    }

    void forgetAll() {
        tiled().clear();
    }

} // namespace gf::tiler
