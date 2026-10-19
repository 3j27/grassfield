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
#include "graphemedata.inc"

constexpr uint kHangulFirst = 0xAC00, kHangulLast = 0xD7A3;
} // namespace

unsigned glyphClasses(uint cp)
{
    // Binary search in the generated runs (graphemedata.inc, from the Unicode properties: scripts/dev/gen-glyph-tables.sh).
    size_t lo = 0, hi = sizeof kGlyphRuns / sizeof kGlyphRuns[0];
    while (lo < hi) {
        const size_t mid = (lo + hi) / 2;
        if (cp < kGlyphRuns[mid][0])
            hi = mid;
        else if (cp > kGlyphRuns[mid][1])
            lo = mid + 1;
        else
            return kGlyphRuns[mid][2];
    }
    return 0;
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

// The end (UTF-16 units) of the first cluster of a non-empty `s`: the rules of UAX #29 (extended grapheme clusters, GB3 to
// GB13 and GB9c) over the generated classes.
int firstClusterEnd(const QString &s)
{
    int units = 0;
    const uint first = codePointAt(s, 0, &units);
    const unsigned firstClasses = glyphClasses(first);
    int end = units;
    if (firstClasses & GlyphControl) {
        // GB3: CR x LF; GB4/GB5: any other control stands alone (the symbol is refused later)
        if (first == 0x0D && end < s.size() && s.at(end) == QChar(0x0A))
            ++end;
        return end;
    }
    Hangul hangul = hangulOf(first, firstClasses);
    bool prepended = (firstClasses & GlyphPrepend) != 0;
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
        if (!join && prepended)
            join = true; // GB9b
        if (!join && (classes & GlyphConsonant) && conjunct == 2)
            join = true; // GB9c
        if (!join && (classes & GlyphPictograph) && pict == PictJoined)
            join = true; // GB11
        if (!join && (classes & GlyphRegional) && regionals % 2 == 1)
            join = true; // GB12, GB13
        if (!join)
            break;
        hangul = h;
        prepended = (classes & GlyphPrepend) != 0;
        regionals = (classes & GlyphRegional) ? regionals + 1 : 0;
        if (classes & GlyphPictograph)
            pict = PictReady;
        else if (pict == PictReady && (classes & GlyphExtend))
            pict = PictReady;
        else if (pict == PictReady && (classes & GlyphJoiner))
            pict = PictJoined;
        else
            pict = NoPict;
        // [InCB=Consonant] [Extend Linker]* Linker [Extend Linker]* x [InCB=Consonant]
        if (classes & GlyphConsonant)
            conjunct = 1;
        else if (classes & GlyphLinker)
            conjunct = conjunct >= 1 ? 2 : 0;
        else if (!(classes & GlyphIncbExtend))
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
