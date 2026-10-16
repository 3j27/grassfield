#include "Titlebar.hpp"

#include "Ipc.hpp"
#include "Plugin.hpp"
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

namespace tb    = gf::titlebar;
namespace theme = gf::theme;

namespace {
    // Higher priority = evaluated first by the positioner = closer to the window. Above the border's
    // priority so the border (and its rounded corners) wraps titlebar + content as one window.
    // Measured in S2: at 10000 the bar was placed outside the border.
    constexpr uint32_t DECORATION_PRIORITY = 10005;

    // The single pointer gesture started on a titlebar (there is one seat pointer).
    struct SPointerGrab {
        CGrassfieldTitlebar*      deco = nullptr; // checked against state().titlebars before use
        std::optional<tb::Button> button;         // pressed button, activated on release over the same button
        bool                      dragging = false;
        PHLWINDOWREF              window;   // window being moved
        Vector2D                  pressPos; // pointer at press (global logical)
        CBox                      startBox; // window layout box at press
    };
    SPointerGrab g_grab;

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

    void toggleZoom(const PHLWINDOW& w) {
        auto& fs = Fullscreen::controller();
        if (!fs)
            return;
        const auto current = fs->getFullscreenModes(w).internal;
        const auto target  = current == Fullscreen::FSMODE_MAXIMIZED ? Fullscreen::FSMODE_NONE : Fullscreen::FSMODE_MAXIMIZED;
        fs->setFullscreenMode(w, target, target, false);
    }

    // Interactive move driven by the plugin: the window follows the pointer from the press point.
    // S2 history: with CLayoutManager::beginDragTarget and CKeybindManager::changeMouseBindMode the window
    // jumped by (window middle - press point). The cause was most likely Config::Actions::focus() warping
    // the cursor to the window middle before the drag started (found afterwards, now avoided in
    // focusAndRaise). Hyprland's own drag (with snapping) should be re-evaluated in M1; this move has no snapping.
    void updateMove() {
        const auto w = g_grab.window.lock();
        if (!w || !g_layoutManager || !g_pInputManager)
            return;
        const auto target = w->layoutTarget();
        if (!target)
            return;
        const Vector2D delta = g_pInputManager->getMouseCoordsInternal() - g_grab.pressPos;
        CBox           box   = g_grab.startBox;
        box.translate(delta);
        g_layoutManager->setTargetGeom(box, target);
    }

    // Focus without Config::Actions::focus(): that action warps the cursor to the window middle when the
    // pointer is outside the client surface (measured in S2), which breaks clicks and drags on the bar.
    void focusAndRaise(const PHLWINDOW& w) {
        if (const auto focus = Desktop::focusState(); focus && !focus->isWindowActive(w))
            focus->fullWindowFocus(w, Desktop::FOCUS_REASON_CLICK);
        (void)Config::Actions::alterZOrder("top", w);
    }
} // namespace

CGrassfieldTitlebar::CGrassfieldTitlebar(PHLWINDOW window) : IHyprWindowDecoration(window), m_owner(window) {
    gf::state().titlebars.push_back(this);
    m_lastShown = shouldShow();
}

CGrassfieldTitlebar::~CGrassfieldTitlebar() {
    std::erase(gf::state().titlebars, this);
    if (g_grab.deco == this) {
        g_grab.deco = nullptr;
        g_grab = {}; // the window is going away: drop the gesture
    }
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
        if (type != INPUT_TYPE_BUTTON || !shouldShow())
            return;
        const auto* e = std::any_cast<IPointer::SButtonEvent>(&data);
        if (!e || e->state != WL_POINTER_BUTTON_STATE_PRESSED)
            return; // releases are handled by onGlobalMouseButton
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

    if (const auto button = tb::buttonForHit(hit)) {
        g_grab        = {};
        g_grab.deco   = this;
        g_grab.button = button;
        m_clicks.reset();
        return true;
    }

    // Drag area: double-click zooms, otherwise start an interactive move.
    if (m_clicks.press(e.timeMs, coords.x, coords.y)) {
        gf::log(Log::DEBUG, "titlebar double-click -> toggle zoom");
        toggleZoom(w);
        return true;
    }

    if (const auto target = w->layoutTarget())
        g_grab = SPointerGrab{.deco = this, .button = std::nullopt, .dragging = true, .window = w, .pressPos = coords, .startBox = target->position()};
    return true;
}

void CGrassfieldTitlebar::activate(tb::Button button) {
    const auto w = window();
    if (!w)
        return;

    switch (button) {
        case tb::Button::Close: gf::log(Log::DEBUG, "titlebar close"); (void)Config::Actions::closeWindow(w); break;
        case tb::Button::Zoom: gf::log(Log::DEBUG, "titlebar zoom"); toggleZoom(w); break;
        case tb::Button::Minimize:
            // PLACEHOLDER (M2): real minimize (hidden state + animation to the Dock) is not implemented.
            // The button only reports the request on the gfc/1 event stream; the window stays visible.
            gf::log(Log::DEBUG, "titlebar minimize (placeholder: event only)");
            gf::ipc::postEvent(gf::gfc::minimizeRequestJson(std::format("{:x}", reinterpret_cast<uintptr_t>(w.get()))));
            break;
    }
}

void CGrassfieldTitlebar::onGlobalMouseButton(const IPointer::SButtonEvent& e, Event::SCallbackInfo& info) {
    gf::guarded("titlebar onGlobalMouseButton", [&] {
        if (e.button != BTN_LEFT || e.state != WL_POINTER_BUTTON_STATE_RELEASED)
            return;
        if (!g_grab.dragging && !g_grab.button)
            return;

        const SPointerGrab grab = g_grab;
        g_grab                  = {};

        if (grab.dragging) {
            g_grab = grab; // final position at the release point
            updateMove();
            g_grab = {};
        }

        if (grab.button && isLive(grab.deco) && g_pInputManager) {
            const auto pos = g_pInputManager->getMouseCoordsInternal();
            const CBox bar = grab.deco->layoutBox();
            if (tb::buttonForHit(tb::hitTest(pos.x - bar.x, pos.y - bar.y, bar.w)) == grab.button)
                grab.deco->activate(*grab.button);
        }

        // The press never reached the client (the titlebar consumed it); keep the release away too.
        info.cancelled = true;
    });
}

void CGrassfieldTitlebar::onGlobalMouseMove() {
    gf::guarded("titlebar onGlobalMouseMove", [] {
        if (g_grab.dragging)
            updateMove();
    });
}

void CGrassfieldTitlebar::cancelPointerGrab() {
    gf::guarded("titlebar cancelPointerGrab", [] {
        g_grab = {};
    });
}
