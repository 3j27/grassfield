// Fuzzing of prompter/1's reading of the shell (bridges/prompter/src/Protocol.cpp; ADR-0035 D-9, decision 9-5): what the
// shell's socket hands the bridge must never crash it, read out of bounds or break the parser's contract. Built and run by
// tests/fuzz/prompter_protocol.sh: with libFuzzer (ASan and UBSan) when clang++ is there, else with the mutation loop below
// under GCC's ASan and UBSan. A finding aborts.
//
// The contract checked on every input (one shell line, then the same bytes as a socket read):
// - parseShellLine: an Ok answer has a valid id; its password, when there is one, lies inside the line and decodes to at
//   most limits::kPassword bytes, the same length with and without an output buffer; an Invalid answer names a valid id;
// - parseFlatObject: every string it accepts decodes (escapes and UTF-8 were validated), with and without a buffer alike;
// - takeLines: every handed line lies inside the buffer and holds no newline, the line before it and its newline are
//   already zero when it is handed, the rest it returns is no longer than the input, and every byte past the rest is zero
//   (the wiping).

#include "Protocol.h"

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <vector>

using namespace gf::prompter;

namespace {
    void require(bool ok, const char* what) {
        if (!ok) {
            std::fprintf(stderr, "prompter-protocol fuzz: contract broken: %s\n", what);
            std::abort();
        }
    }

    void checkString(std::string_view text, const JsonString& raw, std::size_t capacity) {
        require(raw.begin <= raw.end && raw.end <= text.size(), "a string outside its line");
        std::vector<char> out(capacity);
        const long        withBuffer = decodeJsonString(text.data() + raw.begin, raw.end - raw.begin, out.data(), capacity);
        const long        lengthOnly = decodeJsonString(text.data() + raw.begin, raw.end - raw.begin, nullptr, capacity);
        require(withBuffer == lengthOnly, "decoding with and without a buffer differ");
        require(withBuffer <= static_cast<long>(capacity), "a decoded length over the capacity");
    }

    void one(const std::uint8_t* data, std::size_t size) {
        const std::string_view line(reinterpret_cast<const char*>(data), size);

        ShellLine         out;
        QString           error;
        const ParseStatus status = parseShellLine(line, &out, &error);
        if (status == ParseStatus::Ok && out.type == ShellLine::Type::Answer) {
            require(validRequestId(out.id), "an accepted answer without a valid id");
            if (out.hasPassword) {
                checkString(line, out.password, limits::kPassword);
                require(decodeJsonString(line.data() + out.password.begin, out.password.end - out.password.begin, nullptr, limits::kPassword) >= 0,
                        "an accepted password that does not decode");
            }
        }
        if (status == ParseStatus::Invalid)
            require(validRequestId(out.id), "an invalid answer that names no valid id");

        std::vector<JsonMember> members;
        QString                 flatError;
        if (size <= limits::kShellLine && parseFlatObject(line, &members, &flatError)) {
            for (const JsonMember& m : members) {
                if (m.value.type == JsonValue::Type::String) {
                    checkString(line, m.value.string, size + 1);
                    require(decodeJsonString(line.data() + m.value.string.begin, m.value.string.end - m.value.string.begin, nullptr, size + 1) >= 0,
                            "an accepted string that does not decode");
                }
                for (const JsonString& item : m.value.items)
                    checkString(line, item, size + 1);
            }
        }

        std::string buffer(line);
        const char* begin = buffer.data();
        const char* end   = buffer.data() + buffer.size();
        const char* previous = begin; // where the line handed before this one began
        const std::size_t rest = takeLines(buffer.data(), buffer.size(), [&](std::string_view handed) {
            require(handed.data() >= begin && handed.data() + handed.size() <= end, "a handed line outside the buffer");
            require(handed.find('\n') == std::string_view::npos, "a handed line holding a newline");
            for (const char* p = previous; p < handed.data(); ++p)
                require(*p == '\0', "a handed line left unwiped while the next one is handled");
            previous = handed.data();
            return true;
        });
        require(rest <= buffer.size(), "a rest longer than the input");
        for (std::size_t i = rest; i < buffer.size(); ++i)
            require(buffer[i] == '\0', "a byte left behind unwiped");
    }
} // namespace

