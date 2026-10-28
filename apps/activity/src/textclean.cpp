#include "textclean.h"

namespace activity
{
namespace
{

// The Cf (format) ranges of Unicode 15.1 (DerivedGeneralCategory.txt), inclusive.
constexpr char32_t kFormat[][2] = {
    {0x00AD, 0x00AD},   {0x0600, 0x0605},   {0x061C, 0x061C},   {0x06DD, 0x06DD},   {0x070F, 0x070F},
    {0x0890, 0x0891},   {0x08E2, 0x08E2},   {0x180E, 0x180E},   {0x200B, 0x200F},   {0x202A, 0x202E},
    {0x2060, 0x2064},   {0x2066, 0x206F},   {0xFEFF, 0xFEFF},   {0xFFF9, 0xFFFB},   {0x110BD, 0x110BD},
    {0x110CD, 0x110CD}, {0x13430, 0x1343F}, {0x1BCA0, 0x1BCA3}, {0x1D173, 0x1D17A}, {0xE0001, 0xE0001},
    {0xE0020, 0xE007F},
};

void appendUtf8(std::string &out, char32_t cp)
{
    if (cp < 0x80) {
        out.push_back(static_cast<char>(cp));
    } else if (cp < 0x800) {
        out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
        out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    } else if (cp < 0x10000) {
        out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
        out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    } else {
        out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
        out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    }
}

// Decodes one code point at `i` (strict UTF-8: no overlong forms, no surrogates, nothing above U+10FFFF). Returns the number
// of bytes used, or 0 for an invalid sequence (the caller then takes one byte as U+FFFD).
size_t decode(std::string_view s, size_t i, char32_t &cp)
{
    const auto b0 = static_cast<unsigned char>(s[i]);
    if (b0 < 0x80) {
        cp = b0;
        return 1;
    }
    size_t len = 0;
    char32_t min = 0;
    if ((b0 & 0xE0) == 0xC0) {
        len = 2;
        cp = b0 & 0x1F;
        min = 0x80;
    } else if ((b0 & 0xF0) == 0xE0) {
        len = 3;
        cp = b0 & 0x0F;
        min = 0x800;
    } else if ((b0 & 0xF8) == 0xF0) {
        len = 4;
        cp = b0 & 0x07;
        min = 0x10000;
    } else {
        return 0;
    }
    if (i + len > s.size())
        return 0;
    for (size_t k = 1; k < len; ++k) {
        const auto b = static_cast<unsigned char>(s[i + k]);
        if ((b & 0xC0) != 0x80)
            return 0;
        cp = (cp << 6) | (b & 0x3F);
    }
    if (cp < min || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF))
        return 0;
    return len;
}

} // namespace

bool isHiddenCodePoint(char32_t cp)
{
    if (cp < 0x20 || (cp >= 0x7F && cp <= 0x9F)) // Cc
        return true;
    for (const auto &r : kFormat) {
        if (cp >= r[0] && cp <= r[1])
            return true;
    }
    return false;
}

std::string sanitizeDisplay(std::string_view utf8)
{
    std::string out;
    out.reserve(utf8.size());
    for (size_t i = 0; i < utf8.size();) {
        char32_t cp = 0;
        const size_t n = decode(utf8, i, cp);
        if (n == 0) {
            appendUtf8(out, 0xFFFD);
            ++i;
            continue;
        }
        if (!isHiddenCodePoint(cp))
            appendUtf8(out, cp);
        i += n;
    }
    return out;
}

} // namespace activity
