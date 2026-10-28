#include "Tiling.hpp"

#include "ClientChrome.hpp"
#include "DeferredFocus.hpp"
#include "Ipc.hpp"
#include "Plugin.hpp"
#include "Stages.hpp"
#include "Minimize.hpp"
#include "Titlebar.hpp"
#include "TopClamp.hpp"
#include "core/Minimize.hpp"
#include "core/TitlebarLayout.hpp"

#include <hyprland/src/config/shared/actions/ConfigActions.hpp>
#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/devices/IKeyboard.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/layout/LayoutManager.hpp>
#include <hyprland/src/layout/supplementary/DragController.hpp>
#include <hyprland/src/layout/target/Target.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopTimer.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/pointer/cursor/CursorShapeOverrideController.hpp>
#include <hyprland/src/protocols/XDGShell.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/state/MonitorState.hpp>
#include <hyprland/src/xwayland/XSurface.hpp>
#include <hyprland/src/xwayland/XWayland.hpp>

#include <linux/input-event-codes.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <optional>
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

        // The drag of a floating window (the plugin's titlebar drag or one of Hyprland's moves; one seat pointer): the place
        // under the pointer, shown once the preview delay has passed (TL17).
        struct SDrag {
            PHLWINDOWREF        window;
            std::optional<Snap> candidate;
            tiling::CDwell      dwell;
            bool                hyprland = false; // one of Hyprland's moves (ended by Hyprland, tiled after it)
        };

        // The release of one of Hyprland's moves, handled once Hyprland ended the drag (TL16).
        struct SMoveRelease {
            PHLWINDOWREF        window;
            std::optional<Snap> snap; // the place shown at the release: tiled
        };

        // TL20: the clicks on one window's resize border, and a double-click waiting for Hyprland to end its resize.
        struct SBorderClicks {
            PHLWINDOWREF                window;
            uint8_t                     sides = 0;
            gf::titlebar::CClickTracker clicks{}; // braces: its default constructor is explicit
        };
        struct SExtend {
            PHLWINDOWREF window;
            uint8_t      sides = 0; // with Alt's opposite sides (core extendedSides)
        };

        // TL30: a drag of a shared edge's handle (the plugin's own: its press and release are cancelled on the bus). The
        // windows of the edge as they were at the press, the edge, the pointer at the press; the frames last applied, at most
        // one application per refresh of the output (the rest wait for the timer or the release).
        struct SEdgeDrag {
            tiling::SharedEdge                          edge;
            std::vector<tiling::EdgeWindow>             windows;
            tiling::Grid                                grid;
            Vector2D                                    press;
            PHLMONITORREF                               monitor;
            double                                      delta = 0;
            std::vector<std::pair<uint64_t, tiling::Rect>> applied;
            uint64_t                                    beganMs   = 0;
            uint64_t                                    appliedMs = 0;
            uint32_t                                    steps     = 0; // applications that changed a frame
            uint32_t                                    held      = 0; // motions that waited for the next refresh
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
            SDrag                            drag;
            SP<CEventLoopTimer>              previewTimer; // draws the preview once the delay passed (code of this library: removed in stop())
            bool                             recheck = false;  // a key may have changed Alt: the drag's place is read again
            std::optional<Vector2D>          press;            // the pointer at the left button's press (the grip of Hyprland's move)
            uint32_t                         pressMs = 0;
            std::optional<SMoveRelease>      moveRelease;
            SBorderClicks                    border;
            std::optional<SExtend>           extend;
            std::optional<tiling::Suggestion> suggestion; // TL28: valid while the book is at its generation
            std::optional<SEdgeDrag>          edge;            // TL30: a shared edge being dragged
            bool                              edgeReleaseOwed = false; // the release of the handle's cancelled press is cancelled too
            bool                              edgeCursor      = false; // the handle's cursor is set (Hyprland's special-action override)
            SP<CEventLoopTimer>               edgeTimer;       // the frames that waited for the next refresh (code of this library: removed in stop())
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

        tiling::WindowFacts factsOf(const PHLWINDOW& w) {
            const auto target = w ? w->layoutTarget() : nullptr;
            return tiling::WindowFacts{.mapped    = w && w->m_isMapped,
                                       .onDesktop = w && w->m_workspace,
                                       .inSpace   = target && target->space(),
                                       .floating  = target && target->floating()};
        }

        // An output showing an open special workspace (a scratchpad): nothing tiles there (TL9), a drop only moves.
        bool showsSpecial(const PHLMONITOR& m) {
            return m && m->m_activeSpecialWorkspace;
        }

        // TL9 apart from where the window is now: what a window minimized from an output passes to be suggested there (TL28).
        bool tileableKind(const PHLWINDOW& w) {
            if (!w || !tiling::movable(factsOf(w)) || !w->m_isFloating || w->m_pinned || fullscreenNow(w))
                return false;
            if (w->parent() || x11FloatedByHyprland(w) || w->m_class == kGlanceClass)
                return false;
            const auto c = constraintsOf(w);
            return !((c.maxW > 0 && c.minW >= c.maxW) || (c.maxH > 0 && c.minH >= c.maxH)); // fixed size on an axis
        }

        // TL9 (no drag preview, refused by tile and arrange).
        bool placeable(const PHLWINDOW& w) {
            if (!tileableKind(w) || w->isHidden() || !w->m_workspace || w->m_workspace->m_isSpecialWorkspace)
                return false; // minimized and hidden windows live on special workspaces
            return !gf::stager::inStripStage(w);
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
            frames.reserve(zones.size());
            limits.reserve(zones.size());
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

        // The frame of a placement alone: its place, its zone of its layout, or its extended sides.
        std::optional<tiling::Rect> placementFrame(const PHLWINDOW& w, const tiling::Placement& where, const tiling::Area& area, std::string_view output,
                                                   int64_t workspace) {
            if (where.place)
                return placeFrame(w, *where.place, area, output, workspace);
            if (where.sides != 0) // TL20: the sides an edge double-click extended go to this area's edges, the others stay
                return tiling::extendFrame(tiling::frameOf(toRect(w->layoutTarget()->position()), gf::chrome::bandOf(w)), where.sides, constraintsOf(w), area);
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
                const bool moved  = target && r.state == tiling::TileState::Tiled && !r.relayout && !sameBox(target->position(), toCBox(r.box));
                if (!target || moved)
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

        // Why tiled windows are placed again.
        enum class ERelayout : uint8_t {
            Margins,    // TL2: every Tiled window; one that cannot be placed now (an inactive stage) is deferred, Suspended
                        // ones are marked
            OutputGone, // TL11: the windows of a removed output, on the output Hyprland moved them to; one that cannot be
                        // placed is Free
            CatchUp,    // the deferred ones that can be placed now; the others keep waiting
        };

        // Places Tiled windows again from their placement on the work area now. Groups of an arrangement are fitted
        // together; halves come last (TL7 reads the others' new frames).
        void relayout(ERelayout why) {
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
            const bool            margins = why == ERelayout::Margins;
            std::vector<SItem>    items;
            std::vector<uint64_t> suspended;
            std::vector<uint64_t> waiting; // cannot be placed now (an inactive stage): placed once it can be, still checked
            std::vector<uint64_t> lost;    // its output went away and it cannot be placed: Free
            for (const auto& r : s.book.records()) {
                if (r.state == tiling::TileState::Suspended) {
                    if (margins)
                        suspended.push_back(r.id);
                    continue;
                }
                const bool selected = margins || (why == ERelayout::OutputGone ? r.relayout : r.deferred);
                if (r.state != tiling::TileState::Tiled || !selected)
                    continue;
                const auto w  = windowById(r.id);
                const bool ok = placeable(w);
                PHLMONITOR m  = ok && margins ? monitorByName(r.output) : nullptr;
                if (!m && ok)
                    m = monitorOf(w);
                if (!m) {
                    if (why == ERelayout::OutputGone)
                        lost.push_back(r.id); // never left with relayout set: it would never be checked again
                    else if (margins)
                        waiting.push_back(r.id);
                    continue;
                }
                items.push_back(SItem{.id = r.id, .w = w, .m = m, .where = r.where, .group = r.group, .workspace = w->m_workspace->m_id});
            }
            for (const auto id : suspended)
                s.book.markRelayout(id, true);
            for (const auto id : waiting)
                s.book.markDeferred(id, true);
            for (const auto id : lost)
                s.book.forget(id);
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

        // Reconciles the records, then places the deferred windows that can be placed now (TL2: the margins changed while
        // they were in an inactive stage): at the next placement or state read once they can be.
        void catchUp() {
            reconcile();
            const auto records = st().book.records();
            if (std::ranges::any_of(records, [](const tiling::TileRecord& r) { return r.state == tiling::TileState::Tiled && r.deferred; }))
                relayout(ERelayout::CatchUp);
        }

        // TL28: what fills the rest of the layout of `askerId` on `m`: its empty zones (their frames in the work area now) and the
        // windows that can take them (D26): the tileable windows of that output's Desktop in the active stage, top first, then
        // the windows minimized from that output, the latest first; never one that holds a zone of that layout already.
        // nullopt when no zone is empty or no window fits (nothing is shown then).
        std::optional<tiling::Suggestion> suggestionFor(uint64_t askerId, const PHLMONITOR& m) {
            const auto& s      = st();
            const auto* asker  = s.book.find(askerId);
            const auto* layout = asker ? tiling::layoutById(asker->where.layout) : nullptr;
            if (!layout || !m || !m->m_activeWorkspace || !Desktop::windowState())
                return std::nullopt;
            const auto held  = tiling::zonesHeld(s.book.records(), *asker);
            const auto empty = tiling::emptyZones(*layout, held);
            if (empty.empty())
                return std::nullopt;
            tiling::Suggestion sg{.generation = s.book.generation(), .asker = askerId, .layout = asker->where.layout, .output = m->m_name, .zones = empty, .frames = {}, .windows = {}};
            const auto         area = areaFor(m);
            for (const int z : empty)
                sg.frames.push_back(tiling::zoneFrame(layout->zones[static_cast<size_t>(z)], area));
            const auto inLayout = [&s, asker](uint64_t id) {
                const auto* r = s.book.find(id);
                return r && (r->id == asker->id || (asker->group != 0 && r->group == asker->group && r->where.layout == asker->where.layout));
            };
            const auto& all = Desktop::windowState()->windows(); // bottom to top
            for (auto it = all.rbegin(); it != all.rend() && sg.windows.size() < tiling::kMaxSuggested; ++it) {
                const auto& w = *it;
                if (w && w->m_workspace == m->m_activeWorkspace && placeable(w) && monitorOf(w) == m && !inLayout(idOf(w)))
                    sg.windows.push_back(idOf(w));
            }
            for (const auto id : gf::minimizer::minimizedFrom(m->m_name)) {
                if (sg.windows.size() >= tiling::kMaxSuggested)
                    break;
                if (tileableKind(windowById(id)) && !inLayout(id))
                    sg.windows.push_back(id);
            }
            if (sg.windows.empty())
                return std::nullopt;
            return sg;
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
            if (!g_layoutManager || fullscreenNow(w) || !w->m_workspace || w->m_workspace->m_isSpecialWorkspace)
                return; // still full screen, zoomed or minimized: stays Suspended (its own event resumes it)
            if (!placeable(w)) {
                s.book.forget(resume.id); // back, but not tileable any more (pinned, a parent, a strip): Free for good
                notify(tiling::Reason::Forgotten);
                return;
            }
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

        // ---- drags (TL16-TL20) ----

        void scheduleAfter(); // below: its callback is afterEvents

        uint64_t nowMs() {
            return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count());
        }

        // Alt (Option) held on any keyboard.
        bool altHeld() {
            return g_pInputManager && (g_pInputManager->getModsFromAllKBs() & HL_MODIFIER_ALT) != 0;
        }

        // A preview frame appears or goes: it is drawn again.
        void damage(const std::optional<Snap>& snap) {
            if (snap && g_pHyprRenderer)
                g_pHyprRenderer->damageBox(snap->frame);
        }

        std::optional<Snap> shownOf(const SDrag& d) {
            return d.dwell.shown() ? d.candidate : std::nullopt;
        }

        // The preview delay passed with the pointer at rest: the drag's place is read again and shows if the pointer is
        // still on it. No button held any more: the drag ended without its end seen here. (Not tied to ready(): the titlebar
        // drag tiles without the tiling listeners; stop() removes the timer at the unload.)
        void previewDue() {
            auto&      s = st();
            const auto w = s.drag.window.lock();
            if (!w || !g_pInputManager)
                return;
            if (!g_pInputManager->hasHeldButtons()) {
                dragDone();
                return;
            }
            dragMotion(w, g_pInputManager->getMouseCoordsInternal());
        }

        void armPreviewTimer(uint64_t ms) {
            auto& s = st();
            if (!g_pEventLoopManager)
                return;
            if (!s.previewTimer) {
                s.previewTimer = makeShared<CEventLoopTimer>(
                    std::nullopt, [](const SP<CEventLoopTimer>& /*self*/, void* /*data*/) { gf::guarded("tiling preview delay", [] { previewDue(); }); }, nullptr);
                g_pEventLoopManager->addTimer(s.previewTimer);
            }
            s.previewTimer->updateTimeout(std::chrono::milliseconds(ms));
        }

        // TL16: one of Hyprland's moves of a tiled window passed the drag threshold: Moving, with its size from before
        // under the pointer at the same place of its grip (macOS). Hyprland keeps the drag's start to itself
        // (CDragStateController::m_beginDragPositionXY), so its drag is ended and begun again from that box, with the
        // exclusive device grab an app's move request asked for (CWindow::onXDGMoveRequest), as client chrome does after a
        // zoom (ClientChrome.cpp P4).
        void restartAtSizeBefore(const PHLWINDOW& w, const SP<Layout::ITarget>& target, tiling::Rect tiled, const Vector2D& grip, const Vector2D& pointer) {
            if (!movable(w)) {
                logRequest(Log::INFO, "window {:x} closed or unmapped: its move not restarted (gate C1)", idOf(w));
                return;
            }
            const auto& drag      = g_layoutManager->dragController();
            const bool  exclusive = drag && drag->exclusiveDeviceGrab();
            const auto  before    = beginMove(w);
            if (!before)
                return;
            const auto box = gf::titlebar::unzoomedDragBox(gf::titlebar::Rect{tiled.x, tiled.y, tiled.w, tiled.h}, before->w, before->h, grip.x, grip.y, pointer.x,
                                                           pointer.y);
            g_layoutManager->endDragTarget();
            g_layoutManager->setTargetGeom(CBox{box.x, box.y, box.w, box.h}, target);
            g_layoutManager->beginDragTarget(target, MBIND_MOVE, std::nullopt, exclusive);
            logRequest(Log::DEBUG, "Hyprland's move of {:x} leaves its tile: {:.0f}x{:.0f} at {:.0f},{:.0f}", idOf(w), box.w, box.h, box.x, box.y);
        }

        // One of Hyprland's moves (an app's toolbar drag, Super+drag) is at the pointer, before Hyprland applies the motion:
        // a tiled window leaves its tile once past the drag threshold (until then it stays Tiled: its release puts it back);
        // a movable floating window shows the place under the pointer (dragMotion). A window Hyprland itself tiles, dragged
        // out of its layout for the drag only (CDragStateController::draggingTiled), shows none: Hyprland tiles it again.
        void hyprlandMove(const PHLWINDOW& w, const SP<Layout::ITarget>& target) {
            auto& s = st();
            if (!w || !target || !g_pInputManager)
                return;
            const auto& drag = g_layoutManager->dragController();
            if (drag && drag->draggingTiled()) {
                if (s.drag.hyprland)
                    dragDone();
                return;
            }
            const Vector2D pointer = g_pInputManager->getMouseCoordsInternal();
            if (const auto r = s.book.find(idOf(w)); r && r->state == tiling::TileState::Tiled) {
                const Vector2D grip = s.press.value_or(pointer);
                if (!gf::titlebar::exceedsDragThreshold(pointer.x - grip.x, pointer.y - grip.y))
                    return;
                restartAtSizeBefore(w, target, r->box, grip, pointer);
            }
            dragMotion(w, pointer);
            s.drag.hyprland = true;
        }

        // TL16, after Hyprland ended one of its moves: the place shown at the release is tiled; a tiled window released
        // under the drag threshold goes back to its tile; a Moving one released elsewhere is Free. A release that did not
        // end the drag (another button) changes nothing: the drag and its preview go on.
        void finishMove(const SMoveRelease& rel) {
            auto& s = st();
            if (hyprlandDragging())
                return;
            const auto w = rel.window.lock();
            if (s.drag.hyprland)
                dragDone();
            if (!w)
                return;
            if (!movable(w)) {
                endMove(w); // closed or unmapped meanwhile (gate C1): nothing is moved
                return;
            }
            if (rel.snap && gf::deferredFocus::sessionLocked()) {
                endMove(w); // nothing tiles behind the lock screen (TL34, behind Hyprland's own refusal of drags then)
                return;
            }
            if (rel.snap) {
                tile(w, rel.snap->place, rel.snap->monitor.lock());
                return;
            }
            if (const auto r = s.book.find(idOf(w)); r && r->state == tiling::TileState::Tiled) {
                applySurface(w, toCBox(r->box));
                return;
            }
            endMove(w);
        }

        // TL20: a click on `w`'s resize border at `at` (`timeMs`: its press). Two on the same sides within the double-click
        // time and distance (core CClickTracker) extend those sides, with Alt their opposite sides too, once Hyprland ended
        // the resize the second press began.
        void borderClick(const PHLWINDOW& w, const Vector2D& at, uint32_t timeMs) {
            auto&         s     = st();
            const uint8_t sides = tiling::sidesAt(at.x, at.y, toRect(w->getWindowMainSurfaceBox()));
            if (s.border.window.lock() != w || s.border.sides != sides) {
                s.border.window = w;
                s.border.sides  = sides;
                s.border.clicks.reset();
            }
            if (!s.border.clicks.press(timeMs, at.x, at.y))
                return;
            s.extend = SExtend{.window = w, .sides = tiling::extendedSides(sides, altHeld())};
            scheduleAfter();
        }

        // TL20, after Hyprland ended the second click's resize: the sides go to the work area's edges (core extendFrame) and
        // the window is tiled with a box from before; all four sides (Alt on a corner) is Fill.
        void extendSides(const SExtend& e) {
            auto&      s = st();
            const auto w = e.window.lock();
            if (!w || e.sides == 0 || !placeable(w) || !g_layoutManager || hyprlandDragging() || gf::deferredFocus::sessionLocked())
                return; // locked: nothing tiles behind the lock screen (TL34)
            const auto m = monitorOf(w);
            if (!m || showsSpecial(m))
                return;
            if (e.sides == tiling::kAllSides) {
                tile(w, tiling::Place::Fill, m);
                return;
            }
            catchUp();
            const CBox current = w->layoutTarget()->position();
            const auto band    = gf::chrome::bandOf(w);
            const auto frame   = tiling::extendFrame(tiling::frameOf(toRect(current), band), e.sides, constraintsOf(w), areaFor(m));
            const CBox surface = toCBox(tiling::surfaceOf(frame, band));
            applySurface(w, surface);
            tiling::Placement where;
            where.sides = e.sides;
            s.book.placed(idOf(w), toRect(current), toRect(surface), band, where, m->m_name, w->m_workspace->m_id, 0);
            logRequest(Log::DEBUG, "edge double-click {:x}: {} extended on {}", idOf(w), tiling::sidesName(e.sides), m->m_name);
            notify(tiling::Reason::Placed);
        }

        // After Hyprland's own handling of the events that scheduled it: a resize that ended, outputs that went away,
        // windows that came back, a move released, an edge double-clicked, a key that may have changed Alt during a drag.
        void afterEvents() {
            auto& s = st();
            if (!s.ready)
                return;
            if (s.resizing.lock() && !hyprlandDragging())
                finishResize();
            if (std::exchange(s.relayoutPending, false))
                relayout(ERelayout::OutputGone);
            for (const auto& resume : std::exchange(s.resuming, {}))
                resumeNow(resume);
            if (const auto rel = std::exchange(s.moveRelease, std::nullopt))
                finishMove(*rel);
            if (const auto e = std::exchange(s.extend, std::nullopt))
                extendSides(*e);
            if (std::exchange(s.recheck, false)) {
                const auto w = s.drag.window.lock();
                if (w && g_pInputManager && g_pInputManager->hasHeldButtons())
                    dragMotion(w, g_pInputManager->getMouseCoordsInternal());
            }
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
        // ---- shared edge (TL30) ----

        // The shared edges of the Desktop `m` shows (core sharedEdges over its Tiled group members): none over an open
        // special workspace; a window in full screen or zoom, hidden, unmapped or in an inactive stage is not Tiled or left out.
        struct SEdgeScene {
            std::vector<tiling::EdgeWindow> windows;
            std::vector<tiling::SharedEdge> edges;
            tiling::Grid                    grid;
        };
        SEdgeScene edgeScene(const PHLMONITOR& m) {
            SEdgeScene scene;
            if (!m || showsSpecial(m) || !m->m_activeWorkspace)
                return scene;
            const auto area = areaFor(m);
            scene.grid      = area.grid;
            for (const auto& r : st().book.records()) {
                if (r.state != tiling::TileState::Tiled || r.group == 0 || r.output != m->m_name || r.workspace != m->m_activeWorkspace->m_id)
                    continue;
                const auto w = windowById(r.id);
                const auto t = w && w->m_isMapped && !w->isHidden() && !fullscreenNow(w) && !gf::stager::inStripStage(w) ? w->layoutTarget() : nullptr;
                if (!t)
                    continue;
                const auto limits = constraintsOf(w);
                scene.windows.push_back(tiling::EdgeWindow{.id = r.id, .group = r.group, .frame = tiling::frameOf(toRect(t->position()), limits.band), .limits = limits});
            }
            scene.edges = tiling::sharedEdges(scene.windows, area.margin, tiling::kHandleLength, tiling::kHandleBand);
            return scene;
        }

        bool modifierHeld() {
            constexpr uint32_t kMods = HL_MODIFIER_SHIFT | HL_MODIFIER_CTRL | HL_MODIFIER_ALT | HL_MODIFIER_META; // not Caps or Num Lock
            return g_pInputManager && (g_pInputManager->getModsFromAllKBs() & kMods) != 0;
        }

        // The handle under the pointer, for a plain pointer (no button held, no modifier: Super+drag stays Hyprland's move),
        // with the desktop not covered (the lock, a foreign Exclusive layer, a layer under the point: TL34).
        std::optional<tiling::SharedEdge> handleAt(const Vector2D& p, std::vector<tiling::EdgeWindow>* windows, tiling::Grid* grid) {
            if (gf::deferredFocus::sessionLocked() || modifierHeld())
                return std::nullopt;
            auto       scene = edgeScene(monitorAt(p));
            const auto edge  = tiling::edgeAt(scene.edges, p.x, p.y);
            if (!edge || CGrassfieldTitlebar::pointerCovered(p)) // the hit test of the layers only over a handle
                return std::nullopt;
            if (windows)
                *windows = std::move(scene.windows);
            if (grid)
                *grid = scene.grid;
            return edge;
        }

        // The handle's cursor: a left-right or up-down double arrow (Hyprland's special-action override, which outranks the
        // border icon of resize_on_border), set while the pointer rests on a handle and during its drag.
        void edgeCursor(std::optional<bool> vertical) {
            auto& s = st();
            if (!Pointer::Cursor::overrideController)
                return;
            if (vertical) {
                Pointer::Cursor::overrideController->setOverride(*vertical ? "ew-resize" : "ns-resize", Pointer::Cursor::CURSOR_OVERRIDE_SPECIAL_ACTION);
                s.edgeCursor = true;
            } else if (std::exchange(s.edgeCursor, false)) {
                Pointer::Cursor::overrideController->unsetOverride(Pointer::Cursor::CURSOR_OVERRIDE_SPECIAL_ACTION);
            }
        }

        void edgeHover() {
            const auto& s = st();
            if (!g_pInputManager || s.edge)
                return;
            const auto edge = g_pInputManager->hasHeldButtons() ? std::nullopt : handleAt(g_pInputManager->getMouseCoordsInternal(), nullptr, nullptr);
            edgeCursor(edge ? std::optional<bool>{edge->vertical} : std::nullopt);
        }

        // The frames of the drag's delta (core dragEdge) on the windows still there: each surface box set and its animation
        // ended at once (as a step of Hyprland's own resize: setTargetGeom, warpPositionSize). A window closed, unmapped or
        // no longer Resizing meanwhile (full screen, zoom, minimized: Suspended; forgotten) is left out; the others go on.
        void edgeApply() {
            auto& s = st();
            if (!s.edge || !g_layoutManager)
                return;
            auto&      d      = *s.edge;
            const auto frames = tiling::dragEdge(d.edge, d.windows, d.delta, d.grid);
            d.appliedMs       = nowMs();
            if (frames == d.applied)
                return;
            for (const auto& f : frames) {
                const uint64_t id = f.first;
                const auto     w  = windowById(id);
                const auto     t  = w && w->m_isMapped ? w->layoutTarget() : nullptr;
                const auto     e  = std::ranges::find_if(d.windows, [id](const tiling::EdgeWindow& x) { return x.id == id; });
                const auto     r  = s.book.find(id);
                if (!t || e == d.windows.end() || !r || r->state != tiling::TileState::Resizing)
                    continue;
                g_layoutManager->setTargetGeom(toCBox(tiling::surfaceOf(f.second, e->limits.band)), t);
                t->warpPositionSize();
            }
            d.applied = frames;
            ++d.steps;
        }

        void armEdgeTimer(uint64_t ms) {
            auto& s = st();
            if (!g_pEventLoopManager)
                return;
            if (!s.edgeTimer) {
                s.edgeTimer = makeShared<CEventLoopTimer>(
                    std::nullopt, [](const SP<CEventLoopTimer>& /*self*/, void* /*data*/) { gf::guarded("tiling shared edge frame", [] { edgeApply(); }); }, nullptr);
                g_pEventLoopManager->addTimer(s.edgeTimer);
            }
            s.edgeTimer->updateTimeout(std::chrono::milliseconds(ms));
        }

        // The end of a drag (its release; the lock; another press): the last frames, then Resizing -> Tiled with the boxes
        // the windows have, one `resized` notice; the cursor goes back.
        void edgeEnd(std::string_view why) {
            auto& s = st();
            if (!s.edge)
                return;
            if (s.edgeTimer)
                s.edgeTimer->updateTimeout(std::nullopt);
            edgeApply();
            const auto d = std::move(*s.edge);
            s.edge.reset();
            for (const auto& e : d.windows) {
                const auto w = windowById(e.id);
                const auto t = w ? w->layoutTarget() : nullptr;
                const auto r = s.book.find(e.id);
                if (t && r && r->state == tiling::TileState::Resizing)
                    s.book.endResize(e.id, toRect(t->position()));
            }
            notify(tiling::Reason::Resized);
            edgeCursor(std::nullopt);
            logRequest(Log::DEBUG, "shared edge: {} window(s), {:+.0f} px, {} step(s) and {} held motion(s) in {} ms ({})", d.windows.size(), d.delta, d.steps, d.held,
                       nowMs() - d.beganMs, why);
        }

        // A plain left press on a handle: the drag begins (every window of the edge Resizing), the press is the plugin's.
        bool edgePress(const Vector2D& p) {
            auto& s = st();
            // Hyprland's held buttons before this press is recorded: another device holding one would make the release
            // this press owes ambiguous (the bus names no device; FR13, as P6).
            if (s.edge || !g_layoutManager || !g_pInputManager || g_pInputManager->hasHeldButtons())
                return false;
            if (const auto& drag = g_layoutManager->dragController(); drag && drag->mode() != MBIND_INVALID)
                return false;
            std::vector<tiling::EdgeWindow> windows;
            tiling::Grid                    grid;
            const auto                      edge = handleAt(p, &windows, &grid);
            if (!edge)
                return false;
            std::erase_if(windows, [&](const tiling::EdgeWindow& w) {
                return std::ranges::find(edge->before, w.id) == edge->before.end() && std::ranges::find(edge->after, w.id) == edge->after.end();
            });
            for (const auto& w : windows)
                s.book.beginResize(w.id); // Tiled by edgeScene
            const auto now = nowMs();
            s.edge         = SEdgeDrag{.edge = *edge, .windows = std::move(windows), .grid = grid, .press = p, .monitor = monitorAt(p), .delta = 0, .applied = {},
                                       .beganMs = now, .appliedMs = now, .steps = 0, .held = 0};
            s.edgeReleaseOwed = true;
            edgeCursor(edge->vertical);
            return true;
        }

        // A motion during the drag: the edge follows the pointer along its axis, applied at most once per refresh of the
        // output (TL30, P3: the neighbours are configured at most once per refresh), the rest when the frame is due.
        void edgeMotion() {
            auto& s = st();
            auto& d = *s.edge;
            if (gf::deferredFocus::sessionLocked()) {
                edgeEnd("the session locked");
                return;
            }
            const Vector2D p = g_pInputManager ? g_pInputManager->getMouseCoordsInternal() : d.press;
            d.delta          = d.edge.vertical ? p.x - d.press.x : p.y - d.press.y;
            const auto   m       = d.monitor.lock();
            const double hz      = m && m->m_refreshRate > 1 ? m->m_refreshRate : 60.0;
            const auto   frameMs = static_cast<uint64_t>(std::ceil(1000.0 / hz));
            const auto   since   = nowMs() - d.appliedMs;
            if (since < frameMs) {
                ++d.held;
                armEdgeTimer(frameMs - since);
                return;
            }
            edgeApply();
        }

    } // namespace

    bool start() {
        auto& bus = Event::bus();
        auto& s   = st();
        // A load starts with no record, also when the library stayed mapped since a previous load (FR23).
        s.book.clear();
        s.suggestion.reset();
        s.posted = s.book.generation();
        s.resizing.reset();
        s.relayoutPending = false;
        s.resuming.clear();
        s.later.clear(); // a previous stop() cancelled it
        s.drag = {};
        s.recheck = false;
        s.press.reset();
        s.moveRelease.reset();
        s.border = {};
        s.extend.reset();
        s.edge.reset();
        s.edgeReleaseOwed = false;
        s.edgeCursor      = false;
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
        dragDone(); // the preview goes; a drag of Hyprland's goes on as Hyprland's own
        if (s.previewTimer) {
            if (g_pEventLoopManager)
                g_pEventLoopManager->removeTimer(s.previewTimer);
            s.previewTimer.reset();
        }
        s.recheck = false;
        s.press.reset();
        s.moveRelease.reset();
        s.border = {};
        s.extend.reset();
        s.resizing.reset();
        s.relayoutPending = false;
        s.resuming.clear();
        s.book.clear(); // windows keep their boxes; groups are forgotten
        s.suggestion.reset();
        // TL30: a drag of a shared edge ends with the boxes the windows have (the book is cleared just above: no notice for
        // it); the release it owes is still cancelled by nobody once the listener is gone, and Hyprland never saw its press.
        if (s.edgeTimer) {
            if (g_pEventLoopManager)
                g_pEventLoopManager->removeTimer(s.edgeTimer);
            s.edgeTimer.reset();
        }
        s.edge.reset();
        s.edgeReleaseOwed = false;
        edgeCursor(std::nullopt);
        if (std::exchange(s.ready, false))
            notify(tiling::Reason::Unavailable);
    }

    bool edgeOwnsPointer() {
        return st().edge.has_value();
    }

    bool ready() {
        return st().ready;
    }

    std::optional<Snap> snapFor(const PHLWINDOW& w, const Vector2D& pointer) {
        const auto& options = state().tilingDrag;
        const bool  alt     = options.altDrag && altHeld();
        if (!placeable(w) || (!options.edges && !options.menuBar && !alt))
            return std::nullopt;
        const auto m = monitorAt(pointer);
        if (!m || showsSpecial(m))
            return std::nullopt;
        const CBox box = m->logicalBox();
        const tiling::Output output{toRect(box), box.y + m->m_reservedArea.top(), edgeFree(m, true), edgeFree(m, false)};
        const auto           area  = areaFor(m);
        const auto           place = tiling::dragPlace(pointer.x, pointer.y, output, area.box, options, alt);
        if (!place)
            return std::nullopt;
        return Snap{*place, toCBox(placeFrame(w, *place, area, m->m_name, w->m_workspace->m_id)), m};
    }

    std::optional<Snap> dragMotion(const PHLWINDOW& w, const Vector2D& pointer) {
        auto& s = st();
        if (!w)
            return std::nullopt;
        auto& d = s.drag;
        if (d.window.lock() != w) {
            dragDone(); // another window's drag: its preview goes
            d.window = w;
        }
        const auto before = shownOf(d);
        auto       next   = snapFor(w, pointer);
        const auto m      = next ? next->monitor.lock() : nullptr;
        const auto now    = nowMs();
        d.dwell.update(next ? std::optional{next->place} : std::nullopt, m ? std::string_view{m->m_name} : std::string_view{}, now, altHeld());
        d.candidate      = std::move(next);
        const auto after = shownOf(d);
        const bool same  = before && after ? before->place == after->place && before->frame == after->frame : before.has_value() == after.has_value();
        if (!same) {
            damage(before);
            damage(after);
        }
        // The line tests wait for before they capture the preview (tests/compositor/tiling.sh): it shows now.
        if (after && (!before || before->place != after->place))
            logRequest(Log::DEBUG, "tiling preview {:x}: {} on {}", idOf(w), tiling::nameOf(after->place), m ? m->m_name : std::string{});
        if (const auto wait = d.dwell.remaining(now))
            armPreviewTimer(*wait);
        return after;
    }

    void dragDone() {
        auto& s = st();
        damage(shownOf(s.drag));
        s.drag = {};
        if (s.previewTimer)
            s.previewTimer->updateTimeout(std::nullopt);
    }

    std::optional<Snap> previewOf(const PHLWINDOW& w) {
        const auto& s = st();
        if (!w || s.drag.window.lock() != w)
            return std::nullopt;
        return shownOf(s.drag);
    }

    void onKey() {
        auto& s = st();
        if (!s.ready || !s.drag.window.lock())
            return;
        s.recheck = true; // Hyprland applies the key after this listener: Alt is read once it did
        scheduleAfter();
    }

    bool tile(const PHLWINDOW& w, tiling::Place place, const PHLMONITOR& monitor) {
        if (!placeable(w) || !g_layoutManager)
            return false;
        auto& s = st();
        catchUp();
        const auto m = monitor && monitor->m_enabled ? monitor : monitorOf(w);
        if (!m || showsSpecial(m))
            return false; // over an open special workspace the drop only moves the window (followOutput)
        const auto target  = w->layoutTarget();
        const CBox current = target->position();
        const auto band    = gf::chrome::bandOf(w);
        const CBox surface = toCBox(tiling::surfaceOf(placeFrame(w, place, areaFor(m), m->m_name, w->m_workspace->m_id), band));
        g_layoutManager->setTargetGeom(surface, target);
        followOutput(w); // tiled on another output (a drag's release there, tile() after a drag over): that output's Desktop
        const int64_t workspace = w->m_workspace ? w->m_workspace->m_id : 0;
        s.book.placed(idOf(w), toRect(current), toRect(surface), band, tiling::Placement{.place = place, .layout = {}, .zone = -1}, m->m_name, workspace, 0);
        logRequest(Log::DEBUG, "tile {:x}: {} on {}", idOf(w), tiling::nameOf(place), m->m_name);
        notify(tiling::Reason::Placed);
        return true;
    }

    bool movable(const PHLWINDOW& w) {
        return tiling::movable(factsOf(w));
    }

    bool tileable(const PHLWINDOW& w) {
        return placeable(w);
    }

    void moveToRequest(std::string_view addressText, std::string_view outputName) {
        if (gf::deferredFocus::sessionLocked()) {
            logRequest(Log::WARN, "move_to: refused: the session is locked");
            notify(tiling::Reason::Locked);
            return;
        }
        const auto refuse = [](std::string_view why) {
            logRequest(Log::WARN, "move_to: refused: {}", why);
            notify(tiling::Reason::Invalid);
        };
        const uint64_t address = minimize::parseAddress(addressText).value_or(0); // 0 is never a window
        const auto     w       = address != 0 ? windowById(address) : nullptr;
        if (!w || !g_layoutManager) {
            refuse("no such window");
            return;
        }
        if (!tiling::outputNameOk(outputName)) {
            refuse("not an output name");
            return;
        }
        const auto to   = monitorByName(outputName);
        const auto from = monitorOf(w);
        if (!to || !to->m_enabled || !from || to == from || showsSpecial(to) || !to->m_activeWorkspace) {
            refuse("no other output of that name with a Desktop shown");
            return;
        }
        if (!movable(w) || !w->m_isFloating || w->m_pinned || fullscreenNow(w) || !w->m_workspace || w->m_workspace->m_isSpecialWorkspace) {
            refuse("the window cannot move to another output");
            return;
        }
        auto& s = st();
        catchUp();
        const CBox         current  = w->layoutTarget()->position();
        const auto         band     = gf::chrome::bandOf(w);
        const auto         toArea   = areaFor(to);
        const tiling::Rect frame    = tiling::frameOf(toRect(current), band);
        const tiling::Rect relative = tiling::moveToArea(frame, areaFor(from).box, toArea.box);
        const auto         r        = s.book.find(idOf(w));
        std::optional<tiling::Placement> where;
        std::optional<tiling::Rect>      tiled;
        if (r && r->state == tiling::TileState::Tiled && placeable(w)) {
            where = r->where; // a copy: the book changes below
            if (where->sides != 0)
                tiled = tiling::extendFrame(relative, where->sides, constraintsOf(w), toArea);
            else
                tiled = placementFrame(w, *where, toArea, to->m_name, to->m_activeWorkspace->m_id);
        }
        const CBox surface = toCBox(tiling::surfaceOf(tiled.value_or(relative), band));
        g_layoutManager->setTargetGeom(surface, w->layoutTarget());
        followOutput(w); // its middle is on `to` now: that output's Desktop, as after Hyprland's own move (TL21, D9)
        const int64_t workspace = w->m_workspace ? w->m_workspace->m_id : 0;
        if (tiled && where) {
            s.book.placed(idOf(w), toRect(current), toRect(surface), band, *where, to->m_name, workspace, 0); // a group stays on its output
            notify(tiling::Reason::Placed);
        } else if (r) {
            s.book.forget(idOf(w)); // not tiled (or not tileable any more): Free on the other output
            notify(tiling::Reason::Forgotten);
        }
        logRequest(Log::DEBUG, "move_to {:x}: {} -> {}{}", idOf(w), from->m_name, to->m_name, tiled ? " (in the same tile)" : "");
    }

    void followOutput(const PHLWINDOW& w) {
        const auto facts = factsOf(w);
        if (!g_layoutManager || !w)
            return;
        if (!tiling::movable(facts)) {
            // Closed or unmapped (during a drag): no Desktop, no space (gate C1); tiling.sh's C1 cases look for this line.
            logRequest(Log::INFO, "window {:x} closed or unmapped: its Desktop not changed (gate C1)", idOf(w));
            return;
        }
        const auto                target = w->layoutTarget();
        const CBox                box    = target->position();
        const auto                all = monitors();
        std::vector<tiling::Rect> boxes;
        boxes.reserve(all.size());
        for (const auto& m : all)
            boxes.push_back(toRect(m->logicalBox()));
        const auto i = tiling::outputUnder(toRect(box), boxes);
        if (!i)
            return; // off every output: it keeps its Desktop
        const auto& m  = all[*i];
        const auto  ws = m->m_activeSpecialWorkspace ? m->m_activeSpecialWorkspace : m->m_activeWorkspace;
        if (!ws || !ws->m_space || !tiling::shouldFollow(facts, i, ws->m_space == target->space()))
            return;
        target->assignToSpace(ws->m_space);
        g_layoutManager->setTargetGeom(box, target);
        logRequest(Log::DEBUG, "window {:x} moved by the plugin onto {}: now on its Desktop {}", idOf(w), m->m_name, ws->m_name);
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
        const uint64_t address = minimize::parseAddress(addressText).value_or(0); // 0 is never a window
        const auto     window  = address != 0 ? windowById(address) : nullptr;
        if (!window) {
            logRequest(Log::WARN, "tile: rejected: no such window");
            return;
        }
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

    void groupFrontRequest(std::string_view addressText) {
        auto& s = st();
        if (gf::deferredFocus::sessionLocked()) {
            logRequest(Log::INFO, "group_front: refused: the session is locked");
            notify(tiling::Reason::Locked);
            return;
        }
        const uint64_t address = minimize::parseAddress(addressText).value_or(0); // 0 is never a window
        const auto     w       = address != 0 ? windowById(address) : nullptr;
        if (!w) {
            logRequest(Log::WARN, "group_front: rejected: not a live window");
            notify(tiling::Reason::Invalid);
            return;
        }
        if (!Desktop::windowState())
            return;
        std::vector<uint64_t> stack; // the windows on screen, bottom to top: a minimized or hidden one is on a special workspace
        for (const auto& o : Desktop::windowState()->windows()) {
            if (o && o->m_isMapped && !o->isHidden() && o->m_workspace && !o->m_workspace->m_isSpecialWorkspace)
                stack.push_back(idOf(o));
        }
        const auto order = tiling::groupRaiseOrder(s.book.records(), idOf(w), stack);
        for (const auto id : order) {
            const auto member = windowById(id);
            if (!member)
                continue;
            if (const auto result = Config::Actions::alterZOrder("top", member); !result)
                logRequest(Log::WARN, "group_front: raising {:x} failed: {}", id, result.error().message);
        }
        if (!order.empty())
            logRequest(Log::DEBUG, "group_front {:x}: {} member(s) brought forward", idOf(w), order.size());
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
        // A pick of the suggestions (TL28): the window whose layout the zone belongs to, still tiled in that layout.
        const auto asker = request->with ? windowById(*request->with) : nullptr;
        if (request->with) {
            const auto* r = asker ? s.book.find(*request->with) : nullptr;
            if (!r || r->state != tiling::TileState::Tiled || r->where.layout != request->layout) {
                refuse("with is not a window tiled in that layout (tiling.md TL28)");
                return;
            }
        }
        std::vector<PHLWINDOW> windows;
        for (const auto address : request->windows) {
            const auto w = windowById(address);
            if (!w) {
                refuse("a window is not a live tileable window (tiling.md TL9)");
                return;
            }
            windows.push_back(w);
        }
        // The output is the one the windows are on (under their middle), whatever Desktop Hyprland still records for them; for
        // a pick, the one of the window that asked: the picked window may wait on special:minimized (D27).
        const auto here = monitorOf(asker ? asker : windows.front());
        const auto m    = request->output.empty() ? here : monitorByName(request->output);
        if (!m) {
            refuse("the output is unknown");
            return;
        }
        if (here != m) {
            refuse(std::format("the {} window is on {}, not on {} (D3)", asker ? "asking" : "first", here ? here->m_name : "no output", m->m_name));
            return;
        }
        // A pick may be a window minimized from that output (D27): restored first, once every check passed.
        const auto minimized = asker ? gf::minimizer::minimizedFrom(m->m_name) : std::vector<uint64_t>{};
        const bool restoring = asker && std::ranges::find(minimized, idOf(windows.front())) != minimized.end() && tileableKind(windows.front());
        for (const auto& w : windows) {
            if (!restoring && !placeable(w)) {
                refuse("a window is not a live tileable window (tiling.md TL9)");
                return;
            }
        }
        // Every check before anything moves (ADR-0007: a refusal changes nothing).
        if (showsSpecial(m) || !m->m_activeWorkspace) {
            refuse(std::format("{} shows a special workspace or no Desktop (TL9)", m->m_name));
            return;
        }
        for (const auto& w : windows) {
            if (!restoring && monitorOf(w) != m) {
                refuse(std::format("the windows are not all on {}", m->m_name));
                return;
            }
        }
        // The records first (a tile moved by other means is freed, a deferred one placed), so that a pick is checked against
        // them before anything of this request moves: its minimized window is restored only once the pick passed (ADR-0007).
        catchUp();
        if (request->with) {
            const auto* r = s.book.find(*request->with);
            if (!r || r->state != tiling::TileState::Tiled || r->where.layout != request->layout) {
                refuse("with is not a window tiled in that layout any more");
                return;
            }
            if (r->output != m->m_name || r->workspace != m->m_activeWorkspace->m_id) {
                refuse("the asking window's tile is not on that output's Desktop");
                return;
            }
            const int  zone = request->zone.value_or(-1); // parseArrange: with comes with a zone
            const auto held = tiling::zonesHeld(s.book.records(), *r);
            if (std::ranges::find(held, zone) != held.end()) {
                refuse(std::format("zone {} of {} is held", zone, request->layout));
                return;
            }
        }
        // Then a minimized pick comes back to that output's Desktop (no Dock animation: it appears in its zone), and each window
        // takes the Desktop of the output it is on (D9), whatever moved it there: the plugin's titlebar drag, or a move
        // Hyprland's own action makes without changing the Desktop (Actions::move).
        if (restoring) {
            gf::minimizer::restore(idOf(windows.front()), std::nullopt);
            if (!placeable(windows.front()) || monitorOf(windows.front()) != m) {
                refuse("the minimized window did not come back on that output (its restore failed)");
                return;
            }
        }
        for (const auto& w : windows)
            followOutput(w);
        const auto workspace = m->m_activeWorkspace;
        for (const auto& w : windows) {
            if (w->m_workspace != workspace) { // followOutput gives every placeable window that Desktop: never expected
                refuse(std::format("{} shows Desktop {}, a window stayed on Desktop {}", m->m_name, workspace->m_name, w->m_workspace ? w->m_workspace->m_name : "none"));
                return;
            }
        }
        const auto*               layout = tiling::layoutById(request->layout); // parseArrange checked the id
        std::vector<int>          zoneIndex;
        std::vector<tiling::Zone> zones;
        zoneIndex.reserve(layout->zones.size());
        zones.reserve(layout->zones.size());
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
        // The windows placed together form a tile group (TL6, T1d); one window alone has none; a pick joins the asker's (TL28).
        const uint64_t group = request->with ? s.book.joinGroup(*request->with) : windows.size() >= 2 ? s.book.newGroup() : 0;
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
        // TL28: the zones left empty in that layout, offered to the shell in the state reply until the next change.
        s.suggestion = suggestionFor(request->with ? *request->with : idOf(windows.front()), m);
        logRequest(Log::DEBUG, "arrange: {} with {} window(s) on {}{}", layout->id, windows.size(), m->m_name,
                   s.suggestion ? std::format(", {} zone(s) to suggest", s.suggestion->zones.size()) : "");
        notify(tiling::Reason::Placed);
    }

    void marginsChanged() {
        relayout(ERelayout::Margins);
    }

    std::string stateReply() {
        auto& s = st();
        reconcile(); // records only: the reply never moves a window (deferred ones are placed at the next tiling action)
        const auto                       all = monitors();
        std::vector<tiling::StateOutput> outputs;
        outputs.reserve(all.size());
        for (const auto& m : all) {
            const auto area = areaFor(m);
            const CBox box  = m->logicalBox();
            tiling::StateOutput o{.name = m->m_name, .area = area.box, .outputClass = tiling::classify(box.w, box.h), .grid = area.grid.step, .windows = {}};
            for (const auto& r : s.book.records()) {
                if (r.output == m->m_name)
                    o.windows.push_back(&r);
            }
            outputs.push_back(std::move(o));
        }
        // TL28: the suggestion while nothing changed since; a window closed meanwhile is left out.
        std::optional<tiling::Suggestion> suggestion;
        if (s.suggestion && s.suggestion->generation == s.book.generation()) {
            suggestion = *s.suggestion;
            std::erase_if(suggestion->windows, [](uint64_t id) { return !windowById(id); });
            if (suggestion->windows.empty())
                suggestion.reset();
        }
        return tiling::stateJson(s.book.generation(), outputs, suggestion ? &*suggestion : nullptr);
    }

    void beforePointerMotion() {
        auto& s = st();
        if (!s.ready || !g_layoutManager)
            return;
        if (s.edge) {
            edgeMotion(); // TL30: the plugin's own drag (Hyprland has none)
            return;
        }
        const auto& drag = g_layoutManager->dragController();
        if (!drag || !hyprlandDrag(drag->mode())) {
            if (s.resizing.lock())
                finishResize(); // the drag ended without a release seen here
            if (s.drag.hyprland)
                dragDone(); // likewise the preview of a move
            edgeHover();
            return;
        }
        s.edgeCursor = false; // a drag of Hyprland's set its own special-action cursor in place of the handle's
        const auto target = drag->target();
        const auto w      = target ? target->window() : nullptr;
        if (drag->mode() == MBIND_MOVE) {
            hyprlandMove(w, target);
            return;
        }
        if (s.drag.hyprland)
            dragDone(); // a resize now: no move preview
        const auto r = w ? s.book.find(idOf(w)) : nullptr;
        if (r && r->state == tiling::TileState::Tiled && s.book.beginResize(idOf(w)))
            s.resizing = w;
    }

    bool beforePointerButton(uint32_t button, bool pressed, uint32_t timeMs) {
        auto& s = st();
        if (!s.ready || !g_layoutManager || !g_pInputManager)
            return false;
        const Vector2D pointer = g_pInputManager->getMouseCoordsInternal();
        // TL30: the shared edge's handle takes a plain left press and its release (both cancelled: Hyprland's held-button
        // state stays as it was, ADR-0015 P6). A left press while a release is still owed means that release was lost (a
        // device gone): the drag ends and nothing more is cancelled for it.
        if (button == BTN_LEFT && pressed && std::exchange(s.edgeReleaseOwed, false))
            edgeEnd("its release was not seen");
        if (button == BTN_LEFT && !pressed && std::exchange(s.edgeReleaseOwed, false)) {
            edgeEnd("released");
            return true;
        }
        if (button == BTN_LEFT && pressed && edgePress(pointer))
            return true;
        if (pressed) {
            if (button == BTN_LEFT) {
                s.press   = pointer;
                s.pressMs = timeMs;
            }
            return false;
        }
        if (s.resizing.lock())
            scheduleAfter(); // ends Resizing once Hyprland ended its drag (afterEvents)
        if (button != BTN_LEFT)
            return false;
        const auto  grip   = std::exchange(s.press, std::nullopt);
        const auto& drag   = g_layoutManager->dragController();
        const auto  mode   = drag ? drag->mode() : MBIND_INVALID;
        const auto  target = drag && hyprlandDrag(mode) ? drag->target() : nullptr;
        const auto  w      = target ? target->window() : nullptr;
        if (!w)
            return false;
        if (mode == MBIND_MOVE) {
            // TL16: tiled once Hyprland ended the drag; the top clamp leaves the window to it (the tile lies below the menu
            // bar), as it does a tiled window put back in its tile.
            const auto shown = previewOf(w);
            const auto r     = s.book.find(idOf(w));
            if (shown || (r && r->state == tiling::TileState::Tiled))
                gf::topClamp::skip(w);
            s.moveRelease = SMoveRelease{.window = w, .snap = shown};
            scheduleAfter();
            return false;
        }
        // A resize begun at the press and released where it began: a click on the window's resize border (TL20).
        if (grip && !gf::titlebar::exceedsDragThreshold(pointer.x - grip->x, pointer.y - grip->y))
            borderClick(w, *grip, s.pressMs);
        return false;
    }

} // namespace gf::tiler
