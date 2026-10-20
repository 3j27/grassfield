#pragma once

#include <QFileSystemWatcher>
#include <QObject>
#include <QQuickImageProvider>
#include <QStringList>
#include <QUrl>
#include <QVariantMap>

// Backend of Grassfield Preview: the validated file list, per-file inspection (kind, caps, text)
// and appearance. Files are only ever read, never written.
class PreviewApp : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool glance READ glance CONSTANT)
    // The list is the folder of the one file that was opened (browsing with the arrow keys), not what the command line named.
    Q_PROPERTY(bool browsing READ browsing CONSTANT)
    // Index in `files` of the file that was opened.
    Q_PROPERTY(int startIndex READ startIndex CONSTANT)
    Q_PROPERTY(QVariantList files READ files CONSTANT)
    Q_PROPERTY(QStringList errors READ errors CONSTANT)
    Q_PROPERTY(bool dark READ dark NOTIFY appearanceChanged)
    Q_PROPERTY(bool reduceMotion READ reduceMotion NOTIFY appearanceChanged)

public:
    PreviewApp(const QStringList &paths, const QStringList &errors, bool glance, int startIndex = 0, bool browsing = false, QObject *parent = nullptr);

    bool glance() const { return m_glance; }
    bool browsing() const { return m_browsing; }
    int startIndex() const { return m_startIndex; }
    // [{path, name, url, kind}]
    QVariantList files() const { return m_files; }
    QStringList errors() const { return m_errors; }
    bool dark() const { return m_dark; }
    bool reduceMotion() const { return m_reduceMotion; }

    // Paths for the image provider (immutable after construction, read from the render thread).
    const QStringList &paths() const { return m_paths; }

    // {ok, error, kind, name, url, size(Text), width, height, frames, animated, text, type, modified, folder}
    Q_INVOKABLE QVariantMap inspect(int index) const;
    // Start the full viewer (Glance "Open with Preview"); detached. When the list is the folder of one file (browsing)
    // only file `current` is passed (the viewer browses its folder again); otherwise every file, the viewer starting at
    // `current`.
    Q_INVOKABLE void openInPreview(int current = 0) const;

signals:
    void appearanceChanged();

private:
    void readAppearance();

    QStringList m_paths;
    QStringList m_errors;
    QVariantList m_files;
    bool m_glance = false;
    bool m_browsing = false;
    int m_startIndex = 0;
    bool m_dark = true;
    bool m_reduceMotion = false;
    QFileSystemWatcher m_watcher;
};

// image://preview/<frame>/<file index>: decoded with the allocation and size caps, EXIF rotation applied.
// image://preview/thumb/<file index>: the same at the requested (source) size, for the sidebar thumbnails.
class PreviewImageProvider : public QQuickImageProvider
{
public:
    explicit PreviewImageProvider(const PreviewApp *app);
    QImage requestImage(const QString &id, QSize *size, const QSize &requestedSize) override;

private:
    const PreviewApp *m_app;
};
