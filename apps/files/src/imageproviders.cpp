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

#include <memory>

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

namespace
{
// Finished from the GUI thread. Qt requires finished() after cancel() too, so a cancelled response is still finished (empty).
class IconResponse : public QQuickImageResponse
{
public:
    QQuickTextureFactory *textureFactory() const override { return QQuickTextureFactory::textureFactoryForImage(m_image); }
    void cancel() override { m_cancelled->storeRelaxed(1); }
    // Shared with the worker, which must not touch the response itself (the engine may delete it at any time).
    std::shared_ptr<QAtomicInt> cancelFlag() const { return m_cancelled; }
    bool cancelled() const { return m_cancelled->loadRelaxed() != 0; }
    void done(const QImage &image)
    {
        m_image = image;
        emit finished();
    }

private:
    QImage m_image;
    std::shared_ptr<QAtomicInt> m_cancelled = std::make_shared<QAtomicInt>(0);
};

// The decodes run on a pool of their own that is never destroyed: the global pool (or a pool object) is waited for at exit,
// and a decode in progress would keep the process alive after Qt.quit. A worker is a plain thread: it ends with the process.
QThreadPool *decodePool()
{
    static QThreadPool *pool = [] {
        auto *p = new QThreadPool;
        p->setMaxThreadCount(2);
        return p;
    }();
    return pool;
}
} // namespace

QQuickImageResponse *AppIconProvider::requestImageResponse(const QString &id, const QSize &requestedSize)
{
    auto *response = new IconResponse;
    const QSize want = requestedSize.isValid() && !requestedSize.isEmpty() ? requestedSize : QSize(64, 64);
    // The roots are computed here (QStandardPaths), on the thread Qt calls the provider from, once.
    static const QStringList roots = ApplicationsLogic::iconRoots();
    QPointer<IconResponse> guard(response);
    const std::shared_ptr<QAtomicInt> cancelled = response->cancelFlag();
    decodePool()->start([guard, cancelled, id, want] {
        QImage image;
        if (cancelled->loadRelaxed() == 0)
            image = AppIcons::load(id, roots, want);
        // Done on the GUI thread, always (also after cancel): the fallback needs the icon theme, and QIcon is only used there.
        QMetaObject::invokeMethod(
            QCoreApplication::instance(),
            [guard, image, want] {
                if (!guard)
                    return;
                if (guard->cancelled() || !image.isNull()) {
                    guard->done(image);
                    return;
                }
                QIcon icon = QIcon::fromTheme(QStringLiteral("application-x-executable"));
                if (icon.isNull())
                    icon = QIcon::fromTheme(QStringLiteral("text-x-generic"));
                guard->done(icon.pixmap(want).toImage());
            },
            Qt::QueuedConnection);
    });
    return response;
}
