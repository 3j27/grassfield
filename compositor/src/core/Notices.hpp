#pragma once

// The plugin's own notices (Hyprland notifications, shown when the shell cannot speak for it: the plugin refuses itself
// before any gfc/1 channel exists, or failed to start). macOS shows system notices in the user's language (GF-067): the
// text comes from this compiled table, its language chosen by gettext's rule: LANGUAGE's first entry unless the locale is
// C or POSIX, then LC_ALL, LC_MESSAGES, LANG (the first set and not empty). French and English; anything else gets
// English. The shell can differ: it takes Qt's system locale (ui/i18n/translationloader.h), which still follows LANGUAGE
// under LANG=C.UTF-8, where gettext ignores it: `LANGUAGE=fr LANG=C.UTF-8` gives a French shell and English plugin
// notices (gettext's rule, kept on purpose). Pure (no Hyprland include): unit-tested in
// tests/NoticesTest.cpp, which also checks that every notice is in kAll and has a French text.

#include <array>
#include <cstdint>
#include <string_view>

namespace gf::notices {

    enum class Notice : uint8_t {
        AbiMismatch, // the build is for another Hyprland: the plugin refuses itself (degraded mode, C2)
        InitFailed,  // PLUGIN_INIT failed and rolled back: no titlebars
        End,         // not a notice: one past the last (the test checks that kAll lists every notice before it)
    };

    inline constexpr std::array kAll = {Notice::AbiMismatch, Notice::InitFailed};

    enum class Lang : uint8_t { En, Fr };

    // The language of the session's messages from the values of LANGUAGE, LC_ALL, LC_MESSAGES and LANG (null: unset), in
    // gettext's order: the locale is the first of LC_ALL, LC_MESSAGES, LANG that is set and not empty; when it is set and
    // not C or POSIX (also C.<codeset>), LANGUAGE's first entry, if any, wins over it. "fr", "fr_FR.UTF-8", "fr-FR",
    // "fr_CA@euro" -> Fr; "C", "POSIX", "en_US.UTF-8", anything else -> En.
    Lang languageFrom(const char* language, const char* lcAll, const char* lcMessages, const char* lang);

    // The notice's text in that language (never empty; English for a language without a text).
    std::string_view text(Notice notice, Lang lang);

} // namespace gf::notices
