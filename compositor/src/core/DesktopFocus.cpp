#include "DesktopFocus.hpp"

namespace gf::desktopfocus {

    namespace {
        // Nothing may move the keyboard: the session lock, an active keyboard grab (popup), an Exclusive layer.
        bool seatBusy(const Seat& seat) {
            return seat.locked || seat.keyboardGrab || seat.exclusiveLayer;
        }
    } // namespace

    Action onPress(const Seat& seat, const Press& press) {
        if (seatBusy(seat))
            return Action::None;

        switch (press.target) {
            case SurfaceKind::Window:
                // The case Hyprland misses: the desktop holds the keyboard and the click is on a window (also the one
                // Hyprland still counts as focused). Any button, as Hyprland's own click-to-focus.
                if (seat.keyboard == SurfaceKind::Desktop && press.windowFocusable && !press.targetHasKeyboard)
                    return Action::FocusWindow;
                return Action::None;

            case SurfaceKind::Desktop:
                // Left press only: the shell arms the desktop on a left press; a right press opens its menu (popup grab).
                if (!press.primary || press.targetHasKeyboard)
                    return Action::None;
                switch (press.interactivity) {
                    case Interactivity::OnDemand: return Action::FocusDesktop;
                    case Interactivity::None: return Action::AwaitOnDemand;
                    case Interactivity::Exclusive: return Action::None; // Hyprland gives Exclusive surfaces the keyboard itself
                }
                return Action::None;

            case SurfaceKind::None:
            case SurfaceKind::DesktopPopup: // the menu's grab decides (Esc, item, outside click)
            case SurfaceKind::WindowPopup:
            case SurfaceKind::ShellLayer: // Dock, menu bar, widgets: macOS keeps Finder active
            case SurfaceKind::OtherLayer:
            case SurfaceKind::Other: return Action::None;
        }
        return Action::None;
    }

    TargetSource pressTargetSource(PointerFocus focus) {
        return focus == PointerFocus::Live ? TargetSource::PointerFocus : TargetSource::UnderCursor;
    }

    SurfaceKind pressTargetKind(PointerFocus focus, SurfaceKind focusKind, SurfaceKind cursorKind) {
        return pressTargetSource(focus) == TargetSource::PointerFocus ? focusKind : cursorKind;
    }

    bool mayGrantDesktop(const Seat& seat, bool desktopHasKeyboard) {
        return !seatBusy(seat) && !desktopHasKeyboard;
    }

    SurfaceKind classifyLayer(std::string_view layerNamespace, bool popup) {
        if (layerNamespace == kDesktopNamespace)
            return popup ? SurfaceKind::DesktopPopup : SurfaceKind::Desktop;
        if (layerNamespace.starts_with(kShellNamespacePrefix))
            return SurfaceKind::ShellLayer;
        return SurfaceKind::OtherLayer;
    }

    Interactivity interactivityFromProtocol(uint32_t value) {
        switch (value) {
            case 1: return Interactivity::Exclusive;
            case 2: return Interactivity::OnDemand;
            default: return Interactivity::None;
        }
    }

    std::string_view actionName(Action action) {
        switch (action) {
            case Action::None: return "none";
            case Action::FocusWindow: return "focus-window";
            case Action::FocusDesktop: return "focus-desktop";
            case Action::AwaitOnDemand: return "await-on-demand";
        }
        return "none";
    }

    std::string_view kindName(SurfaceKind kind) {
        switch (kind) {
            case SurfaceKind::None: return "none";
            case SurfaceKind::Desktop: return "desktop";
            case SurfaceKind::DesktopPopup: return "desktop-popup";
            case SurfaceKind::Window: return "window";
            case SurfaceKind::WindowPopup: return "window-popup";
            case SurfaceKind::ShellLayer: return "shell-layer";
            case SurfaceKind::OtherLayer: return "other-layer";
            case SurfaceKind::Other: return "other";
        }
        return "other";
    }

    void CPendingGrant::arm(uint64_t surface, TimePoint now) {
        m_surface  = surface;
        m_deadline = now + kGrantWindow;
    }

    void CPendingGrant::cancel() {
        m_surface.reset();
    }

    bool CPendingGrant::onCommit(uint64_t surface, Interactivity interactivity, TimePoint now) {
        if (!m_surface)
            return false;
        if (now > m_deadline) {
            m_surface.reset();
            return false;
        }
        if (*m_surface != surface || interactivity != Interactivity::OnDemand)
            return false;
        m_surface.reset();
        return true;
    }

    GrantUpdate CPendingGrant::onFocusEvent(FocusEvent event, std::optional<uint64_t> keyboardLayer, TimePoint now) {
        if (!m_surface)
            return GrantUpdate::NotArmed;
        const uint64_t armedSurface = *m_surface;
        m_surface.reset(); // every focus change ends the wait, whatever it did
        if (now > m_deadline)
            return GrantUpdate::NotArmed;
        if (event == FocusEvent::KeyboardFocus && keyboardLayer == armedSurface)
            return GrantUpdate::Fulfilled;
        return GrantUpdate::Cancelled;
    }

    std::string_view focusEventName(FocusEvent event) {
        switch (event) {
            case FocusEvent::KeyboardFocus: return "keyboard focus moved";
            case FocusEvent::WindowActivated: return "window activated";
            case FocusEvent::WindowOpened: return "window opened";
            case FocusEvent::WorkspaceChanged: return "workspace changed";
        }
        return "focus changed";
    }

    std::string_view grantUpdateName(GrantUpdate update) {
        switch (update) {
            case GrantUpdate::NotArmed: return "not-armed";
            case GrantUpdate::Fulfilled: return "fulfilled";
            case GrantUpdate::Cancelled: return "cancelled";
        }
        return "not-armed";
    }

    bool CPendingGrant::armed(TimePoint now) const {
        return m_surface.has_value() && now <= m_deadline;
    }

    std::optional<uint64_t> CPendingGrant::surface() const {
        return m_surface;
    }

} // namespace gf::desktopfocus
