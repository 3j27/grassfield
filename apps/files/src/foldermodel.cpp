#include "foldermodel.h"

#include "filelogic.h"
#include "imageproviders.h"
#include "taglogic.h"
#include "tagsearch.h"
#include "tagstore.h"

#include <QAbstractListModel>
#include <QDBusConnection>
#include <QDeadlineTimer>
#include <QDir>
#include <QElapsedTimer>
#include <QFileInfo>
#include <QLoggingCategory>
#include <QIcon>
#include <QMimeDatabase>
#include <QMimeType>
#include <QScopedValueRollback>

#include <KDirLister>
#include <KDirModel>
#include <KDirNotify>
#include <KIO/FileSystemFreeSpaceJob>
#include <KIO/Job>
#include <KIO/PreviewJob>

// QT_LOGGING_RULES="grassfield.files.debug=true": listing times, selection and expectation traces.
Q_LOGGING_CATEGORY(lcFiles, "grassfield.files", QtInfoMsg)

// The matches of a tag search: a flat list of items (the proxy reads them through FolderModel::sourceItem).
class ItemListModel : public QAbstractListModel
{
public:
    using QAbstractListModel::QAbstractListModel;

    int rowCount(const QModelIndex &parent = QModelIndex()) const override { return parent.isValid() ? 0 : int(m_items.size()); }
    QVariant data(const QModelIndex &index, int role) const override
    {
        if (role != Qt::DisplayRole || index.row() < 0 || index.row() >= m_items.size())
            return {};
        return m_items.at(index.row()).text();
    }

    KFileItem item(int row) const { return row >= 0 && row < m_items.size() ? m_items.at(row) : KFileItem(); }
    int rowOf(const QUrl &url) const { return m_rows.value(url, -1); }

    void append(const KFileItemList &items)
    {
        KFileItemList fresh;
        for (const KFileItem &item : items) {
            if (!m_rows.contains(item.url()))
                fresh.append(item);
        }
        if (fresh.isEmpty())
            return;
        const int first = int(m_items.size());
        beginInsertRows(QModelIndex(), first, first + int(fresh.size()) - 1);
        for (const KFileItem &item : std::as_const(fresh)) {
            m_rows.insert(item.url(), int(m_items.size()));
            m_items.append(item);
        }
        endInsertRows();
    }

    void remove(const QUrl &url)
    {
        const int row = rowOf(url);
        if (row < 0)
            return;
        beginRemoveRows(QModelIndex(), row, row);
        m_items.removeAt(row);
        reindex();
        endRemoveRows();
    }

    void replace(const QUrl &url, const KFileItem &item)
    {
        const int row = rowOf(url);
        if (row < 0)
            return;
        m_items[row] = item;
        reindex();
        emit dataChanged(index(row), index(row));
    }

    void clear()
    {
        if (m_items.isEmpty())
            return;
        beginResetModel();
        m_items.clear();
        m_rows.clear();
        endResetModel();
    }

private:
    void reindex()
    {
        m_rows.clear();
        for (int i = 0; i < m_items.size(); ++i)
            m_rows.insert(m_items.at(i).url(), i);
    }

    KFileItemList m_items;
    QHash<QUrl, int> m_rows;
};

namespace
{
constexpr int kSelectionBulkThreshold = 64;
constexpr int kPreviewBatchDelayMs = 30;
// One PreviewJob never holds more than this many items, and at most this many thumbnails are kept
// (a 128 px thumbnail is ~64 KB: 512 of them stay below ~32 MB).
constexpr int kPreviewBatchSize = 32;
// An expected item that has not appeared by then (failed or slow job) no longer steers the selection.
constexpr int kExpectationLifetimeMs = 10000;

QString resolvedIconName(const KFileItem &item)
{
    // Cache per icon name: QIcon::hasThemeIcon walks the theme directories.
    static QHash<QString, QString> cache;
    const QString name = item.iconName();
    const auto it = cache.constFind(name);
    if (it != cache.cend())
        return *it;
    QString resolved = name;
    if (name.isEmpty() || !QIcon::hasThemeIcon(name)) {
        const QString generic = item.currentMimeType().genericIconName();
        if (!generic.isEmpty() && QIcon::hasThemeIcon(generic))
            resolved = generic;
        else
            resolved = item.isDir() ? QStringLiteral("folder") : QStringLiteral("text-x-generic");
    }
    cache.insert(name, resolved);
    return resolved;
}

// Only the fields the active key compares: lessThan runs O(n log n) times while a folder is listed,
// and the MIME comment is a database lookup.
FileLogic::SortEntry sortEntry(const KFileItem &item, FileLogic::SortKey key)
{
    FileLogic::SortEntry e;
    e.name = item.text();
    e.isDir = item.isDir();
    if (key == FileLogic::SortKey::Kind) {
        // The lister resolves MIME types lazily (setDelayedMimeTypes): never sniff file content on the
        // GUI thread while sorting. Until an item's type is known, use the extension/name guess.
        if (item.isMimeTypeKnown()) {
            e.kind = item.mimeComment();
        } else {
            // Memoized per file name: the glob lookup is ~100 us and lessThan asks O(n log n) times.
            static QHash<QString, QString> guesses;
            static const QMimeDatabase db;
            const QString name = item.name();
            auto it = guesses.constFind(name);
            if (it == guesses.cend()) {
                if (guesses.size() > 50000)
                    guesses.clear();
                it = guesses.insert(name, db.mimeTypeForFile(name, QMimeDatabase::MatchExtension).comment());
            }
            e.kind = *it;
        }
    }
    else if (key == FileLogic::SortKey::Date)
        e.modified = item.time(KFileItem::ModificationTime);
    else if (key == FileLogic::SortKey::Size)
        e.size = e.isDir ? -1 : qint64(item.size());
    return e;
}

struct PreviewMimes {
    QSet<QString> exact;
    QStringList prefixes; // "image/" for "image/*"
};

const PreviewMimes &previewMimes()
{
    static const PreviewMimes mimes = [] {
        PreviewMimes m;
        const QStringList all = KIO::PreviewJob::supportedMimeTypes();
        for (const QString &mime : all) {
            if (mime.endsWith(QLatin1String("/*")))
                m.prefixes << mime.chopped(1);
            else
                m.exact.insert(mime);
        }
        return m;
    }();
    return mimes;
}

const QStringList &previewPlugins()
{
    // Every installed thumbnailer (kf6/thumbcreator plugins and freedesktop .thumbnailer entries).
    static const QStringList plugins = KIO::PreviewJob::availablePlugins();
    return plugins;
}
} // namespace

