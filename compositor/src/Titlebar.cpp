#include "Titlebar.hpp"

#include "DeferredFocus.hpp"
#include "Ipc.hpp"
#include "Plugin.hpp"
#include "Tiling.hpp"
#include "core/PointerGesture.hpp"
#include "core/Protocol.hpp"
#include "core/Theme.hpp"

#include <hyprland/src/config/shared/actions/ConfigActions.hpp>
#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/WLSurface.hpp>
#include <hyprland/src/layout/LayoutManager.hpp>
#include <hyprland/src/layout/target/Target.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/protocols/XDGShell.hpp>
#include <hyprland/src/protocols/core/Compositor.hpp>
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
        std::optional<gf::tiler::Snap> snap;        // where a release would tile the window (its preview is drawn)
        PHLWINDOWREF              window;   // window being moved
        Vector2D                  pressPos; // pointer at press (global logical)
        CBox                      startBox; // window layout box at press
        std::vector<WP<IPointer>> devices;  // pointer devices present at the press
    };

    struct SPointerInput {
        SPointerGrab                      grab;
        gf::input::CPointerGestureTracker presses;
        CGrassfieldTitlebar*              hovered = nullptr; // lights under the pointer (glyphs); checked with isLive
        PHLWINDOWREF                      activeWindow;      // last window reported active (its lights are coloured)
    };

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
        const uint64_t address = reinterpret_cast<uintptr_t>(w.get());
        gf::ipc::postEvent(gf::events::Key{.channel = gf::events::Channel::MinimizeRequest, .id = address}, gf::gfc::minimizeRequestJson(std::format("{:x}", address)));
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

    // A move that starts on a maximized window: leave the maximized mode first (the layout gives the window
    // back its floating size), then place that size under the pointer (macOS). Moving the maximized box
    // itself would write it into the floating geometry the zoom toggle restores (FR8 regression, 2026-10-17).
    // Measured in 0.56.2: a floating window's layout box is its surface box, a maximized one's is the work
    // area (decorations included), hence the surface box recorded at the press as the reference.
    void unzoomUnderPointer(SPointerGrab& grab, const PHLWINDOW& w, const SP<Layout::ITarget>& target, const Vector2D& pointer) {
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
    // relative place on the titlebar (macOS), like the un-zoom above.
    void untileUnderPointer(SPointerGrab& grab, const PHLWINDOW& w, const SP<Layout::ITarget>& target, const Vector2D& pointer) {
        grab.untile        = false;
        const auto before = gf::tiler::takePrevious(w);
        if (!before)
            return;
        const CBox tiled = target->position();
        const auto box   = tb::unzoomedDragBox(tb::Rect{tiled.x, tiled.y, tiled.w, tiled.h}, before->w, before->h, grab.pressPos.x, grab.pressPos.y, pointer.x, pointer.y);
        gf::logRequest(Log::DEBUG, "titlebar drag leaves the tile: {:.0f}x{:.0f} at {:.0f},{:.0f}", box.w, box.h, box.x, box.y);
        grab.startBox = CBox{box.x, box.y, box.w, box.h};
        grab.pressPos = pointer;
    }

    // The tiling preview of a drag changes: the old and the new frames are redrawn.
    void damageSnap(const std::optional<gf::tiler::Snap>& snap) {
        if (snap && g_pHyprRenderer)
            g_pHyprRenderer->damageBox(snap->frame);
    }

    void updateSnap(SPointerGrab& grab, const PHLWINDOW& w, const Vector2D& pointer) {
        auto next = gf::tiler::snapFor(w, pointer);
        const bool same = next.has_value() == grab.snap.has_value() && (!next || (next->place == grab.snap->place && next->frame == grab.snap->frame));
        if (same)
            return;
        damageSnap(grab.snap);
        damageSnap(next);
        grab.snap = std::move(next);
    }

    // Interactive move driven by the plugin: the window follows the pointer from the press point.
    // S2 history: with CLayoutManager::beginDragTarget and CKeybindManager::changeMouseBindMode the window
    // jumped by (window middle - press point). The cause was most likely Config::Actions::focus() warping
    // the cursor to the window middle before the drag started (found afterwards, now avoided in
    // focusAndRaise). Hyprland's own drag (with snapping) should be re-evaluated in M1; this move has no snapping.
    // Nothing moves until the pointer has passed kDragThreshold: a click (or the first click of a
    // double-click) never writes the window geometry.
    void updateMove(SPointerGrab& grab) {
        const auto w = grab.window.lock();
        if (!w || !g_layoutManager || !g_pInputManager)
            return;
        const auto target = w->layoutTarget();
        if (!target)
            return;
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
        g_layoutManager->setTargetGeom(box, target);
        updateSnap(grab, w, pointer);
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
        if (input.grab.deco == this) {
            // The window is going away: drop the gesture (and redraw where its tiling preview was). The press ownership
            // stays, so the release that will still arrive is not mistaken for a client's (another titlebar under the
            // pointer consumes it; elsewhere the seat drops it, as the client never saw the press).
            damageSnap(input.grab.snap);
            input.grab = {};
            input.presses.dropGesture();
        }
    });
}

