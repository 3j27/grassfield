#include "units.h"

#include <charconv>

namespace activity
{
namespace
{

bool startsWith(std::string_view s, std::string_view p)
{
    return s.size() >= p.size() && s.substr(0, p.size()) == p;
}

bool endsWith(std::string_view s, std::string_view p)
{
    return s.size() >= p.size() && s.substr(s.size() - p.size()) == p;
}

bool isHex(char c)
{
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

int hexValue(char c)
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    return c - 'A' + 10;
}

bool allDigits(std::string_view s)
{
    if (s.empty())
        return false;
    for (char c : s) {
        if (c < '0' || c > '9')
            return false;
    }
    return true;
}

// The component of `path` before its last one ("" for a path of one component).
std::string_view parentOf(std::string_view path)
{
    while (!path.empty() && path.back() == '/')
        path.remove_suffix(1);
    const size_t last = path.rfind('/');
    if (last == std::string_view::npos || last == 0)
        return {};
    const std::string_view head = path.substr(0, last);
    const size_t prev = head.rfind('/');
    return prev == std::string_view::npos ? head : head.substr(prev + 1);
}

} // namespace

std::string_view unitOf(std::string_view cgroupPath)
{
    while (!cgroupPath.empty() && cgroupPath.back() == '/')
        cgroupPath.remove_suffix(1);
    const size_t slash = cgroupPath.rfind('/');
    return slash == std::string_view::npos ? cgroupPath : cgroupPath.substr(slash + 1);
}

std::string unescapeUnit(std::string_view part)
{
    std::string out;
    out.reserve(part.size());
    for (size_t i = 0; i < part.size(); ++i) {
        if (part[i] == '\\' && i + 3 < part.size() && part[i + 1] == 'x' && isHex(part[i + 2]) && isHex(part[i + 3])) {
            out.push_back(static_cast<char>(hexValue(part[i + 2]) * 16 + hexValue(part[i + 3])));
            i += 3;
        } else {
            out.push_back(part[i]);
        }
    }
    return out;
}

std::optional<AppUnit> parseAppUnit(std::string_view unit)
{
    AppUnit u;
    std::string_view body;
    if (endsWith(unit, ".scope")) {
        body = unit.substr(0, unit.size() - 6);
        u.scope = true;
    } else if (endsWith(unit, ".service")) {
        body = unit.substr(0, unit.size() - 8);
        u.scope = false;
    } else {
        return std::nullopt;
    }
    if (!startsWith(body, "app-"))
        return std::nullopt;
    body.remove_prefix(4);
    // The suffix: "-<8 hex>" for a scope, "@<8 hex>" for a service (uwsm's random_hex(8)).
    const size_t sep = u.scope ? body.rfind('-') : body.rfind('@');
    if (sep == std::string_view::npos)
        return std::nullopt;
    const std::string_view suffix = body.substr(sep + 1);
    if (suffix.size() != 8)
        return std::nullopt;
    for (char c : suffix) {
        if (!isHex(c))
            return std::nullopt;
    }
    body = body.substr(0, sep);
    // "<desktop>-<name>": each part is escaped, so a "-" inside either became "\x2d"; the first "-" separates them.
    const size_t dash = body.find('-');
    if (dash == std::string_view::npos || dash == 0 || dash + 1 >= body.size())
        return std::nullopt;
    const std::string_view name = body.substr(dash + 1);
    if (name.find('-') != std::string_view::npos || name.find('@') != std::string_view::npos)
        return std::nullopt;
    u.desktop = unescapeUnit(body.substr(0, dash));
    u.name = unescapeUnit(name);
    u.suffix = std::string(suffix);
    return u;
}

bool isSessionProcess(std::string_view cgroupPath)
{
    if (cgroupPath.find("/session.slice/") != std::string_view::npos
        || cgroupPath.find("/session-graphical.slice/") != std::string_view::npos)
        return true;
    const std::string_view unit = unitOf(cgroupPath);
    if (startsWith(unit, "wayland-session-bindpid@") && endsWith(unit, ".service"))
        return true;
    // The user manager itself: <...>/user@<uid>.service/init.scope.
    if (unit == "init.scope" && startsWith(parentOf(cgroupPath), "user@") && endsWith(parentOf(cgroupPath), ".service"))
        return true;
    // The login session: <...>/user-<uid>.slice/session-<n>.scope.
    if (startsWith(unit, "session-") && endsWith(unit, ".scope") && allDigits(unit.substr(8, unit.size() - 8 - 6))) {
        const std::string_view parent = parentOf(cgroupPath);
        return startsWith(parent, "user-") && endsWith(parent, ".slice");
    }
    return false;
}

Kind classify(std::string_view cgroupPath, bool own, bool systemAccount, bool ownsWindow)
{
    if (!own)
        return systemAccount ? Kind::System : Kind::OtherUser;
    if (isSessionProcess(cgroupPath))
        return Kind::Session;
    if (ownsWindow || cgroupPath.find("/app-graphical.slice/") != std::string_view::npos)
        return Kind::App;
    return Kind::Background;
}

bool efficiencyEligible(std::string_view cgroupPath)
{
    if (cgroupPath.find("/app-graphical.slice/") == std::string_view::npos || isSessionProcess(cgroupPath))
        return false;
    return parseAppUnit(unitOf(cgroupPath)).has_value();
}

uint32_t parseUidMin(std::string_view loginDefs)
{
    size_t pos = 0;
    while (pos < loginDefs.size()) {
        size_t end = loginDefs.find('\n', pos);
        if (end == std::string_view::npos)
            end = loginDefs.size();
        std::string_view line = loginDefs.substr(pos, end - pos);
        pos = end + 1;
        while (!line.empty() && (line.front() == ' ' || line.front() == '\t'))
            line.remove_prefix(1);
        if (!startsWith(line, "UID_MIN"))
            continue;
        line.remove_prefix(7);
        if (line.empty() || (line.front() != ' ' && line.front() != '\t'))
            continue;
        while (!line.empty() && (line.front() == ' ' || line.front() == '\t'))
            line.remove_prefix(1);
        size_t n = 0;
        while (n < line.size() && line[n] >= '0' && line[n] <= '9')
            ++n;
        uint32_t v = 0;
        const auto r = std::from_chars(line.data(), line.data() + n, v);
        if (r.ec == std::errc() && n > 0)
            return v;
    }
    return 1000;
}

} // namespace activity