FolderModel::FolderModel(QObject *parent)
    : QSortFilterProxyModel(parent)
{
    m_dirModel = new KDirModel(this);
    m_lister = m_dirModel->dirLister();
    m_lister->setAutoErrorHandlingEnabled(false);
    m_lister->setDelayedMimeTypes(true);
    m_results = new ItemListModel(this);
    setSourceModel(m_dirModel);
    setDynamicSortFilter(true);

    // The C locale collator has no numeric ("file2" < "file10") mode.
    QLocale locale;
    if (locale.language() == QLocale::C)
        locale = QLocale(QLocale::English, QLocale::UnitedStates);
    m_collator = QCollator(locale);
    m_collator.setNumericMode(true);
    m_collator.setCaseSensitivity(Qt::CaseInsensitive);
    sort(0, Qt::AscendingOrder);

    connect(m_lister, &KCoreDirLister::started, this, [this] {
        m_loading = true;
        m_listTimer.start();
        emit loadingChanged();
    });
    connect(m_lister, qOverload<>(&KCoreDirLister::completed), this, [this] {
        qCDebug(lcFiles) << "listed" << m_url.toDisplayString() << rowCount() << "items in" << m_listTimer.elapsed() << "ms";
        m_loading = false;
        emit loadingChanged();
        emit rootChanged();
        refreshFreeSpace();
    });
    connect(m_lister, qOverload<>(&KCoreDirLister::canceled), this, [this] {
        m_loading = false;
        emit loadingChanged();
    });
    connect(m_lister, &KCoreDirLister::itemsDeleted, this, &FolderModel::onItemsDeleted);
    connect(m_lister, &KCoreDirLister::refreshItems, this, [this](const QList<QPair<KFileItem, KFileItem>> &items) {
        // Changed files get a fresh thumbnail, and their tags are read again.
        for (const auto &pair : items) {
            const QUrl url = pair.second.url();
            forgetThumbnail(m_small, url, true);
            forgetThumbnail(m_large, url, true);
            dropTags(url);
        }
    });
    connect(m_lister, &KCoreDirLister::jobError, this, [this](KIO::Job *job) {
        if (job)
            setError(job->errorString());
    });
    connect(m_lister, qOverload<const QUrl &, const QUrl &>(&KCoreDirLister::redirection), this, [this](const QUrl &, const QUrl &to) {
        if (to != m_url) {
            m_url = to;
            emit urlChanged();
        }
    });

    // Everything that reacts to a structural change runs after the views have processed it. These
    // connections are made before any view connects, so a synchronous reaction would reach QML
    // (count, currentRow -> GridView.currentIndex, selection dataChanged) while the views still hold
    // the previous rows, which shows up as duplicated or stale delegates.
    m_expectTimer.setSingleShot(true);
    m_expectTimer.setInterval(0);
    connect(&m_expectTimer, &QTimer::timeout, this, &FolderModel::checkExpected);
    const auto queueCheck = [this] {
        if (!m_expected.isEmpty() && !m_checkingExpected)
            m_expectTimer.start();
    };
    m_structureTimer.setSingleShot(true);
    m_structureTimer.setInterval(0);
    connect(&m_structureTimer, &QTimer::timeout, this, [this] {
        emit countChanged();
        emit currentRowChanged();
    });
    const auto queueStructure = [this, queueCheck] {
        m_structureTimer.start();
        queueCheck();
    };
    connect(this, &QAbstractItemModel::rowsInserted, this, queueStructure);
    connect(this, &QAbstractItemModel::rowsRemoved, this, queueStructure);
    connect(this, &QAbstractItemModel::rowsMoved, this, queueStructure);
    connect(this, &QAbstractItemModel::modelReset, this, queueStructure);
    connect(this, &QAbstractItemModel::layoutChanged, this, queueStructure);
    // A renamed item is refreshed in place (no insertion) and may move when re-sorted.
    connect(this, &QAbstractItemModel::dataChanged, this, queueCheck);

    for (ThumbChannel *channel : {&m_small, &m_large}) {
        channel->timer.setSingleShot(true);
        channel->timer.setInterval(kPreviewBatchDelayMs);
        connect(&channel->timer, &QTimer::timeout, this, [this, channel] { startPreviews(*channel); });
    }

    // Tags seen on shown rows are reported in one batch per event loop turn (data() is const and runs per delegate).
    m_seenTimer.setSingleShot(true);
    m_seenTimer.setInterval(0);
    connect(&m_seenTimer, &QTimer::timeout, this, [this] {
        const QStringList tags(m_seenPending.cbegin(), m_seenPending.cend());
        m_seenPending.clear();
        if (!tags.isEmpty())
            emit tagsSeen(tags);
    });

    // The tag search of a search location; the runner drops every batch of a superseded search.
    m_search = new SearchRunner(this);
    connect(m_search, &SearchRunner::found, this, &FolderModel::addResults);
    connect(m_search, &SearchRunner::done, this, [this](bool limited, int visited) {
        qCDebug(lcFiles) << "tag search" << m_url.toDisplayString() << rowCount() << "matches," << visited << "entries visited, limited" << limited << "in" << m_listTimer.elapsed() << "ms";
        m_searchLimited = limited;
        m_loading = false;
        emit loadingChanged();
    });
}

