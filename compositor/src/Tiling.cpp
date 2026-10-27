#include "Tiling.hpp"

#include "ClientChrome.hpp"
#include "DeferredFocus.hpp"
#include "Ipc.hpp"
#include "Plugin.hpp"
#include "Stages.hpp"
#include "core/Minimize.hpp"

#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/layout/LayoutManager.hpp>
#include <hyprland/src/layout/supplementary/DragController.hpp>
#include <hyprland/src/layout/target/Target.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/protocols/XDGShell.hpp>
#include <hyprland/src/state/MonitorState.hpp>
#include <hyprland/src/xwayland/XSurface.hpp>
#include <hyprland/src/xwayland/XWayland.hpp>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <utility>
#include <vector>

namespace gf::tiler {

    namespace {
        // A Suspended window coming back (TL10): after a Desktop move from a special workspace (minimize, hide, Show
        // Desktop) its zone must be free; after full screen or zoom its box is put back.
        struct SResume {
            uint64_t id        = 0;
            bool     checkFree = false;
        };

        struct SState {
            bool                             ready = false;
            tiling::CTileBook                book;
            uint64_t                         posted = 0; // generation of the latest notice
            PHLWINDOWREF                     resizing;   // a tiled window one of Hyprland's resizes holds
            bool                             relayoutPending = false;
            std::vector<SResume>             resuming;
            gf::deferredFocus::CLater        later; // after Hyprland's own handling (its callback is code of this library)
            std::vector<CHyprSignalListener> listeners;
        };

        // Constructed on first use inside a guarded call (R13).
        SState& st() {
            static SState s;
            return s;
        }

        // The quick look panel (docs/specs/preview.md) is never tiled (TL9).
        constexpr std::string_view kGlanceClass = "org.grassfield.Preview.Glance";

        tiling::Rect toRect(const CBox& b) {
            return tiling::Rect{b.x, b.y, b.w, b.h};
        }

        CBox toCBox(const tiling::Rect& r) {
            return CBox{r.x, r.y, r.w, r.h};
        }

        uint64_t idOf(const PHLWINDOW& w) {
            return reinterpret_cast<uintptr_t>(w.get());
        }

        PHLWINDOW windowById(uint64_t id) {
            if (!Desktop::windowState())
                return nullptr;
            for (const auto& w : Desktop::windowState()->windows()) {
                if (w && idOf(w) == id)
                    return w;
            }
            return nullptr;
        }

        // Enabled outputs only: Hyprland keeps a disconnected monitor (m_enabled false) in its list for a while.
        std::vector<PHLMONITOR> monitors() {
            std::vector<PHLMONITOR> out;
            const auto&             state = State::monitorState();
            if (!state)
                return out;
            for (const auto& m : state->monitors()) {
                if (m && m->m_enabled)
                    out.push_back(m);
            }
            return out;
        }

        PHLMONITOR monitorAt(const Vector2D& p) {
            for (const auto& m : monitors()) {
                if (m->logicalBox().containsPoint(p))
                    return m;
            }
            return nullptr;
        }

        PHLMONITOR monitorByName(std::string_view name) {
            for (const auto& m : monitors()) {
                if (m->m_name == name)
                    return m;
            }
            return nullptr;
        }

        // The output a window is on now: the one under its middle. Hyprland's m_monitor is not updated by the plugin's own
        // titlebar drags, so a window dragged to another output would tile back on the old one (R13).
        PHLMONITOR monitorOf(const PHLWINDOW& w) {
            const auto target = w ? w->layoutTarget() : nullptr;
            if (!target)
                return nullptr;
            if (auto m = monitorAt(target->position().middle()))
                return m;
            const auto m = w->m_monitor.lock();
            return m && m->m_enabled ? m : nullptr;
        }

        // An edge of `m` is free when no other monitor touches it along an overlapping span: a shared edge leads to the
        // next output (dragging there moves the window over), it never tiles.
        bool edgeFree(const PHLMONITOR& m, bool left) {
            const CBox box = m->logicalBox();
            for (const auto& o : monitors()) {
                if (o == m)
                    continue;
                const CBox   other    = o->logicalBox();
                const bool   overlaps = other.y < box.y + box.h && other.y + other.h > box.y;
                const double edge     = left ? box.x : box.x + box.w;
                const double touch    = left ? other.x + other.w : other.x;
                if (overlaps && std::abs(edge - touch) < 1.0)
                    return false;
            }
            return true;
        }

        bool sameBox(const CBox& a, const CBox& b) {
            return std::abs(a.x - b.x) <= 1.0 && std::abs(a.y - b.y) <= 1.0 && std::abs(a.w - b.w) <= 1.0 && std::abs(a.h - b.h) <= 1.0;
        }

