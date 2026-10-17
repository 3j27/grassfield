#include "previewapp.h"

#include "previewlogic.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QImageReader>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocale>
#include <QProcess>

namespace {

QString configFile()
{
    const QString dev = qEnvironmentVariable("GRASSFIELD_CONFIG_HOME");
    if (!dev.isEmpty())
        return dev + QStringLiteral("/grassfield.json");
    const QString xdg = qEnvironmentVariable("XDG_CONFIG_HOME");
    return (xdg.isEmpty() ? QDir::homePath() + QStringLiteral("/.config") : xdg) + QStringLiteral("/grassfield/grassfield.json");
}

QString sizeText(qint64 bytes)
{
    return QLocale().formattedDataSize(bytes, 1, QLocale::DataSizeIecFormat);
}

// Size of the image as displayed (EXIF rotation by 90 degrees swaps the sides); invalid when unknown.
QSize displaySize(const QImageReader &reader)
{
    QSize size = reader.size();
    if (size.isValid() && (reader.transformation() & QImageIOHandler::TransformationRotate90))
        size.transpose();
    return size;
}

} // namespace

PreviewApp::PreviewApp(const QStringList &paths, const QStringList &errors, bool glance, QObject *parent)
    : QObject(parent)
    , m_paths(paths)
    , m_errors(errors)
    , m_glance(glance)
{
    for (const QString &p : paths) {
        const QFileInfo info(p);
        m_files.append(QVariantMap{{QStringLiteral("path"), p},
                                   {QStringLiteral("name"), info.fileName()},
                                   {QStringLiteral("url"), QUrl::fromLocalFile(p)},
                                   {QStringLiteral("kind"), preview::kindName(preview::classify(p))}});
    }
    // Appearance follows grassfield.json (read only), like every Grassfield surface.
    const QString file = configFile();
    const QString dir = QFileInfo(file).absolutePath();
    if (QFileInfo(dir).isDir())
        m_watcher.addPath(dir);
    if (QFileInfo::exists(file))
        m_watcher.addPath(file);
    const auto reread = [this] {
        const QString f = configFile();
        if (QFileInfo::exists(f) && !m_watcher.files().contains(f))
            m_watcher.addPath(f);
        readAppearance();
    };
    connect(&m_watcher, &QFileSystemWatcher::fileChanged, this, reread);
    connect(&m_watcher, &QFileSystemWatcher::directoryChanged, this, reread);
    readAppearance();
}

void PreviewApp::readAppearance()
{
    bool dark = true;
    bool reduce = false;
    QFile f(configFile());
    if (f.open(QIODevice::ReadOnly) && f.size() < 1024 * 1024) {
        const QJsonObject root = QJsonDocument::fromJson(f.readAll()).object();
        dark = root.value(QStringLiteral("appearance")).toString() != QLatin1String("light");
        reduce = root.value(QStringLiteral("accessibility")).toObject().value(QStringLiteral("reduceMotion")).toBool(false);
    }
    if (dark != m_dark || reduce != m_reduceMotion) {
        m_dark = dark;
        m_reduceMotion = reduce;
        emit appearanceChanged();
    }
}

