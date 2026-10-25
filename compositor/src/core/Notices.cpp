#include "Notices.hpp"

namespace gf::notices {

    namespace {
        bool set(const char* value) {
            return value != nullptr && value[0] != '\0';
        }

        // "fr" alone or followed by a territory, codeset or modifier ("fr_FR", "fr-FR", "fr.UTF-8", "fr@euro").
        bool isFrench(std::string_view locale) {
            return locale.starts_with("fr") &&
                (locale.size() == 2 || locale[2] == '_' || locale[2] == '-' || locale[2] == '.' || locale[2] == '@');
        }

        // The C locale, under which gettext ignores LANGUAGE: "C", "POSIX", "C.UTF-8" and the like.
        bool isC(std::string_view locale) {
            return locale == "C" || locale == "POSIX" || locale.starts_with("C.");
        }
    } // namespace

    Lang languageFrom(const char* language, const char* lcAll, const char* lcMessages, const char* lang) {
        const char* locale = set(lcAll) ? lcAll : set(lcMessages) ? lcMessages : set(lang) ? lang : nullptr;
        if (locale != nullptr && !isC(locale) && set(language)) {
            const std::string_view list{language};
            return isFrench(list.substr(0, list.find(':'))) ? Lang::Fr : Lang::En;
        }
        return locale != nullptr && isFrench(locale) ? Lang::Fr : Lang::En;
    }

    std::string_view text(Notice notice, Lang lang) {
        const bool fr = lang == Lang::Fr;
        switch (notice) {
            case Notice::AbiMismatch:
                return fr ? "[Grassfield] L’extension du compositeur a été compilée pour une autre version de Hyprland : les barres de "
                            "titre, la réduction des fenêtres et les menus globaux sont désactivés. Lancez grassfield-compositor-rebuild "
                            "dans un terminal, puis fermez la session et rouvrez-la."
                          : "[Grassfield] The compositor extension was built for another Hyprland: titlebars, minimize and global menus "
                            "are off. Run grassfield-compositor-rebuild in a terminal, then log out and back in.";
            case Notice::InitFailed:
                return fr ? "[Grassfield] L’extension du compositeur n’a pas pu démarrer : barres de titre désactivées."
                          : "[Grassfield] Compositor plugin failed to start: titlebars disabled.";
            case Notice::End: break;
        }
        return "[Grassfield]";
    }

} // namespace gf::notices
