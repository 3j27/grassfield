#include "folderstylelogic.h"

#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>

namespace FolderStyleLogic
{

namespace
{
// A grapheme cluster longer than this (UTF-16 units) is not a symbol: the longest emoji sequences (family, flags with
// modifiers) are well below it.
constexpr int kMaxGlyphUnits = 16;
constexpr int kMaxStored = 4096;
} // namespace

const char *attributeName()
{
    return "user.grassfield.folder";
}

bool validColor(const QString &color)
{
    static const QRegularExpression pattern(QStringLiteral("^(theme|accent|#[0-9a-fA-F]{6})$"));
    return pattern.match(color).hasMatch();
}

QString normalizeColor(const QString &color)
{
    return validColor(color) ? color.toLower() : QString();
}

namespace
{
struct Range {
    uint lo, hi;
};

template<size_t N>
bool within(uint cp, const Range (&ranges)[N])
{
    // Short sorted lists: a linear scan is as fast as a search here.
    for (const Range &r : ranges) {
        if (cp < r.lo)
            return false;
        if (cp <= r.hi)
            return true;
    }
    return false;
}

// Extended_Pictographic (emoji-data.txt): what an emoji joiner can join to.
constexpr Range kPictographic[] = {
    {0xA9, 0xA9}, {0xAE, 0xAE}, {0x203C, 0x203C}, {0x2049, 0x2049}, {0x2122, 0x2122}, {0x2139, 0x2139}, {0x2194, 0x2199},
    {0x21A9, 0x21AA}, {0x231A, 0x231B}, {0x2328, 0x2328}, {0x2388, 0x2388}, {0x23CF, 0x23CF}, {0x23E9, 0x23F3},
    {0x23F8, 0x23FA}, {0x24C2, 0x24C2}, {0x25AA, 0x25AB}, {0x25B6, 0x25B6}, {0x25C0, 0x25C0}, {0x25FB, 0x25FE},
    {0x2600, 0x2605}, {0x2607, 0x2612}, {0x2614, 0x2685}, {0x2690, 0x2705}, {0x2708, 0x2712}, {0x2714, 0x2714},
    {0x2716, 0x2716}, {0x271D, 0x271D}, {0x2721, 0x2721}, {0x2728, 0x2728}, {0x2733, 0x2734}, {0x2744, 0x2744},
    {0x2747, 0x2747}, {0x274C, 0x274C}, {0x274E, 0x274E}, {0x2753, 0x2755}, {0x2757, 0x2757}, {0x2763, 0x2767},
    {0x2795, 0x2797}, {0x27A1, 0x27A1}, {0x27B0, 0x27B0}, {0x27BF, 0x27BF}, {0x2934, 0x2935}, {0x2B05, 0x2B07},
    {0x2B1B, 0x2B1C}, {0x2B50, 0x2B50}, {0x2B55, 0x2B55}, {0x3030, 0x3030}, {0x303D, 0x303D}, {0x3297, 0x3297},
    {0x3299, 0x3299}, {0x1F000, 0x1F0FF}, {0x1F10D, 0x1F10F}, {0x1F12F, 0x1F12F}, {0x1F16C, 0x1F171}, {0x1F17E, 0x1F17F},
    {0x1F18E, 0x1F18E}, {0x1F191, 0x1F19A}, {0x1F1AD, 0x1F1E5}, {0x1F201, 0x1F20F}, {0x1F21A, 0x1F21A}, {0x1F22F, 0x1F22F},
    {0x1F232, 0x1F23A}, {0x1F23C, 0x1F23F}, {0x1F249, 0x1F3FA}, {0x1F400, 0x1F53D}, {0x1F546, 0x1F64F}, {0x1F680, 0x1F6FF},
    {0x1F774, 0x1F77F}, {0x1F7D5, 0x1F7FF}, {0x1F80C, 0x1F80F}, {0x1F848, 0x1F84F}, {0x1F85A, 0x1F85F}, {0x1F888, 0x1F88F},
    {0x1F8AE, 0x1F8FF}, {0x1F90C, 0x1F93A}, {0x1F93C, 0x1F945}, {0x1F947, 0x1FAFF}, {0x1FC00, 0x1FFFD},
};

// Characters with the Emoji property in the BMP (emoji-data.txt); the supplementary planes are handled as a block.
constexpr Range kEmojiBmp[] = {
    {0xA9, 0xA9}, {0xAE, 0xAE}, {0x203C, 0x203C}, {0x2049, 0x2049}, {0x2122, 0x2122}, {0x2139, 0x2139}, {0x2194, 0x2199},
    {0x21A9, 0x21AA}, {0x231A, 0x231B}, {0x2328, 0x2328}, {0x23CF, 0x23CF}, {0x23E9, 0x23F3}, {0x23F8, 0x23FA},
    {0x24C2, 0x24C2}, {0x25AA, 0x25AB}, {0x25B6, 0x25B6}, {0x25C0, 0x25C0}, {0x25FB, 0x25FE}, {0x2600, 0x2604},
    {0x260E, 0x260E}, {0x2611, 0x2611}, {0x2614, 0x2615}, {0x2618, 0x2618}, {0x261D, 0x261D}, {0x2620, 0x2620},
    {0x2622, 0x2623}, {0x2626, 0x2626}, {0x262A, 0x262A}, {0x262E, 0x262F}, {0x2638, 0x263A}, {0x2640, 0x2640},
    {0x2642, 0x2642}, {0x2648, 0x2653}, {0x265F, 0x2660}, {0x2663, 0x2663}, {0x2665, 0x2666}, {0x2668, 0x2668},
    {0x267B, 0x267B}, {0x267E, 0x267F}, {0x2692, 0x2697}, {0x2699, 0x2699}, {0x269B, 0x269C}, {0x26A0, 0x26A1},
    {0x26A7, 0x26A7}, {0x26AA, 0x26AB}, {0x26B0, 0x26B1}, {0x26BD, 0x26BE}, {0x26C4, 0x26C5}, {0x26C8, 0x26C8},
    {0x26CE, 0x26CF}, {0x26D1, 0x26D1}, {0x26D3, 0x26D4}, {0x26E9, 0x26EA}, {0x26F0, 0x26F5}, {0x26F7, 0x26FA},
    {0x26FD, 0x26FD}, {0x2702, 0x2702}, {0x2705, 0x2705}, {0x2708, 0x270D}, {0x270F, 0x270F}, {0x2712, 0x2712},
    {0x2714, 0x2714}, {0x2716, 0x2716}, {0x271D, 0x271D}, {0x2721, 0x2721}, {0x2728, 0x2728}, {0x2733, 0x2734},
    {0x2744, 0x2744}, {0x2747, 0x2747}, {0x274C, 0x274C}, {0x274E, 0x274E}, {0x2753, 0x2755}, {0x2757, 0x2757},
    {0x2763, 0x2764}, {0x2795, 0x2797}, {0x27A1, 0x27A1}, {0x27B0, 0x27B0}, {0x27BF, 0x27BF}, {0x2934, 0x2935},
    {0x2B05, 0x2B07}, {0x2B1B, 0x2B1C}, {0x2B50, 0x2B50}, {0x2B55, 0x2B55}, {0x3030, 0x3030}, {0x303D, 0x303D},
    {0x3297, 0x3297}, {0x3299, 0x3299},
};

// InCB=Consonant (Unicode 15.1): the consonants of the scripts whose viramas join them into conjuncts.
constexpr Range kConsonants[] = {
    {0x915, 0x939}, {0x958, 0x95F}, {0x978, 0x97F}, {0x995, 0x9A8}, {0x9AA, 0x9B0}, {0x9B2, 0x9B2}, {0x9B6, 0x9B9},
    {0x9DC, 0x9DD}, {0x9DF, 0x9DF}, {0x9F0, 0x9F1}, {0xA95, 0xAA8}, {0xAAA, 0xAB0}, {0xAB2, 0xAB3}, {0xAB5, 0xAB9},
    {0xAF9, 0xAF9}, {0xB15, 0xB28}, {0xB2A, 0xB30}, {0xB32, 0xB33}, {0xB35, 0xB39}, {0xB5C, 0xB5D}, {0xB5F, 0xB5F},
    {0xB71, 0xB71}, {0xC15, 0xC28}, {0xC2A, 0xC39}, {0xC58, 0xC5A}, {0xD15, 0xD3A},
};

// Spacing marks that do not attach (the exceptions of Grapheme_Cluster_Break=SpacingMark): Myanmar, Tai Tham, Cham, Ahom.
constexpr Range kNotSpacing[] = {
    {0x102B, 0x102C}, {0x1038, 0x1038}, {0x1062, 0x1064}, {0x1067, 0x106D}, {0x1083, 0x1083}, {0x1087, 0x108C},
    {0x108F, 0x108F}, {0x109A, 0x109C}, {0x1A61, 0x1A61}, {0x1A63, 0x1A64}, {0xAA7B, 0xAA7B}, {0xAA7D, 0xAA7D},
    {0x11720, 0x11721},
};

constexpr uint kHangulFirst = 0xAC00, kHangulLast = 0xD7A3;

bool isRejected(uint cp)
{
    switch (QChar::category(cp)) {
    case QChar::Other_Control:
    case QChar::Other_Surrogate:
    case QChar::Separator_Line:
    case QChar::Separator_Paragraph:
        return true;
    case QChar::Other_Format:
        // The joiner of emoji sequences and the tag characters of subdivision flags are allowed.
        return cp != 0x200D && !(cp >= 0xE0020 && cp <= 0xE007F);
    default:
        return cp == 0xFFFD;
    }
}
} // namespace

unsigned glyphClasses(uint cp)
{
    unsigned m = 0;
    const QChar::Category category = QChar::category(cp);
    if (category == QChar::Mark_NonSpacing || category == QChar::Mark_Enclosing || cp == 0x200C || cp == 0xFF9E || cp == 0xFF9F
        || (cp >= 0x1F3FB && cp <= 0x1F3FF) || (cp >= 0xE0020 && cp <= 0xE007F))
        m |= GlyphExtend;
    if ((category == QChar::Mark_SpacingCombining && !within(cp, kNotSpacing)) || cp == 0xEB3)
        m |= GlyphSpacing;
    if (cp == 0x200D)
        m |= GlyphJoiner;
    if (cp >= 0x1F1E6 && cp <= 0x1F1FF)
        m |= GlyphRegional;
    if (within(cp, kPictographic))
        m |= GlyphPictograph;
    if ((cp >= 0x1100 && cp <= 0x115F) || (cp >= 0xA960 && cp <= 0xA97C))
        m |= GlyphHangulL;
    if ((cp >= 0x1160 && cp <= 0x11A7) || (cp >= 0xD7B0 && cp <= 0xD7C6))
        m |= GlyphHangulV;
    if ((cp >= 0x11A8 && cp <= 0x11FF) || (cp >= 0xD7CB && cp <= 0xD7FB))
        m |= GlyphHangulT;
    if (within(cp, kConsonants))
        m |= GlyphConsonant;
    if (cp == 0x94D || cp == 0x9CD || cp == 0xACD || cp == 0xB4D || cp == 0xC4D || cp == 0xD4D)
        m |= GlyphLinker;
    if (isRejected(cp)) {
        m |= GlyphRejected;
        if (!(m & GlyphExtend))
            m |= GlyphControl;
    }
    if (cp >= 0x1F000 || within(cp, kEmojiBmp))
        m |= GlyphEmoji;
    return m;
}

namespace
{
enum Hangul { HangulNone, HangulL, HangulV, HangulT, HangulLV, HangulLVT };

Hangul hangulOf(uint cp, unsigned classes)
{
    if (cp >= kHangulFirst && cp <= kHangulLast)
        return (cp - kHangulFirst) % 28 == 0 ? HangulLV : HangulLVT;
    if (classes & GlyphHangulL)
        return HangulL;
    if (classes & GlyphHangulV)
        return HangulV;
    if (classes & GlyphHangulT)
        return HangulT;
    return HangulNone;
}

// The code point at `i` (a lone surrogate is returned as is) and its length in UTF-16 units.
uint codePointAt(const QString &s, int i, int *units)
{
    const uint c = s.at(i).unicode();
    if (QChar::isHighSurrogate(c) && i + 1 < s.size() && QChar::isLowSurrogate(s.at(i + 1).unicode())) {
        *units = 2;
        return QChar::surrogateToUcs4(c, s.at(i + 1).unicode());
    }
    *units = 1;
    return c;
}

// The end (UTF-16 units) of the first cluster of a non-empty `s`.
int firstClusterEnd(const QString &s)
{
    int units = 0;
    const uint first = codePointAt(s, 0, &units);
    const unsigned firstClasses = glyphClasses(first);
    int end = units;
    if (firstClasses & GlyphControl)
        return end; // GB4/GB5: a control stands alone (the symbol is refused later)
    Hangul hangul = hangulOf(first, firstClasses);
    int regionals = (firstClasses & GlyphRegional) ? 1 : 0;
    enum { NoPict, PictReady, PictJoined } pict = (firstClasses & GlyphPictograph) ? PictReady : NoPict;
    int conjunct = (firstClasses & GlyphConsonant) ? 1 : 0; // 1: a consonant seen, 2: ... then a linker
    while (end < s.size()) {
        const uint cp = codePointAt(s, end, &units);
        const unsigned classes = glyphClasses(cp);
        if (classes & GlyphControl)
            break; // GB5
        const Hangul h = hangulOf(cp, classes);
        bool join = false;
        if (hangul == HangulL && h != HangulNone && h != HangulT)
            join = true; // GB6
        else if ((hangul == HangulLV || hangul == HangulV) && (h == HangulV || h == HangulT))
            join = true; // GB7
        else if ((hangul == HangulLVT || hangul == HangulT) && h == HangulT)
            join = true; // GB8
        if (!join && (classes & (GlyphExtend | GlyphJoiner | GlyphSpacing)))
            join = true; // GB9, GB9a
        if (!join && (classes & GlyphConsonant) && conjunct == 2)
            join = true; // GB9c
        if (!join && (classes & GlyphPictograph) && pict == PictJoined)
            join = true; // GB11
        if (!join && (classes & GlyphRegional) && regionals % 2 == 1)
            join = true; // GB12, GB13
        if (!join)
            break;
        hangul = h;
        regionals = (classes & GlyphRegional) ? regionals + 1 : 0;
        if (classes & GlyphPictograph)
            pict = PictReady;
        else if (pict == PictReady && (classes & GlyphExtend))
            pict = PictReady;
        else if (pict == PictReady && (classes & GlyphJoiner))
            pict = PictJoined;
        else
            pict = NoPict;
        if (classes & GlyphConsonant)
            conjunct = 1;
        else if (classes & GlyphLinker)
            conjunct = conjunct >= 1 ? 2 : 0;
        else if (!(classes & (GlyphExtend | GlyphJoiner)))
            conjunct = 0;
        end += units;
    }
    return end;
}
} // namespace

QString normalizeGlyph(const QString &glyph)
{
    const QString trimmed = glyph.trimmed();
    if (trimmed.isEmpty())
        return {};
    QString cluster = trimmed.left(firstClusterEnd(trimmed));
    // A joiner with nothing to join is invisible baggage: it is dropped ("a" + joiner + star keeps the "a").
    while (cluster.endsWith(QChar(0x200D)))
        cluster.chop(1);
    if (cluster.isEmpty() || cluster.size() > kMaxGlyphUnits)
        return {};
    // No control, format (bidi marks, zero width space...; the emoji joiner and the tag characters of subdivision flags
    // are allowed), separator, lone surrogate or replacement character anywhere in it.
    for (int i = 0; i < cluster.size();) {
        int units = 0;
        const uint cp = codePointAt(cluster, i, &units);
        if (glyphClasses(cp) & GlyphRejected)
            return {};
        i += units;
    }
    return cluster;
}

bool isEmoji(const QString &glyph)
{
    bool emoji = false;
    for (int i = 0; i < glyph.size();) {
        int units = 0;
        const uint cp = codePointAt(glyph, i, &units);
        i += units;
        if (cp == 0xFE0E)
            return false;
        if (cp == 0xFE0F || cp == 0x20E3 || (glyphClasses(cp) & GlyphEmoji))
            emoji = true;
    }
    return emoji;
}

QList<QPair<QUrl, QUrl>> followingPaste(const QList<QUrl> &sources, const QUrl &destination, const QSet<QUrl> &created)
{
    QList<QPair<QUrl, QUrl>> out;
    for (const QUrl &from : sources) {
        QUrl to = destination.adjusted(QUrl::StripTrailingSlash);
        to.setPath(to.path() + QLatin1Char('/') + from.fileName());
        if (created.contains(to))
            out.append({from, to});
    }
    return out;
}

namespace
{
QJsonObject objectOf(const QByteArray &stored)
{
    if (stored.isEmpty() || stored.size() > kMaxStored)
        return {};
    return QJsonDocument::fromJson(stored).object();
}
} // namespace

Style parse(const QByteArray &stored)
{
    const QJsonObject o = objectOf(stored);
    Style style;
    const QJsonValue color = o.value(QStringLiteral("color"));
    if (color.isString())
        style.color = normalizeColor(color.toString());
    const QJsonValue glyph = o.value(QStringLiteral("glyph"));
    if (glyph.isString())
        style.glyph = normalizeGlyph(glyph.toString());
    return style;
}

bool tooLargeToEdit(const QByteArray &stored)
{
    return stored.size() > kMaxStored;
}

QByteArray apply(const QByteArray &stored, const Style &style)
{
    QJsonObject o = objectOf(stored);
    const QString color = normalizeColor(style.color);
    const QString glyph = normalizeGlyph(style.glyph);
    if (color.isEmpty())
        o.remove(QStringLiteral("color"));
    else
        o.insert(QStringLiteral("color"), color);
    if (glyph.isEmpty())
        o.remove(QStringLiteral("glyph"));
    else
        o.insert(QStringLiteral("glyph"), glyph);
    // Nothing of ours and nothing of a newer version is left: no attribute at all.
    if (o.isEmpty() || (o.size() == 1 && o.contains(QStringLiteral("v"))))
        return {};
    if (!o.contains(QStringLiteral("v")))
        o.insert(QStringLiteral("v"), 1);
    return QJsonDocument(o).toJson(QJsonDocument::Compact);
}

QByteArray serialize(const Style &style)
{
    return apply({}, style);
}

int debounceDelay(int quietMs, int maxWaitMs, qint64 sinceFirstMs)
{
    const qint64 left = qMax<qint64>(0, qint64(maxWaitMs) - sinceFirstMs);
    return int(qMin<qint64>(quietMs, left));
}

} // namespace FolderStyleLogic
