#include "wallpaperlogic.h"

#include <QByteArray>
#include <QColorSpace>
#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QImageReader>
#include <QImageIOHandler>
#include <QJsonArray>
#include <QPainter>
#include <QSaveFile>

#include <algorithm>
#include <array>
#include <cmath>

#include <sys/stat.h>

namespace wallpaper {

namespace {

// The formats a wallpaper may be (no SVG: a vector parser is not wanted here; no icons, no PDF).
const QStringList kFormats = {QStringLiteral("jpeg"), QStringLiteral("png"), QStringLiteral("webp"), QStringLiteral("tiff"), QStringLiteral("bmp"), QStringLiteral("gif")};

bool formatAllowed(const QByteArray &format)
{
    return kFormats.contains(QString::fromLatin1(format).toLower());
}

// sRGB byte to linear light.
const std::array<double, 256> &linearTable()
{
    static const std::array<double, 256> table = [] {
        std::array<double, 256> t{};
        for (int i = 0; i < 256; ++i) {
            const double c = i / 255.0;
            t[i] = c <= 0.04045 ? c / 12.92 : std::pow((c + 0.055) / 1.055, 2.4);
        }
        return t;
    }();
    return table;
}

constexpr int kBins = 1024;

struct Histogram {
    std::array<quint32, kBins> bins{};
    quint64 count = 0;
    double sum = 0;
    void add(double lum)
    {
        const int bin = std::clamp(int(lum * (kBins - 1) + 0.5), 0, kBins - 1);
        ++bins[bin];
        ++count;
        sum += lum;
    }
    double percentile(double p) const
    {
        if (count == 0)
            return 0;
        const quint64 target = quint64(std::ceil(p * double(count)));
        quint64 seen = 0;
        for (int i = 0; i < kBins; ++i) {
            seen += bins[i];
            if (seen >= std::max<quint64>(target, 1))
                return double(i) / (kBins - 1);
        }
        return 1;
    }
    QJsonObject toJson() const
    {
        return {{QStringLiteral("mean"), count ? sum / double(count) : 0.0}, {QStringLiteral("p5"), percentile(0.05)}, {QStringLiteral("p95"), percentile(0.95)}};
    }
};

} // namespace

bool parseFit(const QString &name, Fit *fit)
{
    static const QList<QPair<QString, Fit>> table = {{QStringLiteral("fill"), Fit::Fill}, {QStringLiteral("fit"), Fit::Fit}, {QStringLiteral("stretch"), Fit::Stretch}, {QStringLiteral("center"), Fit::Center}, {QStringLiteral("tile"), Fit::Tile}};
    for (const auto &entry : table) {
        if (entry.first == name) {
            *fit = entry.second;
            return true;
        }
    }
    return false;
}

bool parseSize(const QString &text, QSize *size)
{
    const QStringList parts = text.split(QLatin1Char('x'));
    if (parts.size() != 2)
        return false;
    bool okW = false, okH = false;
    const int w = parts[0].toInt(&okW);
    const int h = parts[1].toInt(&okH);
    if (!okW || !okH || w < 1 || h < 1 || w > kMaxSide || h > kMaxSide || qint64(w) * h > kMaxPixels)
        return false;
    *size = QSize(w, h);
    return true;
}

ExitCode checkFile(const QString &path, qint64 maxBytes, qint64 *bytes, qint64 *mtimeMs)
{
    struct stat st;
    const QByteArray local = QFile::encodeName(path);
    if (::stat(local.constData(), &st) != 0)
        return errno == ENOENT || errno == ENOTDIR ? NotFound : Unreadable;
    if (!S_ISREG(st.st_mode))
        return NotRegular;
    if (st.st_size > maxBytes)
        return TooLargeFile;
    if (bytes)
        *bytes = st.st_size;
    if (mtimeMs)
        *mtimeMs = qint64(st.st_mtim.tv_sec) * 1000 + st.st_mtim.tv_nsec / 1000000;
    return Ok;
}

ExitCode probePicture(const QString &path, QSize *size)
{
    QImageReader reader(path);
    reader.setDecideFormatFromContent(true);
    if (!reader.canRead())
        return reader.error() == QImageReader::UnsupportedFormatError ? Unsupported : Unreadable;
    if (!formatAllowed(reader.format()))
        return Unsupported;
    QSize s = reader.size();
    if (!s.isValid() || s.isEmpty())
        return Unreadable;
    const auto t = reader.transformation();
    if (t.testFlag(QImageIOHandler::TransformationRotate90))
        s.transpose();
    if (s.width() > kMaxSide || s.height() > kMaxSide || qint64(s.width()) * s.height() > kMaxPixels)
        return TooLargePicture;
    if (size)
        *size = s;
    return Ok;
}

ExitCode loadPicture(const QString &path, const QSize &target, Fit fit, QImage *out)
{
    QSize shown;
    if (const ExitCode c = probePicture(path, &shown))
        return c;
    QImageReader reader(path);
    reader.setDecideFormatFromContent(true);
    reader.setAutoTransform(true);
    // JPEG decodes scaled (DCT scaling): only without a rotation, where the file's size is the displayed size.
    if (reader.format() == "jpeg" && reader.transformation() == QImageIOHandler::TransformationNone) {
        double scale = 1;
        const double sx = double(target.width()) / shown.width(), sy = double(target.height()) / shown.height();
        switch (fit) {
        case Fit::Fill:
            scale = std::max(sx, sy);
            break;
        case Fit::Fit:
            scale = std::min(sx, sy);
            break;
        case Fit::Stretch:
            scale = std::max(sx, sy);
            break;
        default:
            break;
        }
        if (scale < 1)
            reader.setScaledSize(QSize(std::max(1, int(std::ceil(shown.width() * scale))), std::max(1, int(std::ceil(shown.height() * scale)))));
    }
    QImage img = reader.read();
    if (img.isNull())
        return reader.error() == QImageReader::UnsupportedFormatError ? Unsupported : Unreadable;
    if (img.colorSpace().isValid() && img.colorSpace() != QColorSpace(QColorSpace::SRgb))
        img.convertToColorSpace(QColorSpace(QColorSpace::SRgb));
    *out = img;
    return Ok;
}

QImage compose(const QImage &src, const QSize &target, Fit fit, const QColor &backdrop)
{
    QImage canvas(target, QImage::Format_RGB32);
    canvas.fill(backdrop);
    QPainter p(&canvas);
    p.setRenderHint(QPainter::SmoothPixmapTransform, true);
    switch (fit) {
    case Fit::Fill: {
        const QImage scaled = src.scaled(target, Qt::KeepAspectRatioByExpanding, Qt::SmoothTransformation);
        p.drawImage(QPoint((target.width() - scaled.width()) / 2, (target.height() - scaled.height()) / 2), scaled);
        break;
    }
    case Fit::Fit: {
        const QImage scaled = src.scaled(target, Qt::KeepAspectRatio, Qt::SmoothTransformation);
        p.drawImage(QPoint((target.width() - scaled.width()) / 2, (target.height() - scaled.height()) / 2), scaled);
        break;
    }
    case Fit::Stretch:
        p.drawImage(QRect(QPoint(0, 0), target), src.scaled(target, Qt::IgnoreAspectRatio, Qt::SmoothTransformation));
        break;
    case Fit::Center:
        p.drawImage(QPoint((target.width() - src.width()) / 2, (target.height() - src.height()) / 2), src);
        break;
    case Fit::Tile:
        for (int y = 0; y < target.height(); y += src.height())
            for (int x = 0; x < target.width(); x += src.width())
                p.drawImage(QPoint(x, y), src);
        break;
    }
    p.end();
    return canvas;
}

QJsonObject stripStats(const QImage &img, int rows)
{
    const QImage rgb = img.convertToFormat(QImage::Format_RGB32);
    const int h = std::min(rows, rgb.height());
    const auto &lin = linearTable();
    Histogram all, left, right;
    const int half = rgb.width() / 2;
    for (int y = 0; y < h; ++y) {
        const QRgb *line = reinterpret_cast<const QRgb *>(rgb.constScanLine(y));
        for (int x = 0; x < rgb.width(); ++x) {
            const double lum = 0.2126 * lin[qRed(line[x])] + 0.7152 * lin[qGreen(line[x])] + 0.0722 * lin[qBlue(line[x])];
            all.add(lum);
            (x < half ? left : right).add(lum);
        }
    }
    return {{QStringLiteral("rows"), h}, {QStringLiteral("all"), all.toJson()}, {QStringLiteral("left"), left.toJson()}, {QStringLiteral("right"), right.toJson()}};
}

QString meanColor(const QImage &img)
{
    const QImage rgb = img.convertToFormat(QImage::Format_RGB32);
    const int stepX = std::max(1, rgb.width() / 128), stepY = std::max(1, rgb.height() / 128);
    quint64 r = 0, g = 0, b = 0, n = 0;
    for (int y = 0; y < rgb.height(); y += stepY) {
        const QRgb *line = reinterpret_cast<const QRgb *>(rgb.constScanLine(y));
        for (int x = 0; x < rgb.width(); x += stepX) {
            r += qRed(line[x]);
            g += qGreen(line[x]);
            b += qBlue(line[x]);
            ++n;
        }
    }
    if (n == 0)
        return QStringLiteral("#000000");
    return QColor(int(r / n), int(g / n), int(b / n)).name();
}

QString cacheKey(const QString &realPath, qint64 bytes, qint64 mtimeMs, const QSize &target, Fit fit, const QColor &backdrop, int stripRows)
{
    QByteArray in;
    in += realPath.toUtf8();
    in += '\0' + QByteArray::number(bytes) + '\0' + QByteArray::number(mtimeMs) + '\0';
    in += QByteArray::number(target.width()) + 'x' + QByteArray::number(target.height()) + '\0';
    in += QByteArray::number(int(fit)) + '\0' + backdrop.name().toLatin1() + '\0' + QByteArray::number(stripRows);
    // A version byte: a change of the output format invalidates old entries.
    in += QByteArray("\0v1", 3);
    return QString::fromLatin1(QCryptographicHash::hash(in, QCryptographicHash::Sha256).toHex().left(32));
}

QStringList supportedSuffixes()
{
    const QList<QByteArray> formats = QImageReader::supportedImageFormats();
    auto has = [&](const char *f) { return formats.contains(QByteArray(f)); };
    QStringList out;
    if (has("jpeg") || has("jpg"))
        out << QStringLiteral("jpg") << QStringLiteral("jpeg");
    if (has("png"))
        out << QStringLiteral("png");
    if (has("webp"))
        out << QStringLiteral("webp");
    if (has("tiff") || has("tif"))
        out << QStringLiteral("tif") << QStringLiteral("tiff");
    if (has("bmp"))
        out << QStringLiteral("bmp");
    if (has("gif"))
        out << QStringLiteral("gif");
    return out;
}

ExitCode listFolder(const QString &folder, const QStringList &supported, int max, QStringList *files, bool *truncated, qint64 *mtimeMs)
{
    struct stat st;
    const QByteArray local = QFile::encodeName(folder);
    if (::stat(local.constData(), &st) != 0)
        return errno == ENOENT || errno == ENOTDIR ? NotFound : Unreadable;
    if (!S_ISDIR(st.st_mode))
        return NotRegular;
    if (mtimeMs)
        *mtimeMs = qint64(st.st_mtim.tv_sec) * 1000 + st.st_mtim.tv_nsec / 1000000;
    QDir dir(folder);
    if (!dir.isReadable())
        return Unreadable;
    QStringList names = dir.entryList(QDir::Files | QDir::NoDotAndDotDot | QDir::Readable, QDir::NoSort);
    QStringList kept;
    for (const QString &name : std::as_const(names)) {
        if (name.startsWith(QLatin1Char('.')))
            continue;
        const QString suffix = QFileInfo(name).suffix().toLower();
        if (!supported.contains(suffix))
            continue;
        kept << name;
    }
    std::sort(kept.begin(), kept.end(), [](const QString &a, const QString &b) { return a < b; });
    const int cap = std::clamp(max, 1, kMaxListEntries);
    *truncated = kept.size() > cap;
    if (kept.size() > cap)
        kept = kept.mid(0, cap);
    files->clear();
    const QString base = folder.endsWith(QLatin1Char('/')) ? folder.chopped(1) : folder;
    for (const QString &name : std::as_const(kept))
        files->append(base + QLatin1Char('/') + name);
    return Ok;
}

void pruneCache(const QString &dirPath, qint64 maxBytes, const QString &keep)
{
    QDir dir(dirPath);
    QFileInfoList list = dir.entryInfoList(QDir::Files | QDir::NoDotAndDotDot, QDir::Time | QDir::Reversed); // oldest first
    qint64 total = 0;
    for (const QFileInfo &f : std::as_const(list))
        total += f.size();
    const QDateTime recent = QDateTime::currentDateTime().addSecs(-60);
    for (const QFileInfo &f : std::as_const(list)) {
        if (total <= maxBytes)
            break;
        if (f.absoluteFilePath() == keep || f.lastModified() > recent)
            continue;
        const qint64 size = f.size();
        if (QFile::remove(f.absoluteFilePath()))
            total -= size;
    }
}

bool writeAtomic(const QString &path, const QByteArray &data)
{
    QSaveFile f(path);
    if (!f.open(QIODevice::WriteOnly))
        return false;
    f.setDirectWriteFallback(false);
    if (f.write(data) != data.size())
        return false;
    return f.commit();
}

} // namespace wallpaper
