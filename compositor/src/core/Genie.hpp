#pragma once

// Genie minimize effect: the geometry of the window bending into its Dock tile (macOS "Genie", the default of
// System Settings > Desktop & Dock > "Minimize windows using"). Plain C++ with no Hyprland includes, so it is
// unit-testable (compositor/tests/GenieTest.cpp). The glue (Minimize.cpp, GenieDraw.cpp) draws the window snapshot
// on the mesh computed here.
//
// Model, Dock at the bottom (the other edges use the same math in a rotated frame, see Edge):
// - Every window row (source fraction v: 0 top .. 1 bottom) lies between a far edge (the window's top) and a near
//   edge (its bottom), spread linearly. The near edge travels to the tile's far side (its bottom) in the first half
//   of the effect; the far edge slides into the tile's near side (its top) from a quarter of the effect to its end.
// - A funnel gives every row its horizontal span: the window's span at the window's top, the tile's span from the
//   tile's top on, a smoothstep S-curve in between. While the funnel forms (the "bend", first 40 %), spans blend
//   from the window's own span into it: the sides pinch toward the tile, then the body slides down through them.
// - Progress 0 is exactly the window box, 1 exactly the target box. Positions are monotonic in progress and rows
//   never cross when the tile lies beyond the window toward the Dock edge (isGenieGeometry); the glue uses the Scale
//   effect otherwise.

#include "Minimize.hpp"

#include <cstdint>
#include <span>
#include <vector>

namespace gf::minimize {

    // The monitor edge the Dock is on. The shell sends only the tile rectangle: the edge is the side of the tile's
    // monitor closest to the tile (dockEdge).
    enum class Edge : uint8_t {
        Bottom,
        Top,
        Left,
        Right,
    };

    // Closest edge of `monitor` to `tile` (distance between the tile and each side); ties go to Bottom, then Left,
    // Right, Top (the Dock positions macOS offers, in this order). A degenerate input gives Bottom.
    Edge dockEdge(const Box& tile, const Box& monitor);

    // Phases, as fractions of the progress (0 window .. 1 tile).
    inline constexpr double kGenieBendEnd   = 0.4;  // the funnel is fully formed
    inline constexpr double kGenieNearEnd   = 0.5;  // the near edge (window bottom) reaches the tile's far side
    inline constexpr double kGenieFarStart  = 0.25; // the far edge (window top) starts sliding in

    // Mesh resolution: the funnel bends along the Dock axis, so that axis gets more subdivisions.
    inline constexpr int kGenieAcross = 32; // quads across the Dock axis (rows are straight segments in that direction)
    inline constexpr int kGenieAlong  = 96; // quads along the Dock axis (the S-curved sides)

    struct Point {
        double x = 0;
        double y = 0;
    };

    // A genie from `source` (the window's visible box) to `target` (where it ends, e.g. fitInside(source, tile)), both
    // in layout coordinates, toward the Dock on `edge`.
    class CGenie {
      public:
        CGenie(const Box& source, const Box& target, Edge edge);

        // Where the source point at fractions (u, v) of the source box is drawn at `progress` (clamped to [0, 1]).
        // u, v are 0..1 inside the box; values outside (the window's shadow) are extrapolated with the same map.
        Point at(double u, double v, double progress) const;

        Edge  edge() const {
            return m_edge;
        }

      private:
        // A box in the Dock frame: a = across the Dock axis, b = along it, increasing toward the Dock edge.
        struct SFrameBox {
            double a0 = 0, a1 = 0, b0 = 0, b1 = 0;
        };

        static SFrameBox toFrame(const Box& box, Edge edge);

        SFrameBox        m_src;
        SFrameBox        m_dst;
        Edge             m_edge;
    };

    // The genie draws without folding only when the target's far side lies beyond the source's far edge along the
    // Dock axis (the tile is toward the Dock from the window's top); both boxes must have an area and be finite.
    bool isGenieGeometry(const Box& source, const Box& target, Edge edge);

    // One mesh vertex: where it is drawn (layout coordinates) and the source fractions (u, v) it shows.
    struct SMeshVertex {
        double x = 0;
        double y = 0;
        double u = 0;
        double v = 0;
    };

    // Number of vertices of a mesh with `across` x `along` quads.
    constexpr int meshVertexCount(int across, int along) {
        return (across + 1) * (along + 1);
    }

    // The mesh of the source region `region` (layout; e.g. the window's box with its shadow, clipped to the snapshot)
    // at `progress`: (along + 1) lines of (across + 1) vertices, vertex index = line * (across + 1) + column; lines go
    // from the far edge to the near edge, columns across. `out` is resized. A region without area gives an empty mesh.
    void genieMesh(const CGenie& genie, const Box& source, const Box& region, double progress, int across, int along, std::vector<SMeshVertex>& out);

    // Triangle list (two per quad) for the vertex order of genieMesh.
    std::vector<uint16_t> meshIndices(int across, int along);

    // Bounding box of the mesh positions (empty box for an empty mesh).
    Box meshBounds(std::span<const SMeshVertex> mesh);

    // Timing: about half a second, as macOS. The window fades out over the last 15 % of a minimize (it is a sliver in
    // the tile by then) and in over the first 15 % of a restore. A restore is the minimize played backwards.
    inline constexpr double kGenieDurationMs   = 500.0;
    inline constexpr double kGenieFadeFraction = 0.15;

    struct SGenieFrame {
        double progress = 0;     // 0 window .. 1 tile
        float  alpha    = 1.F;   // snapshot opacity
        bool   done     = false; // elapsed >= duration
    };

    SGenieFrame genieFrameAt(Kind kind, double elapsedMs);

    // Elapsed time at which a `kind` genie shows `progress`: an animation interrupted by the opposite one continues
    // from the shape on screen.
    double genieElapsedFor(Kind kind, double progress);

} // namespace gf::minimize