FolderModel::~FolderModel()
{
    stopSearch();
    clearAllPreviews();
    // The views go first; nothing may reach them while this object is half destroyed.
    m_seenTimer.stop();
}

void FolderModel::setUrl(const QUrl &url)
{
    const bool search = TagLogic::isSearchUrl(url);
    const QUrl clean = search ? url : url.adjusted(QUrl::StripTrailingSlash | QUrl::NormalizePathSegments);
    if (clean == m_url && (search || m_lister->url().isValid()))
        return;
    m_url = clean;
    applySelection({});
    m_current.clear();
    m_anchor.clear();
    m_expected.clear();
    m_renameUrl.clear();
    clearAllPreviews();
    m_tags.clear();
    setError(QString());
    m_freeSpace = -1;
    emit freeSpaceChanged();
    stopSearch();
    if (search) {
        // The folder listing stops; the matches of the search are the rows.
        m_lister->stop();
        m_results->clear();
        if (sourceModel() != m_results)
            setSourceModel(m_results);
        startSearch();
    } else {
        if (sourceModel() != m_dirModel)
            setSourceModel(m_dirModel);
        m_results->clear();
        m_dirModel->openUrl(m_url);
    }
    emit urlChanged();
    emit rootChanged();
    emit currentRowChanged();
}

bool FolderModel::isSearch() const
{
    return TagLogic::isSearchUrl(m_url);
}

void FolderModel::setSortKey(int key)
{
    key = qBound(0, key, 3);
    if (key == m_sortKey)
        return;
    m_sortKey = key;
    QElapsedTimer sortTimer;
    sortTimer.start();
    invalidate();
    qCDebug(lcFiles) << "sorted by key" << key << rowCount() << "items in" << sortTimer.elapsed() << "ms";
    emit sortChanged();
}

void FolderModel::setSortDescending(bool descending)
{
    if (descending == m_descending)
        return;
    m_descending = descending;
    invalidate();
    emit sortChanged();
}

void FolderModel::setFoldersFirst(bool on)
{
    if (on == m_foldersFirst)
        return;
    m_foldersFirst = on;
    invalidate();
    emit sortChanged();
}

bool FolderModel::showHidden() const
{
    return m_lister->showHiddenFiles();
}

void FolderModel::setShowHidden(bool on)
{
    if (on == m_lister->showHiddenFiles())
        return;
    m_lister->setShowHiddenFiles(on);
    m_lister->emitChanges();
    emit showHiddenChanged();
}

void FolderModel::setFilterText(const QString &text)
{
    if (text == m_filterText)
        return;
    beginFilterChange();
    m_filterText = text;
    endFilterChange(QSortFilterProxyModel::Direction::Rows);
    emit filterTextChanged();
}

int FolderModel::currentRow() const
{
    return m_current.isEmpty() ? -1 : rowForUrl(m_current);
}

bool FolderModel::writable() const
{
    // Nothing can be created in a trash or a tag search (its items keep their own folders).
    if (isTrash() || isSearch())
        return false;
    const KFileItem root = m_lister->rootItem();
    return !root.isNull() && root.isWritable();
}

QString FolderModel::title() const
{
    if (isSearch())
        return TagLogic::displayName(TagLogic::searchTag(m_url));
    const QList<FileLogic::Segment> segments = FileLogic::pathSegments(m_url, QDir::homePath(), tr("Computer"), tr("Trash"));
    return segments.isEmpty() ? m_url.toDisplayString() : segments.last().label;
}

void FolderModel::setPreviewSize(int size)
{
    size = qBound(32, size, 512);
    if (size == m_small.size)
        return;
    m_small.size = size;
    clearPreviews(m_small);
    emit previewSizeChanged();
    if (rowCount() > 0)
        emit dataChanged(index(0, 0), index(rowCount() - 1, 0), {ThumbnailRole});
}

void FolderModel::setLargePreviewSize(int size)
{
    // 1024 px is the largest freedesktop thumbnail cache size (xx-large).
    size = qBound(128, size, 1024);
    if (size == m_large.size)
        return;
    m_large.size = size;
    clearPreviews(m_large);
    emit previewSizeChanged();
    if (rowCount() > 0)
        emit dataChanged(index(0, 0), index(rowCount() - 1, 0), {LargeThumbnailRole});
}

