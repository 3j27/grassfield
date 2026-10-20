#pragma once

// Minimize / restore animation logic (master-prompt §5.6 feature 2, ADR-0002). Plain C++ with no Hyprland
// includes, so it is unit-testable (compositor/tests/). The Hyprland glue (Minimize.cpp) validates the
// shell's arguments with it and draws a window snapshot at the boxes it computes.
//
// Coordinates: "layout" = Hyprland's global logical coordinates (what hyprctl reports as `at`/`size`, and
// what the shell sends as the Dock tile rectangle); "pixels" = a monitor's framebuffer coordinates.

#include <cstdint>
#include <optional>
#include <span>
#include <string_view>

namespace gf::minimize {

    struct Box {
        double x = 0;
        double y = 0;
        double w = 0;
        double h = 0;

        bool   operator==(const Box&) const = default;
    };

    // Hyprland window address as the shell sends it: optional "0x", then 1 to 16 hex digits, nothing else.
    std::optional<uint64_t> parseAddress(std::string_view text);

    // All four numbers are finite.
    bool isFinite(const Box& b);

    // A usable animation target (the Dock tile): finite, 1..kMaxTargetSide layout pixels per side and fully
    // inside one monitor box (layout coordinates, kLayoutTolerance px tolerance). Anything else means "no
    // target": the window is minimized or restored without animation.
    inline constexpr double kMaxTargetSide   = 1024.0;
    inline constexpr double kLayoutTolerance = 1.0;
    bool                    isValidTarget(const Box& target, std::span<const Box> monitors);

    // The largest box with source's aspect ratio that fits in target, centered in it (the window shrinks
    // uniformly into the tile; it is never distorted). A degenerate source returns target.
    Box fitInside(const Box& source, const Box& target);

    // Component-wise linear interpolation, t in [0, 1].
    Box lerp(const Box& a, const Box& b, double t);

    // CSS-style cubic Bézier easing through (0,0), (x1,y1), (x2,y2), (1,1); x1 and x2 are clamped to [0, 1]
    // so the curve is a function of time.
    class CCubicBezier {
      public:
        constexpr CCubicBezier(double x1, double y1, double x2, double y2) :
            m_x1(x1 < 0 ? 0 : (x1 > 1 ? 1 : x1)), m_y1(y1), m_x2(x2 < 0 ? 0 : (x2 > 1 ? 1 : x2)), m_y2(y2) {}

        // Eased progress for linear time t (clamped to [0, 1]).
        double operator()(double t) const;

      private:
        double m_x1, m_y1, m_x2, m_y2;
    };

    enum class Kind : uint8_t {
        Minimize, // window box -> tile, ease-in, fades out at the end
        Restore,  // tile -> window box, ease-out, fades in at the start
    };

    // The minimize effect (Settings dock.minimizeEffect, pushed by the shell with hl.plugin.grassfield.config):
    // Genie (macOS default, core/Genie.*), Scale (uniform shrink into the tile, frameAt) or Fade (Reduce Motion: the
    // window fades out where it is, fadeFrameAt; the shell sends it while accessibility.reduceMotion is on).
    enum class Effect : uint8_t {
        Genie,
        Scale,
        Fade,
    };

    inline constexpr std::string_view kConfigMinimizeEffect = "minimizeEffect";

    // nullopt unless key is kConfigMinimizeEffect and value is exactly "genie", "scale" or "fade".
    std::optional<Effect> parseEffect(std::string_view key, std::string_view value);

    struct Frame {
        Box   box;           // where the window's visible box is drawn (layout coordinates)
        float alpha = 1.F;   // snapshot opacity
        bool  done  = false; // elapsed >= duration: the animation is over
    };

    // Animation timing (Grassfield values; ~300 ms like the macOS "Scale" effect).
    inline constexpr double kMinimizeDurationMs = 300.0;
    inline constexpr double kRestoreDurationMs  = 300.0;
    inline constexpr double kFadeFraction       = 0.2; // share of the duration spent fading (end / start)
    double                  durationMs(Kind kind);
    CCubicBezier            curve(Kind kind); // ease-in for Minimize, its time-reverse (ease-out) for Restore

    // State of an animation from `from` to `to` after elapsedMs (negative elapsed = start).
    Frame frameAt(Kind kind, const Box& from, const Box& to, double elapsedMs);

    // Reduce Motion: a quick fade in place, no movement (Tokens.motionReducedMax, docs/specs/ui.md).
    inline constexpr double kFadeDurationMs = 100.0;

    // State of a Fade animation of the window box `box` after elapsedMs: the box never moves; alpha goes 1 -> 0
    // (Minimize) or 0 -> 1 (Restore), linearly.
    Frame fadeFrameAt(Kind kind, const Box& box, double elapsedMs);

    // The affine map that sends `src` onto `dst` (per-axis scale + translation), applied to `inner`
    // (e.g. the window's full box with its shadow, for damage).
    Box mapBox(const Box& inner, const Box& src, const Box& dst);

    // A window snapshot: a texture of the whole source monitor (texW x texH pixels, the monitor's transformed
    // size) in which the window's visible box `visible` (layout) was rendered at its place.
    struct SSnapshotGeometry {
        Box    visible;
        double monitorX     = 0; // source monitor position (layout)
        double monitorY     = 0;
        double monitorScale = 1;
        double texW         = 0;
        double texH         = 0;
    };

    // Box (pixels of the monitor being rendered: position monX/monY, scale monScale) at which to draw the whole
    // snapshot texture so that its window region lands on `dst` (layout). Same math as Hyprland 0.56.2's
    // CWindowFadeout::renderBox, generalized to drawing on another monitor.
    Box textureBox(const SSnapshotGeometry& snapshot, const Box& dst, double monX, double monY, double monScale);

    // Boxes intersect (shared area > 0).
    bool intersects(const Box& a, const Box& b);

} // namespace gf::minimize
