#include "Json.hpp"

#include <charconv>
#include <cmath>
#include <system_error>

namespace gf::json {

    void CReader::skipSpace() {
        while (m_pos < m_text.size() && (m_text[m_pos] == ' ' || m_text[m_pos] == '\t' || m_text[m_pos] == '\n' || m_text[m_pos] == '\r'))
            ++m_pos;
    }

    bool CReader::atEnd() {
        skipSpace();
        return m_pos == m_text.size();
    }

    bool CReader::take(char c) {
        skipSpace();
        if (m_pos < m_text.size() && m_text[m_pos] == c) {
            ++m_pos;
            return true;
        }
        return false;
    }

    char CReader::peek() {
        skipSpace();
        return m_pos < m_text.size() ? m_text[m_pos] : '\0';
    }

    std::optional<std::string> CReader::string() {
        if (!take('"'))
            return std::nullopt;
        std::string out;
        while (m_pos < m_text.size()) {
            const char c = m_text[m_pos++];
            if (c == '"')
                return out;
            if (static_cast<unsigned char>(c) < 0x20)
                return std::nullopt; // raw control characters are not allowed in JSON strings
            if (c != '\\') {
                out += c;
            } else if (!escape(out))
                return std::nullopt;
            if (out.size() > m_maxString)
                return std::nullopt;
        }
        return std::nullopt; // unterminated
    }

    std::optional<double> CReader::number() {
        skipSpace();
        const size_t start = m_pos;
        if (m_pos < m_text.size() && m_text[m_pos] == '-')
            ++m_pos;
        if (m_pos < m_text.size() && m_text[m_pos] == '0')
            ++m_pos;
        else if (!digits())
            return std::nullopt;
        if (m_pos < m_text.size() && m_text[m_pos] == '.') {
            ++m_pos;
            if (!digits())
                return std::nullopt;
        }
        if (m_pos < m_text.size() && (m_text[m_pos] == 'e' || m_text[m_pos] == 'E')) {
            ++m_pos;
            if (m_pos < m_text.size() && (m_text[m_pos] == '+' || m_text[m_pos] == '-'))
                ++m_pos;
            if (!digits())
                return std::nullopt;
        }
        double     value = 0;
        const auto token = m_text.substr(start, m_pos - start);
        const auto [end, ec] = std::from_chars(token.data(), token.data() + token.size(), value);
        if (ec != std::errc{} || end != token.data() + token.size() || !std::isfinite(value))
            return std::nullopt; // out of range (1e999) or not a number
        return value;
    }

    std::optional<bool> CReader::boolean() {
        if (literal("true"))
            return true;
        if (literal("false"))
            return false;
        return std::nullopt;
    }

    bool CReader::skipValue(int depth) {
        if (depth > m_maxDepth)
            return false;
        switch (peek()) {
            case '"': return string().has_value();
            case '{': {
                take('{');
                if (take('}'))
                    return true;
                do {
                    if (!string() || !take(':') || !skipValue(depth + 1))
                        return false;
                } while (take(','));
                return take('}');
            }
            case '[': {
                take('[');
                if (take(']'))
                    return true;
                do {
                    if (!skipValue(depth + 1))
                        return false;
                } while (take(','));
                return take(']');
            }
            case 't':
            case 'f': return boolean().has_value();
            case 'n': return literal("null");
            default: return number().has_value();
        }
    }

    bool CReader::digits() {
        const size_t start = m_pos;
        while (m_pos < m_text.size() && m_text[m_pos] >= '0' && m_text[m_pos] <= '9')
            ++m_pos;
        return m_pos > start;
    }

    bool CReader::literal(std::string_view word) {
        skipSpace();
        if (m_text.substr(m_pos, word.size()) != word)
            return false;
        m_pos += word.size();
        return true;
    }

    std::optional<uint32_t> CReader::hex4() {
        if (m_pos + 4 > m_text.size())
            return std::nullopt;
        uint32_t value = 0;
        const auto [end, ec] = std::from_chars(m_text.data() + m_pos, m_text.data() + m_pos + 4, value, 16);
        if (ec != std::errc{} || end != m_text.data() + m_pos + 4)
            return std::nullopt;
        m_pos += 4;
        return value;
    }

    void CReader::appendUtf8(std::string& out, uint32_t cp) {
        if (cp < 0x80)
            out += static_cast<char>(cp);
        else if (cp < 0x800) {
            out += static_cast<char>(0xC0 | (cp >> 6));
            out += static_cast<char>(0x80 | (cp & 0x3F));
        } else if (cp < 0x10000) {
            out += static_cast<char>(0xE0 | (cp >> 12));
            out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
            out += static_cast<char>(0x80 | (cp & 0x3F));
        } else {
            out += static_cast<char>(0xF0 | (cp >> 18));
            out += static_cast<char>(0x80 | ((cp >> 12) & 0x3F));
            out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
            out += static_cast<char>(0x80 | (cp & 0x3F));
        }
    }

    bool CReader::escape(std::string& out) {
        if (m_pos >= m_text.size())
            return false;
        const char c = m_text[m_pos++];
        switch (c) {
            case '"': out += '"'; return true;
            case '\\': out += '\\'; return true;
            case '/': out += '/'; return true;
            case 'b': out += '\b'; return true;
            case 'f': out += '\f'; return true;
            case 'n': out += '\n'; return true;
            case 'r': out += '\r'; return true;
            case 't': out += '\t'; return true;
            case 'u': {
                auto cp = hex4();
                if (!cp)
                    return false;
                if (*cp >= 0xDC00 && *cp <= 0xDFFF)
                    return false; // lone low surrogate
                if (*cp >= 0xD800 && *cp <= 0xDBFF) {
                    if (m_text.substr(m_pos, 2) != "\\u")
                        return false;
                    m_pos += 2;
                    const auto low = hex4();
                    if (!low || *low < 0xDC00 || *low > 0xDFFF)
                        return false;
                    *cp = 0x10000 + ((*cp - 0xD800) << 10) + (*low - 0xDC00);
                }
                appendUtf8(out, *cp);
                return true;
            }
            default: return false;
        }
    }

} // namespace gf::json
