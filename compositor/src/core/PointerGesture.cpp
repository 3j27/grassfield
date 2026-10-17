#include "PointerGesture.hpp"

#include <algorithm>

namespace gf::input {

    bool CPointerGestureTracker::onPress(uint32_t button) {
        m_offeredRelease.reset();
        releaseOwnership(button); // an older press of this button never got its release

        if (!m_gesture)
            return false;
        // A press while a gesture is active: its release was lost (device gone, release consumed
        // elsewhere) or the user pressed another button. The gesture ends here; another button's
        // ownership stays, its release may still arrive.
        m_gesture.reset();
        return true;
    }

    void CPointerGestureTracker::claim(uint32_t button, bool startsGesture) {
        if (!owns(button))
            m_owned.push_back(button);
        if (startsGesture)
            m_gesture = button;
    }

    CPointerGestureTracker::SRelease CPointerGestureTracker::onRelease(uint32_t button) {
        m_offeredRelease.reset();
        SRelease result;
        result.owned = releaseOwnership(button);
        if (result.owned)
            m_offeredRelease = button; // a titlebar under the pointer consumes it; elsewhere the seat drops it
        if (m_gesture == button) {
            result.endsGesture = true;
            m_gesture.reset();
        }
        return result;
    }

    bool CPointerGestureTracker::onMotion(bool buttonsHeld, bool devicesIntact) {
        if (!m_gesture || (buttonsHeld && devicesIntact))
            return false;
        // The release will never arrive through the normal path: forget the gesture and its button.
        releaseOwnership(*m_gesture);
        m_gesture.reset();
        return true;
    }

    void CPointerGestureTracker::dropGesture() {
        m_gesture.reset();
    }

    bool CPointerGestureTracker::takeTitlebarRelease(uint32_t button) {
        if (m_offeredRelease != button)
            return false;
        m_offeredRelease.reset();
        return true;
    }

    bool CPointerGestureTracker::owns(uint32_t button) const {
        return std::ranges::find(m_owned, button) != m_owned.end();
    }

    std::optional<uint32_t> CPointerGestureTracker::gestureButton() const {
        return m_gesture;
    }

    void CPointerGestureTracker::reset() {
        m_owned.clear();
        m_gesture.reset();
        m_offeredRelease.reset();
    }

    bool CPointerGestureTracker::releaseOwnership(uint32_t button) {
        return std::erase(m_owned, button) > 0;
    }

} // namespace gf::input
