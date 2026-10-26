#pragma once

#include <QHash>
#include <QImage>
#include <QMutex>
#include <QQuickAsyncImageProvider>
#include <QQuickImageProvider>
#include <QString>

// Thumbnails produced by KIO::PreviewJob, keyed by an opaque id. Written on the GUI thread by
// FolderModel, read by ThumbnailProvider (possibly on the QML image thread), hence the mutex.
class ThumbnailStore
{
public:
    static QString insert(const QImage &image);
    static QImage value(const QString &key);
    static void remove(const QString &key);
    static int size();

private:
    static QMutex s_mutex;
    static QHash<QString, QImage> s_images;
    static quint64 s_serial;
};

// image://thumbnail/<key>
class ThumbnailProvider : public QQuickImageProvider
{
public:
    ThumbnailProvider();
    QImage requestImage(const QString &id, QSize *size, const QSize &requestedSize) override;
};

// image://icon/<freedesktop icon name>: the current icon theme through QIcon. MUST stay a synchronous Pixmap provider: Qt
// calls an asynchronous provider on its image-loader thread for every request, and QIcon's theme cache has no lock, so it
// would race with the GUI thread's QIcon::hasThemeIcon (FolderModel, PlacesModel): a segfault in the review's stress run.
// tst_imageproviders.cpp pins this.
class IconProvider : public QQuickImageProvider
{
public:
    IconProvider();
    QPixmap requestPixmap(const QString &id, QSize *size, const QSize &requestedSize) override;
};

// image://appicon/<absolute path of an application's Icon= file>: validated and decoded off the GUI thread by AppIcons::load
// (PNG, or SVG that refers to nothing else; sizes capped; never a FIFO, device or other format) and never touching QIcon
// there. What is refused answers the generic application icon (taken from the theme on the GUI thread, where QIcon is safe).
class AppIconProvider : public QQuickAsyncImageProvider
{
public:
    QQuickImageResponse *requestImageResponse(const QString &id, const QSize &requestedSize) override;
};
