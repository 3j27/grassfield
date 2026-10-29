#pragma once

// Presentation-time probe (ADR-0006 gate P3; core/FrameLog.hpp): every monitor's presented frames (CMonitor::
// m_events.presented, the output's presentation feedback) go into a per-monitor ring of CLOCK_MONOTONIC microseconds,
// returned by `hyprctl grassfield-frames` (registered in Ipc.cpp; feature "frame-times"). One timestamp per presented
// frame: no allocation once a monitor's ring exists, nothing else done on the compositor thread. For attribution, also the
// CPU span of each rendered frame (render.preChecks to RENDER_POST), the phase marks of the plugin's animations, the event
// loop's stalls (a beat every frames::kBeatUs while recording; a late one shows the loop was held) and the plugin's own work
// outside a render (the shared edge's drag). Off by default: only for kMaxRecordingMs after a start request, never while the
// session is locked (core/FrameLog.hpp).

#include <cstdint>
#include <string>
#include <string_view>

namespace gf::frameProbe {

    // Listens to every monitor's presentations and to monitors being added and removed. False if the event bus is missing.
    bool start();

    // Unload: removes every listener (their callbacks are code of this library) and drops the rings.
    void stop();

    bool ready();

    // The JSON `hyprctl grassfield-frames` returns (core framesJson), monitors in Hyprland's order; empty while the session
    // is locked (what was recorded is dropped then).
    std::string json();

    // `hyprctl grassfield-frames-start`: record for the next frames::kMaxRecordingMs (nothing is recorded otherwise, and
    // never while the session is locked). Returns {"v":"gfc/1","type":"frames-recording","recording":bool[,"ms":N]}.
    std::string startRecording();

    // A phase of one of the plugin's animations ("overview-opening", ...), now. Nothing when the probe is not running.
    void mark(std::string_view what);

    // The probe's clock (CLOCK_MONOTONIC microseconds), for work().
    uint64_t nowUs();

    // The plugin's own work on the compositor thread outside a render, from `beginUs` (nowUs() at its start) to now: the
    // shared edge's drag (tiling.md TL30). Recorded only while recording (and never while the session is locked).
    void work(uint64_t beginUs);

} // namespace gf::frameProbe