QHash<int, QByteArray> FolderModel::roleNames() const
{
    return {
        {NameRole, "name"},
        {UrlRole, "url"},
        {IconNameRole, "iconName"},
        {IsDirRole, "isDir"},
        {SizeRole, "size"},
        {SizeTextRole, "sizeText"},
        {ModifiedRole, "modified"},
        {ModifiedTextRole, "modifiedText"},
        {KindRole, "kind"},
        {ThumbnailRole, "thumbnail"},
        {SelectedRole, "selected"},
        {HiddenRole, "hidden"},
        {CanPreviewRole, "canPreview"},
        {EmblemRole, "emblem"},
        {LargeThumbnailRole, "largeThumbnail"},
        {TagsRole, "tags"},
        {TagColorsRole, "tagColors"},
    };
}

QVariant FolderModel::data(const QModelIndex &index, int role) const
{
    if (role < NameRole)
        return QSortFilterProxyModel::data(index, role);
    const KFileItem item = sourceItem(mapToSource(index));
    if (item.isNull())
        return {};
    // Lazy refinement: the lister only guessed the type from the name (setDelayedMimeTypes). A row a
    // view actually shows reads its content once (a few hundred bytes); sorting never does.
    if ((role == IconNameRole || role == KindRole || role == CanPreviewRole) && !item.isMimeTypeKnown())
        item.determineMimeType();
    switch (role) {
    case NameRole:
        return item.text();
    case UrlRole:
        return item.url();
    case IconNameRole:
        return resolvedIconName(item);
    case IsDirRole:
        return item.isDir();
    case SizeRole:
        return item.isDir() ? qint64(-1) : qint64(item.size());
    case SizeTextRole:
        return FileLogic::formatSize(item.isDir() ? -1 : qint64(item.size()));
    case ModifiedRole:
        return item.time(KFileItem::ModificationTime);
    case ModifiedTextRole:
        return FileLogic::formatDate(item.time(KFileItem::ModificationTime), QDateTime::currentDateTime());
    case KindRole:
        return item.mimeComment();
    case ThumbnailRole:
        return thumbnailFor(m_small, item.url());
    case LargeThumbnailRole:
        return thumbnailFor(m_large, item.url());
    case SelectedRole:
        return m_selected.contains(item.url());
    case HiddenRole:
        return item.isHidden();
    case CanPreviewRole:
        return previewSupported(item);
    case EmblemRole:
        return item.isLink() ? QStringLiteral("emblem-symbolic-link") : QString();
    case TagsRole:
        return TagLogic::displayOrder(tagsOf(item));
    case TagColorsRole: {
        QVariantList colors;
        const QList<int> indices = TagLogic::colorIndices(tagsOf(item));
        for (int c : indices)
            colors.append(c);
        return colors;
    }
    }
    return {};
}

KFileItem FolderModel::sourceItem(const QModelIndex &source) const
{
    if (sourceModel() == m_results)
        return m_results->item(source.row());
    return m_dirModel->itemForIndex(source);
}

QModelIndex FolderModel::sourceIndexForUrl(const QUrl &url) const
{
    if (sourceModel() == m_results) {
        const int row = m_results->rowOf(url);
        return row < 0 ? QModelIndex() : m_results->index(row);
    }
    return m_dirModel->indexForUrl(url);
}

QStringList FolderModel::tagsOf(const KFileItem &item) const
{
    const QUrl url = item.url();
    const auto it = m_tags.constFind(url);
    if (it != m_tags.cend())
        return *it;
    // Local items only (trash items have a local path too); links carry no user attributes (TagStore).
    const QString path = item.localPath();
    const QStringList tags = path.isEmpty() || item.isLink() ? QStringList() : TagStore::read(path);
    m_tags.insert(url, tags);
    bool fresh = false;
    for (const QString &tag : tags) {
        if (!m_seenPending.contains(tag)) {
            m_seenPending.insert(tag);
            fresh = true;
        }
    }
    if (fresh && !m_seenTimer.isActive())
        m_seenTimer.start();
    return tags;
}

void FolderModel::dropTags(const QUrl &url)
{
    if (m_tags.remove(url))
        emitRowChanged(url, {TagsRole, TagColorsRole});
}

void FolderModel::emitRowChanged(const QUrl &url, const QList<int> &roles)
{
    const int r = rowForUrl(url);
    if (r >= 0)
        emit dataChanged(index(r, 0), index(r, 0), roles);
}

void FolderModel::tagsChanged(const QList<QUrl> &urls)
{
    const QString tag = TagLogic::searchTag(m_url);
    const QUrl folder = TagLogic::searchFolder(m_url);
    QList<QUrl> gone;
    QStringList joined;
    for (const QUrl &url : urls) {
        m_tags.remove(url);
        if (!isSearch()) {
            emitRowChanged(url, {TagsRole, TagColorsRole});
            continue;
        }
        // A tag search follows the changes made in Files: an item that lost the tag leaves it, a local item in the
        // searched folder that got it joins it.
        const bool listed = m_results->rowOf(url) >= 0;
        const bool matches = url.isLocalFile() && TagLogic::hasTag(TagStore::read(url.toLocalFile()), tag);
        if (listed && !matches)
            gone.append(url);
        else if (!listed && matches && (folder == url || folder.isParentOf(url)))
            joined.append(url.toLocalFile());
        else
            emitRowChanged(url, {TagsRole, TagColorsRole});
    }
    if (!gone.isEmpty())
        removeResults(gone);
    if (!joined.isEmpty())
        addResults(joined);
}

