// Process names and command lines as they may be shown (docs/specs/activity.md AM17, AM28; ADR-0038 i): a process chooses its
// own name and arguments, so before display every control character (Unicode Cc) and format character (Cf: the bidirectional
// embeddings, overrides, isolates and marks, zero-width characters, the byte order mark, tag characters) is removed and every
// byte that is not valid UTF-8 becomes U+FFFD. A process can then neither reorder nor hide text in a row.
#pragma once

#include <string>
#include <string_view>

namespace activity
{

std::string sanitizeDisplay(std::string_view utf8);

// True for a code point the display must not carry (Cc or Cf, Unicode 15.1).
bool isHiddenCodePoint(char32_t cp);

} // namespace activity
