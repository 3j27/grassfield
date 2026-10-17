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
    Q_PROPERTY(QVariantList files READ files CONSTANT)
    Q_PROPERTY(QStringList errors READ errors CONSTANT)
    Q_PROPERTY(bool dark READ dark NOTIFY appearanceChanged)
    Q_PROPERTY(bool reduceMotion READ reduceMotion NOTIFY appearanceChanged)

public:
    PreviewApp(const QStringList &paths, const QStringList &errors, bool glance, QObject *parent = nullptr);

    bool glance() const { return m_glance; }
    // [{path, name, url, kind}]
    QVariantList files() const { return m_files; }
    QStringList errors() const { return m_errors; }
    bool dark() const { return m_dark; }
    bool reduceMotion() const { return m_reduceMotion; }

    // Paths for the image provider (immutable after construction, read from the render thread).
    const QStringList &paths() const { return m_paths; }

    // {ok, error, kind, name, url, size(Text), width, height, frames, animated, text}
    Q_INVOKABLE QVariantMap inspect(int index) const;
    // Start the full viewer for all files (Glance "Open with Preview"); detached.
    Q_INVOKABLE void openInPreview() const;

signals:
    void appearanceChanged();

private:
    void readAppearance();

    QStringList m_paths;
    QStringList m_errors;
    QVariantList m_files;
    bool m_glance = false;
    bool m_dark = true;
    bool m_reduceMotion = false;
    QFileSystemWatcher m_watcher;
};

// image://preview/<frame>/<file index>: decoded with the allocation and size caps, EXIF rotation applied.
class PreviewImageProvider : public QQuickImageProvider
{
public:
    explicit PreviewImageProvider(const PreviewApp *app);
    QImage requestImage(const QString &id, QSize *size, const QSize &requestedSize) override;

private:
    const PreviewApp *m_app;
};
