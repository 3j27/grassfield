#pragma once

// Pointer focus on a Grassfield layer surface that maps or takes the keyboard under a resting pointer (gfc/1 feature
// "layer-pointer", spec FR47-FR48). Hyprland 0.56.2 glue; the reason and the decisions are in core/LayerPointer.*.
//
// Hooks (installed headers): the event bus `layer.opened` (emitted from CLayerSurface::onMap) and `input.keyboard.focus`
// (the seat's keyboard going to a layer surface, also from CLayerSurface::onCommit), one coalesced callback from
// Hyprland's event loop (gf::deferredFocus::CLater), CInputManager::simulateMouseMovement plus a pointer frame (the same
// refresh Stages uses, FR38), and the plugin's first pointer button listener (main.cpp) for a refresh that waited for a
// release or a pointer device. Compositor thread only, nothing blocks.

namespace gf::layerPointer {

    // Registers the layer and keyboard focus listeners. False when the event bus is missing (then layer-pointer is not
    // advertised).
    bool start();

    // Unload: removes the listeners and the scheduled callback (its code is in this library). Safe to call more than once.
    void stop();

    // start() succeeded and stop() has not run.
    bool ready();

    // From the plugin's first pointer button listener, before Hyprland handles the button: an owed refresh runs before a
    // press, or is scheduled after a release.
    void beforePointerButton(bool pressed);

} // namespace gf::layerPointer
