// Checks the folder symbol rule (FolderStyleLogic::normalizeGlyph, isEmoji) against ICU's own grapheme segmenter and
// Unicode properties, on random sequences of interesting code points (marks, prepended characters, Thai/Lao AM, Indic
// conjuncts, Hangul, flags, emoji sequences, controls, lone surrogates...). Development tool (scripts/dev/glyph-icu-compare.sh):
// ICU is used here only; Files and the shell do not link it.
//
//   compare N SEED     N random sequences; prints every difference, exit 1 when there is one
//   ask                reads lines of hex code points from stdin, prints ICU's answer for each as a JSON vector
//   vectors N SEED     the same sequences as JSON vectors {"input": hex, "expected": hex, "emoji": bool} with ICU's answers
//                      (to run FolderStyle.js over them, or to pick lines for tests/fixtures/glyph-vectors.json)
#include "folderstylelogic.h"

#include <unicode/brkiter.h>
#include <unicode/uchar.h>
#include <unicode/unistr.h>

#include <QCoreApplication>
#include <QString>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <random>
#include <vector>

namespace
{
std::vector<UChar32> pool;

void addRange(UChar32 lo, UChar32 hi)
{
    for (UChar32 c = lo; c <= hi; ++c)
        pool.push_back(c);
}

// A few of every class that matters, found by property rather than listed by hand.
void buildPool()
{
    std::mt19937 pick(7);
    const UProperty props[] = {UCHAR_GRAPHEME_CLUSTER_BREAK, UCHAR_INDIC_CONJUNCT_BREAK};
    for (const UProperty prop : props) {
        for (int value = u_getIntPropertyMinValue(prop); value <= u_getIntPropertyMaxValue(prop); ++value) {
            std::vector<UChar32> members;
            for (UChar32 c = 0; c < 0x110000; ++c) {
                if (u_getIntPropertyValue(c, prop) == value)
                    members.push_back(c);
            }
            for (int i = 0; i < 12 && !members.empty(); ++i)
                pool.push_back(members[pick() % members.size()]);
        }
    }
    for (const UProperty prop : {UCHAR_EXTENDED_PICTOGRAPHIC, UCHAR_EMOJI, UCHAR_EMOJI_PRESENTATION, UCHAR_EMOJI_MODIFIER}) {
        std::vector<UChar32> members;
        for (UChar32 c = 0; c < 0x110000; ++c) {
            if (u_hasBinaryProperty(c, prop))
                members.push_back(c);
        }
        for (int i = 0; i < 16 && !members.empty(); ++i)
            pool.push_back(members[pick() % members.size()]);
    }
    for (const UChar32 c : {0x0E33, 0x0EB3, 0x0E01, 0x0E31, 0x0600, 0x0605, 0x06DD, 0x070F, 0x0890, 0x08E2, 0x110BD, 0x110CD, 0x0D4E, 0x111C2,
                            0x200D, 0x200C, 0xFE0F, 0xFE0E, 0x20E3, 0x1F1E6, 0x1F1E7, 0x1F468, 0x1F469, 0x1F3FB, 0x2605, 0x0915, 0x094D, 0x0924,
                            0x0937, 0x093C, 0x0301, 0x0041, 0x0030, 0x0023, 0x002A, 0x000D, 0x000A, 0x0085, 0x2028, 0x202E, 0xFFFD, 0xD800, 0xDC00,
                            0x1F130, 0x20000, 0x1F004, 0x1F0A1, 0x2602, 0x2764, 0x00A9, 0xE0067, 0xE007F, 0x1100, 0x1161, 0x11A8, 0xAC00, 0xAC01})
        pool.push_back(c);
    addRange(0x20, 0x2F);
}

// ICU's answer for the rule: first cluster of the trimmed text, trailing joiners dropped, at most 16 units, nothing
// rejected in it.
QString expected(const QString &input)
{
    const QString text = input.trimmed();
    if (text.isEmpty())
        return {};
    icu::UnicodeString u(reinterpret_cast<const char16_t *>(text.utf16()), text.size());
    UErrorCode status = U_ZERO_ERROR;
    std::unique_ptr<icu::BreakIterator> it(icu::BreakIterator::createCharacterInstance(icu::Locale::getRoot(), status));
    it->setText(u);
    int end = it->next();
    if (end == icu::BreakIterator::DONE)
        end = text.size();
    QString cluster = text.left(end);
    while (cluster.endsWith(QChar(0x200D)))
        cluster.chop(1);
    if (cluster.isEmpty() || cluster.size() > 16)
        return {};
    for (int i = 0; i < cluster.size();) {
        UChar32 c;
        icu::UnicodeString one(reinterpret_cast<const char16_t *>(cluster.utf16()) + i, cluster.size() - i);
        c = one.char32At(0);
        i += U16_LENGTH(c);
        switch (u_charType(c)) {
        case U_CONTROL_CHAR:
        case U_SURROGATE:
        case U_LINE_SEPARATOR:
        case U_PARAGRAPH_SEPARATOR:
            return {};
        case U_FORMAT_CHAR:
            if (c != 0x200D && !(c >= 0xE0020 && c <= 0xE007F))
                return {};
            break;
        default:
            if (c == 0xFFFD)
                return {};
        }
    }
    return cluster;
}

bool expectedEmoji(const QString &glyph)
{
    bool emoji = false;
    const auto cps = glyph.toUcs4();
    for (const char32_t c : cps) {
        if (c == 0xFE0E)
            return false;
        if (c == 0xFE0F || c == 0x20E3 || (c >= 0x80 && u_hasBinaryProperty(UChar32(c), UCHAR_EMOJI)))
            emoji = true;
    }
    return emoji;
}

QString sequence(std::mt19937 &rng)
{
    QString s;
    const int length = 1 + int(rng() % 8);
    for (int i = 0; i < length; ++i) {
        // Mostly the pool, sometimes any code point (surrogates left as lone ones too).
        UChar32 c = (rng() % 8) ? pool[rng() % pool.size()] : UChar32(rng() % 0x110000);
        if (c >= 0xD800 && c <= 0xDFFF) {
            s.append(QChar(ushort(c)));
        } else {
            s.append(QString::fromUcs4(reinterpret_cast<const char32_t *>(&c), 1));
        }
    }
    return s;
}

QByteArray hex(const QString &s)
{
    QByteArray out;
    const auto units = s;
    for (int i = 0; i < units.size();) {
        uint c = units.at(i).unicode();
        int n = 1;
        if (QChar::isHighSurrogate(c) && i + 1 < units.size() && QChar::isLowSurrogate(units.at(i + 1).unicode())) {
            c = QChar::surrogateToUcs4(c, units.at(i + 1).unicode());
            n = 2;
        }
        if (!out.isEmpty())
            out += ' ';
        out += QByteArray::number(c, 16).toUpper();
        i += n;
    }
    return out;
}
} // namespace

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    if (argc >= 2 && std::strcmp(argv[1], "ask") == 0) {
        char line[512];
        while (std::fgets(line, sizeof line, stdin)) {
            QString input;
            for (const QByteArray &h : QByteArray(line).trimmed().split(' ')) {
                bool ok = false;
                const uint cp = h.toUInt(&ok, 16);
                if (ok)
                    input += cp > 0xFFFF ? QString::fromUcs4(reinterpret_cast<const char32_t *>(&cp), 1) : QString(QChar(ushort(cp)));
            }
            const QString want = expected(input);
            std::printf("{\"input\": \"%s\", \"expected\": \"%s\", \"emoji\": %s}\n", hex(input).constData(), hex(want).constData(),
                        !want.isEmpty() && expectedEmoji(want) ? "true" : "false");
        }
        return 0;
    }
    if (argc < 4 || (std::strcmp(argv[1], "compare") != 0 && std::strcmp(argv[1], "vectors") != 0)) {
        std::fprintf(stderr, "usage: glyph-icu-compare compare|vectors N SEED\n");
        return 2;
    }
    const bool vectors = std::strcmp(argv[1], "vectors") == 0;
    const int n = std::atoi(argv[2]);
    std::mt19937 rng(unsigned(std::atoi(argv[3])));
    buildPool();
    int differences = 0, emojiDifferences = 0;
    if (vectors)
        std::printf("[\n");
    for (int i = 0; i < n; ++i) {
        const QString input = sequence(rng);
        const QString want = expected(input);
        const QString got = FolderStyleLogic::normalizeGlyph(input);
        const bool wantEmoji = want.isEmpty() ? false : expectedEmoji(want);
        if (vectors) {
            std::printf("%s{\"input\": \"%s\", \"expected\": \"%s\", \"emoji\": %s}\n", i ? "," : "", hex(input).constData(), hex(want).constData(),
                        wantEmoji ? "true" : "false");
            continue;
        }
        if (got != want) {
            ++differences;
            if (differences <= 20)
                std::printf("DIFF input [%s] ICU [%s] ours [%s]\n", hex(input).constData(), hex(want).constData(), hex(got).constData());
        } else if (!want.isEmpty() && FolderStyleLogic::isEmoji(want) != wantEmoji) {
            ++emojiDifferences;
            if (emojiDifferences <= 20)
                std::printf("EMOJI [%s] ICU %d ours %d\n", hex(want).constData(), wantEmoji, FolderStyleLogic::isEmoji(want));
        }
    }
    if (vectors) {
        std::printf("]\n");
        return 0;
    }
    std::printf("glyph-icu-compare: %d sequences, %d cluster differences, %d emoji differences (ICU %s, Unicode %s)\n", n, differences, emojiDifferences, U_ICU_VERSION, U_UNICODE_VERSION);
    return differences || emojiDifferences ? 1 : 0;
}
