#include "imageproviders.h"

#include <QIcon>
#include <QMutexLocker>
#include <QPixmap>

QMutex ThumbnailStore::s_mutex;
QHash<QString, QImage> ThumbnailStore::s_images;
quint64 ThumbnailStore::s_serial = 0;

QString ThumbnailStore::insert(const QImage &image)
{
    QMutexLocker lock(&s_mutex);
    const QString key = QString::number(++s_serial);
    s_images.insert(key, image);
    return key;
}

QImage ThumbnailStore::value(const QString &key)
{
    QMutexLocker lock(&s_mutex);
    return s_images.value(key);
}

void ThumbnailStore::remove(const QString &key)
{
    QMutexLocker lock(&s_mutex);
    s_images.remove(key);
}

int ThumbnailStore::size()
{
    QMutexLocker lock(&s_mutex);
    return int(s_images.size());
}

ThumbnailProvider::ThumbnailProvider()
    : QQuickImageProvider(QQuickImageProvider::Image)
{
}

QImage ThumbnailProvider::requestImage(const QString &id, QSize *size, const QSize &requestedSize)
{
    QImage image = ThumbnailStore::value(id);
    if (!image.isNull() && requestedSize.isValid() && (image.width() > requestedSize.width() || image.height() > requestedSize.height()))
        image = image.scaled(requestedSize, Qt::KeepAspectRatio, Qt::SmoothTransformation);
    if (size)
        *size = image.size();
    return image;
}

IconProvider::IconProvider()
    : QQuickImageProvider(QQuickImageProvider::Pixmap)
{
}

QPixmap IconProvider::requestPixmap(const QString &id, QSize *size, const QSize &requestedSize)
{
    const QSize want = requestedSize.isValid() && !requestedSize.isEmpty() ? requestedSize : QSize(64, 64);
    QIcon icon = QIcon::fromTheme(id);
    if (icon.isNull())
        icon = QIcon::fromTheme(id.endsWith(QLatin1String("-symbolic")) ? QStringLiteral("folder-symbolic") : QStringLiteral("text-x-generic"));
    const QPixmap pixmap = icon.pixmap(want);
    if (size)
        *size = pixmap.size();
    return pixmap;
}