bool FolderModel::lessThan(const QModelIndex &left, const QModelIndex &right) const
{
    const KFileItem a = sourceItem(left);
    const KFileItem b = sourceItem(right);
    const auto key = FileLogic::SortKey(m_sortKey);
    return FileLogic::compareEntries(sortEntry(a, key), sortEntry(b, key), key, m_descending, m_foldersFirst, m_collator) < 0;
}

bool FolderModel::filterAcceptsRow(int sourceRow, const QModelIndex &sourceParent) const
{
    const KFileItem item = sourceItem(sourceModel()->index(sourceRow, 0, sourceParent));
    // Only remote:/ entries can be hidden; the target is looked up for those alone.
    if (item.url().scheme() == QLatin1String("remote") && FileLogic::hiddenNetworkEntry(item.url(), item.targetUrl()))
        return false;
    if (m_filterText.isEmpty())
        return true;
    return item.text().contains(m_filterText, Qt::CaseInsensitive);
}

void FolderModel::select(int row, int modifiers)
{
    const QUrl url = urlAt(row);
    qCDebug(lcFiles) << "select" << row << url.fileName() << "modifiers" << modifiers;
    if (url.isEmpty())
        return;
    QSet<QUrl> next = m_selected;
    if (modifiers & Qt::ShiftModifier) {
        int anchorRow = rowForUrl(m_anchor);
        if (anchorRow < 0) {
            anchorRow = row;
            m_anchor = url;
        }
        if (!(modifiers & Qt::ControlModifier))
            next.clear();
        for (int r = qMin(row, anchorRow); r <= qMax(row, anchorRow); ++r)
            next.insert(urlAt(r));
    } else if (modifiers & Qt::ControlModifier) {
        if (!next.remove(url))
            next.insert(url);
        m_anchor = url;
    } else {
        next = {url};
        m_anchor = url;
    }
    applySelection(next);
    setCurrent(url);
}

void FolderModel::selectAll()
{
    QSet<QUrl> next;
    for (int r = 0; r < rowCount(); ++r)
        next.insert(urlAt(r));
    applySelection(next);
}

void FolderModel::clearSelection()
{
    applySelection({});
}

void FolderModel::selectUrls(const QList<QUrl> &urls)
{
    QSet<QUrl> next;
    for (const QUrl &u : urls) {
        if (rowForUrl(u) >= 0)
            next.insert(u);
    }
    applySelection(next);
    if (!urls.isEmpty()) {
        m_anchor = urls.first();
        setCurrent(urls.first());
    }
}

QList<QUrl> FolderModel::selectedUrls() const
{
    QList<QUrl> out;
    for (int r : selectedRows())
        out.append(urlAt(r));
    return out;
}

bool FolderModel::isSelected(int row) const
{
    return m_selected.contains(urlAt(row));
}

QList<int> FolderModel::selectedRows() const
{
    QList<int> rows;
    rows.reserve(m_selected.size());
    for (const QUrl &u : m_selected) {
        const int r = rowForUrl(u);
        if (r >= 0)
            rows.append(r);
    }
    std::sort(rows.begin(), rows.end());
    return rows;
}

void FolderModel::applySelection(const QSet<QUrl> &next)
{
    if (next == m_selected)
        return;
    QSet<QUrl> changed = m_selected;
    changed.unite(next);
    changed.subtract(QSet<QUrl>(m_selected).intersect(next));
    m_selected = next;
    qCDebug(lcFiles) << "selection" << m_selected.size() << "changed" << changed.size();
    if (changed.size() > kSelectionBulkThreshold) {
        if (rowCount() > 0)
            emit dataChanged(index(0, 0), index(rowCount() - 1, 0), {SelectedRole});
    } else {
        for (const QUrl &u : std::as_const(changed)) {
            const int r = rowForUrl(u);
            if (r >= 0)
                emit dataChanged(index(r, 0), index(r, 0), {SelectedRole});
        }
    }
    emit selectionChanged();
}

void FolderModel::setCurrent(const QUrl &url)
{
    if (url == m_current)
        return;
    m_current = url;
    emit currentRowChanged();
}

KFileItem FolderModel::itemAt(int row) const
{
    if (row < 0 || row >= rowCount())
        return KFileItem();
    return sourceItem(mapToSource(index(row, 0)));
}

KFileItem FolderModel::rootItem() const
{
    // A tag search stands for its folder (Get Info without a selection).
    if (isSearch())
        return KFileItem(TagLogic::searchFolder(m_url));
    return m_lister->rootItem();
}

QUrl FolderModel::urlAt(int row) const
{
    const KFileItem item = itemAt(row);
    return item.isNull() ? QUrl() : item.url();
}

QString FolderModel::nameAt(int row) const
{
    const KFileItem item = itemAt(row);
    return item.isNull() ? QString() : item.text();
}

bool FolderModel::isDirAt(int row) const
{
    const KFileItem item = itemAt(row);
    return !item.isNull() && item.isDir();
}

