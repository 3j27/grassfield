#include "imageproviders.h"

#include "appicons.h"
#include "applicationslogic.h"

#include <QAtomicInt>
#include <QCoreApplication>
#include <QIcon>
#include <QMutexLocker>
#include <QPixmap>
#include <QPointer>
#include <QThreadPool>

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

namespace
{
// Finished by hand: the image is known when the response is made (a theme icon) or is handed over from a worker thread.
class IconResponse : public QQuickImageResponse
{
public:
    QQuickTextureFactory *textureFactory() const override { return QQuickTextureFactory::textureFactoryForImage(m_image); }
    void cancel() override { m_cancelled.storeRelaxed(1); }
    bool cancelled() const { return m_cancelled.loadRelaxed() != 0; }
    void done(const QImage &image)
    {
        m_image = image;
        emit finished();
    }

private:
    QImage m_image;
    QAtomicInt m_cancelled;
};

// An icon file that is refused (or a path that is no icon) shows the generic application icon.
QImage fallbackImage(const QSize &want)
{
    return IconProvider::themeImage(QStringLiteral("application-x-executable"), want);
}
} // namespace

QImage IconProvider::themeImage(const QString &id, const QSize &requestedSize)
{
    const QSize want = requestedSize.isValid() && !requestedSize.isEmpty() ? requestedSize : QSize(64, 64);
    QIcon icon = QIcon::fromTheme(id);
    if (icon.isNull())
        icon = QIcon::fromTheme(id.endsWith(QLatin1String("-symbolic")) ? QStringLiteral("folder-symbolic") : QStringLiteral("text-x-generic"));
    return icon.pixmap(want).toImage();
}

QQuickImageResponse *IconProvider::requestImageResponse(const QString &id, const QSize &requestedSize)
{
    auto *response = new IconResponse;
    const QSize want = requestedSize.isValid() && !requestedSize.isEmpty() ? requestedSize : QSize(64, 64);
    if (!id.startsWith(QLatin1Char('/'))) {
        // The theme is read on the GUI thread, as before; finished() is emitted once the caller has the response.
        const QImage image = themeImage(id, want);
        QMetaObject::invokeMethod(response, [response, image] { response->done(image); }, Qt::QueuedConnection);
        return response;
    }
    // A file path: validated and decoded off the GUI thread. The roots are computed here (QStandardPaths, GUI thread).
    static const QStringList roots = ApplicationsLogic::iconRoots();
    QPointer<IconResponse> guard(response);
    QThreadPool::globalInstance()->start([guard, id, want] {
        if (guard && guard->cancelled())
            return;
        QImage image = AppIcons::load(id, roots, want);
        // Done on the GUI thread; the fallback needs the icon theme.
        QMetaObject::invokeMethod(
            QCoreApplication::instance(),
            [guard, image, want] {
                if (guard)
                    guard->done(image.isNull() ? fallbackImage(want) : image);
            },
            Qt::QueuedConnection);
    });
    return response;
}
