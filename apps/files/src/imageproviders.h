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

// image://icon/<freedesktop icon name> or <absolute path of an application's Icon= file>.
// A name goes through the current icon theme (QIcon, on the GUI thread, answered at once). A path is decoded on a worker
// thread by AppIcons::load (PNG, or SVG that refers to nothing else; sizes capped; never a FIFO, device or other format);
// what is refused shows the generic application icon.
class IconProvider : public QQuickAsyncImageProvider
{
public:
    QQuickImageResponse *requestImageResponse(const QString &id, const QSize &requestedSize) override;
    // The theme icon `id` at `requestedSize` (64 px when none): the generic text icon for an unknown name.
    static QImage themeImage(const QString &id, const QSize &requestedSize);
};