PHLWINDOW CGrassfieldTitlebar::window() const {
    return m_owner.lock();
}

bool CGrassfieldTitlebar::shouldShow() const {
    const auto w = window();
    if (!w || !w->m_isMapped || w->isHidden() || !w->m_isFloating)
        return false;
    if (w->m_isX11 && (w->isX11OverrideRedirect() || w->m_X11DoesntWantBorders))
        return false;
    if (w->m_ruleApplicator && !w->m_ruleApplicator->decorate().valueOrDefault())
        return false;
    if (const auto& fs = Fullscreen::controller(); fs && fs->getFullscreenModes(w).internal == Fullscreen::FSMODE_FULLSCREEN)
        return false;
    return true;
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

bool CGrassfieldTitlebar::barContains(const Vector2D& pos) const {
    return shouldShow() && layoutBox().containsPoint(pos);
}

bool CGrassfieldTitlebar::buttonGroupContains(const Vector2D& pos) const {
    if (!shouldShow())
        return false;
    const CBox bar = layoutBox();
    return tb::overButtonGroup(pos.x - bar.x, pos.y - bar.y, bar.w);
}

void CGrassfieldTitlebar::damageEntire() {
    gf::guarded("titlebar damageEntire", [this] {
        const auto w = window();
        if (!w || !g_pHyprRenderer)
            return;
        CBox box = layoutBox();
        box.translate(w->m_floatingOffset);
        g_pHyprRenderer->damageBox(box.expand(2));
    });
}

void CGrassfieldTitlebar::draw(PHLMONITOR monitor, float const& alpha) {
    gf::guarded("titlebar draw", [&] { drawTitlebar(monitor, alpha); });
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
    const int    roundPx    = static_cast<int>(std::round(rounding * scale));

    // 0. A drag of this window over a tiling place: the place's frame under the window and over the windows behind it (this
    //    decoration is drawn under the window's surface, after the windows below it), as the blurred material (owner
    //    decision D-8, macOS's frosted pane): its edge, then a plate of Hyprland's blur of the windows behind under the
    //    appearance's tint. Cheap: one blurred element, only while a drag has a place, damage limited to the frame.
    if (const auto& grab = pointerInput().grab; grab.deco == this && grab.snap && grab.snap->monitor.lock() == monitor) {
        CBox preview = grab.snap->frame;
        preview.translate(-monitor->m_position);
        addRect(preview.scale(scale).round(), toColor(palette.previewRim, alpha), roundPx, power);
        CBox inner = grab.snap->frame;
        inner.translate(-monitor->m_position);
        inner.expand(-theme::kTilePreviewRim);
        addBlurredRect(inner.scale(scale).round(), toColor(palette.previewTint, alpha), std::max(0, roundPx - static_cast<int>(std::round(theme::kTilePreviewRim * scale))),
                       power, alpha);
    }

    // 1. Background with rounded top corners: a rounded rect taller than the bar, clipped to the bar.
    CBox bgBox   = bar;
    bgBox.h     += 2.0 * rounding;
    CBox clipBox = bar;
    addRect(bgBox.scale(scale).round(), bgColor, roundPx, power, clipBox.scale(scale).round());

    // 2. The surface's rounded top corners, under the surface: Hyprland cuts them away with the window's rounding, so the
    //    bar colour fills them, then the content's own pixels are drawn there unrounded (macOS: bar and content are one
    //    shape, square where they meet). Where the content is transparent the bar colour stays.
    if (rounding > 0) {
        CBox left{bar.x, bar.y + bar.h, rounding, rounding};
        CBox right{bar.x + bar.w - rounding, bar.y + bar.h, rounding, rounding};
        addRect(left.scale(scale).round(), bgColor, 0, power);
        addRect(right.scale(scale).round(), bgColor, 0, power);
        drawContentCorners(w, bar, rounding, scale, alpha);
    }

    // 3. Buttons (owner-drawn circles): coloured on the active window, grey on the others; coloured again with their
    //    glyphs while the pointer is over the group (macOS). The pointer is checked again here: the window may have moved
    //    or gone under a pointer that has not moved since.
    const bool hovered = pointerInput().hovered == this && g_pInputManager && drawnInPlace(w) && buttonGroupContains(g_pInputManager->getMouseCoordsInternal());
    const bool active  = Desktop::focusState() && Desktop::focusState()->window() == w;
    for (const auto button : tb::kButtonOrder) {
        const auto r = tb::buttonRect(button);
        CBox       box{bar.x + r.x, bar.y + r.y, r.w, r.h};
        box.scale(scale).round();
        addRect(box, toColor(tb::lightColor(button, active, hovered, appearance), alpha), static_cast<int>(std::round(box.w / 2.0)), 2.F);
    }
    if (hovered)
        drawGlyphs(bar, scale, alpha);

    // 4. Title, centered on the bar, never over the buttons.
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

void CGrassfieldTitlebar::drawGlyphs(const CBox& bar, float scale, float alpha) {
    for (size_t i = 0; i < tb::kButtonOrder.size(); ++i) {
        const auto button = tb::kButtonOrder[i];
        const auto r      = tb::buttonRect(button);
        CBox       box{bar.x + r.x, bar.y + r.y, r.w, r.h};
        box.scale(scale).round(); // the light exactly as drawn above
        const int sizePx = tb::glyphSizePx(static_cast<int>(std::lround(box.w)));
        if (sizePx <= 0)
            continue;

        auto& glyph = m_glyphs[i];
        if (!glyph.texture || glyph.sizePx != sizePx || glyph.scale != scale) {
            glyph = {};
            auto pixels = tb::premultipliedBgra(tb::glyphMask(button, sizePx, theme::kGlyphStroke * theme::kButtonDiameter * scale), theme::kGlyphColor);
            if (pixels.empty())
                continue;
            glyph.texture = g_pHyprRenderer->createTexture(DRM_FORMAT_ARGB8888, pixels.data(), static_cast<uint32_t>(sizePx) * 4U, Vector2D{static_cast<double>(sizePx), static_cast<double>(sizePx)});
            glyph.sizePx  = sizePx;
            glyph.scale   = scale;
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
    // hl.plugin.grassfield.config): the zoom button's toggle, the minimize button's path, or nothing (the
    // press is then a single press). Otherwise the press starts an interactive move.
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
        case tb::Button::Zoom: gf::logRequest(Log::DEBUG, "titlebar zoom"); toggleZoom(w); break;
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
                damageSnap(input.grab.snap);
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
        // Released over a tiling place: the window takes it (FR47); the preview goes.
        if (grab.dragging && grab.moved && grab.snap) {
            damageSnap(grab.snap);
            if (const auto w = grab.window.lock())
                gf::tiler::tile(w, grab.snap->place, grab.snap->monitor.lock());
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
            damageSnap(input.grab.snap);
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
        damageSnap(input.grab.snap);
        input.grab         = {};
        input.hovered      = nullptr;
        input.activeWindow = {};
        input.presses.reset();
    });
}
