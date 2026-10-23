#pragma once

#include <QFileSystemWatcher>
#include <QJSValue>
#include <QList>
#include <QObject>
#include <QPointer>
#include <QSettings>
#include <QUrl>
#include <QVariantList>

#include "folderstylestore.h"
#include "tagstore.h"

#include <functional>

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
    // windows.titlebarDoubleClick of grassfield.json: zoom (default), minimize or none (the toolbar's double-click).
    Q_PROPERTY(QString titlebarDoubleClick READ titlebarDoubleClick NOTIFY appearanceChanged)
    // False when the shell says the compositor plugin is absent: the minimize light is greyed (ADR-0015 Q4b, chromecaps.h).
    Q_PROPERTY(bool canMinimize READ canMinimize NOTIFY appearanceChanged)
    // accent.color: multicolor (the Grassfield green), blue, purple, pink, red, orange, yellow, green or graphite.
    Q_PROPERTY(QString accentColor READ accentColor NOTIFY appearanceChanged)
    Q_PROPERTY(QString iconMode READ iconMode NOTIFY appearanceChanged)
    Q_PROPERTY(QString iconTint READ iconTint NOTIFY appearanceChanged)
    // icons.folderColor: "theme", "accent" or "#rrggbb" (every folder icon).
    Q_PROPERTY(QString folderColor READ folderColor NOTIFY appearanceChanged)
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
    // The gallery view shows its info panel (name, kind, dates, tags of the shown item).
    Q_PROPERTY(bool galleryInfo READ galleryInfo WRITE setGalleryInfo NOTIFY prefsChanged)
    // Translated names of the seven colour tags, in palette order (tokens files.tagRed ... files.tagGray).
    Q_PROPERTY(QStringList colorTagNames READ colorTagNames CONSTANT)
    // Changes whenever Files writes tags (bindings that show tag states re-read them).
    Q_PROPERTY(int tagRevision READ tagRevision NOTIFY tagRevisionChanged)
    // Tags removed from the sidebar (stored names), for the Tags section's menu that lists them again.
    Q_PROPERTY(QStringList hiddenTags READ hiddenTags NOTIFY hiddenTagsChanged)

public:
    explicit FilesApp(const QList<QUrl> &initialUrls, QObject *parent = nullptr);

    QObject *places() const;
    QString homePath() const;
    QList<QUrl> initialUrls() const { return m_initialUrls; }
    bool dark() const { return m_dark; }
    // GRASSFIELD_DEV=1: never offers anything that touches the owner's real trash (ADR-0011).
    bool devSession() const { return qEnvironmentVariable("GRASSFIELD_DEV") == QLatin1String("1"); }
    bool reduceMotion() const { return m_reduceMotion; }
    QString titlebarDoubleClick() const { return m_titlebarDoubleClick; }
    bool canMinimize() const { return m_canMinimize; }
    // Icon appearance (ADR-0014): default | dark | clear | tinted, and "accent" or #rrggbb.
    QString accentColor() const { return m_accentColor; }
    QString iconMode() const { return m_iconMode; }
    QString iconTint() const { return m_iconTint; }
    QString folderColor() const { return m_folderColor; }
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
    bool galleryInfo() const;
    void setGalleryInfo(bool on);
    QStringList colorTagNames() const;
    int tagRevision() const { return m_tagRevision; }
    QStringList hiddenTags() const { return m_hiddenTags; }

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

    // Tags (user.xdg.tags, TagLogic/TagStore). Only local files and folders on filesystems with user extended
    // attributes carry tags; tagsUnavailable() is "" when every item of `urls` can be tagged, else the reason shown in
    // place of the tag controls.
    Q_INVOKABLE QString tagsUnavailable(const QList<QUrl> &urls) const;
    // Per colour (palette order): 0 no item has it, 1 some do, 2 all do.
    Q_INVOKABLE QVariantList colorTagStates(const QList<QUrl> &urls) const;
    // The tags of one local item by their shown names, in display order (colour tags first); empty for anything else.
    // Read now: callers depend on tagRevision to read again after Files' own writes.
    Q_INVOKABLE QStringList tagNamesOf(const QUrl &url) const;
    // macOS behaviour: removes colour `index` from every item when all have it, else adds it to those without.
    Q_INVOKABLE void toggleColorTag(const QList<QUrl> &urls, int index);
    // Adds `tag` (a stored tag name) to the local items among `urls` (a drop on a sidebar tag).
    Q_INVOKABLE void addTag(const QList<QUrl> &urls, const QString &tag);
    // A tag's shown name (colour tags translated).
    Q_INVOKABLE QString tagName(const QString &tag) const;
    // Palette index of a colour tag, -1 for other tags.
    Q_INVOKABLE int tagColor(const QString &tag) const;
    // The location listing the items tagged `tag` in the folder shown at `from` and below: `from` itself when it is a
    // local folder, the folder of a tag search, else the home folder.
    Q_INVOKABLE QUrl tagSearchUrl(const QString &tag, const QUrl &from) const;
    Q_INVOKABLE bool isTagSearch(const QUrl &url) const;
    Q_INVOKABLE QString searchedTag(const QUrl &url) const;
    // Remove from Sidebar (macOS): hides the tag from the sidebar's Tags section for good (tags/hidden); files keep it
    // and it stays usable. Setting that tag in Files again lists it again.
    Q_INVOKABLE void forgetTag(const QString &tag);
    // The way back: lists a tag removed from the sidebar again (Tags section's menu).
    Q_INVOKABLE void showTag(const QString &tag);

    // Customize Folder (FolderStyleLogic, FolderStyleStore): a folder's own colour and symbol. Only local folders
    // carry one. folderStyleUnavailable() is "" when every item of `urls` is such a folder, else the reason shown in
    // place of the controls (the menu item is disabled for it).
    Q_INVOKABLE QString folderStyleUnavailable(const QList<QUrl> &urls) const;
    // {color, glyph} of one folder, read now ("" fields: none). Callers depend on folderStyleRevision.
    Q_INVOKABLE QVariantMap folderStyleOf(const QUrl &url) const;
    // Sets the look of the folders among `urls` to exactly `color` ("theme", "accent", "#rrggbb" or "" = follow the
    // global setting) and `glyph` ("" = none). Returns {ok, fellBack, error}: fellBack when a folder's volume can't
    // hold the attribute and the choice went to the per-user store (documented in docs/specs/files.md).
    Q_INVOKABLE QVariantMap applyFolderStyle(const QList<QUrl> &urls, const QString &color, const QString &glyph);
    // Back to the global colour and no symbol.
    Q_INVOKABLE QVariantMap resetFolderStyle(const QList<QUrl> &urls);
    // The shown folders' own looks follow Files' writes and the per-user store's changes.
    Q_PROPERTY(int folderStyleRevision READ folderStyleRevision NOTIFY folderStyleRevisionChanged)
    int folderStyleRevision() const { return m_folderStyleRevision; }

