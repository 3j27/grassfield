#include "Titlebar.hpp"

#include "ClientChrome.hpp"
#include "DeferredFocus.hpp"
#include "Ipc.hpp"
#include "Plugin.hpp"
#include "Stages.hpp"
#include "Tiling.hpp"
#include "TopClamp.hpp"
#include "core/ClientChrome.hpp"
#include "core/PointerGesture.hpp"
#include "core/Protocol.hpp"
#include "core/Theme.hpp"

#include <hyprland/src/config/ConfigValue.hpp>
#include <hyprland/src/config/shared/actions/ConfigActions.hpp>
#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/desktop/state/ViewHitTester.hpp>
#include <hyprland/src/desktop/state/ViewState.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/LayerSurface.hpp>
#include <hyprland/src/desktop/view/WLSurface.hpp>
#include <hyprland/src/devices/IKeyboard.hpp>
#include <hyprland/src/layout/LayoutManager.hpp>
#include <hyprland/src/layout/supplementary/DragController.hpp>
#include <hyprland/src/layout/target/Target.hpp>
#include <hyprland/src/managers/SessionLockManager.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/protocols/LayerShell.hpp>
#include <hyprland/src/protocols/XDGShell.hpp>
#include <hyprland/src/protocols/core/Compositor.hpp>
#include <hyprland/src/protocols/core/DataDevice.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/decorations/DecorationPositioner.hpp>
#include <hyprland/src/render/pass/RectPassElement.hpp>
#include <hyprland/src/render/pass/TexPassElement.hpp>

#include <drm_fourcc.h>
#include <linux/input-event-codes.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <format>
#include <optional>
#include <string_view>
#include <utility>
#include <vector>

namespace tb    = gf::titlebar;
namespace theme = gf::theme;

namespace {
    // Higher priority = evaluated first by the positioner = closer to the window. Above the border's
    // priority so the border (and its rounded corners) wraps titlebar + content as one window.
    // Measured in S2: at 10000 the bar was placed outside the border.
    constexpr uint32_t DECORATION_PRIORITY = 10005;

    // The single pointer gesture started on a titlebar (there is one seat pointer). Its lifetime and
    // the ownership of pressed buttons are decided by the press tracker (core/PointerGesture.*).
    struct SPointerGrab {
        CGrassfieldTitlebar*      deco = nullptr; // checked against state().titlebars before use
        std::optional<tb::Button> button;         // pressed button, activated on release over the same button
        bool                      dragging = false;
        bool                      moved    = false; // the pointer passed kDragThreshold: the window follows it
        bool                      unzoom   = false; // pressed on a maximized window: un-zoom it when the move starts
        CBox                      zoomedSurface;    // surface box of that maximized window at the press
        bool                      untile   = false; // pressed on a tiled window: its size from before comes back when the move starts
        PHLWINDOWREF              window;   // window being moved (its tiling preview: gf::tiler::previewOf)
        Vector2D                  pressPos; // pointer at press (global logical)
        CBox                      startBox; // window layout box at press
        CBox                      pressBox; // the same, never changed by an un-zoom or un-tile (a drop on the Stages strip gives it back)
        bool                      plainPress = false; // pressed on a window that was neither zoomed nor tiled
        bool                      unmovable  = false; // the window closed or unmapped during the drag (logged once, gate C1)
        std::vector<WP<IPointer>> devices;  // pointer devices present at the press
    };

    struct SPointerInput {
        SPointerGrab                      grab;
        gf::input::CPointerGestureTracker presses;
        CGrassfieldTitlebar*              hovered = nullptr; // lights under the pointer (glyphs); checked with isLive
        PHLWINDOWREF                      activeWindow;      // last window reported active (its lights are coloured)
        gf::chrome::CRevealPresses        revealPresses;     // presses on a revealed full-screen titlebar (P6)
        gf::chrome::CHeldButtons          heldButtons;       // the buttons Hyprland holds, as the bus shows them (P6)
        CGrassfieldTitlebar*              revealArmed = nullptr; // its light pressed, activated on release over it
        std::optional<tb::Button>         revealLight;
    };

    bool sessionLocked() {
        return !g_pSessionLockManager || g_pSessionLockManager->isSessionLocked(); // undecidable: locked (failures stay locked)
    }

    // The shell's menu bar (a layer of that namespace on the monitor): a revealed full-screen titlebar starts below it.
    constexpr std::string_view kMenubarNamespace = "grassfield-menubar";
    constexpr double           kMaxMenubarInset  = 64.0; // a larger layer of that name is not a menu bar: the bar stays at the top

    double menubarInset(const PHLMONITOR& mon) {
        if (!mon)
            return 0.0;
        for (const auto& level : mon->m_layerSurfaceLayers) {
            for (const auto& ref : level) {
                const auto ls = ref.lock();
                if (ls && ls->m_mapped && ls->m_namespace == kMenubarNamespace)
                    return ls->m_geometry.h > 0.0 && ls->m_geometry.h <= kMaxMenubarInset ? ls->m_geometry.h : 0.0;
            }
        }
        return 0.0;
    }

    // A surface drawn over a revealed full-screen titlebar takes its own presses: a layer popup (the menu bar's menus) or
    // an Overlay layer (a dialog, the menu bar itself), as Hyprland orders pointer focus (CInputManager::mouseMoveUnified).
    bool overlaySurfaceAt(const Vector2D& pos, const PHLMONITOR& mon) {
        if (!mon || !Desktop::viewState())
            return false;
        Vector2D local;
        PHLLS    layer;
        if (Desktop::viewState()->hitTest().layerPopupSurfaceAt(pos, mon, &local, &layer))
            return true;
        return Desktop::viewState()->hitTest().layerSurfaceAt(pos, &mon->m_layerSurfaceLayers[ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY], &local, &layer) != nullptr;
    }

    // Constructed on first use, inside a guarded call, so a throwing constructor cannot escape (R13).
    SPointerInput& pointerInput() {
        static SPointerInput input;
        return input;
    }

    bool isLive(const CGrassfieldTitlebar* deco) {
        const auto& all = gf::state().titlebars;
        return deco && std::ranges::find(all, deco) != all.end();
    }

    CHyprColor toColor(const theme::Rgba& c, float alpha = 1.F) {
        return CHyprColor{c.r, c.g, c.b, c.a * alpha};
    }

    void addRect(const CBox& box, const CHyprColor& color, int round, float roundingPower, const CBox& clip = {}) {
        CRectPassElement::SRectData data;
        data.box           = box;
        data.color         = color;
        data.round         = round;
        data.roundingPower = roundingPower;
        data.clipBox       = clip;
        g_pHyprRenderer->addPassElement(makeUnique<CRectPassElement>(data));
    }

    // A rect over Hyprland's blur of what is already drawn behind it (live blur, not xray: the windows behind count), under
    // `tint`: the blurred material (owner decision D-8). Hyprland's own path (CRectPassElement with blur, as its group bars
    // and other decorations use it); with Hyprland's blur disabled in the config it is drawn as the plain tint.
    void addBlurredRect(const CBox& box, const CHyprColor& tint, int round, float roundingPower, float blurAlpha) {
        CRectPassElement::SRectData data;
        data.box           = box;
        data.color         = tint;
        data.round         = round;
        data.roundingPower = roundingPower;
        data.blur          = true;
        data.xray          = false;
        data.blurA         = blurAlpha;
        g_pHyprRenderer->addPassElement(makeUnique<CRectPassElement>(data));
    }