int FolderModel::rowForUrl(const QUrl &url) const
{
    if (url.isEmpty())
        return -1;
    const QModelIndex source = sourceIndexForUrl(url);
    if (!source.isValid())
        return -1;
    const QModelIndex proxy = mapFromSource(source);
    return proxy.isValid() ? proxy.row() : -1;
}

int FolderModel::findPrefix(const QString &prefix, int from) const
{
    const int n = rowCount();
    if (prefix.isEmpty() || n == 0)
        return -1;
    from = qBound(0, from, n - 1);
    for (int i = 0; i < n; ++i) {
        const int r = (from + i) % n;
        if (nameAt(r).startsWith(prefix, Qt::CaseInsensitive))
            return r;
    }
    return -1;
}

QVariantMap FolderModel::info(int row) const
{
    const KFileItem item = row < 0 ? rootItem() : itemAt(row);
    QVariantMap m;
    if (item.isNull())
        return m;
    const QDateTime now = QDateTime::currentDateTime();
    const qint64 size = item.isDir() ? -1 : qint64(item.size());
    // A folder's own info carries its title ("Computer", "Trash", the home folder's name); a tag search shows its folder.
    m[QStringLiteral("name")] = row < 0 && !isSearch() ? title() : item.text();
    m[QStringLiteral("url")] = item.url();
    m[QStringLiteral("iconName")] = resolvedIconName(item);
    m[QStringLiteral("thumbnail")] = thumbnailFor(m_small, item.url());
    m[QStringLiteral("kind")] = item.mimeComment();
    m[QStringLiteral("mimeType")] = item.mimetype();
    m[QStringLiteral("isDir")] = item.isDir();
    m[QStringLiteral("size")] = size;
    m[QStringLiteral("sizeText")] = FileLogic::formatSize(size);
    m[QStringLiteral("bytes")] = QLocale().toString(size);
    const QUrl parent = item.url().adjusted(QUrl::RemoveFilename | QUrl::StripTrailingSlash);
    m[QStringLiteral("where")] = parent.isLocalFile() ? parent.toLocalFile() : parent.toDisplayString();
    m[QStringLiteral("created")] = FileLogic::formatDate(item.time(KFileItem::CreationTime), now);
    m[QStringLiteral("modified")] = FileLogic::formatDate(item.time(KFileItem::ModificationTime), now);
    m[QStringLiteral("accessed")] = FileLogic::formatDate(item.time(KFileItem::AccessTime), now);
    m[QStringLiteral("permissions")] = item.permissionsString();
    m[QStringLiteral("owner")] = item.user();
    m[QStringLiteral("group")] = item.group();
    m[QStringLiteral("readable")] = item.isReadable();
    m[QStringLiteral("writable")] = item.isWritable();
    m[QStringLiteral("linkDest")] = item.isLink() ? item.linkDest() : QString();
    // Tags in display order, by their shown names, and the colour dots.
    const QStringList tags = TagLogic::displayOrder(tagsOf(item));
    QStringList names;
    for (const QString &tag : tags)
        names.append(TagLogic::displayName(tag));
    m[QStringLiteral("tags")] = names;
    QVariantList colors;
    const QList<int> indices = TagLogic::colorIndices(tags);
    for (int c : indices)
        colors.append(c);
    m[QStringLiteral("tagColors")] = colors;
    return m;
}

void FolderModel::requestPreview(int row, bool large)
{
    const KFileItem item = itemAt(row);
    if (item.isNull() || !previewSupported(item))
        return;
    ThumbChannel &c = large ? m_large : m_small;
    if (c.queue.request(item.url()) && !c.timer.isActive())
        c.timer.start();
}

void FolderModel::cancelPreview(const QUrl &url, bool large)
{
    (large ? m_large : m_small).queue.cancel(url);
}

void FolderModel::startPreviews(ThumbChannel &c)
{
    if (c.job || c.queue.isEmpty())
        return;
    KFileItemList batch;
    const QList<QUrl> urls = c.queue.takeBatch(kPreviewBatchSize);
    for (const QUrl &url : urls) {
        const KFileItem item = itemAt(rowForUrl(url));
        if (item.isNull())
            c.queue.forget(url);
        else
            batch.append(item);
    }
    ThumbChannel *channel = &c;
    if (batch.isEmpty()) {
        if (!c.queue.isEmpty())
            QTimer::singleShot(0, this, [this, channel] { startPreviews(*channel); });
        return;
    }
    auto *job = KIO::filePreview(batch, QSize(c.size, c.size), &previewPlugins());
    c.job = job;
    connect(job, &KIO::PreviewJob::generated, this, [this, channel](const KFileItem &item, const QImage &image) {
        if (image.isNull())
            return;
        ThumbChannel &c = *channel;
        const QUrl url = item.url();
        qCDebug(lcFiles) << "thumbnail" << item.name() << c.size << "px, stored" << c.thumbs.size() + 1;
        const QString old = c.thumbs.value(url);
        if (!old.isEmpty())
            ThumbnailStore::remove(old);
        c.thumbs.insert(url, ThumbnailStore::insert(image));
        const int r = rowForUrl(url);
        if (r >= 0)
            emit dataChanged(index(r, 0), index(r, 0), {c.role});
        // Least recently loaded thumbnails go first; they may be asked for again when shown.
        const QList<QUrl> evicted = c.lru.add(url);
        for (const QUrl &gone : evicted)
            forgetThumbnail(c, gone, false);
    });
    connect(job, &KJob::result, this, [this, channel] {
        // The finished job is only deleteLater()'d: release the slot now so the next batch can start.
        channel->job.clear();
        if (!channel->queue.isEmpty())
            QTimer::singleShot(0, this, [this, channel] { startPreviews(*channel); });
    });
}

