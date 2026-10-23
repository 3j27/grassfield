#include "ClientChrome.hpp"

#include <algorithm>

namespace gf::chrome {

    bool hasClientChromeTag(const std::set<std::string>& tags) {
        return std::ranges::any_of(tags, [](const std::string& tag) {
            std::string_view name = tag;
            if (name.ends_with('*'))
                name.remove_suffix(1);
            return name == kTag;
        });
    }

    double band(bool clientChrome) {
        return clientChrome ? 0.0 : theme::kTitlebarHeight;
    }

    bool moveAnswersPress(const std::optional<ZoomedPress>& press, uint64_t window, bool buttonHeld, uint64_t nowMs) {
        if (!press || press->window == 0 || press->window != window || !buttonHeld)
            return false;
        return nowMs >= press->timeMs && nowMs - press->timeMs <= kMovePressMaxAgeMs;
    }

    titlebar::Rect unzoomedBox(const ZoomedPress& press, double restoredW, double restoredH, double pointerX, double pointerY) {
        return titlebar::unzoomedDragBox(press.zoomed, restoredW, restoredH, press.x, press.y, pointerX, pointerY);
    }

    ZoomAction zoomAction(bool maximized, bool fullscreen, bool altHeld) {
        if (fullscreen)
            return ZoomAction::LeaveFullscreen;
        if (altHeld)
            return ZoomAction::EnterFullscreen;
        return maximized ? ZoomAction::Unzoom : ZoomAction::Zoom;
    }

    bool zoomGlyphIsArrows(bool altHeld) {
        return altHeld;
    }

} // namespace gf::chrome
