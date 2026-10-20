#pragma once

// Draws a window snapshot on a deformed mesh (the Genie minimize effect, core/Genie.*). Hyprland 0.56.2 glue: a
// render pass element of type EK_CUSTOM whose draw() runs while Hyprland renders the pass, in pass order (after the
// windows, before the top layers, like the Scale effect's CTexPassElement), and issues its own GLES 3 draw call: one
// indexed triangle list, a minimal textured shader with an opacity uniform, scissored to the frame's damage.
//
// GL state contract: the program, vertex array, array buffer, active texture unit and 2D texture binding are read
// before the draw and restored after it, so Hyprland's own state caches stay true; blending and scissoring go through
// Hyprland's cache-aware calls. GL objects (program, buffers, vertex array) are created on the first draw (the EGL
// context is current then) and deleted by release() with the context made current (plugin unload).
// Only with the GL renderer (IHyprRenderer::RT_GL); available() is false otherwise, or after a shader failure, and the
// minimizer then uses the Scale effect.

#include "core/Genie.hpp"

#include <hyprland/src/helpers/math/Math.hpp>
#include <hyprland/src/helpers/memory/Memory.hpp>
#include <hyprland/src/render/Texture.hpp>
#include <hyprland/src/render/pass/PassElement.hpp>

#include <cstdint>
#include <optional>
#include <vector>

namespace gf::genie {

    // The renderer is GL and nothing failed so far (shader compile / link, GL errors, a custom element never drawn).
    bool available();

    // Marks the Genie drawing unusable (logged once with `why`): the minimizer falls back to the Scale effect.
    void disable(const char* why);

    // Number of custom elements whose draw() ran since the plugin loaded (to detect a renderer that skips them).
    uint64_t drawnCount();

    // Longest CPU time spent in one draw() since the last call, in microseconds (0 when none ran), then reset.
    double takeMaxDrawMicros();

    // Deletes the GL objects (EGL context made current). Unload, or the renderer going away.
    void release();

    // One frame of a genie on the monitor being rendered.
    struct SDrawData {
        SP<Render::ITexture> tex;
        // Per vertex: x, y (pixels of the monitor being rendered, before its transform), s, t (texture coordinates).
        std::vector<float> vertices;
        int                across = 0; // mesh size (quads), as built by core genieMesh
        int                along  = 0;
        CBox               pixelBounds;   // bounding box of the vertices (pixels)
        CBox               logicalBounds; // the same in monitor-local logical coordinates (pass bookkeeping)
        float              alpha = 1.F;
    };

    class CGenieElement : public IPassElement {
      public:
        explicit CGenieElement(SDrawData&& data);
        ~CGenieElement() override = default;

        CGenieElement(const CGenieElement&)            = delete;
        CGenieElement& operator=(const CGenieElement&) = delete;
        CGenieElement(CGenieElement&&)                 = delete;
        CGenieElement& operator=(CGenieElement&&)      = delete;

        std::vector<UP<IPassElement>> draw() override;
        bool                          needsLiveBlur() override;
        bool                          needsPrecomputeBlur() override;
        const char*                   passName() override;
        ePassElementType              type() override;
        std::optional<CBox>           boundingBox() override;
        CRegion                       opaqueRegion() override;

      private:
        SDrawData m_data;
    };

} // namespace gf::genie