    const char* hitName(tb::HitTarget hit) {
        switch (hit) {
            case tb::HitTarget::None: return "none";
            case tb::HitTarget::Close: return "close";
            case tb::HitTarget::Minimize: return "minimize";
            case tb::HitTarget::Zoom: return "zoom";
            case tb::HitTarget::DragArea: return "drag-area";
        }
        return "?";
    }

    void logIfFailed(std::string_view action, const Config::Actions::ActionResult& result) {
        if (!result)
            gf::logRequest(Log::WARN, "titlebar {} failed: {}", action, result.error().message);
    }

    // The minimize path, shared by the minimize button and a double-click set to "minimize": the shell owns
    // the Dock tile rectangle, so it is asked to minimize (it answers with hl.plugin.grassfield.minimize, or
    // parks the window on special:minimized itself when the plugin lacks the feature). Clicks can come from a
    // virtual pointer at any rate: the request is coalesced per window (spec FR24).
    void requestMinimize(const PHLWINDOW& w) {
        gf::ipc::postMinimizeRequest(reinterpret_cast<uintptr_t>(w.get()));
    }

    // The one zoom toggle, shared by the zoom button and the double-click on the drag area.
    void toggleZoom(const PHLWINDOW& w) {
        auto& fs = Fullscreen::controller();
        if (!fs)
            return;
        const auto current = fs->getFullscreenModes(w).internal;
        const auto target  = current == Fullscreen::FSMODE_MAXIMIZED ? Fullscreen::FSMODE_NONE : Fullscreen::FSMODE_MAXIMIZED;
        fs->setFullscreenMode(w, target, target, false);
    }

    Fullscreen::eFullscreenMode fullscreenMode(const PHLWINDOW& w) {
        const auto& fs = Fullscreen::controller();
        return fs ? fs->getFullscreenModes(w).internal : Fullscreen::FSMODE_NONE;
    }

    // Alt (Option) held on any keyboard.
    bool altHeld() {
        return g_pInputManager && (g_pInputManager->getModsFromAllKBs() & HL_MODIFIER_ALT) != 0;
    }

    // The zoom light (ADR-0015 P6, REQ-ADR0002-6): zoom (maximized) and back; with Alt held, true full screen (the shell
    // hides the menu bar as in any full screen); a window in full screen leaves it.
    void zoomLight(const PHLWINDOW& w) {
        auto& fs = Fullscreen::controller();
        if (!fs)
            return;
        const auto mode = fullscreenMode(w);
        switch (gf::chrome::zoomAction(mode == Fullscreen::FSMODE_MAXIMIZED, mode == Fullscreen::FSMODE_FULLSCREEN, altHeld())) {
            case gf::chrome::ZoomAction::EnterFullscreen:
                gf::logRequest(Log::DEBUG, "titlebar zoom with Alt -> full screen");
                fs->setFullscreenMode(w, Fullscreen::FSMODE_FULLSCREEN, Fullscreen::FSMODE_FULLSCREEN, false);
                break;
            case gf::chrome::ZoomAction::LeaveFullscreen: fs->setFullscreenMode(w, Fullscreen::FSMODE_NONE, Fullscreen::FSMODE_NONE, false); break;
            case gf::chrome::ZoomAction::Zoom:
            case gf::chrome::ZoomAction::Unzoom: toggleZoom(w); break;
        }
    }

    // A move that starts on a maximized window: leave the maximized mode first (the layout gives the window
    // back its floating size), then place that size under the pointer (macOS). Moving the maximized box
    // itself would write it into the floating geometry the zoom toggle restores (FR8 regression, 2026-10-17).
    // Measured in 0.56.2: a floating window's layout box is its surface box, a maximized one's is the work
    // area (decorations included), hence the surface box recorded at the press as the reference.
    void unzoomUnderPointer(SPointerGrab& grab, const PHLWINDOW& w, const SP<Layout::ITarget>& target, const Vector2D& pointer) {
        gf::tiler::leave(w); // a tile kept while zoomed (tiling.md TL12) ends: the window leaves under the pointer
        if (fullscreenMode(w) == Fullscreen::FSMODE_MAXIMIZED)
            toggleZoom(w);
        const CBox  restored = target->position();
        const CBox& zoomed   = grab.zoomedSurface;
        const auto  box      = tb::unzoomedDragBox(tb::Rect{zoomed.x, zoomed.y, zoomed.w, zoomed.h}, restored.w, restored.h, grab.pressPos.x, grab.pressPos.y, pointer.x, pointer.y);
        gf::logRequest(Log::DEBUG, "titlebar drag un-zooms: restored {:.0f}x{:.0f} at {:.0f},{:.0f}", box.w, box.h, box.x, box.y);
        grab.startBox = CBox{box.x, box.y, box.w, box.h};
        grab.pressPos = pointer;
        grab.unzoom   = false;
    }

    // A move that starts on a tiled window gives it back its size from before tiling, under the pointer at the same
    // relative place on the titlebar (macOS), like the un-zoom above. Its tile record is Moving until the release
    // (docs/specs/tiling.md TL10): a release in a drag zone tiles it again with the same box from before, elsewhere it is Free.
    void untileUnderPointer(SPointerGrab& grab, const PHLWINDOW& w, const SP<Layout::ITarget>& target, const Vector2D& pointer) {
        grab.untile        = false;
        const auto before = gf::tiler::beginMove(w);
        if (!before)
            return;
        const CBox tiled = target->position();
        const auto box   = tb::unzoomedDragBox(tb::Rect{tiled.x, tiled.y, tiled.w, tiled.h}, before->w, before->h, grab.pressPos.x, grab.pressPos.y, pointer.x, pointer.y);
        gf::logRequest(Log::DEBUG, "titlebar drag leaves the tile: {:.0f}x{:.0f} at {:.0f},{:.0f}", box.w, box.h, box.x, box.y);
        grab.startBox = CBox{box.x, box.y, box.w, box.h};
        grab.pressPos = pointer;
    }

    // Hyprland's general:snap:enabled, read at each step (a configuration reload may change it).
    bool snapEnabled() {
        const CConfigValue<Config::INTEGER> enabled("general:snap:enabled");
        return enabled.good() && *enabled != 0;
    }

