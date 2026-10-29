#pragma once

#include <QIcon>
#include <QQuickImageProvider>

namespace activity {

// image://icon/<name>: a freedesktop icon name from the current icon theme (as Files' IconProvider), the generic
// executable's icon when the theme has no such name (AM10). Names only, never a path (ADR-0038 AD36). A synchronous Pixmap
// provider: QIcon's theme cache has no lock, so it is used on the GUI thread only (Files' tst_imageproviders pins why).
class IconProvider : public QQuickImageProvider
{
public:
    IconProvider()
        : QQuickImageProvider(QQuickImageProvider::Pixmap)
    {
    }

    QPixmap requestPixmap(const QString &id, QSize *size, const QSize &requestedSize) override
    {
        const QSize want = requestedSize.isValid() && !requestedSize.isEmpty() ? requestedSize : QSize(32, 32);
        QIcon icon = id.contains(QLatin1Char('/')) ? QIcon() : QIcon::fromTheme(id);
        if (icon.isNull())
            icon = QIcon::fromTheme(QStringLiteral("application-x-executable"));
        QPixmap pixmap = icon.pixmap(want);
        if (pixmap.isNull()) { // no icon theme at all: a transparent pixel, never a warning per row
            pixmap = QPixmap(1, 1);
            pixmap.fill(Qt::transparent);
        }
        if (size)
            *size = pixmap.size();
        return pixmap;
    }
};

} // namespace activity