        bool fullscreenNow(const PHLWINDOW& w) {
            const auto& fs = Fullscreen::controller();
            return fs && fs->getFullscreenModes(w).internal != Fullscreen::FSMODE_NONE; // zoom is FSMODE_MAXIMIZED
        }

        // TL9: an X11 window Hyprland floats by type or role: CHyprXWaylandManager::shouldBeFloated's X11 branch
        // (XWaylandManager.cpp:110-131), read here without its side effects (that function also sets focus flags).
        bool x11FloatedByHyprland(const PHLWINDOW& w) {
            if (!w->m_isX11)
                return false;
            if (w->isX11OverrideRedirect() || w->isModal())
                return true;
            const auto xs = w->m_xwaylandSurface.lock();
            if (!xs)
                return true; // nothing to read: never tiled
            if (xs->m_transient || static_cast<bool>(xs->m_parent) || xs->m_role.contains("task_dialog") || xs->m_role.contains("pop-up"))
                return true;
            static constexpr std::array<std::string_view, 10> kTypes{
                "_NET_WM_WINDOW_TYPE_DIALOG",  "_NET_WM_WINDOW_TYPE_SPLASH",        "_NET_WM_WINDOW_TYPE_TOOLBAR", "_NET_WM_WINDOW_TYPE_UTILITY",
                "_NET_WM_WINDOW_TYPE_TOOLTIP", "_NET_WM_WINDOW_TYPE_POPUP_MENU",    "_NET_WM_WINDOW_TYPE_DOCK",    "_NET_WM_WINDOW_TYPE_DROPDOWN_MENU",
                "_NET_WM_WINDOW_TYPE_MENU",    "_KDE_NET_WM_WINDOW_TYPE_OVERRIDE"};
            for (const auto name : kTypes) {
                const auto it = HYPRATOMS.find(std::string{name}); // find, never operator[]: Hyprland's table is only read
                if (it != HYPRATOMS.end() && it->second != 0 && std::ranges::find(xs->m_atoms, it->second) != xs->m_atoms.end())
                    return true;
            }
            return false;
        }

        // ICCCM WM_NORMAL_HINTS flags (4.1.2.3).
        constexpr uint32_t kHintMinSize   = 1U << 4;
        constexpr uint32_t kHintResizeInc = 1U << 6;
        constexpr uint32_t kHintBaseSize  = 1U << 8;
        // Hyprland's "no maximum" (CWindow::maxSize: numeric_limits<double>::max() per axis).
        constexpr double kNoMaximum = 1e7;

        // TL8: the window's limits. Minimum: CWindow::minSize() (a min_size rule, else the client's) and, for an xdg window,
        // at least the protocol minimum Hyprland's commit clamp applies (Window.cpp:2741-2747). Maximum: likewise the
        // smaller of the rule and the protocol maximum. X11 increments from WM_NORMAL_HINTS.
        tiling::Constraints constraintsOf(const PHLWINDOW& w) {
            tiling::Constraints c;
            c.band       = gf::chrome::bandOf(w); // none above a window that draws its own chrome (ADR-0015)
            Vector2D min = w->minSize().value_or(Vector2D{1, 1});
            Vector2D max = w->maxSize().value_or(Vector2D{0, 0});
            if (!w->m_isX11) {
                const auto xdg = w->m_xdgSurface.lock();
                const auto top = xdg ? xdg->m_toplevel.lock() : nullptr;
                if (top) {
                    const auto pmin = top->layoutMinSize();
                    const auto pmax = top->layoutMaxSize();
                    min.x           = std::max(min.x, pmin.x);
                    min.y           = std::max(min.y, pmin.y);
                    if (pmax.x > 1)
                        max.x = max.x > 0 && max.x < kNoMaximum ? std::min(max.x, pmax.x) : pmax.x;
                    if (pmax.y > 1)
                        max.y = max.y > 0 && max.y < kNoMaximum ? std::min(max.y, pmax.y) : pmax.y;
                }
            }
            c.minW = std::max(1.0, min.x);
            c.minH = std::max(1.0, min.y);
            c.maxW = max.x > 0 && max.x < kNoMaximum ? max.x : 0;
            c.maxH = max.y > 0 && max.y < kNoMaximum ? max.y : 0;
            if (w->m_isX11) {
                const auto xs = w->m_xwaylandSurface.lock();
                if (xs && xs->m_sizeHints) {
                    const auto& hints = *xs->m_sizeHints;
                    if (hints.flags & kHintResizeInc) {
                        c.incW = std::max(0, hints.width_inc);
                        c.incH = std::max(0, hints.height_inc);
                    }
                    if (hints.flags & kHintBaseSize) {
                        c.baseW = std::max(0, hints.base_width);
                        c.baseH = std::max(0, hints.base_height);
                    } else if (hints.flags & kHintMinSize) {
                        c.baseW = std::max(0, hints.min_width);
                        c.baseH = std::max(0, hints.min_height);
                    }
                }
            }
            return c;
        }

