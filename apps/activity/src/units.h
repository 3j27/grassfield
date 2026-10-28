// What a process is, from its cgroup path and its owner (ADR-0038 AD20, AD22, AD25, AD26; docs/specs/activity.md AM54, AM65,
// AM68). Pure functions, unit-tested on fixture paths (tests/unit/activity/tst_units.cpp).
#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

namespace activity
{

// Processes, by Type (AM65), in the order the view shows them.
enum class Kind { App, Background, Session, System, OtherUser };

// The last component of a cgroup path ("/user.slice/.../app-Hyprland-foot-1a2b3c4d.scope" → "app-Hyprland-foot-1a2b3c4d.scope").
std::string_view unitOf(std::string_view cgroupPath);

// systemd's escape undone: every "\xNN" becomes its byte (uwsm writes "-" as "\x2d", A7). Malformed escapes stay as they are.
std::string unescapeUnit(std::string_view part);

// A unit uwsm named for one launch (A7): app-<desktop>-<name>-<8 hex>.scope or app-<desktop>-<name>@<8 hex>.service.
// `name` is unescaped: a desktop id without ".desktop" (a launch by desktop entry) or a command's basename.
struct AppUnit {
    std::string desktop;
    std::string name;
    std::string suffix; // the 8 hex digits
    bool scope = true;
};

std::optional<AppUnit> parseAppUnit(std::string_view unit);

// A session process (AM54): its unit ends the session or runs it. Units of session.slice or session-graphical.slice, uwsm's
// wayland-session-bindpid@<pid>.service whatever its slice, the login session's session-<n>.scope directly under
// user-<uid>.slice, the user manager's init.scope.
bool isSessionProcess(std::string_view cgroupPath);

// The Kind of a process. `own`: its uid is the app's; `systemAccount`: its uid is below UID_MIN; `ownsWindow`: the shell's
// projection names it (AM60).
Kind classify(std::string_view cgroupPath, bool own, bool systemAccount, bool ownsWindow);

// Efficiency Mode applies (AM68): an own process in a unit uwsm named for one launch under app-graphical.slice.
bool efficiencyEligible(std::string_view cgroupPath);

// UID_MIN of /etc/login.defs (1000 when the file says nothing).
uint32_t parseUidMin(std::string_view loginDefs);

} // namespace activity
