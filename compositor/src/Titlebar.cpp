#include "Titlebar.hpp"

#include "Ipc.hpp"
#include "Plugin.hpp"
#include "core/PointerGesture.hpp"
#include "core/Protocol.hpp"
#include "core/Theme.hpp"

#include <hyprland/src/config/shared/actions/ConfigActions.hpp>
#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/layout/LayoutManager.hpp>
#include <hyprland/src/layout/target/Target.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/decorations/DecorationPositioner.hpp>
#include <hyprland/src/render/pass/RectPassElement.hpp>
#include <hyprland/src/render/pass/TexPassElement.hpp>

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
        PHLWINDOWREF              window;   // window being moved
        Vector2D                  pressPos; // pointer at press (global logical)
        CBox                      startBox; // window layout box at press
        std::vector<WP<IPointer>> devices;  // pointer devices present at the press
    };

    struct SPointerInput {
        SPointerGrab                      grab;
        gf::input::CPointerGestureTracker presses;
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

    theme::Rgba buttonColor(tb::Button b) {
        switch (b) {
            case tb::Button::Close: return theme::kCloseColor;
            case tb::Button::Minimize: return theme::kMinimizeColor;
            case tb::Button::Zoom: return theme::kZoomColor;
        }
        return theme::kCloseColor;
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
            gf::log(Log::WARN, "titlebar {} failed: {}", action, result.error().message);
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

    // Maximized or full screen: the layout owns the window's box. A titlebar move would write that box
    // into the floating geometry the zoom toggle restores (FR8 regression, 2026-10-17).
    bool inFullscreenMode(const PHLWINDOW& w) {
        const auto& fs = Fullscreen::controller();
        return fs && fs->getFullscreenModes(w).internal != Fullscreen::FSMODE_NONE;
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
        const Vector2D delta = g_pInputManager->getMouseCoordsInternal() - grab.pressPos;
        if (!grab.moved && !tb::exceedsDragThreshold(delta.x, delta.y))
            return;
        grab.moved = true;
        CBox box   = grab.startBox;
        box.translate(delta);
        g_layoutManager->setTargetGeom(box, target);
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
    void focusAndRaise(const PHLWINDOW& w) {
        if (const auto focus = Desktop::focusState(); focus && !focus->isWindowActive(w))
            focus->fullWindowFocus(w, Desktop::FOCUS_REASON_CLICK);
        logIfFailed("raise", Config::Actions::alterZOrder("top", w));
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
        if (input.grab.deco == this) {
            // The window is going away: drop the gesture. The press ownership stays, so the release that
            // will still arrive is not mistaken for a client's (another titlebar under the pointer
            // consumes it; elsewhere the seat drops it, as the client never saw the press).
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
    const auto   palette  = theme::titlebarPalette(theme::kDefaultAppearance);
    const auto   bgColor  = toColor(palette.background, alpha);
    const int    roundPx  = static_cast<int>(std::round(rounding * scale));

    // 1. Background with rounded top corners: a rounded rect taller than the bar, clipped to the bar.
    CBox bgBox   = bar;
    bgBox.h     += 2.0 * rounding;
    CBox clipBox = bar;
    addRect(bgBox.scale(scale).round(), bgColor, roundPx, power, clipBox.scale(scale).round());

    // 2. Fill the window surface's rounded top corners so bar and content join without notches.
    if (rounding > 0) {
        CBox left{bar.x, bar.y + bar.h, rounding, rounding};
        CBox right{bar.x + bar.w - rounding, bar.y + bar.h, rounding, rounding};
        addRect(left.scale(scale).round(), bgColor, 0, power);
        addRect(right.scale(scale).round(), bgColor, 0, power);
    }

    // 3. Buttons (owner-drawn circles; glyphs on hover are a later M1 slice).
    for (const auto button : tb::kButtonOrder) {
        const auto r = tb::buttonRect(button);
        CBox       box{bar.x + r.x, bar.y + r.y, r.w, r.h};
        box.scale(scale).round();
        addRect(box, toColor(buttonColor(button), alpha), static_cast<int>(std::round(box.w / 2.0)), 2.F);
    }

    // 4. Title, centered on the bar, never over the buttons.
    const int maxWidthPx = static_cast<int>(std::floor(tb::maxTitleWidth(bar.w) * scale));
    if (w->m_title.empty() || maxWidthPx <= 0)
        return;

    if (!m_title.texture || m_title.text != w->m_title || m_title.scale != scale || m_title.maxWidthPx != maxWidthPx) {
        m_title.texture    = g_pHyprRenderer->renderText(w->m_title, toColor(palette.title), static_cast<int>(std::round(theme::kTitleFontSizePt * scale)), false,
                                                         theme::kTitleFontFamily, maxWidthPx, theme::kTitleFontWeight);
        m_title.text       = w->m_title;
        m_title.scale      = scale;
        m_title.maxWidthPx = maxWidthPx;
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
    gf::log(Log::DEBUG, "titlebar press at {:.1f},{:.1f} bar {:.1f},{:.1f} {:.0f}x{:.0f} -> {}", coords.x, coords.y, bar.x, bar.y, bar.w, bar.h, hitName(hit));
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

    // Drag area: double-click zooms (the zoom button's toggle, nothing else), otherwise start an
    // interactive move.
    if (m_clicks.press(e.timeMs, coords.x, coords.y)) {
        gf::log(Log::DEBUG, "titlebar double-click -> toggle zoom");
        toggleZoom(w);
        input.presses.claim(e.button, false); // acts now; its release is still the titlebar's
        return true;
    }

    if (inFullscreenMode(w)) {
        input.presses.claim(e.button, false); // focus and raise only; the release is still the titlebar's
        return true;
    }

    const auto target = w->layoutTarget();
    if (target) {
        input.grab          = {};
        input.grab.deco     = this;
        input.grab.dragging = true;
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
            gf::log(Log::DEBUG, "titlebar close");
            logIfFailed("close", Config::Actions::closeWindow(w));
            break;
        case tb::Button::Zoom: gf::log(Log::DEBUG, "titlebar zoom"); toggleZoom(w); break;
        case tb::Button::Minimize:
            // PLACEHOLDER (M2): real minimize (hidden state + animation to the Dock) is not implemented.
            // The button only reports the request on the gfc/1 event stream; the window stays visible.
            gf::log(Log::DEBUG, "titlebar minimize (placeholder: event only)");
            gf::ipc::postEvent(gf::gfc::minimizeRequestJson(std::format("{:x}", reinterpret_cast<uintptr_t>(w.get()))));
            break;
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
                gf::log(Log::DEBUG, "titlebar gesture cancelled by a new press (button {:#x})", e.button);
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

        if (grab.button && isLive(grab.deco) && g_pInputManager) {
            const auto pos = g_pInputManager->getMouseCoordsInternal();
            const CBox bar = grab.deco->layoutBox();
            if (tb::buttonForHit(tb::hitTest(pos.x - bar.x, pos.y - bar.y, bar.w)) == grab.button)
                grab.deco->activate(*grab.button);
        }
    });
}

void CGrassfieldTitlebar::onGlobalMouseMove() {
    gf::guarded("titlebar onGlobalMouseMove", [] {
        auto& input = pointerInput();
        if (!input.presses.gestureButton())
            return;
        // Hyprland's held-button state and the pointer devices tell whether the gesture's button can
        // still be down; if not, its release will never arrive and the gesture must not stick.
        const bool held = g_pInputManager && g_pInputManager->hasHeldButtons();
        if (input.presses.onMotion(held, devicesIntact(input.grab.devices))) {
            gf::log(Log::DEBUG, "titlebar gesture cancelled: no button held or a pointer device went away");
            input.grab = {};
            return;
        }
        if (input.grab.dragging)
            updateMove(input.grab);
    });
}

void CGrassfieldTitlebar::cancelPointerGrab() {
    gf::guarded("titlebar cancelPointerGrab", [] {
        auto& input = pointerInput();
        input.grab  = {};
        input.presses.reset();
    });
}