        // TL9 (no drag preview, refused by tile and arrange).
        bool placeable(const PHLWINDOW& w) {
            if (!w || !w->m_isMapped || w->isHidden() || !w->m_isFloating || w->m_pinned || !w->layoutTarget())
                return false;
            if (!w->m_workspace || w->m_workspace->m_isSpecialWorkspace || fullscreenNow(w))
                return false; // minimized and hidden windows live on special workspaces
            if (w->parent() || x11FloatedByHyprland(w) || w->m_class == kGlanceClass || gf::stager::inStripStage(w))
                return false;
            const auto c = constraintsOf(w);
            return !((c.maxW > 0 && c.minW >= c.maxW) || (c.maxH > 0 && c.minH >= c.maxH)); // fixed size on an axis
        }

        // TL1, TL2, TL3: the output minus its reserved area now, minus the Stages strip column; the margin; the grid.
        tiling::Area areaFor(const PHLMONITOR& m) {
            CBox box = m->logicalBoxMinusReserved();
            if (const auto right = gf::stager::stripColumnRight(m); right && *right > box.x) {
                const double cut = std::min(*right, box.x + box.w) - box.x;
                box.x += cut;
                box.w -= cut;
            }
            const CBox output = m->logicalBox();
            return tiling::Area{.box    = toRect(box),
                                .margin = state().tilingMargins ? tiling::kMargin : 0.0,
                                .grid   = tiling::Grid{.originX = output.x, .originY = output.y, .step = tiling::gridStep(m->m_scale)}};
        }

        // Windows of inactive stages (drawn in the strip at their real places): never neighbours, never holding a zone.
        std::vector<uint64_t> stripWindows() {
            std::vector<uint64_t> out;
            for (const auto& r : st().book.records()) {
                if (const auto w = windowById(r.id); w && gf::stager::inStripStage(w))
                    out.push_back(r.id);
            }
            return out;
        }

        bool isHalf(tiling::Place place) {
            return place == tiling::Place::Left || place == tiling::Place::Right || place == tiling::Place::Top || place == tiling::Place::Bottom;
        }

        // The frames of `zones` (zone order) filled by `windows` (same order) in `area`, fitted to each window's limits.
        std::vector<tiling::Rect> fitted(const std::vector<tiling::Zone>& zones, const std::vector<PHLWINDOW>& windows, const tiling::Area& area) {
            std::vector<tiling::Rect>        frames;
            std::vector<tiling::Constraints> limits;
            for (size_t i = 0; i < zones.size(); ++i) {
                frames.push_back(tiling::zoneFrame(zones[i], area));
                limits.push_back(constraintsOf(windows[i]));
            }
            return tiling::fitFrames(zones, frames, limits, area);
        }

        // The frame of a single place for `w` (TL4, TL7, TL8): Center keeps its size; a half next to a tiled neighbour on
        // the same output and Desktop takes the rest of the work area beside it.
        tiling::Rect placeFrame(const PHLWINDOW& w, tiling::Place place, const tiling::Area& area, std::string_view output, int64_t workspace) {
            const auto band = gf::chrome::bandOf(w);
            if (place == tiling::Place::Center)
                return tiling::centerFrame(toRect(w->layoutTarget()->position()), band, area);
            const tiling::Zone zone  = tiling::zoneOf(place).value_or(tiling::Zone{});
            tiling::Rect       frame = tiling::zoneFrame(zone, area);
            if (isHalf(place)) {
                const auto                strip = stripWindows();
                std::vector<tiling::Rect> neighbours;
                for (const auto& r : st().book.records()) {
                    if (r.id == idOf(w) || r.output != output || r.workspace != workspace || std::ranges::find(strip, r.id) != strip.end())
                        continue;
                    if (r.state == tiling::TileState::Tiled || r.state == tiling::TileState::Resizing)
                        neighbours.push_back(tiling::frameOf(r.box, r.band));
                }
                if (const auto beside = tiling::halfBesideNeighbour(place, area, neighbours))
                    frame = *beside;
            }
            const std::array<tiling::Zone, 1>        zones{zone};
            const std::array<tiling::Rect, 1>        frames{frame};
            const std::array<tiling::Constraints, 1> limits{constraintsOf(w)};
            return tiling::fitFrames(zones, frames, limits, area).front();
        }