    // Interactive move driven by the plugin: the window follows the pointer from the press point.
    // S2 history: with CLayoutManager::beginDragTarget and CKeybindManager::changeMouseBindMode the window
    // jumped by (window middle - press point). The cause was most likely Config::Actions::focus() warping
    // the cursor to the window middle before the drag started (found afterwards, now avoided in
    // focusAndRaise). Away from a tiling place the window snaps as in Hyprland's own move (tiling.md TL19).
    // Nothing moves until the pointer has passed kDragThreshold: a click (or the first click of a
    // double-click) never writes the window geometry.
    void updateMove(SPointerGrab& grab) {
        const auto w = grab.window.lock();
        if (!w || !g_layoutManager || !g_pInputManager)
            return;
        const auto target = w->layoutTarget();
        if (!target || !gf::tiler::movable(w)) {
            // Closed or unmapped during the drag: no Desktop, no layout space (gate C1). The line is what tiling.sh's C1 cases
            // look for: the risky state was reached and nothing was moved.
            if (!std::exchange(grab.unmovable, true))
                gf::logRequest(Log::INFO, "titlebar drag: window {:x} closed or unmapped during the drag: not moved (gate C1)",
                               reinterpret_cast<uintptr_t>(w.get()));
            return;
        }
        const Vector2D pointer = g_pInputManager->getMouseCoordsInternal();
        if (!grab.moved && !tb::exceedsDragThreshold(pointer.x - grab.pressPos.x, pointer.y - grab.pressPos.y))
            return;
        grab.moved = true;
        if (grab.unzoom)
            unzoomUnderPointer(grab, w, target, pointer);
        else if (grab.untile)
            untileUnderPointer(grab, w, target, pointer);
        CBox box = grab.startBox;
        box.translate(pointer - grab.pressPos);
        // TL19: away from a tiling place the window snaps to the outputs' edges and to the other windows as Hyprland's own
        // move does (the public CLayoutManager::performSnap with the general:snap values), so every drag behaves alike.
        if (!gf::tiler::snapFor(w, pointer) && snapEnabled()) {
            Vector2D pos  = box.pos();
            Vector2D size = box.size();
            g_layoutManager->performSnap(pos, size, target, MBIND_MOVE, -1, grab.startBox.size());
            box = CBox{pos.round(), size};
        }
        // The titlebar stops at the menu bar while the pointer goes on, and follows it again on the way down (macOS).
        box = gf::topClamp::heldMove(w, box, pointer);
        g_layoutManager->setTargetGeom(box, target);
        gf::tiler::dragMotion(w, pointer); // the place under the pointer, shown after the preview delay (TL17)
    }

    std::vector<WP<IPointer>> pointerDevices() {
        std::vector<WP<IPointer>> devices;
        if (g_pInputManager) {
            for (const auto& device : g_pInputManager->m_pointers)
                devices.emplace_back(device);
        }
        return devices;
    }

    // Every pointer device present at the press still exists. Hyprland 0.56.2 does not release the
    // buttons of a pointer device that goes away (CInputManager::destroyPointer), so a vanished device
    // means the gesture's release may never arrive.
    bool devicesIntact(const std::vector<WP<IPointer>>& devices) {
        if (!g_pInputManager)
            return false;
        const auto& present = g_pInputManager->m_pointers;
        return std::ranges::all_of(devices, [&present](const WP<IPointer>& device) {
            const auto alive = device.lock();
            return alive && std::ranges::find(present, alive) != present.end();
        });
    }

    // Focus without Config::Actions::focus(): that action warps the cursor to the window middle when the
    // pointer is outside the client surface (measured in S2), which breaks clicks and drags on the bar.
    // Whether the window holds the keyboard decides, not whether Hyprland counts it active: after a session
    // unlock with the pointer off the windows, Hyprland still counts its last window active while the keyboard
    // is on no surface (tests/compositor/click_focus.sh).
    void focusAndRaise(const PHLWINDOW& w) {
        if (!gf::deferredFocus::windowHoldsKeyboard(w))
            gf::deferredFocus::focusWindow(w, Desktop::FOCUS_REASON_CLICK);
        logIfFailed("raise", Config::Actions::alterZOrder("top", w));
    }

    // A window drawn where it is, taking input: no overview or Stages transform, no input block. Only such a window
    // shows hover glyphs (a transformed window is drawn away from where the pointer hovers its real lights).
    bool drawnInPlace(const PHLWINDOW& w) {
        return w && w->m_transformers.empty() && !w->isInputBlocked();
    }

    // The titlebar whose lights are under the pointer, on the topmost window there. Plain geometry over Hyprland's window
    // list, walked from the top (the stacking order `hyprctl clients` reports): the first mapped window on a visible
    // workspace whose surface or titlebar contains the pointer decides. Hyprland's hit tester is not used here: calling
    // CViewHitTester::windowAt from this motion listener cost Qt and GTK4 windows their keyboard enter on a titlebar click
    // (tests/compositor/click_focus.sh clients, 2026-10-22: 13/15 with it, 15/15 without).
    CGrassfieldTitlebar* titlebarHoveredAt(const Vector2D& pos) {
        const auto& all = gf::state().titlebars;
        if (all.empty() || !Desktop::windowState())
            return nullptr;
        // A revealed full-screen titlebar is drawn over every window (P6).
        for (auto* deco : all) {
            if (deco->revealed() && deco->barContains(pos))
                return deco->buttonGroupContains(pos) ? deco : nullptr;
        }
        const auto& windows = Desktop::windowState()->windows();
        for (auto it = windows.rbegin(); it != windows.rend(); ++it) {
            const auto& w = *it;
            if (!w || !w->m_isMapped || w->isHidden() || !w->m_workspace || !w->m_workspace->isVisible())
                continue;
            const auto deco  = std::ranges::find_if(all, [&w](const CGrassfieldTitlebar* d) { return d->window() == w; });
            const bool onBar = deco != all.end() && (*deco)->barContains(pos);
            if (!onBar && !w->getWindowMainSurfaceBox().containsPoint(pos))
                continue; // not under the pointer: a window further down may be
            return onBar && drawnInPlace(w) && (*deco)->buttonGroupContains(pos) ? *deco : nullptr;
        }
        return nullptr;
    }

    // Pointer motion: the glyphs follow the pointer onto and off the lights. Only the titlebars that change are damaged.
    void updateHover() {
        auto& input = pointerInput();
        auto* now   = g_pInputManager ? titlebarHoveredAt(g_pInputManager->getMouseCoordsInternal()) : nullptr;
        auto* was   = input.hovered;
        if (now == was)
            return;
        input.hovered = now;
        if (isLive(was))
            was->damageEntire();
        if (now)
            now->damageEntire();
    }
} // namespace

CGrassfieldTitlebar::CGrassfieldTitlebar(const PHLWINDOW& window) : IHyprWindowDecoration(window), m_owner(window) {
    gf::state().titlebars.push_back(this);
    m_lastShown = shouldShow();
}

CGrassfieldTitlebar::~CGrassfieldTitlebar() {
    std::erase(gf::state().titlebars, this);
    gf::forgetRegisteredDecoration(this);
    gf::guarded("titlebar destructor", [this] {
        auto& input = pointerInput();
        if (input.hovered == this)
            input.hovered = nullptr;
        if (input.revealArmed == this) {
            input.revealArmed = nullptr;
            input.revealLight.reset();
        }
        if (input.grab.deco == this) {
            // The window is going away: drop the gesture (and redraw where its tiling preview was). The press ownership
            // stays, so the release that will still arrive is not mistaken for a client's (another titlebar under the
            // pointer consumes it; elsewhere the seat drops it, as the client never saw the press).
            if (input.grab.dragging)
                gf::tiler::dragDone();
            input.grab = {};
            input.presses.dropGesture();
        }
    });
}

PHLWINDOW CGrassfieldTitlebar::window() const {
    return m_owner.lock();
}

bool CGrassfieldTitlebar::titlebarAllowed() const {
    const auto w = window();
    if (!w || !w->m_isMapped || w->isHidden())
        return false;
    if (w->m_isX11 && (w->isX11OverrideRedirect() || w->m_X11DoesntWantBorders))
        return false;
    if (w->m_ruleApplicator && !w->m_ruleApplicator->decorate().valueOrDefault())
        return false;
    return !gf::chrome::isClientChrome(w); // the app draws its own lights and toolbar (ADR-0015 P1)
}

