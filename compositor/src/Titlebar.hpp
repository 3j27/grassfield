#pragma once

// Grassfield titlebar: a window decoration with close / minimize / zoom buttons and a centered title.
// Geometry and hit-testing live in core/TitlebarLayout.* (no Hyprland dependency).

#include "core/TitlebarLayout.hpp"

#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/devices/IPointer.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/render/decorations/IHyprWindowDecoration.hpp>

#include <string>

namespace Render {
    class ITexture;
}

class CGrassfieldTitlebar : public IHyprWindowDecoration {
  public:
    explicit CGrassfieldTitlebar(const PHLWINDOW& window);
    ~CGrassfieldTitlebar() override;

    CGrassfieldTitlebar(const CGrassfieldTitlebar&)            = delete;
    CGrassfieldTitlebar& operator=(const CGrassfieldTitlebar&) = delete;

    SDecorationPositioningInfo getPositioningInfo() override;
    void                       onPositioningReply(const SDecorationPositioningReply& reply) override;
    void                       draw(PHLMONITOR monitor, float const& alpha) override;
    eDecorationType            getDecorationType() override;
    void                       updateWindow(PHLWINDOW window) override;
    void                       damageEntire() override;
    bool                       onInputOnDeco(const eInputType type, const Vector2D& coords, std::any data = {}) override;
    eDecorationLayer           getDecorationLayer() override;
    uint64_t                   getDecorationFlags() override;
    std::string                getDisplayName() override;

    PHLWINDOW                  window() const;

    // Floating, not full screen, decorations allowed by window rules.
    bool shouldShow() const;

    // Re-evaluates visibility (floating / full screen / rule changes) and requests new extents if needed.
    void refresh();

    // Window title changed: the cached title texture is rebuilt on the next draw.
    void onTitleChanged();

    // True when Hyprland routes button events at `pos` (global logical) to this titlebar: shown and
    // its box contains the point.
    bool receivesPointerAt(const Vector2D& pos) const;

    // Global pointer button listener (Event::bus()->m_events.input.mouse.button), called before any
    // titlebar or client sees the event. Tracks press ownership, ends gestures (drag, armed button)
    // on their release or on a new press, and keeps from clients the releases of presses a titlebar
    // consumed.
    static void onGlobalMouseButton(const IPointer::SButtonEvent& e, Event::SCallbackInfo& info);

    // Global pointer motion listener (Event::bus()->m_events.input.mouse.move): moves a dragged window,
    // or cancels the gesture when no button is held any more or the pressing device may be gone.
    static void onGlobalMouseMove();

    // Drops any gesture and press ownership (plugin unload).
    static void cancelPointerGrab();

  private:
    CBox layoutBox() const; // titlebar box in global logical (layout) coordinates
    bool onButtonPress(const Vector2D& coords, const IPointer::SButtonEvent& e);
    void activate(gf::titlebar::Button button);
    void drawTitlebar(const PHLMONITOR& monitor, float alpha);

    PHLWINDOWREF                m_owner;
    bool                        m_lastShown = false;
    gf::titlebar::CClickTracker m_clicks;

    struct {
        SP<Render::ITexture> texture;
        std::string          text;
        float                scale      = 0.F;
        int                  maxWidthPx = 0;
    } m_title;
};