QVariantMap PreviewApp::inspect(int index) const
{
    QVariantMap out{{QStringLiteral("ok"), false}};
    if (index < 0 || index >= m_paths.size()) {
        out[QStringLiteral("error")] = tr("There is no file to show.");
        return out;
    }
    const QString path = m_paths.at(index);
    const QFileInfo info(path);
    const preview::Kind kind = preview::classify(path);
    out[QStringLiteral("name")] = info.fileName();
    out[QStringLiteral("kind")] = preview::kindName(kind);
    out[QStringLiteral("url")] = QUrl::fromLocalFile(path);
    out[QStringLiteral("size")] = sizeText(info.size());
    out[QStringLiteral("frames")] = 1;
    out[QStringLiteral("animated")] = false;
    if (!info.isFile() || !info.isReadable()) {
        out[QStringLiteral("error")] = tr("This file cannot be read.");
        return out;
    }
    switch (kind) {
    case preview::Kind::Image: {
        QImageReader reader(path);
        reader.setAutoTransform(true);
        if (!reader.canRead()) {
            out[QStringLiteral("error")] = tr("This image cannot be decoded.");
            return out;
        }
        QSize size = displaySize(reader);
        if (!size.isValid()) {
            // Decoders refuse images over the allocation limit before they report a size: say why for PNG.
            QFile head(path);
            const QSize sniffed = head.open(QIODevice::ReadOnly) ? preview::pngSize(head.read(32)) : QSize();
            if (sniffed.isValid() && !preview::imageSizeAllowed(sniffed))
                size = sniffed;
        }
        if (!size.isValid()) {
            // A few formats only know their size after decoding; the allocation limit still applies.
            const QImage probe = reader.read();
            if (probe.isNull()) {
                out[QStringLiteral("error")] = tr("This image cannot be decoded: %1").arg(reader.errorString());
                return out;
            }
            size = probe.size();
        }
        if (!preview::imageSizeAllowed(size)) {
            out[QStringLiteral("error")] = tr("This image is too large to preview (%1 × %2 pixels; limit %3 per side and %4 MB in memory).")
                                               .arg(size.width()).arg(size.height()).arg(preview::kMaxImageSide).arg(preview::kAllocationLimitMb);
            return out;
        }
        // QTiffHandler only knows the number of directories after the first query: ask twice.
        const int firstCount = reader.imageCount();
        const int frames = qMax(1, qMax(firstCount, reader.imageCount()));
        out[QStringLiteral("width")] = size.width();
        out[QStringLiteral("height")] = size.height();
        out[QStringLiteral("frames")] = frames;
        out[QStringLiteral("animated")] = frames > 1 && reader.supportsAnimation();
        out[QStringLiteral("ok")] = true;
        return out;
    }
    case preview::Kind::Text: {
        if (!preview::textSizeAllowed(info.size())) {
            out[QStringLiteral("error")] = tr("This file is too large to preview (%1; limit %2).")
                                               .arg(sizeText(info.size()), sizeText(preview::kMaxTextBytes));
            return out;
        }
        QFile f(path);
        if (!f.open(QIODevice::ReadOnly)) {
            out[QStringLiteral("error")] = tr("This file cannot be read.");
            return out;
        }
        const QByteArray data = f.read(preview::kMaxTextBytes + 1);
        if (!preview::textSizeAllowed(data.size())) {
            out[QStringLiteral("error")] = tr("This file is too large to preview.");
            return out;
        }
        if (preview::looksBinary(data.left(8192))) {
            out[QStringLiteral("error")] = tr("This file is not text.");
            return out;
        }
        out[QStringLiteral("text")] = QString::fromUtf8(data);
        out[QStringLiteral("ok")] = true;
        return out;
    }
    case preview::Kind::Pdf:
    case preview::Kind::Audio:
    case preview::Kind::Video:
        out[QStringLiteral("ok")] = true;
        return out;
    case preview::Kind::Unsupported:
        break;
    }
    out[QStringLiteral("error")] = tr("There is no preview for this kind of file.");
    return out;
}

void PreviewApp::openInPreview() const
{
    if (m_paths.isEmpty())
        return;
    // GRASSFIELD_PREVIEW_CMD (dev) may carry a --glance flag; the full viewer never gets it.
    QStringList prefix = qEnvironmentVariable("GRASSFIELD_PREVIEW_CMD").split(QLatin1Char(' '), Qt::SkipEmptyParts);
    if (prefix.isEmpty())
        prefix << QCoreApplication::applicationFilePath();
    const QString program = prefix.takeFirst();
    prefix.removeAll(QStringLiteral("--glance"));
    QProcess::startDetached(program, prefix + QStringList{QStringLiteral("--")} + m_paths);
}

PreviewImageProvider::PreviewImageProvider(const PreviewApp *app)
    : QQuickImageProvider(QQuickImageProvider::Image)
    , m_app(app)
{
}

QImage PreviewImageProvider::requestImage(const QString &id, QSize *size, const QSize &requestedSize)
{
    const int slash = id.indexOf(QLatin1Char('/'));
    bool okFrame = false;
    bool okIndex = false;
    const int frame = id.left(slash).toInt(&okFrame);
    const int index = id.mid(slash + 1).toInt(&okIndex);
    if (slash < 0 || !okFrame || !okIndex || frame < 0 || index < 0 || index >= m_app->paths().size())
        return {};
    QImageReader reader(m_app->paths().at(index));
    reader.setAutoTransform(true);
    if (!reader.canRead() || (frame > 0 && !reader.jumpToImage(frame)))
        return {};
    const QSize native = displaySize(reader);
    if (native.isValid() && !preview::imageSizeAllowed(native))
        return {};
    QImage image = reader.read();
    if (image.isNull() || !preview::imageSizeAllowed(image.size()))
        return {};
    if (size)
        *size = image.size();
    if (requestedSize.isValid() && (requestedSize.width() < image.width() || requestedSize.height() < image.height()))
        image = image.scaled(requestedSize, Qt::KeepAspectRatio, Qt::SmoothTransformation);
    return image;
}