bool CGrassfieldTitlebar::shouldShow() const {
    const auto w = window();
    if (!w || !w->m_isFloating || !titlebarAllowed())
        return false;
    if (const auto& fs = Fullscreen::controller(); fs && fs->getFullscreenModes(w).internal == Fullscreen::FSMODE_FULLSCREEN)
        return false; // away; the pointer at the top edge reveals it (P6, revealable)
    return true;
}

bool CGrassfieldTitlebar::revealable() const {
    const auto w = window();
    if (!w || !w->m_workspace || !w->m_workspace->isVisible())
        return false;
    const auto& fs = Fullscreen::controller();
    if (!fs || fs->getFullscreenModes(w).internal != Fullscreen::FSMODE_FULLSCREEN)
        return false;
    if (sessionLocked())
        return false; // every press is the lock screen's
    // The pointer belongs to the client (review of part B, major 2): a pointer it confines or locks (a game that scrolls at
    // the screen's edge: pushing up there and clicking the corner hit a working close light), a move or resize it started
    // (or a key binding's), a drag and drop.
    if (g_pInputManager && g_pInputManager->isConstrained())
        return false;
    if (g_layoutManager) {
        if (const auto& drag = g_layoutManager->dragController(); drag && drag->mode() != MBIND_INVALID)
            return false;
    }
    if (PROTO::data && PROTO::data->dndActive())
        return false;
    // A special workspace shown on the monitor is drawn above the full-screen window: the bar would be under its windows.
    if (const auto mon = w->m_monitor.lock(); mon && mon->m_activeSpecialWorkspace && mon->m_activeSpecialWorkspace != w->m_workspace)
        return false;
    return drawnInPlace(w) && titlebarAllowed();
}

bool CGrassfieldTitlebar::revealed() const {
    return m_revealed;
}

SDecorationPositioningInfo CGrassfieldTitlebar::getPositioningInfo() {
    SDecorationPositioningInfo info;
    info.policy   = DECORATION_POSITION_STICKY;
    info.edges    = DECORATION_EDGE_TOP;
    info.priority = DECORATION_PRIORITY;
    info.reserved = true;
    gf::guarded("titlebar getPositioningInfo", [&] {
        m_lastShown         = shouldShow();
        info.desiredExtents = SBoxExtents{.topLeft = Vector2D{0.0, m_lastShown ? theme::kTitlebarHeight : 0.0}, .bottomRight = Vector2D{0.0, 0.0}};
    });
    return info;
}

void CGrassfieldTitlebar::onPositioningReply(const SDecorationPositioningReply& /*reply*/) {
    // The assigned box is read back from the positioner when needed (layoutBox()).
}

eDecorationType CGrassfieldTitlebar::getDecorationType() {
    return DECORATION_CUSTOM;
}

eDecorationLayer CGrassfieldTitlebar::getDecorationLayer() {
    // Under the window surface: the background also fills the surface's rounded top corners.
    return DECORATION_LAYER_UNDER;
}

uint64_t CGrassfieldTitlebar::getDecorationFlags() {
    return DECORATION_ALLOWS_MOUSE_INPUT | DECORATION_PART_OF_MAIN_WINDOW;
}

std::string CGrassfieldTitlebar::getDisplayName() {
    return "grassfield-titlebar";
}

void CGrassfieldTitlebar::updateWindow(PHLWINDOW /*window*/) {
    gf::guarded("titlebar updateWindow", [this] { refresh(); });
}

void CGrassfieldTitlebar::refresh() {
    const auto w = window();
    if (!w)
        return;
    if (m_revealed && !revealable()) {
        damageRevealed(); // the window left full screen (or its workspace): the revealed bar goes with it
        m_revealed = false;
    }
    const bool show = shouldShow();
    if (show == m_lastShown)
        return;
    m_lastShown = show;
    if (g_pDecorationPositioner)
        g_pDecorationPositioner->repositionDeco(this);
    w->updateWindowDecos();
    if (g_pHyprRenderer)
        g_pHyprRenderer->damageWindow(w);
}

void CGrassfieldTitlebar::onTitleChanged() {
    if (m_title.text == (window() ? window()->m_title : std::string{}))
        return;
    m_title.texture.reset(); // rebuilt lazily in draw()
    damageEntire();
}

CBox CGrassfieldTitlebar::layoutBox() const {
    if (!g_pDecorationPositioner)
        return {};
    // NOLINTNEXTLINE(cppcoreguidelines-pro-type-const-cast): the positioner API is not const-correct
    return g_pDecorationPositioner->getWindowDecorationBox(const_cast<CGrassfieldTitlebar*>(this));
}

CBox CGrassfieldTitlebar::revealBox() const {
    const auto w   = window();
    const auto mon = w ? w->m_monitor.lock() : nullptr;
    if (!w || !mon)
        return {};
    const CBox surface = w->getWindowMainSurfaceBox(); // the monitor's box in full screen
    return CBox{surface.x, mon->m_position.y + menubarInset(mon), surface.w, theme::kTitlebarHeight};
}

CBox CGrassfieldTitlebar::barBox() const {
    return m_revealed ? revealBox() : layoutBox();
}

bool CGrassfieldTitlebar::barShown() const {
    return m_revealed || shouldShow();
}

bool CGrassfieldTitlebar::barContains(const Vector2D& pos) const {
    return barShown() && barBox().containsPoint(pos);
}

bool CGrassfieldTitlebar::buttonGroupContains(const Vector2D& pos) const {
    if (!barShown())
        return false;
    const CBox bar = barBox();
    return tb::overButtonGroup(pos.x - bar.x, pos.y - bar.y, bar.w);
}

void CGrassfieldTitlebar::damageRevealed() {
    if (!m_revealed || !g_pHyprRenderer)
        return;
    CBox box = revealBox();
    g_pHyprRenderer->damageBox(box.expand(2));
}

void CGrassfieldTitlebar::damageEntire() {
    gf::guarded("titlebar damageEntire", [this] {
        const auto w = window();
        if (!w || !g_pHyprRenderer)
            return;
        if (m_revealed) {
            damageRevealed();
            return;
        }
        CBox box = layoutBox();
        box.translate(w->m_floatingOffset);
        g_pHyprRenderer->damageBox(box.expand(2));
    });
}

void CGrassfieldTitlebar::draw(PHLMONITOR monitor, float const& alpha) {
    gf::guarded("titlebar draw", [&] {
        drawPreview(monitor, alpha);
        drawTitlebar(monitor, alpha);
    });
}