        // The frame of a placement alone: its place, or its zone of its layout.
        std::optional<tiling::Rect> placementFrame(const PHLWINDOW& w, const tiling::Placement& where, const tiling::Area& area, std::string_view output,
                                                   int64_t workspace) {
            if (where.place)
                return placeFrame(w, *where.place, area, output, workspace);
            const auto* layout = tiling::layoutById(where.layout);
            if (!layout || where.zone < 0 || where.zone >= static_cast<int>(layout->zones.size()))
                return std::nullopt;
            return fitted({layout->zones[static_cast<size_t>(where.zone)]}, {w}, area).front();
        }

        // Posts the `tiling` notice when the records changed since the latest one; refusals and the unload always post.
        void notify(tiling::Reason reason) {
            auto&      s      = st();
            const auto gen    = s.book.generation();
            const bool always = reason == tiling::Reason::Invalid || reason == tiling::Reason::Locked || reason == tiling::Reason::Unavailable;
            if (!always && gen == s.posted)
                return;
            s.posted = gen;
            gf::ipc::postEvent(gf::events::Key{.channel = gf::events::Channel::Tiling, .id = 0}, tiling::noticeJson(gen, reason));
        }

        // Records of closed windows are dropped; a Tiled window whose box is not the one the plugin gave it (an app's own
        // configure, a keyboard move or resize, a rule) becomes Free (TL10).
        void reconcile() {
            auto&                 s = st();
            std::vector<uint64_t> gone;
            for (const auto& r : s.book.records()) {
                const auto w      = windowById(r.id);
                const auto target = w && w->m_isMapped ? w->layoutTarget() : nullptr;
                if (!target)
                    gone.push_back(r.id);
                else if (r.state == tiling::TileState::Tiled && !r.relayout && !sameBox(target->position(), toCBox(r.box)))
                    gone.push_back(r.id);
            }
            for (const auto id : gone)
                s.book.forget(id);
            if (!gone.empty())
                notify(tiling::Reason::Forgotten);
        }

        void applySurface(const PHLWINDOW& w, const CBox& surface) {
            const auto target = w->layoutTarget();
            if (target && !sameBox(target->position(), surface))
                g_layoutManager->setTargetGeom(surface, target);
        }

        // Places Tiled windows again from their placement on the work area now: every one (TL2, the margins changed) or
        // those marked when their output went away (TL11, on the output Hyprland moved them to). Groups of an arrangement
        // are fitted together; halves come last (TL7 reads the others' new frames). Suspended windows are marked: they
        // are placed from their zone when they come back.
        void relayout(bool all) {
            auto& s = st();
            if (!g_layoutManager)
                return;
            reconcile();
            struct SItem {
                uint64_t          id = 0;
                PHLWINDOW         w;
                PHLMONITOR        m;
                tiling::Placement where;
                uint64_t          group     = 0;
                int64_t           workspace = 0;
                bool              done      = false;
            };
            std::vector<SItem>    items;
            std::vector<uint64_t> suspended;
            for (const auto& r : s.book.records()) {
                if (r.state == tiling::TileState::Suspended) {
                    if (all)
                        suspended.push_back(r.id);
                    continue;
                }
                if (r.state != tiling::TileState::Tiled || (!all && !r.relayout))
                    continue;
                const auto w = windowById(r.id);
                if (!placeable(w))
                    continue;
                PHLMONITOR m = all ? monitorByName(r.output) : nullptr;
                if (!m)
                    m = monitorOf(w);
                if (!m)
                    continue;
                items.push_back(SItem{.id = r.id, .w = w, .m = m, .where = r.where, .group = r.group, .workspace = w->m_workspace->m_id});
            }
            for (const auto id : suspended)
                s.book.markRelayout(id, true);
            const auto place = [&s](SItem& item, const tiling::Rect& frame) {
                const CBox surface = toCBox(tiling::surfaceOf(frame, gf::chrome::bandOf(item.w)));
                applySurface(item.w, surface);
                s.book.setBox(item.id, toRect(surface), item.m->m_name);
                item.done = true;
            };
            // Arrangement groups, fitted together on their output.
            for (auto& first : items) {
                if (first.done || first.where.layout.empty() || first.group == 0)
                    continue;
                const auto* layout = tiling::layoutById(first.where.layout);
                if (!layout)
                    continue;
                std::vector<SItem*>       members;
                std::vector<tiling::Zone> zones;
                std::vector<PHLWINDOW>    windows;
                for (auto& other : items) {
                    if (other.done || other.group != first.group || other.where.layout != first.where.layout || other.m != first.m || other.workspace != first.workspace)
                        continue;
                    if (other.where.zone < 0 || other.where.zone >= static_cast<int>(layout->zones.size()))
                        continue;
                    members.push_back(&other);
                    zones.push_back(layout->zones[static_cast<size_t>(other.where.zone)]);
                    windows.push_back(other.w);
                }
                if (members.empty())
                    continue;
                const auto frames = fitted(zones, windows, areaFor(first.m));
                for (size_t i = 0; i < members.size(); ++i)
                    place(*members[i], frames[i]);
            }
            // Single zones and places, halves last.
            for (const bool halves : {false, true}) {
                for (auto& item : items) {
                    if (item.done || (item.where.place && isHalf(*item.where.place)) != halves)
                        continue;
                    if (const auto frame = placementFrame(item.w, item.where, areaFor(item.m), item.m->m_name, item.workspace))
                        place(item, *frame);
                }
            }
            notify(tiling::Reason::Relaid);
        }