extern "C" int LLVMFuzzerTestOneInput(const std::uint8_t* data, std::size_t size) {
    one(data, size);
    return 0;
}

#ifndef GF_LIBFUZZER
// The mutation loop for a build without libFuzzer: seeds of every message shape, mutated byte by byte, by JSON tokens and
// by splicing, for GF_FUZZ_SECONDS (default 20) or GF_FUZZ_ITERATIONS inputs, from GF_FUZZ_SEED (default 1).
int main() {
    const char*         secondsText    = std::getenv("GF_FUZZ_SECONDS");
    const char*         iterationsText = std::getenv("GF_FUZZ_ITERATIONS");
    const char*         seedText       = std::getenv("GF_FUZZ_SEED");
    const double        seconds        = secondsText ? std::atof(secondsText) : 20.0;
    const unsigned long iterations     = iterationsText ? std::strtoul(iterationsText, nullptr, 10) : 0;
    const unsigned long seed           = seedText ? std::strtoul(seedText, nullptr, 10) : 1;
    const std::vector<std::string> seeds = {
        R"({"v":"prompter/1","type":"hello","shell":"1.0","kinds":["password","confirm"]})",
        R"({"type":"answer","id":"p1","result":"ok","password":"s3cr\"t é🔑","choice":true})",
        R"({"type":"answer","id":"p12","result":"cancel","choice":false})",
        R"({"type":"answer","id":"p3","result":"ok","password":""})",
        R"({"type":"answer","id":"p07","result":"ok"})",
        R"({"type":"pwn","x":[]})",
        "{\"type\":\"answer\",\"id\":\"p1\",\"result\":\"ok\",\"password\":\"a\"}\n{\"type\":\"hello\"}\npartial",
        R"({"a":"\u0000","b":[1],"c":{"d":null}})",
    };
    const std::vector<std::string> tokens = {"\\u", "\\ud800", "\\udc00", "\\u0000", "\\\"", "\"", "\\", "{", "}", "[", "]", ",", ":",
                                             "true", "false", "null", "\n", "\xc3", "\xe2\x80\xae", "\xff", "p", "p0", "p18446744073709551616"};
    std::mt19937_64 rng(seed);
    auto            pick = [&](std::size_t n) { return n ? static_cast<std::size_t>(rng() % n) : 0; };
    std::vector<std::string> corpus = seeds;
    const auto      start = std::chrono::steady_clock::now();
    unsigned long   count = 0;
    for (const std::string& s : seeds) {
        one(reinterpret_cast<const std::uint8_t*>(s.data()), s.size());
        ++count;
    }
    while (true) {
        if (iterations ? count >= iterations : std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count() >= seconds)
            break;
        std::string input = corpus[pick(corpus.size())];
        const int   edits = 1 + static_cast<int>(pick(8));
        for (int e = 0; e < edits; ++e) {
            switch (pick(6)) {
                case 0: if (!input.empty()) input[pick(input.size())] ^= static_cast<char>(1u << pick(8)); break;
                case 1: input.insert(pick(input.size() + 1), 1, static_cast<char>(rng())); break;
                case 2: if (!input.empty()) input.erase(pick(input.size()), 1 + pick(8)); break;
                case 3: input.insert(pick(input.size() + 1), tokens[pick(tokens.size())]); break;
                case 4: {
                    const std::string& other = corpus[pick(corpus.size())];
                    const std::size_t  from  = pick(other.size() + 1);
                    input.insert(pick(input.size() + 1), other.substr(from, pick(other.size() - from + 1)));
                    break;
                }
                default: if (input.size() < 20000) input.append(input.substr(pick(input.size() + 1))); break;
            }
        }
        one(reinterpret_cast<const std::uint8_t*>(input.data()), input.size());
        ++count;
        if (corpus.size() < 4096 && pick(64) == 0)
            corpus.push_back(input);
    }
    const double took = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
    std::printf("[fuzz] prompter-protocol: %lu inputs in %.1f s (seed %lu), no finding\n", count, took, seed);
    return 0;
}
#endif