// A drag of this window over a tiling place: the place's frame under the window and over the windows behind it (this
// decoration is drawn under the window's surface, after the windows below it), as the blurred material (owner decision D-8,
// macOS's frosted pane): its edge, then a plate of Hyprland's blur of the windows behind under the appearance's tint.
// Cheap: one blurred element, only while a drag shows a place, damage limited to the frame (gf::tiler). Drawn for a window
// whose bar is hidden too: Hyprland's move of a client-chrome window shows the same preview (tiling.md TL16).
void CGrassfieldTitlebar::drawPreview(const PHLMONITOR& monitor, float alpha) {
    const auto w = window();
    if (!w || !monitor || !g_pHyprRenderer)
        return;
    const auto snap = gf::tiler::previewOf(w);
    if (!snap || snap->monitor.lock() != monitor)
        return;
    const float  scale    = monitor->m_scale;
    const double rounding = std::max(0.0, static_cast<double>(w->rounding()));
    const float  power    = w->roundingPower();
    const auto   palette  = theme::titlebarPalette(gf::state().appearance);
    const int    roundPx  = static_cast<int>(std::round(rounding * scale));
    CBox preview = snap->frame;
    preview.translate(-monitor->m_position);
    addRect(preview.scale(scale).round(), toColor(palette.previewRim, alpha), roundPx, power);
    CBox inner = snap->frame;
    inner.translate(-monitor->m_position);
    inner.expand(-theme::kTilePreviewRim);
    addBlurredRect(inner.scale(scale).round(), toColor(palette.previewTint, alpha), std::max(0, roundPx - static_cast<int>(std::round(theme::kTilePreviewRim * scale))),
                   power, alpha);
}

void CGrassfieldTitlebar::drawTitlebar(const PHLMONITOR& monitor, float alpha) {
    const auto w = window();
    if (!w || !monitor || !g_pHyprRenderer || !shouldShow())
        return;

    CBox bar = layoutBox();
    if (bar.w <= 0 || bar.h <= 0)
        return;

    // Follow the window during workspace slides and floating offsets, like Hyprland's own decorations.
    Vector2D offset = w->m_floatingOffset;
    if (w->m_workspace && !w->m_pinned)
        offset = offset + w->m_workspace->m_renderOffset->value();
    bar.translate(offset - monitor->m_position);

    const float  scale    = monitor->m_scale;
    const double rounding = std::max(0.0, static_cast<double>(w->rounding()));
    const float  power    = w->roundingPower();
    const auto   appearance = gf::state().appearance; // follows the shell (config "appearance", audit UX-06)
    const auto   palette    = theme::titlebarPalette(appearance);
    const auto   bgColor    = toColor(palette.background, alpha);

    // 1. The bar (a drag's tiling preview is drawn under it, drawPreview): background, lights and their glyphs, title
    //    (drawBar). The pointer is checked again here: the window may have moved or gone under a pointer that has not moved
    //    since.
    const bool hovered = pointerInput().hovered == this && g_pInputManager && drawnInPlace(w) && buttonGroupContains(g_pInputManager->getMouseCoordsInternal());
    drawBar(w, bar, scale, rounding, power, alpha, hovered, false);

    // 2. The surface's rounded top corners, under the surface: Hyprland cuts them away with the window's rounding, so the
    //    bar colour fills them, then the content's own pixels are drawn there unrounded (macOS: bar and content are one
    //    shape, square where they meet). Where the content is transparent the bar colour stays. Below the bar: nothing
    //    drawBar draws overlaps them.
    if (rounding > 0) {
        CBox left{bar.x, bar.y + bar.h, rounding, rounding};
        CBox right{bar.x + bar.w - rounding, bar.y + bar.h, rounding, rounding};
        addRect(left.scale(scale).round(), bgColor, 0, power);
        addRect(right.scale(scale).round(), bgColor, 0, power);
        drawContentCorners(w, bar, rounding, scale, alpha);
    }
}

void CGrassfieldTitlebar::drawBar(const PHLWINDOW& w, const CBox& bar, float scale, double rounding, float power, float alpha, bool hovered, bool fullscreen) {
    const auto appearance = gf::state().appearance;
    const auto palette    = theme::titlebarPalette(appearance);
    const auto bgColor    = toColor(palette.background, alpha);
    const int  roundPx    = static_cast<int>(std::round(rounding * scale));

    // Background with rounded top corners: a rounded rect taller than the bar, clipped to the bar.
    CBox bgBox   = bar;
    bgBox.h     += 2.0 * rounding;
    CBox clipBox = bar;
    addRect(bgBox.scale(scale).round(), bgColor, roundPx, power, clipBox.scale(scale).round());

    // Buttons (owner-drawn circles): coloured on the active window, grey on the others; coloured again with their glyphs
    // while the pointer is over the group (macOS). On a full-screen window minimize stays grey (unavailable).
    const bool active = Desktop::focusState() && Desktop::focusState()->window() == w;
    for (const auto button : tb::kButtonOrder) {
        const bool available = !fullscreen || gf::chrome::lightAvailableInFullscreen(button);
        const auto r         = tb::buttonRect(button);
        CBox       box{bar.x + r.x, bar.y + r.y, r.w, r.h};
        box.scale(scale).round();
        addRect(box, toColor(tb::lightColor(button, active && available, hovered && available, appearance), alpha), static_cast<int>(std::round(box.w / 2.0)), 2.F);
    }
    if (hovered)
        drawGlyphs(bar, scale, alpha, fullscreen);

    // Title, centered on the bar, never over the buttons.
    const int maxWidthPx = static_cast<int>(std::floor(tb::maxTitleWidth(bar.w) * scale));
    if (w->m_title.empty() || maxWidthPx <= 0)
        return;

    if (!m_title.texture || m_title.text != w->m_title || m_title.scale != scale || m_title.maxWidthPx != maxWidthPx || m_title.appearance != appearance) {
        m_title.texture    = g_pHyprRenderer->renderText(w->m_title, toColor(palette.title), static_cast<int>(std::round(theme::kTitleFontSizePt * scale)), false,
                                                         theme::kTitleFontFamily, maxWidthPx, theme::kTitleFontWeight);
        m_title.text       = w->m_title;
        m_title.scale      = scale;
        m_title.maxWidthPx = maxWidthPx;
        m_title.appearance = appearance;
    }

    const auto& tex = m_title.texture;
    if (!tex || tex->m_size.x <= 0 || tex->m_size.y <= 0)
        return;

    const double texW      = tex->m_size.x / scale;
    const double texH      = tex->m_size.y / scale;
    const auto   placement = tb::placeTitle(bar.w, texW);
    if (!placement.visible)
        return;

    CTexPassElement::SRenderData data;
    data.tex = tex;
    data.box = CBox{bar.x + placement.x, bar.y + ((bar.h - texH) / 2.0), std::min(texW, placement.maxWidth), texH}.scale(scale).round();
    data.a   = alpha;
    g_pHyprRenderer->addPassElement(makeUnique<CTexPassElement>(data));
}

