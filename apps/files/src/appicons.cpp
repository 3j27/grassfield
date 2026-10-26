#include "appicons.h"

#include "applicationslogic.h"

#include <QBuffer>
#include <QHash>
#include <QList>
#include <QImageReader>
#include <QXmlStreamReader>

namespace AppIcons
{

namespace
{
// Every "url(" in `text` must name a fragment of the document: url(#id), also quoted or padded.
bool urlsStayInside(const QString &text)
{
    int from = 0;
    for (;;) {
        const int at = text.indexOf(QLatin1String("url("), from, Qt::CaseInsensitive);
        if (at < 0)
            return true;
        int i = at + 4;
        while (i < text.size() && text.at(i).isSpace())
            ++i;
        if (i < text.size() && (text.at(i) == QLatin1Char('"') || text.at(i) == QLatin1Char('\'')))
            ++i;
        if (i >= text.size() || text.at(i) != QLatin1Char('#'))
            return false;
        from = i;
    }
}

// CSS: no at-rule (@import, @font-face) and no escape that could spell one of the words above.
bool cssIsPlain(const QString &text)
{
    return !text.contains(QLatin1Char('@')) && !text.contains(QLatin1Char('\\')) && urlsStayInside(text);
}
} // namespace

bool svgIsSelfContained(const QByteArray &data)
{
    if (data.isEmpty() || data.size() > kMaxSvgBytes)
        return false;
    QByteArray text = data;
    if (text.startsWith("\xEF\xBB\xBF"))
        text.remove(0, 3);
    // Plain UTF-8 only: a gzip (svgz) or UTF-16 document cannot be checked here and is refused.
    int first = 0;
    while (first < text.size() && (text.at(first) == ' ' || text.at(first) == '\t' || text.at(first) == '\n' || text.at(first) == '\r'))
        ++first;
    if (first >= text.size() || text.at(first) != '<')
        return false;

    QXmlStreamReader xml(text);
    int depth = 0;
    int elements = 0;
    int uses = 0;
    int styleDepth = 0;
    // <use> copies what it references: a use inside something that is itself used multiplies (63 chained uses are 9^7 copies,
    // minutes of CPU). Only a use of an element with no use inside it is accepted, so the expansion is at most kMaxSvgUses
    // copies of one element. Each open element is an index; `ids` maps an id to its index.
    QList<int> open;
    QList<bool> containsUse;
    QList<bool> isStyle;
    QHash<QString, int> ids;
    QStringList useTargets;
    while (!xml.atEnd()) {
        switch (xml.readNext()) {
        case QXmlStreamReader::StartDocument: {
            const QString encoding = xml.documentEncoding().toString();
            if (!encoding.isEmpty() && encoding.compare(QLatin1String("utf-8"), Qt::CaseInsensitive) != 0)
                return false;
            break;
        }
        case QXmlStreamReader::DTD:
        case QXmlStreamReader::EntityReference:
        case QXmlStreamReader::ProcessingInstruction:
            return false;
        case QXmlStreamReader::StartElement: {
            if (++depth > kMaxSvgDepth || ++elements > kMaxSvgElements)
                return false;
            const QString name = xml.name().toString().toLower();
            // <image> and <feImage> are refused whatever they name: QtSvg opens even "#name" as a file relative to the
            // working directory (a FIFO there blocks the worker for good), and a data: image is not bounded in pixels.
            if (name == QLatin1String("image") || name == QLatin1String("feimage") || name == QLatin1String("script")
                || name == QLatin1String("foreignobject") || name == QLatin1String("iframe") || name == QLatin1String("embed")
                || name == QLatin1String("object") || name == QLatin1String("audio") || name == QLatin1String("video")
                || name == QLatin1String("handler") || name == QLatin1String("listener"))
                return false;
            const int index = int(containsUse.size());
            containsUse.append(false);
            isStyle.append(name == QLatin1String("style"));
            open.append(index);
            if (name == QLatin1String("style"))
                ++styleDepth;
            if (name == QLatin1String("use")) {
                if (++uses > kMaxSvgUses)
                    return false;
                for (const int i : std::as_const(open))
                    containsUse[i] = true;
            }
            const auto attributes = xml.attributes();
            for (const QXmlStreamAttribute &a : attributes) {
                const QString key = a.name().toString().toLower();
                const QString value = a.value().toString();
                if (key == QLatin1String("href")) {
                    if (!value.startsWith(QLatin1Char('#')))
                        return false;
                    if (name == QLatin1String("use"))
                        useTargets << value.mid(1);
                }
                if (key == QLatin1String("id"))
                    ids.insert(value, index);
                if (key == QLatin1String("base") || key == QLatin1String("src"))
                    return false;
                // <set attributeName="href" to="file"> and <animate ...> write an href later.
                if (key == QLatin1String("attributename") && value.contains(QLatin1String("href"), Qt::CaseInsensitive))
                    return false;
                if (key.startsWith(QLatin1String("on")))
                    return false;
                if (!urlsStayInside(value) || (key == QLatin1String("style") && !cssIsPlain(value)))
                    return false;
            }
            break;
        }
        case QXmlStreamReader::EndElement:
            --depth;
            if (!open.isEmpty()) {
                if (isStyle.at(open.last()))
                    --styleDepth;
                open.removeLast();
            }
            break;
        case QXmlStreamReader::Characters:
        case QXmlStreamReader::Comment: {
            const QString content = xml.text().toString();
            if (!urlsStayInside(content) || (styleDepth > 0 && !cssIsPlain(content)))
                return false;
            break;
        }
        default:
            break;
        }
    }
    if (xml.hasError() || depth != 0 || elements == 0)
        return false;
    for (const QString &target : std::as_const(useTargets)) {
        const auto it = ids.constFind(target);
        if (it != ids.cend() && containsUse.at(*it))
            return false;
    }
    return true;
}

QImage decode(const QByteArray &data, const QSize &wanted)
{
    QSize want = wanted.expandedTo(QSize(1, 1)).boundedTo(QSize(kMaxSide, kMaxSide));
    static const QByteArray pngMagic("\x89PNG\r\n\x1a\n", 8);
    QByteArray copy = data; // QBuffer needs a non-const array
    QBuffer buffer(&copy);
    if (!buffer.open(QIODevice::ReadOnly))
        return {};
    const bool png = data.startsWith(pngMagic);
    if (png ? data.size() > kMaxPngBytes : !svgIsSelfContained(data))
        return {};

    QImageReader reader(&buffer, png ? "png" : "svg");
    reader.setAutoDetectImageFormat(false);
    reader.setAllocationLimit(64); // MiB
    const QSize size = reader.size();
    if (png) {
        if (!size.isValid() || size.width() > kMaxSide || size.height() > kMaxSide)
            return {};
    } else {
        // An SVG is rendered at the size asked, never at the size it declares (a width of a million pixels).
        const QSize fit = size.isValid() && !size.isEmpty() ? size.scaled(want, Qt::KeepAspectRatio) : want;
        reader.setScaledSize(fit.expandedTo(QSize(1, 1)));
    }
    QImage image = reader.read();
    if (image.isNull())
        return {};
    if (image.width() > want.width() || image.height() > want.height())
        image = image.scaled(want, Qt::KeepAspectRatio, Qt::SmoothTransformation);
    return image;
}

QImage load(const QString &path, const QStringList &roots, const QSize &want)
{
    const qint64 cap = qMax(kMaxPngBytes, kMaxSvgBytes);
    const QByteArray data = ApplicationsLogic::readIconFile(path, roots, cap);
    return data.isEmpty() ? QImage() : decode(data, want);
}

} // namespace AppIcons
