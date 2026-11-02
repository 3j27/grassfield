#include "Protocol.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonValue>

#include <algorithm>
#include <array>
#include <cstring>
#include <string.h>

namespace gf::prompter {

    namespace {
        constexpr std::size_t kMembers = 16;
        constexpr std::size_t kKeyBytes = 32;

        struct Cursor {
            std::string_view s;
            std::size_t      i = 0;
            bool             atEnd() const {
                return i >= s.size();
            }
            char peek() const {
                return s[i];
            }
        };

        void skipSpace(Cursor& c) {
            while (!c.atEnd() && (c.peek() == ' ' || c.peek() == '\t' || c.peek() == '\r'))
                ++c.i;
        }

        int hexDigit(char ch) {
            if (ch >= '0' && ch <= '9')
                return ch - '0';
            if (ch >= 'a' && ch <= 'f')
                return ch - 'a' + 10;
            if (ch >= 'A' && ch <= 'F')
                return ch - 'A' + 10;
            return -1;
        }

        // The 16-bit unit of the four hex digits at s[i..i+3], or -1.
        long hexUnit(std::string_view s, std::size_t i) {
            if (i + 4 > s.size())
                return -1;
            long unit = 0;
            for (std::size_t k = 0; k < 4; ++k) {
                const int d = hexDigit(s[i + k]);
                if (d < 0)
                    return -1;
                unit = unit * 16 + d;
            }
            return unit;
        }

        // The length of the valid UTF-8 sequence that starts at s[i] (a byte >= 0x80), or 0: no overlong form, no surrogate,
        // nothing above U+10FFFF.
        std::size_t utf8Length(std::string_view s, std::size_t i) {
            const auto  byte = [&](std::size_t k) { return static_cast<unsigned char>(s[k]); };
            const auto  b0   = byte(i);
            std::size_t len  = 0;
            unsigned    lo = 0x80, hi = 0xBF; // range of the second byte
            if (b0 >= 0xC2 && b0 <= 0xDF)
                len = 2;
            else if (b0 == 0xE0)
                len = 3, lo = 0xA0;
            else if ((b0 >= 0xE1 && b0 <= 0xEC) || b0 == 0xEE || b0 == 0xEF)
                len = 3;
            else if (b0 == 0xED)
                len = 3, hi = 0x9F;
            else if (b0 == 0xF0)
                len = 4, lo = 0x90;
            else if (b0 >= 0xF1 && b0 <= 0xF3)
                len = 4;
            else if (b0 == 0xF4)
                len = 4, hi = 0x8F;
            else
                return 0;
            if (i + len > s.size())
                return 0;
            if (byte(i + 1) < lo || byte(i + 1) > hi)
                return 0;
            for (std::size_t k = 2; k < len; ++k) {
                if (byte(i + k) < 0x80 || byte(i + k) > 0xBF)
                    return 0;
            }
            return len;
        }

        // A \u escape at s[i] (the backslash): the code point and the length of the escape (6, or 12 for a surrogate pair),
        // or {0, 0} when it is not valid, unpaired, or NUL.
        std::pair<char32_t, std::size_t> unicodeEscape(std::string_view s, std::size_t i) {
            if (i + 1 >= s.size() || s[i] != '\\' || s[i + 1] != 'u')
                return {0, 0};
            const long first = hexUnit(s, i + 2);
            if (first <= 0 || (first >= 0xDC00 && first <= 0xDFFF))
                return {0, 0};
            if (first < 0xD800 || first > 0xDBFF)
                return {static_cast<char32_t>(first), 6};
            if (i + 7 >= s.size() || s[i + 6] != '\\' || s[i + 7] != 'u')
                return {0, 0};
            const long second = hexUnit(s, i + 8);
            if (second < 0xDC00 || second > 0xDFFF)
                return {0, 0};
            return {static_cast<char32_t>(0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)), 12};
        }