        // Return to Previous Size and a window coming back to a taken zone: `before`, centred in the free area of the
        // output the window is on when it lies off every output (its output went away).
        CBox beforeBox(const PHLWINDOW& w, const tiling::Rect& before) {
            CBox box = toCBox(before);
            if (monitorAt(box.middle()))
                return box;
            auto m = monitorOf(w);
            if (!m && Desktop::focusState())
                m = Desktop::focusState()->monitor();
            if (m) {
                const CBox area = m->logicalBoxMinusReserved();
                box.x           = std::round(area.x + (area.w - box.w) / 2);
                box.y           = std::round(area.y + (area.h - box.h) / 2);
            }
            return box;
        }

        bool hyprlandDrag(eMouseBindMode mode) {
            return mode == MBIND_MOVE || mode == MBIND_RESIZE || mode == MBIND_RESIZE_BLOCK_RATIO || mode == MBIND_RESIZE_FORCE_RATIO;
        }

        bool hyprlandDragging() {
            if (!g_layoutManager)
                return false;
            const auto& drag = g_layoutManager->dragController();
            return drag && hyprlandDrag(drag->mode());
        }

        // One of Hyprland's drags holds `w` now (a client-chrome window dragged out of its zoom restarts one, ADR-0015 P4).
        bool heldByHyprlandDrag(const PHLWINDOW& w) {
            if (!hyprlandDragging())
                return false;
            const auto target = g_layoutManager->dragController()->target();
            return target && target->window() == w;
        }

        // TL10: a Suspended window comes back. On the output Hyprland shows it on (under its middle, else the focused one):
        // its own box when that output is the record's and nothing re-placed it meanwhile, else its zone placed there.
        // From a special workspace the zone must be free (else Free at `before`); from full screen or zoom it is put back.
        void resumeNow(const SResume& resume) {
            auto&      s = st();
            const auto r = s.book.find(resume.id);
            if (!r || r->state != tiling::TileState::Suspended)
                return;
            const auto w = windowById(resume.id);
            if (!w) {
                s.book.forget(resume.id);
                notify(tiling::Reason::Forgotten);
                return;
            }
            if (!placeable(w) || !g_layoutManager)
                return; // still full screen, minimized, or not tileable any more: stays Suspended
            if (heldByHyprlandDrag(w)) {
                s.book.forget(resume.id); // dragged out of its zoom: it leaves its tile under the pointer
                notify(tiling::Reason::Moved);
                return;
            }
            const CBox current = w->layoutTarget()->position();
            auto       m       = monitorAt(current.middle());
            if (!m && Desktop::focusState())
                m = Desktop::focusState()->monitor();
            if (!m || !m->m_enabled)
                return;
            const int64_t           workspace = w->m_workspace->m_id;
            const auto              band      = gf::chrome::bandOf(w);
            const tiling::Placement where     = r->where;
            const uint64_t          group     = r->group;
            const tiling::Rect      before    = r->before;
            std::optional<tiling::Rect> frame;
            if (r->output == m->m_name && !r->relayout)
                frame = tiling::frameOf(r->box, r->band);
            else
                frame = placementFrame(w, where, areaFor(m), m->m_name, workspace);
            const auto strip = stripWindows();
            if (frame && (!resume.checkFree || s.book.zoneFree(*frame, m->m_name, workspace, resume.id, strip))) {
                const CBox surface = toCBox(tiling::surfaceOf(*frame, band));
                applySurface(w, surface);
                s.book.placed(resume.id, toRect(current), toRect(surface), band, where, m->m_name, workspace, group);
                notify(tiling::Reason::Restored);
                return;
            }
            g_layoutManager->setTargetGeom(beforeBox(w, before), w->layoutTarget());
            s.book.forget(resume.id);
            notify(tiling::Reason::Forgotten);
        }