signals:
    void appearanceChanged();
    void undoChanged();
    void clipboardChanged();
    void prefsChanged();
    void activityChanged();
    void operationFailed(const QString &message);
    // Files wrote the tags of `urls` (every listing reads them again).
    void tagsChanged(const QList<QUrl> &urls);
    void tagRevisionChanged();
    void hiddenTagsChanged();
    // Files wrote the folder looks of `urls`; allFolderStylesChanged: the per-user store changed under us.
    void folderStylesChanged(const QList<QUrl> &urls);
    void allFolderStylesChanged();
    void folderStyleRevisionChanged();

private:
    void track(KJob *job, const QString &activity);
    void readAppearance();
    QString configFile() const;
    // Adds `tag` to, or removes it from, each item (TagLogic::applyTag keeps every other entry as stored); reports
    // failures; announces the changed items.
    void rewriteTags(const QList<QUrl> &urls, const QString &tag, bool on);
    void unhideTag(const QString &tag);
    // Why `url` can't be tagged, "" when it can (`support`: what TagStore found).
    QString tagsReason(const QUrl &url, TagStore::Support support) const;
    QString schemeReason(const QUrl &url) const;
    void styleMoved(const QUrl &from, const QUrl &to);
    QVariantMap changeFolderStyles(const QList<QUrl> &urls, const FolderStyleLogic::Style &style);
    // Tags in use, for the sidebar (kept across sessions, at most kMaxKnownTags).
    void noteTags(const QStringList &tags);
    void publishKnownTags();

    QList<QUrl> m_initialUrls;
    PlacesModel *m_places = nullptr;
    QSettings m_settings;
    QFileSystemWatcher m_watcher;
    bool m_dark = true;
    bool m_reduceMotion = false;
    QString m_titlebarDoubleClick = QStringLiteral("zoom");
    bool m_canMinimize = true;
    QString m_accentColor = QStringLiteral("multicolor");
    QString m_iconMode = QStringLiteral("default");
    QString m_iconTint = QStringLiteral("accent");
    QString m_folderColor = QStringLiteral("theme");
    QString m_activity;
    int m_activityPercent = -1;
    QList<QPointer<KJob>> m_jobs;
    QStringList m_knownTags;
    // Tags removed from the sidebar (not listed again when seen), persisted as tags/hidden.
    QStringList m_hiddenTags;
    // Tag state of the items asked about by the menus (selection), probed once per few seconds.
    mutable TagStore::Cache m_tagCache;
    int m_tagRevision = 0;
    FolderStyleStore m_folderStyles;
    int m_folderStyleRevision = 0;
};
