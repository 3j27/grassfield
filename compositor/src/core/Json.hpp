#pragma once

// A strict JSON reader for the plugin's Lua verbs that take one JSON string (overview, stages): untrusted input, read
// once, never interpolated. RFC 8259 grammar, just enough for the requests: objects, arrays, strings, numbers,
// true/false/null. Plain C++ with no Hyprland includes (unit-tested through the parsers that use it).

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

namespace gf::json {

    // Every function leaves the cursor after what it read, or fails (nullopt / false) leaving it somewhere inside.
    class CReader {
      public:
        // `maxStringBytes`: longer strings are refused; `maxDepth`: nesting of skipped unknown values.
        CReader(std::string_view text, size_t maxStringBytes, int maxDepth) : m_text(text), m_maxString(maxStringBytes), m_maxDepth(maxDepth) {}

        void                       skipSpace();
        bool                       atEnd();          // only whitespace left
        bool                       take(char c);     // consumes `c` (after whitespace) if it is next
        char                       peek();           // next non-space character, '\0' at the end
        std::optional<std::string> string();         // a string (escapes decoded, UTF-8)
        std::optional<double>      number();         // a finite number (1e999 is refused)
        std::optional<bool>        boolean();        // true / false
        bool                       skipValue(int depth = 0); // any value (unknown keys), at most maxDepth deep

      private:
        bool                    digits();
        bool                    literal(std::string_view word);
        std::optional<uint32_t> hex4();
        bool                    escape(std::string& out); // after a backslash
        static void             appendUtf8(std::string& out, uint32_t cp);

        std::string_view        m_text;
        size_t                  m_pos = 0;
        size_t                  m_maxString;
        int                     m_maxDepth;
    };

} // namespace gf::json