        // Resizing -> Tiled with the box Hyprland's resize left (the top clamp has run: it is scheduled first).
        void finishResize() {
            auto&      s = st();
            const auto w = std::exchange(s.resizing, PHLWINDOWREF{}).lock();
            const auto t = w ? w->layoutTarget() : nullptr;
            if (!t)
                return; // closed meanwhile: reconcile() drops the record
            s.book.endResize(idOf(w), toRect(t->position()));
            notify(tiling::Reason::Resized);
        }

        // After Hyprland's own handling of the events that scheduled it: a resize that ended, outputs that went away,
        // windows that came back.
        void afterEvents() {
            auto& s = st();
            if (!s.ready)
                return;
            if (s.resizing.lock() && !hyprlandDragging())
                finishResize();
            if (std::exchange(s.relayoutPending, false))
                relayout(false);
            for (const auto& resume : std::exchange(s.resuming, {}))
                resumeNow(resume);
        }

        void scheduleAfter() {
            st().later.schedule([] { gf::guarded("tiling after events", [] { afterEvents(); }); });
        }

        void onClose(const PHLWINDOW& w) {
            auto& s = st();
            if (!w || !s.book.find(idOf(w)))
                return;
            s.book.forget(idOf(w));
            notify(tiling::Reason::Forgotten);
        }

        // TL12: full screen and zoom suspend; leaving them puts the box back once Hyprland restored the window.
        void onFullscreen(const PHLWINDOW& w) {
            auto&      s = st();
            const auto r = w ? s.book.find(idOf(w)) : nullptr;
            if (!r)
                return;
            if (fullscreenNow(w)) {
                if (s.book.suspend(idOf(w)))
                    notify(tiling::Reason::Suspended);
                return;
            }
            if (r->state == tiling::TileState::Suspended && w->m_workspace && !w->m_workspace->m_isSpecialWorkspace) {
                s.resuming.push_back(SResume{.id = idOf(w), .checkFree = false});
                scheduleAfter();
            }
        }

        // TL14: minimize, hide and Show Desktop move a window to a special workspace (Suspended); back on a regular one it
        // returns to its zone if it is free. Move to Desktop between regular workspaces keeps the state.
        void onMoveToWorkspace(const PHLWINDOW& w, const PHLWORKSPACE& ws) {
            auto&      s = st();
            const auto r = w && ws ? s.book.find(idOf(w)) : nullptr;
            if (!r)
                return;
            if (ws->m_isSpecialWorkspace) {
                if (s.book.suspend(idOf(w)))
                    notify(tiling::Reason::Suspended);
                return;
            }
            if (r->state == tiling::TileState::Suspended) {
                s.resuming.push_back(SResume{.id = idOf(w), .checkFree = true});
                scheduleAfter();
                return;
            }
            s.book.setWorkspace(idOf(w), ws->m_id); // the state reply carries no Desktop: no notice
        }

        // TL11: Hyprland moves the windows of a removed output to another one (its workspaces); the tiled ones are placed
        // into the same zone there once it did. Not checked meanwhile (markRelayout).
        void onMonitorRemoved(const PHLMONITOR& m) {
            auto& s = st();
            if (!m)
                return;
            bool any = false;
            for (const auto& r : s.book.records()) {
                if (r.output == m->m_name) {
                    s.book.markRelayout(r.id, true);
                    any = true;
                }
            }
            if (!any)
                return;
            s.relayoutPending = true;
            scheduleAfter();
        }
    } // namespace

    bool start() {
        auto& bus = Event::bus();
        auto& s   = st();
        // A load starts with no record, also when the library stayed mapped since a previous load (FR23).
        s.book.clear();
        s.posted = s.book.generation();
        s.resizing.reset();
        s.relayoutPending = false;
        s.resuming.clear();
        s.later.clear(); // a previous stop() cancelled it
        if (!bus || !Desktop::windowState() || !State::monitorState() || !Fullscreen::controller())
            return false;
        auto& ev = bus->m_events;
        auto& l  = s.listeners;
        l.push_back(ev.window.close.listen([](const PHLWINDOW& w) { gf::guarded("tiling window.close", [&] { onClose(w); }); }));
        l.push_back(ev.window.fullscreen.listen([](const PHLWINDOW& w) { gf::guarded("tiling window.fullscreen", [&] { onFullscreen(w); }); }));
        l.push_back(ev.window.moveToWorkspace.listen(
            [](const PHLWINDOW& w, const PHLWORKSPACE& ws) { gf::guarded("tiling window.moveToWorkspace", [&] { onMoveToWorkspace(w, ws); }); }));
        l.push_back(ev.monitor.removed.listen([](const PHLMONITOR& m) { gf::guarded("tiling monitor.removed", [&] { onMonitorRemoved(m); }); }));
        s.ready = true;
        return true;
    }

