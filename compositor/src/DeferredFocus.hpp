#pragma once

// Deferred focus, Hyprland 0.56.2 glue shared by Stages (docs/specs/stages.md ST10, ST23, ST24) and the overview focus
// (docs/specs/overview.md "Close focus"), for the decisions in core/DeferredFocus.*: Hyprland's own refusal conditions
// (read only: the plugin never changes Hyprland's lists, R13 counter-review #3 of e9ebc7f), the keyboard holder, where a
// press goes while an Exclusive layer is mapped, Hyprland's focus reasons, and one coalesced attempt from the event loop.
// Compositor thread only, nothing blocks.

#include "core/DeferredFocus.hpp"

#include <hyprland/src/desktop/DesktopTypes.hpp>
#include <hyprland/src/helpers/math/Math.hpp>
#include <hyprland/src/helpers/memory/Memory.hpp>

#include <cstdint>
#include <functional>
#include <optional>

class CWLSurfaceResource;
namespace Desktop {
    enum eFocusReason : uint8_t;
}

namespace gf::deferredFocus {

    // The session is locked.
    bool sessionLocked();

    // Hyprland's own condition for refusing a window focus (CFocusState::rawWindowFocus): its Exclusive-layer list is not
    // empty. Read only: the list is never changed by this plugin.
    bool exclusiveLayerMapped();

    // Hyprland refuses every window focus now (CFocusState::rawWindowFocus: "Refusing a keyboard focus to a window because
    // of a sessionlock / an exclusive ls"). The plugin then never asks for one (R13 counter-review #3 of e9ebc7f).
    bool windowFocusRefused();

    // Hyprland counts `w` as its focused window and the seat's keyboard is on `w` (its main surface, a subsurface or a popup).
    bool windowHoldsKeyboard(const PHLWINDOW& w);

    // Gives `w` the keyboard through Hyprland's own window focus (CFocusState::fullWindowFocus, with every rule Hyprland
    // applies: no_focus, a modal child, X11 windows that refuse focus). It also works for the window Hyprland still counts as
    // focused while the keyboard is elsewhere: fullWindowFocus returns early when Hyprland's focus state still names that
    // window's surface, so the state is reset (CFocusState::resetWindowFocus, what Hyprland does when its focused window
    // unmaps) and the focus made again. Nothing is asked while Hyprland refuses window focus (lock, Exclusive layer).
    // `stateReset` (optional) tells whether the reset was needed. True when `w` holds the keyboard afterwards.
    bool focusWindow(const PHLWINDOW& w, Desktop::eFocusReason reason, bool* stateReset = nullptr);

    // The surface that holds the keyboard as Hyprland sees it: its focus surface; else the seat's keyboard focus; else,
    // while an Exclusive layer is mapped, that layer (Hyprland resets its focus surface when its focused window closes,
    // CWindow::onUnmap, and refuses the next window while the layer is mapped: the layer keeps the keys). Read only.
    SP<CWLSurfaceResource> keyboardHolder();

    // The cursor lies over a mapped Exclusive layer surface (or one of its popups): Hyprland's own hit test of its
    // Exclusive-layer list (CInputManager::mouseMoveUnified), run on a copy of the list (it is only read).
    bool cursorOnExclusiveLayer(const Vector2D& at);

    // Where a press that arrives now goes (before Hyprland handles it). `pointer`: a pointer button at the cursor; otherwise
    // a touch or a tablet tool, whose point is not the cursor (they count as presses into an Exclusive layer while one is
    // mapped).
    gf::deferredfocus::PressContext pressContext(bool pointer);

    // Hyprland 0.56.2's focus reasons, one to one (no default: a new reason in an update is a compiler warning).
    gf::deferredfocus::FocusCause causeOf(Desktop::eFocusReason reason);

    // One callback from Hyprland's event loop at a time (coalesced): after Hyprland's own handling of the event that
    // scheduled it. Its callback is code of this library: cancel() before dlclose. Not copyable (the callback refers to it).
    class CLater {
      public:
        CLater() = default;
        CLater(const CLater&)            = delete;
        CLater& operator=(const CLater&) = delete;
        ~CLater()                        = default;

        // Schedules `fn` unless a callback is already scheduled. `fn` must not throw (wrap it in gf::guarded). False when
        // nothing was scheduled (already scheduled, or no event loop).
        bool schedule(std::function<void()> fn);

        bool scheduled() const;

        // Removes the scheduled callback (Hyprland will not call it).
        void cancel();

        // Forgets the scheduled callback without removing it (start(): a reload after a previous stop(), which cancelled).
        void clear();

      private:
        std::optional<uint64_t> m_seq; // doLater sequence
    };

} // namespace gf::deferredFocus