void CGrassfieldTitlebar::drawGlyphs(const CBox& bar, float scale, float alpha, bool fullscreen) {
    for (size_t i = 0; i < tb::kButtonOrder.size(); ++i) {
        const auto button = tb::kButtonOrder[i];
        if (fullscreen && !gf::chrome::lightAvailableInFullscreen(button))
            continue;
        const auto r      = tb::buttonRect(button);
        CBox       box{bar.x + r.x, bar.y + r.y, r.w, r.h};
        box.scale(scale).round(); // the light exactly as drawn above
        const int sizePx = tb::glyphSizePx(static_cast<int>(std::lround(box.w)));
        if (sizePx <= 0)
            continue;

        auto&      glyph  = m_glyphs[i];
        const bool arrows = button == tb::Button::Zoom && gf::chrome::zoomGlyphIsArrows(altHeld(), fullscreen);
        if (!glyph.texture || glyph.sizePx != sizePx || glyph.scale != scale || glyph.arrows != arrows) {
            glyph = {};
            auto pixels = tb::premultipliedBgra(tb::glyphMask(button, sizePx, theme::kGlyphStroke * theme::kButtonDiameter * scale, arrows), theme::kGlyphColor);
            if (pixels.empty())
                continue;
            glyph.texture = g_pHyprRenderer->createTexture(DRM_FORMAT_ARGB8888, pixels.data(), static_cast<uint32_t>(sizePx) * 4U, Vector2D{static_cast<double>(sizePx), static_cast<double>(sizePx)});
            glyph.sizePx  = sizePx;
            glyph.scale   = scale;
            glyph.arrows  = arrows;
        }
        if (!glyph.texture || !glyph.texture->ok())
            continue;

        // glyphSizePx keeps the light's parity: the glyph sits centred on whole pixels.
        CTexPassElement::SRenderData data;
        data.tex = glyph.texture;
        data.box = CBox{box.x + std::floor((box.w - sizePx) / 2.0), box.y + std::floor((box.h - sizePx) / 2.0), static_cast<double>(sizePx), static_cast<double>(sizePx)};
        data.a   = alpha;
        g_pHyprRenderer->addPassElement(makeUnique<CTexPassElement>(data));
    }
}

void CGrassfieldTitlebar::drawContentCorners(const PHLWINDOW& w, const CBox& bar, double rounding, float scale, float alpha) {
    // Only where the surface's texture maps 1:1 onto its box: no overview or Stages transform, no buffer transform, no
    // viewport crop. Elsewhere the bar colour drawn before stays (the former look).
    if (!drawnInPlace(w))
        return;
    const auto view    = w->wlSurface();
    const auto surface = view ? view->resource() : nullptr;
    if (!surface)
        return;
    const auto& state = surface->m_current;
    if (!state.texture || !state.texture->ok() || state.transform != WL_OUTPUT_TRANSFORM_NORMAL || state.viewport.hasSource)
        return;
    // The window's box (right below the bar) is its xdg geometry; the texture starts at the surface's origin, the
    // geometry's offset up-left of it (client-side shadows). XWayland surfaces have no offset.
    Vector2D origin{0.0, 0.0};
    if (!w->m_isX11) {
        const auto xdg = w->m_xdgSurface.lock();
        if (!xdg)
            return;
        origin = xdg->m_current.geometry.pos();
    }
    const tb::Rect texture{.x = bar.x - origin.x, .y = bar.y + bar.h - origin.y, .w = state.size.x, .h = state.size.y};
    const auto     patch = tb::contentCornerPatch(tb::Rect{.x = bar.x, .y = bar.y, .w = bar.w, .h = bar.h}, rounding, texture);
    if (!patch.valid)
        return;

    CBox texBox{texture.x, texture.y, texture.w, texture.h};
    texBox.scale(scale).round();
    for (const auto& square : {patch.left, patch.right}) {
        CBox clip{square.x, square.y, square.w, square.h};
        CTexPassElement::SRenderData data;
        data.tex     = state.texture;
        data.box     = texBox;
        data.clipBox = clip.scale(scale).round();
        data.a       = alpha;
        g_pHyprRenderer->addPassElement(makeUnique<CTexPassElement>(data));
    }
}

void CGrassfieldTitlebar::onActiveWindowChanged(const PHLWINDOW& window) {
    gf::guarded("titlebar onActiveWindowChanged", [&] {
        // Grey or coloured lights: the titlebars of the window that lost the focus and of the one that got it.
        auto&      input    = pointerInput();
        const auto previous = input.activeWindow.lock();
        input.activeWindow  = window;
        for (auto* deco : gf::state().titlebars) {
            const auto w = deco->window();
            if (w && (w == window || w == previous))
                deco->damageEntire();
        }
    });
}

void CGrassfieldTitlebar::onAppearanceChanged() {
    gf::guarded("titlebar onAppearanceChanged", [] {
        for (auto* deco : gf::state().titlebars) {
            deco->m_title.texture.reset(); // the title colour is in its texture: rebuilt on the next draw
            deco->damageEntire();
        }
    });
}

void CGrassfieldTitlebar::onKey() {
    gf::guarded("titlebar onKey", [] {
        // Only the lights under the pointer show glyphs; the frame drawn next reads Alt after Hyprland applied this key.
        if (auto* hovered = pointerInput().hovered; isLive(hovered))
            hovered->damageEntire();
    });
}

bool CGrassfieldTitlebar::onInputOnDeco(const eInputType type, const Vector2D& coords, std::any data) {
    bool consumed = false;
    gf::guarded("titlebar onInputOnDeco", [&] {
        if (type != INPUT_TYPE_BUTTON)
            return;
        const auto* e = std::any_cast<IPointer::SButtonEvent>(&data);
        if (!e)
            return;
        if (e->state == WL_POINTER_BUTTON_STATE_RELEASED) {
            // Only the release of a press a titlebar consumed (offered by onGlobalMouseButton). Hyprland
            // has already cleared its held button when it routes the release here. The release of a
            // press that went to a client is left to Hyprland, which sends it to that client.
            consumed = pointerInput().presses.takeTitlebarRelease(e->button);
            return;
        }
        if (shouldShow())
            consumed = onButtonPress(coords, *e);
    });
    return consumed;
}

bool CGrassfieldTitlebar::onButtonPress(const Vector2D& coords, const IPointer::SButtonEvent& e) {
    const auto w = window();
    if (!w || e.button != BTN_LEFT)
        return false;

    const CBox bar = layoutBox();
    const auto hit = tb::hitTest(coords.x - bar.x, coords.y - bar.y, bar.w);
    gf::logRequest(Log::DEBUG, "titlebar press at {:.1f},{:.1f} bar {:.1f},{:.1f} {:.0f}x{:.0f} -> {}", coords.x, coords.y, bar.x, bar.y, bar.w, bar.h, hitName(hit));
    if (hit == tb::HitTarget::None)
        return false;

    focusAndRaise(w);

    auto& input = pointerInput();
    if (const auto button = tb::buttonForHit(hit)) {
        input.grab         = {};
        input.grab.deco    = this;
        input.grab.button  = button;
        input.grab.devices = pointerDevices();
        input.presses.claim(e.button, true);
        m_clicks.reset();
        return true;
    }

    // Drag area: a double-click does what Settings say (windows.titlebarDoubleClick, pushed by the shell with
    // hl.plugin.grassfield.config): the zoom button's toggle, the minimize button's path, Fill (tiling.md M40), or
    // nothing (the press is then a single press). Otherwise the press starts an interactive move.
    if (m_clicks.press(e.timeMs, coords.x, coords.y)) {
        switch (gf::state().doubleClickAction) {
            case gf::gfc::DoubleClickAction::Zoom:
                gf::logRequest(Log::DEBUG, "titlebar double-click -> toggle zoom");
                toggleZoom(w);
                input.presses.claim(e.button, false); // acts now; its release is still the titlebar's
                return true;
            case gf::gfc::DoubleClickAction::Minimize:
                gf::logRequest(Log::DEBUG, "titlebar double-click -> minimize");
                requestMinimize(w);
                input.presses.claim(e.button, false);
                return true;
            case gf::gfc::DoubleClickAction::Fill:
                gf::logRequest(Log::DEBUG, "titlebar double-click -> fill");
                gf::tiler::tile(w, gf::tiling::Place::Fill);
                input.presses.claim(e.button, false);
                return true;
            case gf::gfc::DoubleClickAction::None: break;
        }
    }

    const auto mode = fullscreenMode(w);
    if (mode != Fullscreen::FSMODE_NONE && mode != Fullscreen::FSMODE_MAXIMIZED) {
        input.presses.claim(e.button, false); // focus and raise only; the release is still the titlebar's
        return true;
    }

    const auto target = w->layoutTarget();
    if (target) {
        input.grab          = {};
        input.grab.deco     = this;
        input.grab.dragging = true;
        input.grab.unzoom   = mode == Fullscreen::FSMODE_MAXIMIZED;
        if (input.grab.unzoom)
            input.grab.zoomedSurface = w->geometricBox(Desktop::View::IGeometric::GEOMETRIC_GOAL);
        input.grab.untile   = !input.grab.unzoom && gf::tiler::isTiled(w);
        input.grab.window   = w;
        input.grab.pressPos = coords;
        input.grab.startBox = target->position();
        input.grab.pressBox   = input.grab.startBox;
        input.grab.plainPress = !input.grab.unzoom && !input.grab.untile;
        input.grab.devices  = pointerDevices();
    }
    input.presses.claim(e.button, target != nullptr);
    return true;
}

