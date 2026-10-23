#include "LayerPointer.hpp"

namespace gf::layerpointer {

    bool isGrassfieldNamespace(std::string_view ns) {
        return ns.size() > kNamespacePrefix.size() && ns.starts_with(kNamespacePrefix);
    }

    bool CRefreshState::onLayerEvent(std::string_view ns) {
        if (m_inRefresh || !isGrassfieldNamespace(ns))
            return false;
        m_owed = true;
        if (m_scheduled)
            return false;
        m_scheduled = true;
        return true;
    }

    Step CRefreshState::onAttempt(bool pointerDevice, bool buttonsHeld) {
        m_scheduled = false;
        if (!m_owed)
            return Step::None;
        if (!pointerDevice || buttonsHeld)
            return Step::Wait;
        m_owed = false;
        ++m_refreshes;
        return Step::Refresh;
    }

    Step CRefreshState::beforeButton(bool pressed, bool pointerDevice, bool buttonsHeld) {
        if (!m_owed)
            return Step::None;
        if (pressed) {
            // Also while the attempt is still scheduled: a press read in the same event loop pass as the map comes before
            // it (Hyprland has handled the map by then; the attempt then finds nothing owed).
            if (!pointerDevice || buttonsHeld)
                return Step::None;
            m_owed = false;
            ++m_refreshes;
            return Step::Refresh;
        }
        // A release: Hyprland handles it next (and refocuses when it was the last held button); the attempt comes after.
        if (m_scheduled)
            return Step::None;
        m_scheduled = true;
        return Step::Schedule;
    }

    bool CRefreshState::onKeyboardFocus(uint64_t surface, std::string_view layerNs) {
        const bool moved  = surface != m_keyboardSurface;
        m_keyboardSurface = surface;
        if (!moved || surface == 0)
            return false;
        return onLayerEvent(layerNs); // nothing while a refresh runs; nothing for a window, a popup or another client's layer
    }

    void CRefreshState::beginRefresh() {
        m_inRefresh = true;
    }

    void CRefreshState::endRefresh() {
        m_inRefresh = false;
    }

    bool CRefreshState::admit(uint64_t nowMs) {
        if (nowMs < m_windowStartMs || nowMs - m_windowStartMs >= 1000) {
            m_windowStartMs = nowMs;
            m_inWindow      = 0;
        }
        if (m_inWindow >= kMaxRefreshesPerSecond) {
            ++m_dropped;
            return false;
        }
        ++m_inWindow;
        return true;
    }

    uint64_t CRefreshState::dropped() const {
        return m_dropped;
    }

    void CRefreshState::reset() {
        m_scheduled       = false;
        m_owed            = false;
        m_refreshes       = 0;
        m_keyboardSurface = 0;
        m_inRefresh       = false;
        m_windowStartMs   = 0;
        m_inWindow        = 0;
        m_dropped         = 0;
    }

    bool CRefreshState::scheduled() const {
        return m_scheduled;
    }

    bool CRefreshState::owed() const {
        return m_owed;
    }

    uint64_t CRefreshState::refreshes() const {
        return m_refreshes;
    }

} // namespace gf::layerpointer
