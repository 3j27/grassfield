#pragma once

#include <QCollator>
#include <QDeadlineTimer>
#include <QElapsedTimer>
#include <QHash>
#include <QPointer>
#include <QSet>
#include <QSortFilterProxyModel>
#include <QTimer>
#include <QUrl>
#include <QVariantMap>

#include <KFileItem>

class KDirLister;
class KDirModel;
class KJob;

namespace KIO
{
class PreviewJob;
}

// One folder listing for QML: KIO's KDirModel (fed by a KDirLister) behind a sort/filter proxy.
// Adds flat roles for QML delegates, Finder-style sorting (FileLogic::compareEntries), a name filter,
// a URL-keyed selection that survives re-sorting, thumbnails through KIO::PreviewJob and free space
// through KIO::fileSystemFreeSpace. It never touches files: operations live in FilesApp.
class FolderModel : public QSortFilterProxyModel
{
    Q_OBJECT
    Q_PROPERTY(QUrl url READ url WRITE setUrl NOTIFY urlChanged)
    Q_PROPERTY(int sortKey READ sortKey WRITE setSortKey NOTIFY sortChanged)
    Q_PROPERTY(bool sortDescending READ sortDescending WRITE setSortDescending NOTIFY sortChanged)
    Q_PROPERTY(bool foldersFirst READ foldersFirst WRITE setFoldersFirst NOTIFY sortChanged)
    Q_PROPERTY(bool showHidden READ showHidden WRITE setShowHidden NOTIFY showHiddenChanged)
    Q_PROPERTY(QString filterText READ filterText WRITE setFilterText NOTIFY filterTextChanged)
    Q_PROPERTY(int count READ count NOTIFY countChanged)
    Q_PROPERTY(int selectedCount READ selectedCount NOTIFY selectionChanged)
    Q_PROPERTY(int currentRow READ currentRow NOTIFY currentRowChanged)
    Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)
    Q_PROPERTY(qint64 freeSpace READ freeSpace NOTIFY freeSpaceChanged)
    Q_PROPERTY(QString error READ error NOTIFY errorChanged)
    Q_PROPERTY(bool isTrash READ isTrash NOTIFY urlChanged)
    Q_PROPERTY(bool writable READ writable NOTIFY rootChanged)
    Q_PROPERTY(QString title READ title NOTIFY rootChanged)
    Q_PROPERTY(int previewSize READ previewSize WRITE setPreviewSize NOTIFY previewSizeChanged)