        // After the opening quote: validates the string up to its closing quote, which c ends after.
        bool scanString(Cursor& c, JsonString* out, QString* error) {
            out->begin = c.i;
            while (!c.atEnd()) {
                const auto b = static_cast<unsigned char>(c.peek());
                if (b == '"') {
                    out->end = c.i;
                    ++c.i;
                    return true;
                }
                if (b == '\\') {
                    if (c.i + 1 >= c.s.size()) {
                        *error = QStringLiteral("unterminated escape");
                        return false;
                    }
                    const char e = c.s[c.i + 1];
                    if (e == 'u') {
                        const auto [cp, len] = unicodeEscape(c.s, c.i);
                        if (len == 0) {
                            *error = QStringLiteral("invalid \\u escape (unpaired surrogate, NUL or not hex)");
                            return false;
                        }
                        c.i += len;
                        continue;
                    }
                    if (e != '"' && e != '\\' && e != '/' && e != 'b' && e != 'f' && e != 'n' && e != 'r' && e != 't') {
                        *error = QStringLiteral("invalid escape");
                        return false;
                    }
                    c.i += 2;
                    continue;
                }
                if (b < 0x20) {
                    *error = QStringLiteral("control character in a string");
                    return false;
                }
                if (b < 0x80) {
                    ++c.i;
                    continue;
                }
                const std::size_t len = utf8Length(c.s, c.i);
                if (len == 0) {
                    *error = QStringLiteral("invalid UTF-8");
                    return false;
                }
                c.i += len;
            }
            *error = QStringLiteral("unterminated string");
            return false;
        }

        bool literal(Cursor& c, std::string_view word) {
            if (c.s.substr(c.i, word.size()) != word)
                return false;
            c.i += word.size();
            return true;
        }

        bool validKey(const std::string& key) {
            if (key.empty() || !((key[0] >= 'a' && key[0] <= 'z') || (key[0] >= 'A' && key[0] <= 'Z')))
                return false;
            return std::all_of(key.begin(), key.end(), [](char ch) {
                return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_' || ch == '-';
            });
        }

        const JsonMember* member(const std::vector<JsonMember>& members, std::string_view key) {
            for (const JsonMember& m : members) {
                if (m.key == key)
                    return &m;
            }
            return nullptr;
        }

        bool onlyKeys(const std::vector<JsonMember>& members, std::initializer_list<std::string_view> allowed) {
            return std::all_of(members.begin(), members.end(), [&](const JsonMember& m) {
                return std::find(allowed.begin(), allowed.end(), m.key) != allowed.end();
            });
        }

        // A short string value (an id, a type, a version): decoded, at most limits::kShortString bytes.
        bool shortString(std::string_view line, const JsonString& raw, QString* out) {
            std::array<char, limits::kShortString> buffer{};
            const long n = decodeJsonString(line.data() + raw.begin, raw.end - raw.begin, buffer.data(), buffer.size());
            if (n < 0)
                return false;
            *out = QString::fromUtf8(buffer.data(), n);
            return true;
        }

        bool stringMember(std::string_view line, const JsonMember* m, QString* out) {
            return m && m->value.type == JsonValue::Type::String && shortString(line, m->value.string, out);
        }