void CGrassfieldTitlebar::activate(tb::Button button) {
    const auto w = window();
    if (!w)
        return;

    switch (button) {
        case tb::Button::Close:
            gf::logRequest(Log::DEBUG, "titlebar close");
            logIfFailed("close", Config::Actions::closeWindow(w));
            break;
        case tb::Button::Zoom: gf::logRequest(Log::DEBUG, "titlebar zoom"); zoomLight(w); break;
        case tb::Button::Minimize: gf::logRequest(Log::DEBUG, "titlebar minimize"); requestMinimize(w); break;
    }
}

void CGrassfieldTitlebar::onGlobalMouseButton(const IPointer::SButtonEvent& e) {
    gf::guarded("titlebar onGlobalMouseButton", [&] {
        auto& input = pointerInput();
        if (e.state == WL_POINTER_BUTTON_STATE_PRESSED) {
            // A press while a gesture is active: its release was lost (e.g. the pressing device went away)
            // or another button was pressed. End the gesture where it is; this press goes wherever
            // Hyprland sends it, and its release with it.
            if (input.presses.onPress(e.button)) {
                gf::logRequest(Log::DEBUG, "titlebar gesture cancelled by a new press (button {:#x})", e.button);
                if (input.grab.dragging)
                    gf::tiler::dragDone(); // no preview, no tile
                gf::tiler::endMove(input.grab.window.lock()); // a tiled window dragged away is Free
                if (input.grab.moved)
                    gf::tiler::followOutput(input.grab.window.lock());
                input.grab = {};
            }
            return;
        }

        // The release is never cancelled. Hyprland 0.56.2 records every press as held, also one a titlebar
        // consumes (CInputManager::onMouseButton adds the button to m_currentlyHeldButtons before
        // processMouseDownNormal offers the press to the decorations), and while a button is held it keeps
        // pointer focus on the surface that has it. A cancelled release returns before the button is
        // removed: pointer focus then stayed on the dragged window, and the next click on another window
        // went to it. Processed normally, an owned release is consumed by a titlebar under the pointer
        // (onInputOnDeco); elsewhere it reaches the seat, which drops it for a client that never got the
        // press (CWLPointerResource::sendButton).
        const auto release = input.presses.onRelease(e.button);
        if (!release.owned || !release.endsGesture)
            return; // a client's press (or an immediate action): nothing to finish here

        SPointerGrab grab = std::exchange(input.grab, {});
        if (grab.dragging)
            updateMove(grab); // final position at the release point (none for a click)
        // Released over the place shown (after the preview delay, TL17): the window takes it (FR47); the preview goes.
        // Released elsewhere, or before the place showed, a tiled window dragged away is Free (tiling.md TL10).
        const auto snap = grab.dragging && grab.moved ? gf::tiler::previewOf(grab.window.lock()) : std::nullopt;
        if (grab.dragging)
            gf::tiler::dragDone();
        if (snap) {
            if (const auto w = grab.window.lock())
                gf::tiler::tile(w, snap->place, snap->monitor.lock());
        }
        gf::tiler::endMove(grab.window.lock()); // no-op unless the window is still Moving
        // Dropped on another output: the window takes that output's Desktop, as after Hyprland's own move (R13).
        if (grab.dragging && grab.moved)
            gf::tiler::followOutput(grab.window.lock());
        // Released on the Stages strip (macOS: a window dragged onto the strip becomes a stage of its own): the plugin does
        // what the shell's op move "new" does; the shell cannot see a titlebar drag (stages.md, Shell side work item 1).
        if (grab.dragging && grab.moved && g_pInputManager) {
            if (const auto w = grab.window.lock()) {
                const auto at = g_pInputManager->getMouseCoordsInternal();
                const auto& p = grab.pressBox;
                gf::stager::dropOnStrip(w, at.x, at.y, snap.has_value(),
                                        grab.plainPress ? std::optional<gf::stages::Box>{gf::stages::Box{p.x, p.y, p.w, p.h}} : std::nullopt);
            }
        }

        if (grab.button && isLive(grab.deco) && g_pInputManager) {
            const auto pos = g_pInputManager->getMouseCoordsInternal();
            const CBox bar = grab.deco->layoutBox();
            if (tb::buttonForHit(tb::hitTest(pos.x - bar.x, pos.y - bar.y, bar.w)) == grab.button)
                grab.deco->activate(*grab.button);
        }
    });
}

void CGrassfieldTitlebar::onGlobalMouseMove() {
    gf::guarded("titlebar reveal", [] { updateReveal(); }); // before the hover: a bar just revealed shows its glyphs
    gf::guarded("titlebar hover", [] { updateHover(); });
    gf::guarded("titlebar onGlobalMouseMove", [] {
        auto& input = pointerInput();
        if (!input.presses.gestureButton())
            return;
        // Hyprland's held-button state and the pointer devices tell whether the gesture's button can
        // still be down; if not, its release will never arrive and the gesture must not stick.
        const bool held = g_pInputManager && g_pInputManager->hasHeldButtons();
        if (input.presses.onMotion(held, devicesIntact(input.grab.devices))) {
            gf::logRequest(Log::DEBUG, "titlebar gesture cancelled: no button held or a pointer device went away");
            if (input.grab.dragging)
                gf::tiler::dragDone();
            gf::tiler::endMove(input.grab.window.lock());
            if (input.grab.moved)
                gf::tiler::followOutput(input.grab.window.lock());
            input.grab = {};
            return;
        }
        if (input.grab.dragging)
            updateMove(input.grab);
    });
}

