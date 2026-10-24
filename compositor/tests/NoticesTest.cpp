// The plugin's own notices in the session's language (GF-067; core/Notices.hpp).
#include "core/Notices.hpp"

#include <gtest/gtest.h>

#include <string>

using gf::notices::Lang;
using gf::notices::languageFrom;
using gf::notices::Notice;
using gf::notices::text;

TEST(Notices, EveryNoticeHasAFrenchAndAnEnglishText) {
    for (const Notice n : gf::notices::kAll) {
        const std::string_view en = text(n, Lang::En);
        const std::string_view fr = text(n, Lang::Fr);
        EXPECT_TRUE(en.starts_with("[Grassfield] ")) << en;
        EXPECT_TRUE(fr.starts_with("[Grassfield] ")) << fr;
        EXPECT_GT(en.size(), std::string_view("[Grassfield] ").size());
        EXPECT_NE(en, fr) << "a notice without its French text: " << en;
    }
}

TEST(Notices, TheRecoveryCommandIsNeverTranslated) {
    EXPECT_NE(text(Notice::AbiMismatch, Lang::Fr).find("grassfield-compositor-rebuild"), std::string_view::npos);
    EXPECT_NE(text(Notice::AbiMismatch, Lang::En).find("grassfield-compositor-rebuild"), std::string_view::npos);
}

TEST(Notices, TheFirstSetLocaleVariableDecidesInPosixOrder) {
    EXPECT_EQ(languageFrom("fr_FR.UTF-8", "en_US.UTF-8", "en_US.UTF-8"), Lang::Fr);
    EXPECT_EQ(languageFrom("C", "fr_FR.UTF-8", "fr_FR.UTF-8"), Lang::En) << "LC_ALL wins even when it is C";
    EXPECT_EQ(languageFrom(nullptr, "fr_FR.UTF-8", "en_US.UTF-8"), Lang::Fr);
    EXPECT_EQ(languageFrom("", "", "fr_FR.UTF-8"), Lang::Fr) << "an empty variable counts as unset";
    EXPECT_EQ(languageFrom(nullptr, nullptr, "en_GB.UTF-8"), Lang::En);
    EXPECT_EQ(languageFrom(nullptr, nullptr, nullptr), Lang::En);
}

TEST(Notices, FrenchIsAnyFrLocaleAndNothingElse) {
    for (const char* fr : {"fr", "fr_FR", "fr_FR.UTF-8", "fr_CA", "fr_BE@euro", "fr.UTF-8"})
        EXPECT_EQ(languageFrom(fr, nullptr, nullptr), Lang::Fr) << fr;
    for (const char* other : {"POSIX", "C.UTF-8", "de_DE.UTF-8", "fur_IT", "fry_NL", "en_US.UTF-8"})
        EXPECT_EQ(languageFrom(other, nullptr, nullptr), Lang::En) << other;
}
