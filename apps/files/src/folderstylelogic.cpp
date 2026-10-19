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
    for (const QChar c : cluster) {
        if (c.category() == QChar::Other_Control || c == QChar(0xFFFD))
            return {};
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