void CGrassfieldTitlebar::cancelPointerGrab() {
    gf::guarded("titlebar cancelPointerGrab", [] {
        auto& input        = pointerInput();
        if (input.grab.dragging)
            gf::tiler::dragDone();
        gf::tiler::endMove(input.grab.window.lock());
        input.grab         = {};
        input.hovered      = nullptr;
        input.activeWindow = {};
        input.presses.reset();
        // A release still owed reaches Hyprland, which has no such button held and returns (read from the binary).
        input.revealPresses.reset();
        input.heldButtons.reset();
        input.revealArmed = nullptr;
        input.revealLight.reset();
        for (auto* deco : gf::state().titlebars) {
            deco->damageRevealed();
            deco->m_revealed = false;
        }
    });
}

void CGrassfieldTitlebar::updateReveal() {
    if (!g_pInputManager)
        return;
    const Vector2D pos      = g_pInputManager->getMouseCoordsInternal();
    const bool     pressing = pointerInput().revealPresses.pressing();
    for (auto* deco : gf::state().titlebars) {
        gf::chrome::RevealInput in;
        const auto              w   = deco->window();
        const auto              mon = w ? w->m_monitor.lock() : nullptr;
        if (mon) {
            in.onMonitor = pos.x >= mon->m_position.x && pos.x < mon->m_position.x + mon->m_size.x && pos.y >= mon->m_position.y && pos.y < mon->m_position.y + mon->m_size.y;
            in.pointerY  = pos.y - mon->m_position.y;
        }
        // The cheap test first, on every pointer motion: away and the pointer not at its monitor's top edge, nothing changes.
        if (!deco->m_revealed && (!in.onMonitor || in.pointerY > gf::chrome::kRevealEdge))
            continue;
        in.fullscreen = deco->revealable();
        if (!in.fullscreen && !deco->m_revealed)
            continue;
        in.barTop       = menubarInset(mon);
        in.pressing     = pressing;
        const bool next = gf::chrome::nextRevealed(deco->m_revealed, in);
        if (next == deco->m_revealed)
            continue;
        deco->damageRevealed(); // where it was
        deco->m_revealed = next;
        deco->damageRevealed(); // where it is
        if (!sessionLocked())
            gf::logRequest(Log::DEBUG, "titlebar of a full-screen window {}", next ? "revealed" : "away");
    }
}

void CGrassfieldTitlebar::drawRevealed() {
    gf::guarded("titlebar drawRevealed", [] {
        if (!g_pHyprRenderer)
            return;
        const auto mon = g_pHyprRenderer->m_renderData.pMonitor.lock();
        if (!mon)
            return;
        for (auto* deco : gf::state().titlebars) {
            if (!deco->m_revealed)
                continue;
            const auto w = deco->window();
            if (!w || w->m_monitor.lock() != mon || !deco->revealable())
                continue;
            CBox bar = deco->revealBox();
            if (bar.w <= 0 || bar.h <= 0)
                continue;
            bar.translate(-mon->m_position);
            const bool hovered = pointerInput().hovered == deco && g_pInputManager && deco->buttonGroupContains(g_pInputManager->getMouseCoordsInternal());
            deco->drawBar(w, bar, mon->m_scale, 0.0, w->roundingPower(), 1.F, hovered, true); // square: it spans the monitor
        }
    });
}

bool CGrassfieldTitlebar::onRevealedBarButton(const IPointer::SButtonEvent& e) {
    bool cancel = false;
    gf::guarded("titlebar revealed bar button", [&] {
        auto&      input  = pointerInput();
        const bool locked = sessionLocked();
        if (locked) {
            // A light armed before the lock never acts (review of part B, 2026-10-24).
            input.revealArmed = nullptr;
            input.revealLight.reset();
        }
        if (e.state == WL_POINTER_BUTTON_STATE_RELEASED) {
            if (!input.revealPresses.takeRelease(e.button))
                return; // a release Hyprland expects
            cancel           = true;
            auto*      armed = std::exchange(input.revealArmed, nullptr);
            const auto light = std::exchange(input.revealLight, std::nullopt);
            if (e.button == BTN_LEFT && light && isLive(armed) && armed->m_revealed && armed->revealable() && g_pInputManager) {
                const auto pos    = g_pInputManager->getMouseCoordsInternal();
                const CBox bar    = armed->revealBox();
                const bool overIt = tb::buttonForHit(tb::hitTest(pos.x - bar.x, pos.y - bar.y, bar.w)) == light;
                gf::logRequest(Log::INFO, "revealed titlebar: release {}", overIt ? "on the light: it acts" : "away from the light: nothing");
                if (overIt)
                    armed->activate(*light);
            } else if (light && !locked)
                gf::logRequest(Log::INFO, "revealed titlebar: release of an armed light with the bar gone: nothing");
            updateReveal(); // the pointer may have left the bar during the press
            return;
        }
        if (!g_pInputManager)
            return;
        const auto           pos     = g_pInputManager->getMouseCoordsInternal();
        auto&                held    = input.heldButtons;
        const bool           none    = !g_pInputManager->hasHeldButtons();
        CGrassfieldTitlebar* deco    = nullptr;
        const char*          refused = nullptr;
        for (auto* d : gf::state().titlebars) {
            if (!d->m_revealed || !d->revealBox().containsPoint(pos))
                continue;
            const auto w = d->window();
            if (!w || !d->revealable())
                refused = "the window cannot show it now";
            else if (overlaySurfaceAt(pos, w->m_monitor.lock()))
                refused = "a layer popup or an Overlay layer is over it";
            // Hyprland's held buttons are per button and the bus event names no device (IPointer::SButtonEvent): a press of a
            // button another device already holds goes to Hyprland, so that the other device's release is never mistaken
            // for the bar's (review of part B: B holds LEFT, A presses LEFT on the bar); so does any press until the plugin
            // has seen Hyprland hold nothing (core CHeldButtons).
            else if (!held.mayTake(e.button, none))
                refused = held.known() ? "that button is already held" : "the held buttons are not known yet";
            else
                deco = d;
            break;
        }
        // One line per press over the revealed bar (never a key, never while locked, never a position): what it did and
        // why (tests/compositor/fullscreen_reveal.sh prints them).
        if (refused && !locked)
            gf::logRequest(Log::INFO, "revealed titlebar: a press left to Hyprland: {} (Hyprland {})", refused, none ? "holds no button" : "holds some button");
        if (deco)
            cancel = true; // first: whatever follows, the press never reaches Hyprland without its release owed
        input.revealPresses.onPress(e.button, deco != nullptr);
        if (!deco)
            return;
        input.revealArmed = nullptr;
        input.revealLight.reset();
        const auto w = deco->window();
        if (e.button != BTN_LEFT || !w)
            return; // other buttons do nothing on the bar
        const CBox bar = deco->revealBox();
        const auto hit = tb::hitTest(pos.x - bar.x, pos.y - bar.y, bar.w);
        gf::logRequest(Log::INFO, "revealed titlebar: a press taken -> {}", hitName(hit));
        focusAndRaise(w);
        if (const auto light = tb::buttonForHit(hit); light && gf::chrome::lightAvailableInFullscreen(*light)) {
            input.revealArmed = deco;
            input.revealLight = light;
        }
    });
    // What Hyprland holds from here on: a press it processes adds its button, a release it processes removes it (its list
    // removes every entry of that button).
    gf::guarded("titlebar held buttons", [&] {
        if (!cancel)
            pointerInput().heldButtons.observe(e.button, e.state == WL_POINTER_BUTTON_STATE_PRESSED);
    });
    return cancel;
}