void FolderModel::forgetThumbnail(ThumbChannel &c, const QUrl &url, bool again)
{
    const QString key = c.thumbs.take(url);
    if (!key.isEmpty())
        ThumbnailStore::remove(key);
    c.lru.remove(url);
    const bool wasAsked = c.queue.asked(url);
    c.queue.cancel(url);
    c.queue.forget(url);
    const int r = rowForUrl(url);
    if (again && wasAsked && r >= 0) {
        // The delegate keeps showing the old picture until the new one replaces it (no flicker).
        requestPreview(r, &c == &m_large);
    } else if (r >= 0 && !key.isEmpty()) {
        emit dataChanged(index(r, 0), index(r, 0), {c.role});
    }
}

void FolderModel::clearPreviews(ThumbChannel &c)
{
    c.timer.stop();
    if (c.job) {
        c.job->kill(KJob::Quietly);
        c.job.clear();
    }
    for (const QString &key : std::as_const(c.thumbs))
        ThumbnailStore::remove(key);
    c.thumbs.clear();
    c.lru.clear();
    c.queue.clear();
}

void FolderModel::clearAllPreviews()
{
    clearPreviews(m_small);
    clearPreviews(m_large);
}

QString FolderModel::thumbnailFor(const ThumbChannel &c, const QUrl &url) const
{
    const QString key = c.thumbs.value(url);
    return key.isEmpty() ? QString() : QStringLiteral("image://thumbnail/") + key;
}

bool FolderModel::previewSupported(const KFileItem &item) const
{
    if (item.isNull() || item.isDir() || item.size() == 0)
        return false;
    const PreviewMimes &mimes = previewMimes();
    const QMimeType type = item.currentMimeType();
    QStringList names = {type.name()};
    names += type.allAncestors();
    for (const QString &name : std::as_const(names)) {
        if (mimes.exact.contains(name))
            return true;
        for (const QString &prefix : mimes.prefixes) {
            if (name.startsWith(prefix))
                return true;
        }
    }
    return false;
}

void FolderModel::reload()
{
    m_tags.clear();
    if (isSearch()) {
        clearAllPreviews();
        stopSearch();
        applySelection({});
        m_current.clear();
        m_results->clear();
        startSearch();
        return;
    }
    // Thumbnails stay: KIO refreshes the rows of a listed folder in place (the delegates are not recreated and would
    // not ask again), and refreshItems renews the thumbnails of the files that changed. Tags are read again.
    if (rowCount() > 0)
        emit dataChanged(index(0, 0), index(rowCount() - 1, 0), {TagsRole, TagColorsRole});
    m_dirModel->openUrl(m_url, KDirModel::Reload);
}

void FolderModel::startSearch()
{
    const QString tag = TagLogic::searchTag(m_url);
    const QUrl folder = TagLogic::searchFolder(m_url);
    m_searchLimited = false;
    if (!folder.isLocalFile()) {
        // FilesApp only builds searches of local folders; a typed location may name anything.
        setError(tr("Tags are only searched in local folders."));
        m_loading = false;
        emit loadingChanged();
        return;
    }
    watchChanges();
    m_listTimer.start();
    m_loading = true;
    emit loadingChanged();
    m_search->start(folder.toLocalFile(), tag, showHidden());
}

void FolderModel::stopSearch()
{
    m_search->stop();
}

void FolderModel::watchChanges()
{
    if (m_notify)
        return;
    // KIO announces every change made through it (this app's jobs and other KIO applications') on the session bus.
    m_notify = new OrgKdeKDirNotifyInterface(QString(), QString(), QDBusConnection::sessionBus(), this);
    connect(m_notify, &OrgKdeKDirNotifyInterface::FileRenamedWithLocalPath, this, [this](const QString &src, const QString &dst, const QString &) {
        if (isSearch())
            renameResult(QUrl(src), QUrl(dst));
    });
    connect(m_notify, &OrgKdeKDirNotifyInterface::FileRenamed, this, [this](const QString &src, const QString &dst) {
        if (isSearch())
            renameResult(QUrl(src), QUrl(dst));
    });
    connect(m_notify, &OrgKdeKDirNotifyInterface::FileMoved, this, [this](const QString &src, const QString &dst) {
        if (isSearch())
            renameResult(QUrl(src), QUrl(dst));
    });
    connect(m_notify, &OrgKdeKDirNotifyInterface::FilesRemoved, this, [this](const QStringList &files) {
        if (!isSearch())
            return;
        QList<QUrl> urls;
        for (const QString &f : files)
            urls.append(QUrl(f));
        removeResults(urls);
    });
    connect(m_notify, &OrgKdeKDirNotifyInterface::FilesChanged, this, [this](const QStringList &files) {
        if (!isSearch())
            return;
        for (const QString &f : files) {
            const QUrl url(f);
            if (m_results->rowOf(url) < 0)
                continue;
            m_results->replace(url, KFileItem(url, KFileItem::SkipMimeTypeFromContent));
            forgetThumbnail(m_small, url, true);
            forgetThumbnail(m_large, url, true);
            dropTags(url);
        }
    });
}

