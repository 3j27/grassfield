#pragma once

#include <QHash>
#include <QImage>
#include <QMutex>
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

// image://icon/<freedesktop icon name>: the current icon theme through QIcon (GUI thread, Pixmap provider).
class IconProvider : public QQuickImageProvider
{
public:
    IconProvider();
    QPixmap requestPixmap(const QString &id, QSize *size, const QSize &requestedSize) override;
};
