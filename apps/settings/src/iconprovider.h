#pragma once

#include <QFileInfo>
#include <QIcon>
#include <QImageReader>
#include <QQuickImageProvider>

#include "systemguard.h"

// image://icon/<name>: a desktop entry's Icon for Login Items: a freedesktop icon name from the current icon theme (as Files
// does), or an absolute path to a small regular raster file (systemguard.h isIconFile), decoded only in the format its
// extension names (Qt would otherwise pick the decoder by content: an SVG named .png, whose references QtSvg follows, is
// refused). An unknown icon is a 1 x 1 transparent pixmap (a null one would log a warning per row): AppIcon.qml then shows its
// own tile. GUI thread (a Pixmap provider).
class IconProvider : public QQuickImageProvider
{
public:
    IconProvider()
        : QQuickImageProvider(QQuickImageProvider::Pixmap)
    {
    }

    QPixmap requestPixmap(const QString &id, QSize *size, const QSize &requestedSize) override
    {
        const QSize want = requestedSize.isValid() && !requestedSize.isEmpty() ? requestedSize : QSize(64, 64);
        QPixmap pixmap;
        if (!id.startsWith(QLatin1Char('/'))) {
            const QIcon icon = QIcon::fromTheme(id);
            pixmap = icon.isNull() ? QPixmap() : icon.pixmap(want);
        } else if (grassfield::settings::isIconFile(id)) {
            QString format = QFileInfo(id).suffix().toLower();
            if (format == QLatin1String("jpeg"))
                format = QStringLiteral("jpg");
            QImageReader reader(id, format.toLatin1());
            reader.setAutoDetectImageFormat(false);
            const QImage image = reader.read();
            if (!image.isNull())
                pixmap = QPixmap::fromImage(image.scaled(want, Qt::KeepAspectRatio, Qt::SmoothTransformation));
        }
        if (pixmap.isNull()) {
            pixmap = QPixmap(1, 1);
            pixmap.fill(Qt::transparent);
        }
        if (size)
            *size = pixmap.size();
        return pixmap;
    }
};
