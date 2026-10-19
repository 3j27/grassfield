#include "folderstylelogic.h"

#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QTextBoundaryFinder>

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

QString normalizeGlyph(const QString &glyph)
{
    const QString trimmed = glyph.trimmed();
    if (trimmed.isEmpty())
        return {};
    QTextBoundaryFinder finder(QTextBoundaryFinder::Grapheme, trimmed);
    const int end = finder.toNextBoundary();
    const QString cluster = end < 0 ? trimmed : trimmed.left(end);
    if (cluster.size() > kMaxGlyphUnits)
        return {};
    // Same rule as ui/Grassfield/Ui/FolderStyle.js normalizeGlyph: no control, format (bidi marks, zero width space...,
    // except the joiner of emoji sequences and the tag characters of subdivision flags), separator, lone surrogate or
    // replacement character.
    for (int i = 0; i < cluster.size(); ++i) {
        uint ucs4 = cluster.at(i).unicode();
        if (QChar::isHighSurrogate(ucs4) && i + 1 < cluster.size() && QChar::isLowSurrogate(cluster.at(i + 1).unicode())) {
            ucs4 = QChar::surrogateToUcs4(ucs4, cluster.at(i + 1).unicode());
            ++i;
        }
        switch (QChar::category(ucs4)) {
        case QChar::Other_Control:
        case QChar::Other_Surrogate:
        case QChar::Separator_Line:
        case QChar::Separator_Paragraph:
            return {};
        case QChar::Other_Format:
            if (ucs4 != 0x200D && !(ucs4 >= 0xE0020 && ucs4 <= 0xE007F))
                return {};
            break;
        default:
            if (ucs4 == 0xFFFD)
                return {};
            break;
        }
    }
    return cluster;
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

} // namespace FolderStyleLogic
