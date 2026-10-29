// Names as they may be shown (apps/activity/src/textclean.cpp; docs/specs/activity.md AM17, AM28, acceptance A-S8): no
// control or format character survives, invalid UTF-8 becomes U+FFFD, everything else is kept as it is.
#include "textclean.h"

#include <gtest/gtest.h>

using namespace activity;

TEST(TextClean, KeepsOrdinaryText)
{
    EXPECT_EQ(sanitizeDisplay("firefox"), "firefox");
    EXPECT_EQ(sanitizeDisplay("Réglages – Écran"), "Réglages – Écran");
    EXPECT_EQ(sanitizeDisplay("日本語 🚀"), "日本語 🚀");
    EXPECT_EQ(sanitizeDisplay(""), "");
}

TEST(TextClean, RemovesControlCharacters)
{
    EXPECT_EQ(sanitizeDisplay("a\tb\nc\x1b[31md\x7f"), "abc[31md");
    EXPECT_EQ(sanitizeDisplay("x\xc2\x85y"), "xy"); // U+0085, a C1 control
}

TEST(TextClean, RemovesBidirectionalAndInvisibleFormatCharacters)
{
    // A right-to-left override would show "exe.txt" as "txt.exe" (the classic trick).
    EXPECT_EQ(sanitizeDisplay("evil\u202Etxt.exe"), "eviltxt.exe");
    EXPECT_EQ(sanitizeDisplay("a\u2066b\u2069c"), "abc");    // isolates
    EXPECT_EQ(sanitizeDisplay("a\u200Eb\u200Fc"), "abc");    // marks
    EXPECT_EQ(sanitizeDisplay("a\u200Bb\u2060c\uFEFF"), "abc"); // zero-width space, word joiner, byte order mark
    EXPECT_EQ(sanitizeDisplay("a\u00ADb"), "ab");            // soft hyphen
    EXPECT_EQ(sanitizeDisplay("a\U000E0041b"), "ab");        // a tag character
}

TEST(TextClean, InvalidUtf8BecomesReplacementCharacters)
{
    EXPECT_EQ(sanitizeDisplay("a\xffz"), "a\uFFFDz");
    EXPECT_EQ(sanitizeDisplay("a\xc0\xafz"), "a\uFFFD\uFFFDz");     // an overlong "/"
    EXPECT_EQ(sanitizeDisplay("a\xed\xa0\x80z"), "a\uFFFD\uFFFD\uFFFDz"); // a surrogate
    EXPECT_EQ(sanitizeDisplay("a\xe2\x82"), "a\uFFFD\uFFFD");      // cut short
}

TEST(TextClean, HiddenCodePoints)
{
    EXPECT_TRUE(isHiddenCodePoint(0x00));
    EXPECT_TRUE(isHiddenCodePoint(0x9F));
    EXPECT_TRUE(isHiddenCodePoint(0x202A));
    EXPECT_TRUE(isHiddenCodePoint(0x2066));
    EXPECT_FALSE(isHiddenCodePoint(0x2065)); // unassigned, not Cf
    EXPECT_FALSE(isHiddenCodePoint('A'));
    EXPECT_FALSE(isHiddenCodePoint(0x00A0)); // no-break space is Zs, kept
}