public:
    enum Roles {
        NameRole = Qt::UserRole + 1,
        UrlRole,
        IconNameRole,
        IsDirRole,
        SizeRole,
        SizeTextRole,
        ModifiedRole,
        ModifiedTextRole,
        KindRole,
        ThumbnailRole,
        SelectedRole,
        HiddenRole,
        CanPreviewRole,
        EmblemRole,
    };
    Q_ENUM(Roles)

    explicit FolderModel(QObject *parent = nullptr);
    ~FolderModel() override;

    QUrl url() const { return m_url; }
    void setUrl(const QUrl &url);
    int sortKey() const { return m_sortKey; }
    void setSortKey(int key);
    bool sortDescending() const { return m_descending; }
    void setSortDescending(bool descending);
    bool foldersFirst() const { return m_foldersFirst; }
    void setFoldersFirst(bool on);
    bool showHidden() const;
    void setShowHidden(bool on);
    QString filterText() const { return m_filterText; }
    void setFilterText(const QString &text);
    int count() const { return rowCount(); }
    int selectedCount() const { return int(m_selected.size()); }
    int currentRow() const;
    bool loading() const { return m_loading; }
    qint64 freeSpace() const { return m_freeSpace; }
    QString error() const { return m_error; }
    bool isTrash() const { return m_url.scheme() == QLatin1String("trash"); }
    bool writable() const;
    QString title() const;
    int previewSize() const { return m_previewSize; }
    void setPreviewSize(int size);

    QHash<int, QByteArray> roleNames() const override;
    QVariant data(const QModelIndex &index, int role = Qt::DisplayRole) const override;

    // Selection. `modifiers` is a Qt.KeyboardModifiers value: Shift extends from the anchor, Ctrl toggles.
    Q_INVOKABLE void select(int row, int modifiers = 0);
    Q_INVOKABLE void selectAll();
    Q_INVOKABLE void clearSelection();
    Q_INVOKABLE void selectUrls(const QList<QUrl> &urls);
    Q_INVOKABLE QList<QUrl> selectedUrls() const;
    Q_INVOKABLE bool isSelected(int row) const;
    // Selected rows in view order (for Get Info and the context menu).
    Q_INVOKABLE QList<int> selectedRows() const;

    Q_INVOKABLE QUrl urlAt(int row) const;
    Q_INVOKABLE QString nameAt(int row) const;
    Q_INVOKABLE bool isDirAt(int row) const;
    Q_INVOKABLE int rowForUrl(const QUrl &url) const;
    // Type-to-select: first row at or after `from` (wrapping) whose name starts with `prefix`, or -1.
    Q_INVOKABLE int findPrefix(const QString &prefix, int from) const;
    // Get Info data of a row, or of the listed folder itself (row -1).
    Q_INVOKABLE QVariantMap info(int row) const;
    // Ask for a thumbnail (icon view delegates call this when created); batched into one PreviewJob.
    Q_INVOKABLE void requestPreview(int row);
    Q_INVOKABLE void reload();
    Q_INVOKABLE void refreshFreeSpace();
    // Select `url` (and ask the view to start renaming it) once it appears in the listing. Successive calls
    // before the items appear build one selection.
    Q_INVOKABLE void expect(const QUrl &url, bool rename);

    KFileItem itemAt(int row) const;
    KFileItem rootItem() const;

signals:
    void urlChanged();
    void sortChanged();
    void showHiddenChanged();
    void filterTextChanged();
    void countChanged();
    void selectionChanged();
    void currentRowChanged();
    void loadingChanged();
    void freeSpaceChanged();
    void errorChanged();
    void rootChanged();
    void previewSizeChanged();
    // The view should scroll to `row`, and start inline renaming when `rename` is true.
    void revealRequested(int row, bool rename);
    // The listed folder was deleted or the listing redirected elsewhere.
    void redirected(const QUrl &url);

protected:
    bool lessThan(const QModelIndex &left, const QModelIndex &right) const override;
    bool filterAcceptsRow(int sourceRow, const QModelIndex &sourceParent) const override;

private:
    void applySelection(const QSet<QUrl> &next);
    void setCurrent(const QUrl &url);
    void setError(const QString &error);
    void checkExpected();
    void dropExpiredExpectations();
    void onItemsDeleted(const KFileItemList &items);
    void startPreviews();
    void clearPreviews();
    QString thumbnailFor(const QUrl &url) const;
    bool previewSupported(const KFileItem &item) const;

    KDirLister *m_lister = nullptr;
    KDirModel *m_dirModel = nullptr;
    QUrl m_url;
    int m_sortKey = 0;
    bool m_descending = false;
    bool m_foldersFirst = true;
    QString m_filterText;
    QCollator m_collator;
    bool m_loading = false;
    QElapsedTimer m_listTimer;
    qint64 m_freeSpace = -1;
    QString m_error;
    QSet<QUrl> m_selected;
    QUrl m_current;
    QUrl m_anchor;
    QHash<QUrl, QDeadlineTimer> m_expected;
    bool m_expectFresh = true;
    bool m_checkingExpected = false;
    QUrl m_renameUrl;
    int m_previewSize = 128;

    // Thumbnails: url -> key in ThumbnailStore; urls already asked for (done or failed).
    QHash<QUrl, QString> m_thumbs;
    QSet<QUrl> m_previewAsked;
    KFileItemList m_previewQueue;
    QTimer m_previewTimer;
    QTimer m_expectTimer;
    QTimer m_structureTimer;
    QPointer<KIO::PreviewJob> m_previewJob;
    QPointer<KJob> m_freeSpaceJob;
};
