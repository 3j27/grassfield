#pragma once

#include <QIcon>
#include <QQuickImageProvider>

#include "systemguard.h"

// image://icon/<name>: a desktop entry's Icon (a freedesktop icon name from the current icon theme, or an absolute path to a
// small raster file), for
// Login Items. An unknown icon is a 1 x 1 transparent pixmap (a null one would log a warning per row): AppIcon.qml then shows
// its own tile. GUI thread (a Pixmap provider).
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
        // An absolute path only when it is a small regular raster file (systemguard.h isIconFile); a name from the icon theme,
        // as Files does.
        const QIcon icon = id.startsWith(QLatin1Char('/')) ? (grassfield::settings::isIconFile(id) ? QIcon(id) : QIcon()) : QIcon::fromTheme(id);
        QPixmap pixmap = icon.isNull() ? QPixmap() : icon.pixmap(want);
        if (pixmap.isNull()) {
            pixmap = QPixmap(1, 1);
            pixmap.fill(Qt::transparent);
        }
        if (size)
            *size = pixmap.size();
        return pixmap;
    }
};
