#include "printlogic.h"

#include <QDir>
#include <QFileInfo>
#include <QRegularExpression>
#include <QUrl>

#include <algorithm>
#include <cmath>

namespace grassfield::portal::print {

namespace {

constexpr int kMaxRanges = 64;
constexpr double kInch = 25.4;

QString text(const QVariantMap &map, const QString &key)
{
    const QVariant v = map.value(key);
    return v.canConvert<QString>() ? v.toString().trimmed() : QString();
}

bool flag(const QVariantMap &map, const QString &key, bool fallback)
{
    const QString v = text(map, key).toLower();
    if (v == QLatin1String("true"))
        return true;
    if (v == QLatin1String("false"))
        return false;
    return fallback;
}

// A positive number in a GTK settings string ("2", "100.000000"), else 0; at most 1e6 (an application's "1e300" never reaches
// an int conversion it would overflow).
double number(const QVariant &value)
{
    bool ok = false;
    const double d = value.toString().trimmed().toDouble(&ok);
    return ok && std::isfinite(d) && d > 0 ? std::min(d, 1e6) : 0;
}

QString orientationOf(const QString &value)
{
    // GTK's settings write "reverse_landscape", its page setup "reverse-landscape": the sheet keeps the two it shows.
    return value.contains(QLatin1String("landscape")) ? QStringLiteral("landscape") : QStringLiteral("portrait");
}

QString oneLine(const QString &s)
{
    QString out;
    for (const QChar c : s) {
        if (c.isPrint() || c == QLatin1Char(' '))
            out += c;
        else if (c.isSpace())
            out += QLatin1Char(' ');
    }
    return out.simplified().left(200);
}

// The common sizes by the name before their size.
struct Known {
    const char *prefix;
    const char *shown;
};
const Known kKnown[] = {
    {"iso_a3", "A3"},
    {"iso_a4", "A4"},
    {"iso_a5", "A5"},
    {"iso_a6", "A6"},
    {"iso_b4", "B4"},
    {"iso_b5", "B5"},
    {"jis_b4", "JIS B4"},
    {"jis_b5", "JIS B5"},
    {"na_letter", "US Letter"},
    {"na_legal", "US Legal"},
    {"na_ledger", "Tabloid"},
    {"na_executive", "Executive"},
    {"na_index-4x6", "4 × 6"},
    {"na_5x7", "5 × 7"},
    {"iso_dl", "DL"},
    {"iso_c5", "C5"},
    {"iso_c6", "C6"},
    {"na_number-10", "#10"},
};

QString formatMm(double mm)
{
    const double rounded = std::round(mm * 10) / 10;
    return QString::number(rounded, 'f', rounded == std::floor(rounded) ? 0 : 1);
}

} // namespace

bool parseRanges(const QString &input, QList<PageRange> *out)
{
    const QString all = input.trimmed();
    if (all.isEmpty())
        return false;
    const QStringList parts = all.split(QLatin1Char(','));
    if (parts.size() > kMaxRanges)
        return false;
    static const QRegularExpression single(QStringLiteral("^\\s*([0-9]{1,6})\\s*$"));
    // A hyphen or an en dash between the two pages.
    static const QRegularExpression span(QStringLiteral("^\\s*([0-9]{1,6})\\s*[-\\x{2013}]\\s*([0-9]{1,6})\\s*$"));
    QList<PageRange> ranges;
    for (const QString &part : parts) {
        int first = 0, last = 0;
        if (const auto m = single.match(part); m.hasMatch()) {
            first = last = m.captured(1).toInt();
        } else if (const auto m2 = span.match(part); m2.hasMatch()) {
            first = m2.captured(1).toInt();
            last = m2.captured(2).toInt();
        } else {
            return false;
        }
        if (first < 1 || last < first || last > kMaxPage)
            return false;
        ranges.append({first - 1, last - 1});
    }
    std::sort(ranges.begin(), ranges.end(), [](const PageRange &a, const PageRange &b) { return a.first < b.first; });
    QList<PageRange> merged;
    for (const PageRange &r : std::as_const(ranges)) {
        if (!merged.isEmpty() && r.first <= merged.last().last + 1)
            merged.last().last = std::max(merged.last().last, r.last);
        else
            merged.append(r);
    }
    *out = merged;
    return true;
}

QString gtkRanges(const QList<PageRange> &ranges)
{
    QStringList parts;
    for (const PageRange &r : ranges)
        parts << (r.first == r.last ? QString::number(r.first) : QStringLiteral("%1-%2").arg(r.first).arg(r.last));
    return parts.join(QLatin1Char(','));
}

QString shownRanges(const QList<PageRange> &ranges)
{
    QStringList parts;
    for (const PageRange &r : ranges)
        parts << (r.first == r.last ? QString::number(r.first + 1) : QStringLiteral("%1-%2").arg(r.first + 1).arg(r.last + 1));
    return parts.join(QStringLiteral(", "));
}

bool pwgSize(const QString &name, double *widthMm, double *heightMm)
{
    static const QRegularExpression size(QStringLiteral("_([0-9]{1,5}(?:\\.[0-9]{1,6})?)x([0-9]{1,5}(?:\\.[0-9]{1,6})?)(mm|in)$"));
    const auto m = size.match(name);
    if (!m.hasMatch())
        return false;
    const double unit = m.captured(3) == QLatin1String("in") ? kInch : 1.0;
    const double w = m.captured(1).toDouble() * unit;
    const double h = m.captured(2).toDouble() * unit;
    if (!(w > 0) || !(h > 0))
        return false;
    *widthMm = w;
    *heightMm = h;
    return true;
}

QString mediaDisplayName(const QString &name)
{
    for (const Known &k : kKnown) {
        const QString prefix = QLatin1String(k.prefix);
        if (name == prefix || name.startsWith(prefix + QLatin1Char('_')))
            return QString::fromUtf8(k.shown);
    }
    double w = 0, h = 0;
    if (pwgSize(name, &w, &h))
        return QStringLiteral("%1 × %2 mm").arg(formatMm(w), formatMm(h));
    return oneLine(name);
}

Media findMedia(const QList<Media> &media, const QString &name, double widthMm, double heightMm)
{
    if (!name.isEmpty()) {
        for (const Media &m : media) {
            if (m.name == name)
                return m;
        }
    }
    if (widthMm > 0 && heightMm > 0) {
        for (const Media &m : media) {
            if (std::abs(m.widthMm - widthMm) <= 1.0 && std::abs(m.heightMm - heightMm) <= 1.0)
                return m;
        }
    }
    return {};
}

Choices initialChoices(const QString &printer, const Capabilities &caps, const QVariantMap &settings, const QVariantMap &pageSetup,
                       bool hasCurrentPage, bool hasSelection)
{
    Choices c;
    c.printer = printer;
    const int maxCopies = std::clamp(caps.maxCopies, 1, kMaxCopies);

    // The paper: the application's (page setup, then settings), as the printer names it; else the printer's default.
    QString name = text(pageSetup, QStringLiteral("Name"));
    double w = number(pageSetup.value(QStringLiteral("Width")));
    double h = number(pageSetup.value(QStringLiteral("Height")));
    if (name.isEmpty())
        name = text(settings, QStringLiteral("paper-format"));
    if (w <= 0 || h <= 0) {
        w = number(settings.value(QStringLiteral("paper-width")));
        h = number(settings.value(QStringLiteral("paper-height")));
    }
    if ((w <= 0 || h <= 0) && !pwgSize(name, &w, &h))
        w = h = 0;
    Media media = findMedia(caps.media, name, w, h);
    if (media.name.isEmpty() && !caps.media.isEmpty())
        media = findMedia(caps.media, caps.defaultMedia);
    if (media.name.isEmpty() && !caps.media.isEmpty())
        media = caps.media.first();
    if (media.name.isEmpty() && !caps.known && w > 0 && h > 0) {
        // Not known yet: the application's paper, until the printer says what it takes.
        media.name = name.isEmpty() || name.contains(QLatin1Char(' ')) ? QStringLiteral("custom_%1x%2mm").arg(formatMm(w), formatMm(h)) : name;
        media.displayName = text(pageSetup, QStringLiteral("DisplayName"));
        if (media.displayName.isEmpty())
            media.displayName = mediaDisplayName(media.name);
        media.widthMm = w;
        media.heightMm = h;
    }
    if (media.name.isEmpty()) {
        media.name = QStringLiteral("iso_a4_210x297mm");
        media.displayName = mediaDisplayName(media.name);
        media.widthMm = 210;
        media.heightMm = 297;
    }
    c.media = media;

    const QString orientation = text(pageSetup, QStringLiteral("Orientation"));
    c.orientation = orientationOf(orientation.isEmpty() ? text(settings, QStringLiteral("orientation")) : orientation);

    const double copies = number(settings.value(QStringLiteral("n-copies")));
    c.copies = copies >= 1 ? std::clamp(int(copies), 1, maxCopies) : 1;
    c.collate = flag(settings, QStringLiteral("collate"), true);

    const QString pages = text(settings, QStringLiteral("print-pages"));
    QList<PageRange> ranges;
    if (pages == QLatin1String("ranges")) {
        // GTK's form is 0-based ("0-2,4"); one shown 1-based.
        QStringList shown;
        bool ok = true;
        const QStringList parts = text(settings, QStringLiteral("page-ranges")).split(QLatin1Char(','), Qt::SkipEmptyParts);
        for (const QString &part : parts) {
            const QStringList ends = part.split(QLatin1Char('-'));
            bool a = false, b = true;
            const int first = ends.value(0).trimmed().toInt(&a);
            const int last = ends.size() > 1 ? ends.value(1).trimmed().toInt(&b) : first;
            if (!a || !b || ends.size() > 2 || first < 0 || last < first || last >= kMaxPage) {
                ok = false;
                break;
            }
            shown << (first == last ? QString::number(first + 1) : QStringLiteral("%1-%2").arg(first + 1).arg(last + 1));
        }
        if (ok && !shown.isEmpty() && parseRanges(shown.join(QLatin1Char(',')), &ranges)) {
            c.pages = QStringLiteral("ranges");
            c.ranges = shownRanges(ranges);
        }
    } else if (pages == QLatin1String("current") && hasCurrentPage) {
        c.pages = pages;
    } else if (pages == QLatin1String("selection") && hasSelection) {
        c.pages = pages;
    }

    const double scale = number(settings.value(QStringLiteral("scale")));
    c.scale = scale > 0 ? std::clamp(int(std::lround(scale)), kMinScale, kMaxScale) : 100;

    const QString duplex = text(settings, QStringLiteral("duplex"));
    if ((duplex == QLatin1String("horizontal") || duplex == QLatin1String("vertical")) && (caps.twoSided || !caps.known))
        c.duplex = duplex;

    c.color = flag(settings, QStringLiteral("use-color"), caps.known ? caps.color : true);
    if (caps.known && !caps.color)
        c.color = false;
    return c;
}

bool toGtk(const Choices &c, QVariantMap *settings, QVariantMap *pageSetup)
{
    QList<PageRange> ranges;
    if (c.pages == QLatin1String("ranges") && !parseRanges(c.ranges, &ranges))
        return false;
    if (c.media.name.isEmpty() || !(c.media.widthMm > 0) || !(c.media.heightMm > 0))
        return false;
    const bool toFile = !c.outputUri.isEmpty();
    QVariantMap s;
    if (!toFile && !c.printer.isEmpty())
        s.insert(QStringLiteral("printer"), c.printer);
    // One copy: GTK 3 would render the copies into the document, GTK 4 too for a file; the job asks the printer for them.
    s.insert(QStringLiteral("n-copies"), QStringLiteral("1"));
    s.insert(QStringLiteral("collate"), c.collate ? QStringLiteral("true") : QStringLiteral("false"));
    const QString pages = c.pages == QLatin1String("ranges") || c.pages == QLatin1String("current") || c.pages == QLatin1String("selection")
        ? c.pages
        : QStringLiteral("all");
    s.insert(QStringLiteral("print-pages"), pages);
    if (pages == QLatin1String("ranges"))
        s.insert(QStringLiteral("page-ranges"), gtkRanges(ranges));
    const QString orientation = c.orientation == QLatin1String("landscape") ? QStringLiteral("landscape") : QStringLiteral("portrait");
    s.insert(QStringLiteral("orientation"), orientation);
    s.insert(QStringLiteral("paper-format"), c.media.name);
    s.insert(QStringLiteral("paper-width"), QString::number(c.media.widthMm, 'f', 2));
    s.insert(QStringLiteral("paper-height"), QString::number(c.media.heightMm, 'f', 2));
    s.insert(QStringLiteral("scale"), QString::number(std::clamp(c.scale, kMinScale, kMaxScale)));
    const QString duplex = c.duplex == QLatin1String("horizontal") || c.duplex == QLatin1String("vertical") ? c.duplex : QStringLiteral("simplex");
    s.insert(QStringLiteral("duplex"), duplex);
    s.insert(QStringLiteral("use-color"), c.color ? QStringLiteral("true") : QStringLiteral("false"));
    if (toFile) {
        s.insert(QStringLiteral("output-uri"), QString::fromLatin1(kPdfOutputUri));
        s.insert(QStringLiteral("output-file-format"), QStringLiteral("pdf"));
    }

    QVariantMap p;
    p.insert(QStringLiteral("Name"), c.media.name);
    p.insert(QStringLiteral("DisplayName"), c.media.displayName.isEmpty() ? mediaDisplayName(c.media.name) : c.media.displayName);
    p.insert(QStringLiteral("Width"), c.media.widthMm);
    p.insert(QStringLiteral("Height"), c.media.heightMm);
    p.insert(QStringLiteral("MarginTop"), std::max(0.0, c.media.topMm));
    p.insert(QStringLiteral("MarginBottom"), std::max(0.0, c.media.bottomMm));
    p.insert(QStringLiteral("MarginLeft"), std::max(0.0, c.media.leftMm));
    p.insert(QStringLiteral("MarginRight"), std::max(0.0, c.media.rightMm));
    p.insert(QStringLiteral("Orientation"), orientation);
    *settings = s;
    *pageSetup = p;
    return true;
}

QList<QPair<QString, QString>> cupsOptions(const Choices &c, const Capabilities &caps)
{
    QList<QPair<QString, QString>> out;
    if (!c.outputUri.isEmpty())
        return out;
    const int copies = std::clamp(c.copies, 1, std::clamp(caps.maxCopies, 1, kMaxCopies));
    if (copies > 1) {
        out.append({QStringLiteral("copies"), QString::number(copies)});
        out.append({QStringLiteral("multiple-document-handling"),
                    c.collate ? QStringLiteral("separate-documents-collated-copies") : QStringLiteral("separate-documents-uncollated-copies")});
    }
    const bool listed = std::any_of(caps.media.cbegin(), caps.media.cend(), [&c](const Media &m) { return m.name == c.media.name; });
    if (!c.media.name.isEmpty() && (listed || (caps.media.isEmpty() && validMediaName(c.media.name))))
        out.append({QStringLiteral("media"), c.media.name});
    if (caps.twoSided) {
        const QString sides = c.duplex == QLatin1String("horizontal") ? QStringLiteral("two-sided-long-edge")
            : c.duplex == QLatin1String("vertical")                    ? QStringLiteral("two-sided-short-edge")
                                                                       : QStringLiteral("one-sided");
        out.append({QStringLiteral("sides"), sides});
    }
    if (caps.color)
        out.append({QStringLiteral("print-color-mode"), c.color ? QStringLiteral("color") : QStringLiteral("monochrome")});
    return out;
}

QVariantMap toQml(const Media &m)
{
    return {
        {QStringLiteral("name"), m.name},
        {QStringLiteral("displayName"), m.displayName.isEmpty() ? mediaDisplayName(m.name) : m.displayName},
        {QStringLiteral("widthMm"), m.widthMm},
        {QStringLiteral("heightMm"), m.heightMm},
        {QStringLiteral("topMm"), m.topMm},
        {QStringLiteral("bottomMm"), m.bottomMm},
        {QStringLiteral("leftMm"), m.leftMm},
        {QStringLiteral("rightMm"), m.rightMm},
    };
}

QVariantMap toQml(const Choices &c)
{
    return {
        {QStringLiteral("printer"), c.printer},
        {QStringLiteral("copies"), c.copies},
        {QStringLiteral("collate"), c.collate},
        {QStringLiteral("pages"), c.pages},
        {QStringLiteral("ranges"), c.ranges},
        {QStringLiteral("media"), toQml(c.media)},
        {QStringLiteral("orientation"), c.orientation},
        {QStringLiteral("scale"), c.scale},
        {QStringLiteral("duplex"), c.duplex},
        {QStringLiteral("color"), c.color},
        {QStringLiteral("outputUri"), c.outputUri},
    };
}

Choices fromQml(const QVariantMap &map, const Choices &base)
{
    Choices c = base;
    if (map.contains(QStringLiteral("printer")))
        c.printer = oneLine(map.value(QStringLiteral("printer")).toString());
    if (map.contains(QStringLiteral("copies")))
        c.copies = std::clamp(map.value(QStringLiteral("copies")).toInt(), 1, kMaxCopies);
    if (map.contains(QStringLiteral("collate")))
        c.collate = map.value(QStringLiteral("collate")).toBool();
    if (map.contains(QStringLiteral("pages"))) {
        const QString p = map.value(QStringLiteral("pages")).toString();
        if (p == QLatin1String("all") || p == QLatin1String("ranges") || p == QLatin1String("current") || p == QLatin1String("selection"))
            c.pages = p;
    }
    if (map.contains(QStringLiteral("ranges")))
        c.ranges = map.value(QStringLiteral("ranges")).toString().left(400);
    if (map.contains(QStringLiteral("media"))) {
        const QVariantMap m = map.value(QStringLiteral("media")).toMap();
        Media media;
        media.name = oneLine(m.value(QStringLiteral("name")).toString());
        media.displayName = oneLine(m.value(QStringLiteral("displayName")).toString());
        media.widthMm = m.value(QStringLiteral("widthMm")).toDouble();
        media.heightMm = m.value(QStringLiteral("heightMm")).toDouble();
        media.topMm = m.value(QStringLiteral("topMm")).toDouble();
        media.bottomMm = m.value(QStringLiteral("bottomMm")).toDouble();
        media.leftMm = m.value(QStringLiteral("leftMm")).toDouble();
        media.rightMm = m.value(QStringLiteral("rightMm")).toDouble();
        if (!media.name.isEmpty() && media.widthMm > 0 && media.heightMm > 0 && std::isfinite(media.widthMm) && std::isfinite(media.heightMm))
            c.media = media;
    }
    if (map.contains(QStringLiteral("orientation")))
        c.orientation = orientationOf(map.value(QStringLiteral("orientation")).toString());
    if (map.contains(QStringLiteral("scale")))
        c.scale = std::clamp(map.value(QStringLiteral("scale")).toInt(), kMinScale, kMaxScale);
    if (map.contains(QStringLiteral("duplex"))) {
        const QString d = map.value(QStringLiteral("duplex")).toString();
        c.duplex = d == QLatin1String("horizontal") || d == QLatin1String("vertical") ? d : QStringLiteral("simplex");
    }
    if (map.contains(QStringLiteral("color")))
        c.color = map.value(QStringLiteral("color")).toBool();
    if (map.contains(QStringLiteral("outputUri"))) {
        // GTK gets the file's URI in its encoded form.
        const QString path = localPdfPath(map.value(QStringLiteral("outputUri")).toString());
        c.outputUri = path.isEmpty() ? QString() : QUrl::fromLocalFile(path).toString(QUrl::FullyEncoded);
    }
    return c;
}

QVariantMap toQml(const Capabilities &caps)
{
    QVariantList media;
    for (const Media &m : caps.media)
        media.append(toQml(m));
    return {
        {QStringLiteral("known"), caps.known},
        {QStringLiteral("media"), media},
        {QStringLiteral("defaultMedia"), caps.defaultMedia},
        {QStringLiteral("twoSided"), caps.twoSided},
        {QStringLiteral("color"), caps.color},
        {QStringLiteral("maxCopies"), std::clamp(caps.maxCopies, 1, kMaxCopies)},
    };
}

QVariantMap toQml(const Destination &d)
{
    return {
        {QStringLiteral("name"), d.name},
        {QStringLiteral("displayName"), d.displayName.isEmpty() ? d.name : d.displayName},
        {QStringLiteral("location"), d.location},
        {QStringLiteral("isDefault"), d.isDefault},
    };
}

QVariantMap prepareOptions(const QVariantMap &options)
{
    QString accept = oneLine(options.value(QStringLiteral("accept_label")).toString());
    // A mnemonic's underscore goes ("_Print" → "Print"; "__" is one underscore).
    accept.replace(QStringLiteral("__"), QStringLiteral("\x01"));
    accept.remove(QLatin1Char('_'));
    accept.replace(QStringLiteral("\x01"), QStringLiteral("_"));
    QStringList formats;
    const QStringList given = options.value(QStringLiteral("supported_output_file_formats")).toStringList();
    for (const QString &f : given) {
        const QString lower = f.toLower();
        if ((lower == QLatin1String("pdf") || lower == QLatin1String("ps") || lower == QLatin1String("svg")) && !formats.contains(lower))
            formats << lower;
    }
    if (given.isEmpty())
        formats = {QStringLiteral("pdf"), QStringLiteral("ps"), QStringLiteral("svg")};
    const QVariant modal = options.value(QStringLiteral("modal"));
    return {
        {QStringLiteral("modal"), modal.metaType() == QMetaType::fromType<bool>() ? modal.toBool() : true},
        {QStringLiteral("acceptLabel"), accept},
        {QStringLiteral("hasCurrentPage"), options.value(QStringLiteral("has_current_page")).toBool()},
        {QStringLiteral("hasSelection"), options.value(QStringLiteral("has_selected_pages")).toBool()},
        {QStringLiteral("formats"), formats},
    };
}

bool validMediaName(const QString &name)
{
    // Anchored at the very end (\z): "$" would also let a final newline through.
    static const QRegularExpression pwg(QRegularExpression::anchoredPattern(QStringLiteral("[a-z0-9][a-z0-9_.-]{0,63}")));
    return pwg.match(name).hasMatch();
}

QString documentFormat(const QByteArray &head)
{
    if (head.startsWith("%PDF-"))
        return QStringLiteral("application/pdf");
    if (head.startsWith("%!"))
        return QStringLiteral("application/postscript");
    return {};
}

QByteArray jobName(const QString &title)
{
    QByteArray name = title.toUtf8();
    if (name.size() <= 255)
        return name;
    qsizetype cut = 255;
    // Back to the first byte of the character the cut falls in (continuation bytes are 10xxxxxx).
    while (cut > 0 && (uchar(name.at(cut)) & 0xC0) == 0x80)
        --cut;
    name.truncate(cut);
    return name;
}

QString localPdfPath(const QString &uri)
{
    // As the Save panel answers it ("file:///home/u/My%20Report.pdf"), or written with its spaces as they are.
    const QUrl url(uri);
    if (!url.isValid() || !url.isLocalFile() || !url.host().isEmpty())
        return {};
    const QString path = url.toLocalFile();
    if (!QDir::isAbsolutePath(path) || path.endsWith(QLatin1Char('/')) || path.contains(QStringLiteral("/../"))
        || path.endsWith(QStringLiteral("/..")) || path.contains(QStringLiteral("/./")) || path.contains(QLatin1Char('\0')))
        return {};
    return QDir::cleanPath(path) == path ? path : QString();
}

} // namespace grassfield::portal::print