    void stop() {
        auto& s = st();
        s.listeners.clear();
        s.later.cancel();
        s.resizing.reset();
        s.relayoutPending = false;
        s.resuming.clear();
        s.book.clear(); // windows keep their boxes; groups are forgotten
        if (std::exchange(s.ready, false))
            notify(tiling::Reason::Unavailable);
    }

    bool ready() {
        return st().ready;
    }

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
        return Snap{*place, toCBox(placeFrame(w, *place, areaFor(m), m->m_name, w->m_workspace->m_id)), m};
    }

    bool tile(const PHLWINDOW& w, tiling::Place place, const PHLMONITOR& monitor) {
        if (!placeable(w) || !g_layoutManager)
            return false;
        auto& s = st();
        reconcile();
        const auto m = monitor && monitor->m_enabled ? monitor : monitorOf(w);
        if (!m)
            return false;
        const auto    target    = w->layoutTarget();
        const CBox    current   = target->position();
        const int64_t workspace = w->m_workspace->m_id;
        const auto    band      = gf::chrome::bandOf(w);
        const CBox    surface   = toCBox(tiling::surfaceOf(placeFrame(w, place, areaFor(m), m->m_name, workspace), band));
        g_layoutManager->setTargetGeom(surface, target);
        s.book.placed(idOf(w), toRect(current), toRect(surface), band, tiling::Placement{.place = place, .layout = {}, .zone = -1}, m->m_name, workspace, 0);
        logRequest(Log::DEBUG, "tile {:x}: {} on {}", idOf(w), tiling::nameOf(place), m->m_name);
        notify(tiling::Reason::Placed);
        return true;
    }

    bool isTiled(const PHLWINDOW& w) {
        if (!w)
            return false;
        reconcile();
        const auto r = st().book.find(idOf(w));
        return r && r->state == tiling::TileState::Tiled;
    }

    std::optional<CBox> beginMove(const PHLWINDOW& w) {
        if (!w)
            return std::nullopt;
        const auto before = st().book.beginMove(idOf(w));
        if (!before)
            return std::nullopt;
        notify(tiling::Reason::Moved);
        return toCBox(*before);
    }

    void leave(const PHLWINDOW& w) {
        auto& s = st();
        if (!w || !s.book.find(idOf(w)))
            return;
        s.book.forget(idOf(w));
        notify(tiling::Reason::Moved);
    }

    void endMove(const PHLWINDOW& w) {
        auto&      s = st();
        const auto r = w ? s.book.find(idOf(w)) : nullptr;
        if (!r || r->state != tiling::TileState::Moving)
            return;
        s.book.endMove(idOf(w));
        notify(tiling::Reason::Forgotten);
    }

    void tileRequest(std::string_view addressText, std::string_view placeName) {
        if (gf::deferredFocus::sessionLocked()) {
            logRequest(Log::INFO, "tile: refused: the session is locked");
            notify(tiling::Reason::Locked);
            return;
        }
        const auto parsed = minimize::parseAddress(addressText);
        const auto window = parsed ? windowById(*parsed) : nullptr;
        if (!window) {
            logRequest(Log::WARN, "tile: rejected: no such window");
            return;
        }
        const uint64_t address = *parsed;
        if (placeName == "previous") {
            auto&      s      = st();
            const auto r      = placeable(window) && g_layoutManager ? s.book.find(address) : nullptr;
            const auto before = r ? s.book.takeBefore(address) : std::nullopt;
            if (!before) {
                logRequest(Log::INFO, "tile {:x}: not tiled, nothing to return to", address);
                return;
            }
            g_layoutManager->setTargetGeom(beforeBox(window, *before), window->layoutTarget());
            notify(tiling::Reason::Forgotten);
            return;
        }
        const auto place = tiling::parsePlace(placeName);
        if (!place) {
            logRequest(Log::WARN, "tile: rejected: unknown place");
            return;
        }
        if (!tile(window, *place))
            logRequest(Log::INFO, "tile {:x}: not tileable (tiling.md TL9)", address);
    }

    void arrangeRequest(std::string_view json) {
        auto&      s      = st();
        const auto refuse = [](std::string_view why) {
            logRequest(Log::WARN, "arrange: rejected: {}", why);
            notify(tiling::Reason::Invalid);
        };
        if (gf::deferredFocus::sessionLocked()) {
            logRequest(Log::INFO, "arrange: refused: the session is locked");
            notify(tiling::Reason::Locked);
            return;
        }
        const auto request = tiling::parseArrange(json);
        if (!request) {
            refuse(request.error());
            return;
        }
        if (!g_layoutManager) {
            refuse("no layout manager");
            return;
        }
        std::vector<PHLWINDOW> windows;
        for (const auto address : request->windows) {
            const auto w = windowById(address);
            if (!placeable(w)) {
                refuse("a window is not a live tileable window (tiling.md TL9)");
                return;
            }
            windows.push_back(w);
        }
        const auto first     = windows.front();
        const auto workspace = first->m_workspace;
        const auto m         = request->output.empty() ? monitorOf(first) : monitorByName(request->output);
        if (!m || m->m_activeWorkspace != workspace) {
            refuse("the output is unknown or does not show the first window's Desktop");
            return;
        }
        for (const auto& w : windows) {
            if (w->m_workspace != workspace) {
                refuse("the windows are not on one Desktop");
                return;
            }
        }
        reconcile();
        const auto*               layout = tiling::layoutById(request->layout); // parseArrange checked the id
        std::vector<int>          zoneIndex;
        std::vector<tiling::Zone> zones;
        if (request->zone) {
            zoneIndex.push_back(*request->zone);
        } else {
            // TL6: then the next tileable windows in stacking order (top first) on that output and Desktop, in the active stage.
            if (request->fill && Desktop::windowState()) {
                const auto& all = Desktop::windowState()->windows(); // bottom to top
                for (auto it = all.rbegin(); it != all.rend() && windows.size() < layout->zones.size(); ++it) {
                    const auto& w = *it;
                    if (!w || std::ranges::find(windows, w) != windows.end() || w->m_workspace != workspace || !placeable(w) || monitorOf(w) != m)
                        continue;
                    windows.push_back(w);
                }
            }
            for (size_t i = 0; i < windows.size(); ++i)
                zoneIndex.push_back(static_cast<int>(i));
        }
        for (const auto i : zoneIndex)
            zones.push_back(layout->zones[static_cast<size_t>(i)]);
        const auto frames = fitted(zones, windows, areaFor(m));
        // The windows placed together form a tile group (TL6, T1d); one window alone has none.
        const uint64_t group = windows.size() >= 2 ? s.book.newGroup() : 0;
        for (size_t i = 0; i < windows.size(); ++i) {
            const auto& w       = windows[i];
            const auto  target  = w->layoutTarget();
            const CBox  current = target->position();
            const auto  band    = gf::chrome::bandOf(w);
            const CBox  surface = toCBox(tiling::surfaceOf(frames[i], band));
            g_layoutManager->setTargetGeom(surface, target);
            s.book.placed(idOf(w), toRect(current), toRect(surface), band, tiling::Placement{.place = std::nullopt, .layout = std::string{layout->id}, .zone = zoneIndex[i]},
                          m->m_name, workspace->m_id, group);
        }
        logRequest(Log::DEBUG, "arrange: {} with {} window(s) on {}", layout->id, windows.size(), m->m_name);
        notify(tiling::Reason::Placed);
    }

    void marginsChanged() {
        relayout(true);
    }

    std::string stateReply() {
        auto& s = st();
        reconcile();
        std::vector<tiling::StateOutput> outputs;
        for (const auto& m : monitors()) {
            const auto area = areaFor(m);
            const CBox box  = m->logicalBox();
            tiling::StateOutput o{.name = m->m_name, .area = area.box, .outputClass = tiling::classify(box.w, box.h), .grid = area.grid.step, .windows = {}};
            for (const auto& r : s.book.records()) {
                if (r.output == m->m_name)
                    o.windows.push_back(&r);
            }
            outputs.push_back(std::move(o));
        }
        return tiling::stateJson(s.book.generation(), outputs);
    }

    void beforePointerMotion() {
        auto& s = st();
        if (!s.ready || !g_layoutManager)
            return;
        const auto& drag = g_layoutManager->dragController();
        if (!drag || !hyprlandDrag(drag->mode())) {
            if (s.resizing.lock())
                finishResize(); // the drag ended without a release seen here
            return;
        }
        const auto target = drag->target();
        const auto w      = target ? target->window() : nullptr;
        const auto r      = w ? s.book.find(idOf(w)) : nullptr;
        if (!r || r->state != tiling::TileState::Tiled)
            return;
        if (drag->mode() == MBIND_MOVE) {
            // Step 1: the window leaves its tile at its tiled size (step 2 restarts the drag at its size from before, TL16).
            s.book.forget(idOf(w));
            notify(tiling::Reason::Moved);
            return;
        }
        if (s.book.beginResize(idOf(w)))
            s.resizing = w;
    }

    void beforePointerButton(bool pressed) {
        auto& s = st();
        if (pressed || !s.ready || !s.resizing.lock())
            return;
        scheduleAfter(); // ends Resizing once Hyprland ended its drag (afterEvents)
    }

} // namespace gf::tiler
