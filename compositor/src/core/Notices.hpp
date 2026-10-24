#pragma once

// The plugin's own notices (Hyprland notifications, shown when the shell cannot speak for it: the plugin refuses itself
// before any gfc/1 channel exists, or failed to start). macOS shows system notices in the user's language (GF-067): the
// text comes from this compiled table, by the session locale (POSIX order: LC_ALL, then LC_MESSAGES, then LANG; the first
// set and not empty decides). French and English; anything else gets English. Pure (no Hyprland include): unit-tested in
// tests/NoticesTest.cpp, which also checks that every notice has a French text.

#include <array>
#include <cstdint>
#include <string_view>

namespace gf::notices {

    enum class Notice : uint8_t {
        AbiMismatch, // the build is for another Hyprland: the plugin refuses itself (degraded mode, C2)
        InitFailed,  // PLUGIN_INIT failed and rolled back: no titlebars
    };

    inline constexpr std::array kAll = {Notice::AbiMismatch, Notice::InitFailed};

    enum class Lang : uint8_t { En, Fr };

    // The language of the session's messages from the values of LC_ALL, LC_MESSAGES and LANG (null: unset). The first set
    // and not empty decides: "fr", "fr_FR.UTF-8", "fr_CA@euro" -> Fr; "C", "POSIX", "en_US.UTF-8", anything else -> En.
    Lang languageFrom(const char* lcAll, const char* lcMessages, const char* lang);

    // The notice's text in that language (never empty; English for a language without a text).
    std::string_view text(Notice notice, Lang lang);

} // namespace gf::notices
