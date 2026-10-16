#pragma once

// gfc/1: the versioned shell <-> grassfield-compositor protocol (master-prompt §5.3, ADR-0007 input).
// Plain C++ with no Hyprland includes, so it is unit-testable (compositor/tests/).
//
// Transport measured in spike S2:
//   plugin -> shell: Hyprland's socket2 event stream. Hyprland formats each event as
//                    "<name>>><data>\n"; the plugin posts name "grassfield" with compact JSON as data.
//   shell -> plugin: Lua functions under hl.plugin.grassfield.*, reached with
//                    `hyprctl dispatch 'hl.plugin.grassfield.<verb>()'` / Hyprland.dispatch(...) in
//                    Quickshell (Hyprland evaluates `return hl.dispatch(<arg>)` under the Lua config).
//   query:           `hyprctl grassfield` returns the capabilities JSON.

#include <span>
#include <string>
#include <string_view>

namespace gf::gfc {

    inline constexpr std::string_view kVersion        = "gfc/1";
    inline constexpr std::string_view kEventName      = "grassfield"; // socket2 event name
    inline constexpr std::string_view kHyprctlCommand = "grassfield"; // `hyprctl grassfield`
    inline constexpr std::string_view kLuaNamespace   = "grassfield"; // hl.plugin.grassfield
    inline constexpr std::string_view kLuaHello       = "hello";      // hl.plugin.grassfield.hello(): re-posts capabilities

    // What a shell sends through Hyprland.dispatch() to call a plugin verb.
    std::string luaDispatchRequest(std::string_view verb);

    // Features implemented by this build. Only advertise what really works (R11).
    inline constexpr std::string_view kFeatureDecorations = "decorations";
    inline constexpr std::string_view kFeatures[]         = {kFeatureDecorations};

    // JSON string escaping (RFC 8259): quotes, backslash and control characters.
    std::string jsonEscape(std::string_view in);

    // {"v":"gfc/1","type":"capabilities","features":[...]}
    std::string capabilitiesJson(std::span<const std::string_view> features = kFeatures);

    // PLACEHOLDER (M2): the minimize button only reports the request; nothing is minimized yet.
    // {"v":"gfc/1","type":"minimize-request","address":"<hex address, no 0x, as in socket2 events>"}
    std::string minimizeRequestJson(std::string_view windowAddress);

    // The line a socket2 subscriber receives for a given payload (without the trailing newline).
    std::string socket2Line(std::string_view json);

} // namespace gf::gfc
