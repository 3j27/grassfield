#pragma once

#include <QFileSystemWatcher>
#include <QJSValue>
#include <QList>
#include <QObject>
#include <QPointer>
#include <QSettings>
#include <QUrl>
#include <QVariantList>

class FolderModel;
class KJob;
class PlacesModel;

// Application services for the QML windows. Every file operation is a KIO job (copy, move, trash,
// restore, mkdir, rename, delete, empty trash, paste), recorded in KIO::FileUndoManager where KIO
// supports undo. Opening uses KIO::OpenUrlJob / ApplicationLauncherJob (MIME associations from
// KService). Nothing here reimplements KIO: names and selection are the only app-side logic.
class FilesApp : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QObject *places READ places CONSTANT)
    Q_PROPERTY(QString homePath READ homePath CONSTANT)
    Q_PROPERTY(QList<QUrl> initialUrls READ initialUrls CONSTANT)
    Q_PROPERTY(bool dark READ dark NOTIFY appearanceChanged)
    Q_PROPERTY(bool devSession READ devSession CONSTANT)
    Q_PROPERTY(bool reduceMotion READ reduceMotion NOTIFY appearanceChanged)
    Q_PROPERTY(bool canUndo READ canUndo NOTIFY undoChanged)
    Q_PROPERTY(QString undoText READ undoText NOTIFY undoChanged)
    Q_PROPERTY(bool canRedo READ canRedo NOTIFY undoChanged)
    Q_PROPERTY(QString redoText READ redoText NOTIFY undoChanged)
    Q_PROPERTY(bool canPaste READ canPaste NOTIFY clipboardChanged)
    Q_PROPERTY(int clipboardCount READ clipboardCount NOTIFY clipboardChanged)
    Q_PROPERTY(QString activity READ activity NOTIFY activityChanged)
    Q_PROPERTY(int activityPercent READ activityPercent NOTIFY activityChanged)
    // Persisted preferences (QSettings "Grassfield/Files").
    Q_PROPERTY(QString viewMode READ viewMode WRITE setViewMode NOTIFY prefsChanged)
    Q_PROPERTY(int sortKey READ sortKey WRITE setSortKey NOTIFY prefsChanged)
    Q_PROPERTY(bool sortDescending READ sortDescending WRITE setSortDescending NOTIFY prefsChanged)
    Q_PROPERTY(bool foldersFirst READ foldersFirst WRITE setFoldersFirst NOTIFY prefsChanged)
    Q_PROPERTY(bool showHidden READ showHidden WRITE setShowHidden NOTIFY prefsChanged)

public:
    explicit FilesApp(const QList<QUrl> &initialUrls, QObject *parent = nullptr);

    QObject *places() const;
    QString homePath() const;
    QList<QUrl> initialUrls() const { return m_initialUrls; }
    bool dark() const { return m_dark; }
    // GRASSFIELD_DEV=1: never offers anything that touches the owner's real trash (ADR-0011).
    bool devSession() const { return qEnvironmentVariable("GRASSFIELD_DEV") == QLatin1String("1"); }
    bool reduceMotion() const { return m_reduceMotion; }
    bool canUndo() const;
    QString undoText() const;
    bool canRedo() const;
    QString redoText() const;
    bool canPaste() const;
    int clipboardCount() const;
    QString activity() const { return m_activity; }
    int activityPercent() const { return m_activityPercent; }

    QString viewMode() const;
    void setViewMode(const QString &mode);
    int sortKey() const;
    void setSortKey(int key);
    bool sortDescending() const;
    void setSortDescending(bool on);
    bool foldersFirst() const;
    void setFoldersFirst(bool on);
    bool showHidden() const;
    void setShowHidden(bool on);

    // A new folder listing owned by `parent` (a QML item: the listing dies with its view).
    Q_INVOKABLE QObject *createFolderModel(QObject *parent);

    // Pure helpers (FileLogic) for QML.
    Q_INVOKABLE QVariantList pathSegments(const QUrl &url) const;
    Q_INVOKABLE QString formatSize(qint64 bytes) const;
    Q_INVOKABLE bool isValidFileName(const QString &name) const;
    Q_INVOKABLE int baseNameLength(const QString &name, bool isDir) const;
    Q_INVOKABLE bool defaultDescending(int sortKey) const;
    Q_INVOKABLE QString uriList(const QList<QUrl> &urls) const;
    // URL comparisons for QML: QML's url-to-string conversion is not canonical (a QUrl may print
    // percent-encoded or not depending on where it came from), so equality is decided on parsed QUrls.
    Q_INVOKABLE bool sameUrl(const QUrl &a, const QUrl &b) const;
    Q_INVOKABLE bool isDirectChild(const QUrl &parent, const QUrl &child) const;
    // "Go to Folder": "~", "~/x", absolute paths, paths relative to `base`, or URLs. Invalid if no such folder.
    Q_INVOKABLE QUrl resolveLocation(const QString &text, const QUrl &base) const;

    // Opening.
    Q_INVOKABLE void open(const QList<QUrl> &urls);
    // [{id, name}] of the applications registered for the first item's MIME type, preferred first.
    Q_INVOKABLE QVariantList applicationsFor(const QList<QUrl> &urls) const;
    Q_INVOKABLE void openWith(const QString &storageId, const QList<QUrl> &urls);
    // Glance: starts `grassfield-preview --glance` (detached) for the local regular files among `urls`.
    Q_INVOKABLE void glance(const QList<QUrl> &urls);

    // Operations. `folder` (a FolderModel, may be null) selects the created items when they appear.
    Q_INVOKABLE void copyToClipboard(const QList<QUrl> &urls, bool cut);
    Q_INVOKABLE void paste(const QUrl &destination, QObject *folder);
    Q_INVOKABLE void trash(const QList<QUrl> &urls);
    Q_INVOKABLE void restore(const QList<QUrl> &urls);
    // Only for items inside trash:/ (the UI confirms first).
    Q_INVOKABLE void deletePermanently(const QList<QUrl> &urls);
    // The UI confirms first. Never called by automated tests.
    Q_INVOKABLE void emptyTrash();
    Q_INVOKABLE void newFolder(const QUrl &directory, QObject *folder);
    Q_INVOKABLE void rename(const QUrl &url, const QString &newName, QObject *folder);
    Q_INVOKABLE void duplicate(const QList<QUrl> &urls, QObject *folder);
    // Drag and drop: move on the same filesystem, copy across filesystems or with Ctrl/Alt held.
    Q_INVOKABLE void drop(const QList<QUrl> &urls, const QUrl &destination, QObject *folder);
    Q_INVOKABLE void undo();
    Q_INVOKABLE void redo();
    // Recursive size through KIO::directorySize; callback(bytes, files, folders), bytes -1 on error.
    Q_INVOKABLE void directorySize(const QUrl &url, const QJSValue &callback);

signals:
    void appearanceChanged();
    void undoChanged();
    void clipboardChanged();
    void prefsChanged();
    void activityChanged();
    void operationFailed(const QString &message);

private:
    void track(KJob *job, const QString &activity);
    void readAppearance();
    QString configFile() const;

    QList<QUrl> m_initialUrls;
    PlacesModel *m_places = nullptr;
    QSettings m_settings;
    QFileSystemWatcher m_watcher;
    bool m_dark = true;
    bool m_reduceMotion = false;
    QString m_activity;
    int m_activityPercent = -1;
    QList<QPointer<KJob>> m_jobs;
};
