#pragma once

// Appmenu logic (master-prompt §5.6 feature 3, D4, ADR-0008). Plain C++ with no Hyprland or Wayland
// includes, so it is unit-testable (compositor/tests/). The Hyprland glue (Appmenu.cpp) implements the
// org_kde_kwin_appmenu_manager global: clients link a wl_surface to a DBusMenu (service name, object path)
// with org_kde_kwin_appmenu.set_address. The plugin validates the strings (untrusted client input), keeps
// the latest address per surface here, and announces it per window to the shell over gfc/1:
//   grassfield>>{"v":"gfc/1","type":"appmenu","address":"<hex>","service":"<bus name>","path":"<path>"}
// with empty service and path when the window has no (more) registration.

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace gf::appmenu {

    // Longest service name / object path accepted (D-Bus caps bus names at 255; paths get the same cap).
    inline constexpr size_t kMaxNameLength = 255;

    // D-Bus bus name: a unique name (":1.42") or a well-known name ("org.kde.Foo"): at most 255 bytes, at
    // least two non-empty dot-separated elements of [A-Za-z0-9_-]; elements of well-known names do not start
    // with a digit. Anything else (spaces, NUL, non-ASCII, leading or doubled dots) is rejected.
    bool isValidBusName(std::string_view name);

    // D-Bus object path: "/" or "/" followed by non-empty "/"-separated elements of [A-Za-z0-9_], no
    // trailing "/", at most 255 bytes.
    bool isValidObjectPath(std::string_view path);

    // Both strings of a set_address request are valid (the request is ignored otherwise).
    bool isValidAddress(std::string_view service, std::string_view path);

    struct Registration {
        std::string service;
        std::string path;

        bool        operator==(const Registration&) const = default;
    };

    // One gfc/1 appmenu event to post: the window's registration, or empty service and path ("no menu").
    struct Announcement {
        uint64_t     window = 0;
        Registration registration{};

        bool         operator==(const Announcement&) const = default;
    };

    // Latest DBusMenu address per wl_surface and the mapped window that shows the surface. Surfaces, appmenu
    // objects and windows are opaque non-zero ids (their addresses in the plugin, compared, never followed).
    // Each method returns the event to post, if any: an announcement is posted when a mapped window gets a new
    // registration (or is mapped again with one), and a clear when an announced registration goes away.
    class CRegistry {
      public:
        // set_address from `object` on `surface`, already validated. `window`: the surface's mapped window,
        // 0 when it is not mapped yet (announced later by windowMapped). The latest request on a surface wins.
        // An unchanged, already announced registration announces nothing.
        std::optional<Announcement> setAddress(uint64_t surface, uint64_t object, Registration registration, uint64_t window);

        // The window showing `surface` was mapped: announces the surface's registration, if there is one.
        std::optional<Announcement> windowMapped(uint64_t surface, uint64_t window);

        // The window was unmapped or destroyed: clears its announced registration. The registration stays with
        // the surface, so a window mapped again on the same surface is announced again.
        std::optional<Announcement> windowGone(uint64_t window);

        // The appmenu object was released or destroyed: the registration it made goes away.
        std::optional<Announcement> objectGone(uint64_t object);

        // The surface was destroyed: its registration goes away.
        std::optional<Announcement> surfaceGone(uint64_t surface);

        // What the window shows now (empty registration when none): for focus changes and re-emits.
        Announcement query(uint64_t window) const;

        // Removes everything; returns a clear for each announced window (plugin unload).
        std::vector<Announcement> clear();

        // The windows currently linked to a registered surface.
        std::vector<uint64_t> windows() const;

        size_t                size() const;

      private:
        struct SEntry {
            uint64_t     surface = 0;
            uint64_t     object  = 0; // the appmenu object that made the latest request
            Registration registration{};
            uint64_t     window    = 0; // mapped window showing the surface, 0 if none
            bool         announced = false;
        };

        std::optional<Announcement> erase(std::vector<SEntry>::iterator it);

        std::vector<SEntry>         m_entries;
    };

} // namespace gf::appmenu
