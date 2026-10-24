#pragma once

#include <QFileSystemWatcher>
#include <QMutex>
#include <QObject>
#include <QQuickImageProvider>
#include <QStringList>
#include <QThread>
#include <QTimer>
#include <QUrl>
#include <QVariantMap>

#include <atomic>

#include "previewlogic.h"

// Backend of Grassfield Preview: the validated file list, per-file inspection (kind, caps, text)
// and appearance. Files are only ever read, never written.
class PreviewApp : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool glance READ glance CONSTANT)
    // The list is the folder of the one file that was opened (browsing with the arrow keys), not what the command line named.
    Q_PROPERTY(bool browsing READ browsing CONSTANT)
    // Index in `files` of the file that was opened.
    Q_PROPERTY(int startIndex READ startIndex NOTIFY filesChanged)
    // Starts as the opened file alone; the folder is listed in a worker thread and replaces it when done.
    Q_PROPERTY(QVariantList files READ files NOTIFY filesChanged)
    // The folder is still being listed (the arrows and "n of N" wait for it).
    Q_PROPERTY(bool listing READ listing NOTIFY listingChanged)
    Q_PROPERTY(QStringList errors READ errors CONSTANT)
    Q_PROPERTY(bool dark READ dark NOTIFY appearanceChanged)
    Q_PROPERTY(bool reduceMotion READ reduceMotion NOTIFY appearanceChanged)
    // windows.titlebarDoubleClick of grassfield.json: zoom (default), minimize or none (the toolbar's double-click).
    Q_PROPERTY(QString titlebarDoubleClick READ titlebarDoubleClick NOTIFY appearanceChanged)
    // False when the shell says the compositor plugin is absent: the minimize light is greyed (ADR-0015 Q4b, chromecaps.h).
    Q_PROPERTY(bool canMinimize READ canMinimize NOTIFY appearanceChanged)
    // accent.color: multicolor (the Grassfield green), blue, purple, pink, red, orange, yellow, green or graphite.
    Q_PROPERTY(QString accentColor READ accentColor NOTIFY appearanceChanged)

public:
    PreviewApp(const QStringList &paths, const QStringList &errors, bool glance, int startIndex = 0, bool browsing = false, QObject *parent = nullptr);
    ~PreviewApp() override;

    bool listing() const { return m_listing; }
    // List the folder of the only file in a worker thread (GUI thread never blocks); the list replaces the file when ready.
    void startBrowse(preview::BrowseKinds kinds);
    // Stop a running listing (window closing).
    void cancelBrowse();

    bool glance() const { return m_glance; }
    bool browsing() const { return m_browsing; }
    int startIndex() const { return m_startIndex; }
    // [{path, name, url, kind}]
    QVariantList files() const { return m_files; }
    QStringList errors() const { return m_errors; }
    bool dark() const { return m_dark; }
    bool reduceMotion() const { return m_reduceMotion; }
    QString titlebarDoubleClick() const { return m_titlebarDoubleClick; }
    bool canMinimize() const { return m_canMinimize; }
    QString accentColor() const { return m_accentColor; }

    // Path of file `index` for the image provider (render thread): empty when out of range.
    QString pathAt(int index) const;

    // {ok, error, kind, name, url, size(Text), width, height, frames, animated, text, type, modified, folder}
    Q_INVOKABLE QVariantMap inspect(int index) const;
    // The first lines of a text file for its sidebar thumbnail (at most 12 lines of 40 characters, control characters
    // replaced); "" for any other kind, an unreadable file or an empty one.
    Q_INVOKABLE QString textSnippet(int index) const;
    // The same for the file that was opened first (stays that file when the folder list replaces the files).
    Q_INVOKABLE QVariantMap inspectFirst() const;
    // Start the full viewer (Glance "Open with Preview"); detached. When the list is the folder of one file (browsing)
    // only file `current` is passed (the viewer browses its folder again); otherwise every file, the viewer starting at
    // `current`.
    Q_INVOKABLE void openInPreview(int current = 0) const;

signals:
    void appearanceChanged();
    void filesChanged();
    void listingChanged();

private:
    QVariantMap inspectPath(const QString &path) const;
    void readAppearance();
    void applyBrowse(const preview::Browse &browse, const QVariantList &files);

    mutable QMutex m_lock; // guards m_paths (written on the GUI thread, read by the image provider)
    QStringList m_paths;
    QStringList m_errors;
    QVariantList m_files;
    bool m_glance = false;
    bool m_browsing = false;
    int m_startIndex = 0;
    QString m_firstPath;
    bool m_listing = false;
    std::atomic_bool m_cancel{false};
    QThread *m_worker = nullptr;
    bool m_dark = true;
    bool m_autoAppearance = false;
    QTimer m_autoTimer;
    bool m_reduceMotion = false;
    QString m_titlebarDoubleClick = QStringLiteral("zoom");
    bool m_canMinimize = true;
    QString m_accentColor = QStringLiteral("multicolor");
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