void FolderModel::addResults(const QStringList &paths)
{
    KFileItemList items;
    items.reserve(paths.size());
    for (const QString &path : paths) {
        // The type is guessed from the name here; rows that are shown refine it from content (data()).
        const KFileItem item(QUrl::fromLocalFile(path), KFileItem::SkipMimeTypeFromContent);
        if (!item.isNull())
            items.append(item);
    }
    m_results->append(items);
}

void FolderModel::removeResults(const QList<QUrl> &urls)
{
    bool selectionTouched = false;
    for (const QUrl &url : urls) {
        if (m_results->rowOf(url) < 0)
            continue;
        selectionTouched |= m_selected.remove(url);
        if (url == m_current)
            m_current.clear();
        forgetThumbnail(m_small, url, false);
        forgetThumbnail(m_large, url, false);
        m_tags.remove(url);
        m_results->remove(url);
    }
    if (selectionTouched)
        emit selectionChanged();
}

void FolderModel::renameResult(const QUrl &from, const QUrl &to)
{
    if (m_results->rowOf(from) < 0)
        return;
    // Moved out of the searched folder (or to the Trash): it leaves the results.
    const QUrl folder = TagLogic::searchFolder(m_url);
    if (!to.isLocalFile() || !(folder == to || folder.isParentOf(to))) {
        removeResults({from});
        return;
    }
    const bool selected = m_selected.remove(from);
    forgetThumbnail(m_small, from, false);
    forgetThumbnail(m_large, from, false);
    m_tags.remove(from);
    m_results->replace(from, KFileItem(to, KFileItem::SkipMimeTypeFromContent));
    if (selected)
        m_selected.insert(to);
    if (m_current == from)
        m_current = to;
    if (m_anchor == from)
        m_anchor = to;
    if (selected)
        emit selectionChanged();
}

void FolderModel::refreshFreeSpace()
{
    if (m_freeSpaceJob)
        return;
    QUrl target = m_url;
    if (isTrash())
        target = QUrl::fromLocalFile(QDir::homePath());
    if (!target.isLocalFile())
        return;
    auto *job = KIO::fileSystemFreeSpace(target);
    m_freeSpaceJob = job;
    connect(job, &KJob::result, this, [this, job] {
        const qint64 value = job->error() ? -1 : qint64(job->availableSize());
        if (value != m_freeSpace) {
            m_freeSpace = value;
            emit freeSpaceChanged();
        }
    });
}

void FolderModel::expect(const QUrl &url, bool rename)
{
    const QUrl clean = url.adjusted(QUrl::StripTrailingSlash);
    dropExpiredExpectations();
    // A new batch (nothing pending) replaces the selection with its first item.
    if (m_expected.isEmpty())
        m_expectFresh = true;
    m_expected.insert(clean, QDeadlineTimer(kExpectationLifetimeMs));
    qCDebug(lcFiles) << "expect" << clean.fileName() << "rename" << rename << "fresh" << m_expectFresh << "row now" << rowForUrl(clean);
    if (rename)
        m_renameUrl = clean;
    checkExpected();
}

void FolderModel::dropExpiredExpectations()
{
    for (auto it = m_expected.begin(); it != m_expected.end();) {
        if (it.value().hasExpired())
            it = m_expected.erase(it);
        else
            ++it;
    }
    if (!m_renameUrl.isEmpty() && !m_expected.contains(m_renameUrl))
        m_renameUrl.clear();
}

void FolderModel::checkExpected()
{
    // select() emits dataChanged, which calls back here.
    if (m_expected.isEmpty() || m_checkingExpected)
        return;
    const QScopedValueRollback<bool> guard(m_checkingExpected, true);
    dropExpiredExpectations();
    const QList<QUrl> pending = m_expected.keys();
    for (const QUrl &url : pending) {
        const int r = rowForUrl(url);
        if (r < 0)
            continue;
        m_expected.remove(url);
        // The first item of a batch replaces the selection, the others join it.
        if (m_expectFresh) {
            select(r, 0);
            m_expectFresh = false;
        } else if (!m_selected.contains(url)) {
            select(r, Qt::ControlModifier);
        }
        const bool rename = url == m_renameUrl;
        if (rename)
            m_renameUrl.clear();
        qCDebug(lcFiles) << "reveal" << r << url.fileName() << "rename" << rename << "row check" << rowForUrl(url);
        emit revealRequested(r, rename);
    }
}

void FolderModel::onItemsDeleted(const KFileItemList &items)
{
    bool selectionTouched = false;
    for (const KFileItem &item : items) {
        const QUrl url = item.url();
        if (url.adjusted(QUrl::StripTrailingSlash) == m_url) {
            emit redirected(m_url.adjusted(QUrl::RemoveFilename | QUrl::StripTrailingSlash));
            continue;
        }
        selectionTouched |= m_selected.remove(url);
        if (url == m_current)
            m_current.clear();
        forgetThumbnail(m_small, url, false);
        forgetThumbnail(m_large, url, false);
        m_tags.remove(url);
    }
    if (selectionTouched)
        emit selectionChanged();
    m_structureTimer.start();
    refreshFreeSpace();
}

void FolderModel::setError(const QString &error)
{
    if (error == m_error)
        return;
    m_error = error;
    emit errorChanged();
}
