#include "Appmenu.hpp"

#include <algorithm>
#include <utility>

namespace gf::appmenu {

    namespace {
        bool isAsciiAlpha(char c) {
            return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
        }

        bool isAsciiDigit(char c) {
            return c >= '0' && c <= '9';
        }

        bool isBusNameChar(char c) {
            return isAsciiAlpha(c) || isAsciiDigit(c) || c == '_' || c == '-';
        }

        bool isPathChar(char c) {
            return isAsciiAlpha(c) || isAsciiDigit(c) || c == '_';
        }
    } // namespace

    bool isValidBusName(std::string_view name) {
        if (name.empty() || name.size() > kMaxNameLength)
            return false;
        const bool unique = name.front() == ':';
        if (unique)
            name.remove_prefix(1);

        size_t elements = 0;
        while (true) {
            const size_t           dot     = name.find('.');
            const std::string_view element = name.substr(0, dot);
            if (element.empty() || !std::ranges::all_of(element, isBusNameChar))
                return false;
            if (!unique && isAsciiDigit(element.front()))
                return false;
            ++elements;
            if (dot == std::string_view::npos)
                break;
            name.remove_prefix(dot + 1);
        }
        return elements >= 2;
    }

    bool isValidObjectPath(std::string_view path) {
        if (path.empty() || path.size() > kMaxNameLength || path.front() != '/')
            return false;
        if (path.size() == 1)
            return true; // "/"
        path.remove_prefix(1);
        while (true) {
            const size_t           slash   = path.find('/');
            const std::string_view element = path.substr(0, slash);
            if (element.empty() || !std::ranges::all_of(element, isPathChar))
                return false; // "//", trailing "/" or a bad character
            if (slash == std::string_view::npos)
                return true;
            path.remove_prefix(slash + 1);
        }
    }

    bool isValidAddress(std::string_view service, std::string_view path) {
        return isValidBusName(service) && isValidObjectPath(path);
    }

    std::optional<Announcement> CRegistry::setAddress(uint64_t surface, uint64_t object, Registration registration, uint64_t window) {
        auto it = std::ranges::find(m_entries, surface, &SEntry::surface);
        if (it == m_entries.end()) {
            m_entries.push_back(SEntry{.surface = surface});
            it = std::prev(m_entries.end());
        }
        it->object = object;
        if (window != 0 && it->window != window) {
            it->window    = window;
            it->announced = false;
        }
        const bool changed = it->registration != registration;
        it->registration   = std::move(registration);
        if (it->window == 0 || (!changed && it->announced))
            return std::nullopt;
        it->announced = true;
        return Announcement{.window = it->window, .registration = it->registration};
    }

    std::optional<Announcement> CRegistry::windowMapped(uint64_t surface, uint64_t window) {
        const auto it = std::ranges::find(m_entries, surface, &SEntry::surface);
        if (it == m_entries.end() || window == 0)
            return std::nullopt;
        it->window    = window;
        it->announced = true;
        return Announcement{.window = window, .registration = it->registration};
    }

    std::optional<Announcement> CRegistry::windowGone(uint64_t window) {
        std::optional<Announcement> out;
        if (window == 0)
            return out;
        for (auto& e : m_entries) {
            if (e.window != window)
                continue;
            if (e.announced)
                out = Announcement{.window = window};
            e.window    = 0;
            e.announced = false;
        }
        return out;
    }

    std::optional<Announcement> CRegistry::erase(std::vector<SEntry>::iterator it) {
        std::optional<Announcement> out;
        if (it->announced && it->window != 0)
            out = Announcement{.window = it->window};
        m_entries.erase(it);
        return out;
    }

    std::optional<Announcement> CRegistry::objectGone(uint64_t object) {
        const auto it = std::ranges::find(m_entries, object, &SEntry::object);
        if (it == m_entries.end())
            return std::nullopt;
        return erase(it);
    }

    std::optional<Announcement> CRegistry::surfaceGone(uint64_t surface) {
        const auto it = std::ranges::find(m_entries, surface, &SEntry::surface);
        if (it == m_entries.end())
            return std::nullopt;
        return erase(it);
    }

    Announcement CRegistry::query(uint64_t window) const {
        const auto it = std::ranges::find(m_entries, window, &SEntry::window);
        if (window == 0 || it == m_entries.end())
            return Announcement{.window = window};
        return Announcement{.window = window, .registration = it->registration};
    }

    std::vector<Announcement> CRegistry::clear() {
        std::vector<Announcement> out;
        for (const auto& e : m_entries) {
            if (e.announced && e.window != 0)
                out.push_back(Announcement{.window = e.window});
        }
        m_entries.clear();
        return out;
    }

    std::vector<uint64_t> CRegistry::windows() const {
        std::vector<uint64_t> out;
        for (const auto& e : m_entries) {
            if (e.window != 0)
                out.push_back(e.window);
        }
        return out;
    }

    size_t CRegistry::size() const {
        return m_entries.size();
    }

} // namespace gf::appmenu