        QByteArray line(const QJsonObject& object) {
            QByteArray bytes = QJsonDocument(object).toJson(QJsonDocument::Compact);
            bytes.append('\n');
            return bytes;
        }
    } // namespace

    bool parseFlatObject(std::string_view text, std::vector<JsonMember>* members, QString* error) {
        members->clear();
        Cursor c{text};
        skipSpace(c);
        if (c.atEnd() || c.peek() != '{') {
            *error = QStringLiteral("not a JSON object");
            return false;
        }
        ++c.i;
        skipSpace(c);
        if (!c.atEnd() && c.peek() == '}') {
            ++c.i;
        } else {
            while (true) {
                if (c.atEnd() || c.peek() != '"') {
                    *error = QStringLiteral("expected a key");
                    return false;
                }
                ++c.i;
                JsonString rawKey;
                if (!scanString(c, &rawKey, error))
                    return false;
                std::array<char, kKeyBytes> keyBytes{};
                const long keyLength = decodeJsonString(text.data() + rawKey.begin, rawKey.end - rawKey.begin, keyBytes.data(), keyBytes.size());
                JsonMember m;
                if (keyLength > 0)
                    m.key.assign(keyBytes.data(), static_cast<std::size_t>(keyLength));
                if (!validKey(m.key)) {
                    *error = QStringLiteral("invalid key");
                    return false;
                }
                if (member(*members, m.key)) {
                    *error = QStringLiteral("duplicate key");
                    return false;
                }
                skipSpace(c);
                if (c.atEnd() || c.peek() != ':') {
                    *error = QStringLiteral("expected ':'");
                    return false;
                }
                ++c.i;
                skipSpace(c);
                if (c.atEnd()) {
                    *error = QStringLiteral("expected a value");
                    return false;
                }
                const char ch = c.peek();
                if (ch == '"') {
                    ++c.i;
                    m.value.type = JsonValue::Type::String;
                    if (!scanString(c, &m.value.string, error))
                        return false;
                } else if (ch == 't' && literal(c, "true")) {
                    m.value.type    = JsonValue::Type::Bool;
                    m.value.boolean = true;
                } else if (ch == 'f' && literal(c, "false")) {
                    m.value.type = JsonValue::Type::Bool;
                } else if (ch == 'n' && literal(c, "null")) {
                    m.value.type = JsonValue::Type::Null;
                } else if (ch == '[') {
                    ++c.i;
                    m.value.type = JsonValue::Type::Array;
                    skipSpace(c);
                    if (!c.atEnd() && c.peek() == ']') {
                        ++c.i;
                    } else {
                        while (true) {
                            if (c.atEnd() || c.peek() != '"') {
                                *error = QStringLiteral("arrays hold strings only");
                                return false;
                            }
                            ++c.i;
                            JsonString item;
                            if (!scanString(c, &item, error))
                                return false;
                            m.value.items.push_back(item);
                            if (m.value.items.size() > static_cast<std::size_t>(limits::kKinds)) {
                                *error = QStringLiteral("array too long");
                                return false;
                            }
                            skipSpace(c);
                            if (!c.atEnd() && c.peek() == ',') {
                                ++c.i;
                                skipSpace(c);
                                continue;
                            }
                            if (!c.atEnd() && c.peek() == ']') {
                                ++c.i;
                                break;
                            }
                            *error = QStringLiteral("expected ',' or ']'");
                            return false;
                        }
                    }
                } else {
                    *error = QStringLiteral("unsupported value (strings, booleans, null and arrays of strings only)");
                    return false;
                }
                members->push_back(std::move(m));
                if (members->size() > kMembers) {
                    *error = QStringLiteral("too many members");
                    return false;
                }
                skipSpace(c);
                if (!c.atEnd() && c.peek() == ',') {
                    ++c.i;
                    skipSpace(c);
                    continue;
                }
                if (!c.atEnd() && c.peek() == '}') {
                    ++c.i;
                    break;
                }
                *error = QStringLiteral("expected ',' or '}'");
                return false;
            }
        }
        skipSpace(c);
        if (!c.atEnd()) {
            *error = QStringLiteral("trailing bytes after the object");
            return false;
        }
        return true;
    }

    long decodeJsonString(const char* raw, std::size_t size, char* out, std::size_t capacity) {
        const std::string_view s(raw, size);
        std::size_t            n = 0;
        const auto             put = [&](char ch) {
            if (n >= capacity)
                return false;
            if (out)
                out[n] = ch;
            ++n;
            return true;
        };
        for (std::size_t i = 0; i < s.size();) {
            const auto b = static_cast<unsigned char>(s[i]);
            if (b == '\\') {
                if (i + 1 >= s.size())
                    return -1;
                const char e = s[i + 1];
                if (e == 'u') {
                    const auto [cp, len] = unicodeEscape(s, i);
                    if (len == 0)
                        return -1;
                    // UTF-8 of the code point.
                    bool ok = true;
                    if (cp < 0x80) {
                        ok = put(static_cast<char>(cp));
                    } else if (cp < 0x800) {
                        ok = put(static_cast<char>(0xC0 | (cp >> 6))) && put(static_cast<char>(0x80 | (cp & 0x3F)));
                    } else if (cp < 0x10000) {
                        ok = put(static_cast<char>(0xE0 | (cp >> 12))) && put(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)))
                            && put(static_cast<char>(0x80 | (cp & 0x3F)));
                    } else {
                        ok = put(static_cast<char>(0xF0 | (cp >> 18))) && put(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)))
                            && put(static_cast<char>(0x80 | ((cp >> 6) & 0x3F))) && put(static_cast<char>(0x80 | (cp & 0x3F)));
                    }
                    if (!ok)
                        return -1;
                    i += len;
                    continue;
                }
                char decoded = 0;
                switch (e) {
                    case '"': decoded = '"'; break;
                    case '\\': decoded = '\\'; break;
                    case '/': decoded = '/'; break;
                    case 'b': decoded = '\b'; break;
                    case 'f': decoded = '\f'; break;
                    case 'n': decoded = '\n'; break;
                    case 'r': decoded = '\r'; break;
                    case 't': decoded = '\t'; break;
                    default: return -1;
                }
                if (!put(decoded))
                    return -1;
                i += 2;
                continue;
            }
            if (b < 0x20 || b == '"')
                return -1;
            if (b < 0x80) {
                if (!put(static_cast<char>(b)))
                    return -1;
                ++i;
                continue;
            }
            const std::size_t len = utf8Length(s, i);
            if (len == 0)
                return -1;
            for (std::size_t k = 0; k < len; ++k) {
                if (!put(s[i + k]))
                    return -1;
            }
            i += len;
        }
        return static_cast<long>(n);
    }

    std::size_t takeLines(char* buffer, std::size_t length, const std::function<bool(std::string_view line)>& handle) {
        std::size_t start = 0;
        while (true) {
            const void* newline = std::memchr(buffer + start, '\n', length - start);
            if (!newline)
                break;
            const std::size_t end = static_cast<std::size_t>(static_cast<const char*>(newline) - buffer);
            if (!handle(std::string_view(buffer + start, end - start)))
                return 0; // dropped: the buffer was wiped by whoever dropped the connection
            explicit_bzero(buffer + start, end - start + 1);
            start = end + 1;
        }
        if (start > 0) {
            std::memmove(buffer, buffer + start, length - start);
            explicit_bzero(buffer + (length - start), start);
        }
        return length - start;
    }

    bool validRequestId(const QString& id) {
        if (id.size() < 2 || id.size() > 20 || id.at(0) != u'p' || id.at(1) == u'0')
            return false;
        for (qsizetype i = 1; i < id.size(); ++i) {
            if (id.at(i) < u'0' || id.at(i) > u'9')
                return false;
        }
        return true;
    }

    ParseStatus parseShellLine(std::string_view text, ShellLine* out, QString* error) {
        *out = ShellLine();
        if (text.size() > limits::kShellLine) {
            *error = QStringLiteral("line too long");
            return ParseStatus::Malformed;
        }
        std::vector<JsonMember> members;
        if (!parseFlatObject(text, &members, error))
            return ParseStatus::Malformed;
        QString type;
        if (!stringMember(text, member(members, "type"), &type)) {
            *error = QStringLiteral("no type");
            return ParseStatus::Malformed;
        }

        if (type == QLatin1String("hello")) {
            out->type = ShellLine::Type::Hello;
            if (!onlyKeys(members, {"v", "type", "shell", "kinds"})) {
                *error = QStringLiteral("unknown key in hello");
                return ParseStatus::Malformed;
            }
            QString version;
            if (!stringMember(text, member(members, "v"), &version)) {
                *error = QStringLiteral("hello without a version");
                return ParseStatus::Malformed;
            }
            if (version != QLatin1String(kProtocol)) {
                *error = QStringLiteral("protocol %1 is not %2").arg(version, QLatin1String(kProtocol));
                return ParseStatus::Version;
            }
            if (const JsonMember* shell = member(members, "shell"); shell && !stringMember(text, shell, &out->shell)) {
                *error = QStringLiteral("invalid shell version");
                return ParseStatus::Malformed;
            }
            const JsonMember* kinds = member(members, "kinds");
            if (!kinds || kinds->value.type != JsonValue::Type::Array) {
                *error = QStringLiteral("hello without kinds");
                return ParseStatus::Malformed;
            }
            for (const JsonString& item : kinds->value.items) {
                QString kind;
                if (!shortString(text, item, &kind) || kind.isEmpty()) {
                    *error = QStringLiteral("invalid kind");
                    return ParseStatus::Malformed;
                }
                if (!out->kinds.contains(kind))
                    out->kinds.append(kind);
            }
            return ParseStatus::Ok;
        }

        if (type == QLatin1String("answer")) {
            out->type = ShellLine::Type::Answer;
            if (!stringMember(text, member(members, "id"), &out->id) || !validRequestId(out->id)) {
                out->id.clear();
                *error = QStringLiteral("answer without a usable id");
                return ParseStatus::Malformed;
            }
            if (!onlyKeys(members, {"type", "id", "result", "password", "choice", "identity"})) {
                *error = QStringLiteral("unknown key in answer");
                return ParseStatus::Invalid;
            }
            QString result;
            if (!stringMember(text, member(members, "result"), &result)
                || (result != QLatin1String("ok") && result != QLatin1String("cancel") && result != QLatin1String("refused"))) {
                *error = QStringLiteral("result is not ok, cancel or refused");
                return ParseStatus::Invalid;
            }
            out->ok      = result == QLatin1String("ok");
            out->refused = result == QLatin1String("refused");
            if (const JsonMember* password = member(members, "password")) {
                if (password->value.type != JsonValue::Type::String
                    || decodeJsonString(text.data() + password->value.string.begin, password->value.string.end - password->value.string.begin, nullptr,
                                        limits::kPassword)
                        < 0) {
                    *error = QStringLiteral("password not a string, not valid, or over %1 bytes").arg(limits::kPassword);
                    return ParseStatus::Invalid;
                }
                out->hasPassword = true;
                out->password    = password->value.string;
            }
            if (const JsonMember* choice = member(members, "choice")) {
                if (choice->value.type != JsonValue::Type::Bool) {
                    *error = QStringLiteral("choice is not a boolean");
                    return ParseStatus::Invalid;
                }
                out->hasChoice = true;
                out->choice    = choice->value.boolean;
            }
            if (const JsonMember* identity = member(members, "identity")) {
                if (identity->value.type != JsonValue::Type::String
                    || decodeJsonString(text.data() + identity->value.string.begin, identity->value.string.end - identity->value.string.begin, nullptr,
                                        limits::kIdentity)
                        < 0) {
                    *error = QStringLiteral("identity not a string, not valid, or over %1 bytes").arg(limits::kIdentity);
                    return ParseStatus::Invalid;
                }
                out->hasIdentity = true;
                out->identity    = identity->value.string;
            }
            return ParseStatus::Ok;
        }

        *error = QStringLiteral("unknown type");
        return ParseStatus::Unknown;
    }

    QByteArray helloMessage(const QStringList& kinds) {
        return line({
            {QStringLiteral("v"), QLatin1String(kProtocol)},
            {QStringLiteral("type"), QStringLiteral("hello")},
            {QStringLiteral("bridge"), QLatin1String(kBridgeVersion)},
            {QStringLiteral("kinds"), QJsonArray::fromStringList(kinds)},
            {QStringLiteral("max"), limits::kRequests},
        });
    }

    QByteArray nameMessage(const QString& state) {
        return line({{QStringLiteral("type"), QStringLiteral("name")}, {QStringLiteral("state"), state}});
    }

    namespace {
        QJsonObject requesterObject(const RequesterView& r) {
            return {
                {QStringLiteral("role"), r.role},
                {QStringLiteral("name"), r.name},
                {QStringLiteral("desktopId"), r.desktopId},
                {QStringLiteral("icon"), r.icon},
                {QStringLiteral("path"), r.path},
                {QStringLiteral("identified"), r.identified},
                {QStringLiteral("onBehalf"), r.onBehalf},
            };
        }
    } // namespace

    QByteArray promptMessage(const PromptView& p) {
        const QJsonObject requester{
            {QStringLiteral("role"), p.requester.role},
            {QStringLiteral("name"), p.requester.name},
            {QStringLiteral("desktopId"), p.requester.desktopId},
            {QStringLiteral("icon"), p.requester.icon},
            {QStringLiteral("path"), p.requester.path},
            {QStringLiteral("identified"), p.requester.identified},
            {QStringLiteral("onBehalf"), p.requester.onBehalf},
        };
        const QJsonObject texts{
            {QStringLiteral("title"), p.title},       {QStringLiteral("message"), p.message},
            {QStringLiteral("description"), p.description}, {QStringLiteral("warning"), p.warning},
            {QStringLiteral("continue"), p.continueLabel}, {QStringLiteral("cancel"), p.cancelLabel},
        };
        const QJsonValue choice = p.hasChoice ? QJsonValue(QJsonObject{{QStringLiteral("label"), p.choiceLabel}, {QStringLiteral("chosen"), p.choiceChosen}})
                                              : QJsonValue(QJsonValue::Null);
        const bool password = p.kind == QLatin1String("password");
        return line({
            {QStringLiteral("type"), QStringLiteral("prompt")},
            {QStringLiteral("id"), p.id},
            {QStringLiteral("kind"), p.kind},
            {QStringLiteral("requester"), requester},
            {QStringLiteral("texts"), texts},
            {QStringLiteral("choice"), choice},
            {QStringLiteral("passwordNew"), password && p.passwordNew},
            {QStringLiteral("strength"), password && p.passwordNew},
        });
    }

    QByteArray nmPromptMessage(const NmPromptView& p) {
        return line({
            {QStringLiteral("type"), QStringLiteral("prompt")},
            {QStringLiteral("id"), p.id},
            {QStringLiteral("kind"), QStringLiteral("nm")},
            {QStringLiteral("network"),
             QJsonObject{{QStringLiteral("ssid"), p.ssid}, {QStringLiteral("security"), p.security}, {QStringLiteral("identity"), p.identity}}},
        });
    }

    QByteArray kioPromptMessage(const KioPromptView& p) {
        return line({
            {QStringLiteral("type"), QStringLiteral("prompt")},
            {QStringLiteral("id"), p.id},
            {QStringLiteral("kind"), QStringLiteral("kio")},
            {QStringLiteral("requester"), requesterObject(p.requester)},
            {QStringLiteral("server"), p.server},
            {QStringLiteral("login"),
             QJsonObject{
                 {QStringLiteral("name"), p.name},
                 {QStringLiteral("nameMode"), p.nameMode},
                 {QStringLiteral("realm"), p.realm},
                 {QStringLiteral("retry"), p.retry},
                 {QStringLiteral("remember"), p.remember},
                 {QStringLiteral("keyring"), p.keyring},
             }},
        });
    }

    QByteArray cancelMessage(const QString& id) {
        return line({{QStringLiteral("type"), QStringLiteral("cancel")}, {QStringLiteral("id"), id}});
    }

    QByteArray errorMessage(const QString& code, const QString& message) {
        return line({{QStringLiteral("type"), QStringLiteral("error")}, {QStringLiteral("code"), code}, {QStringLiteral("message"), message}});
    }

} // namespace gf::prompter
