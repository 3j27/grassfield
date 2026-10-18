#include "foldermodel.h"

#include "filelogic.h"
#include "imageproviders.h"

#include <QDeadlineTimer>
#include <QDir>
#include <QElapsedTimer>
#include <QLoggingCategory>
#include <QIcon>
#include <QMimeDatabase>
#include <QMimeType>
#include <QScopedValueRollback>

#include <KDirLister>
#include <KDirModel>
#include <KIO/FileSystemFreeSpaceJob>
#include <KIO/Job>
#include <KIO/PreviewJob>
#include <QMimeDatabase>

// QT_LOGGING_RULES="grassfield.files.debug=true": listing times, selection and expectation traces.
Q_LOGGING_CATEGORY(lcFiles, "grassfield.files", QtInfoMsg)

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
        // Changed files get a fresh thumbnail.
        for (const auto &pair : items) {
            const QUrl url = pair.second.url();
            const QString key = m_thumbs.take(url);
            if (!key.isEmpty())
                ThumbnailStore::remove(key);
            m_thumbLru.remove(url);
            if (m_previews.asked(url)) {
                m_previews.cancel(url);
                m_previews.forget(url);
                requestPreview(rowForUrl(url));
            }
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

    m_previewTimer.setSingleShot(true);
    m_previewTimer.setInterval(kPreviewBatchDelayMs);
    connect(&m_previewTimer, &QTimer::timeout, this, &FolderModel::startPreviews);
}

FolderModel::~FolderModel()
{
    clearPreviews();
}

void FolderModel::setUrl(const QUrl &url)
{
    const QUrl clean = url.adjusted(QUrl::StripTrailingSlash | QUrl::NormalizePathSegments);
    if (clean == m_url && m_lister->url().isValid())
        return;
    m_url = clean;
    applySelection({});
    m_current.clear();
    m_anchor.clear();
    m_expected.clear();
    m_renameUrl.clear();
    clearPreviews();
    setError(QString());
    m_freeSpace = -1;
    emit freeSpaceChanged();
    m_dirModel->openUrl(m_url);
    emit urlChanged();
    emit rootChanged();
    emit currentRowChanged();
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
    if (isTrash())
        return false;
    const KFileItem root = m_lister->rootItem();
    return !root.isNull() && root.isWritable();
}

QString FolderModel::title() const
{
    const QList<FileLogic::Segment> segments = FileLogic::pathSegments(m_url, QDir::homePath(), tr("Computer"), tr("Trash"));
    return segments.isEmpty() ? m_url.toDisplayString() : segments.last().label;
}

void FolderModel::setPreviewSize(int size)
{
    size = qBound(32, size, 512);
    if (size == m_previewSize)
        return;
    m_previewSize = size;
    clearPreviews();
    emit previewSizeChanged();
    if (rowCount() > 0)
        emit dataChanged(index(0, 0), index(rowCount() - 1, 0), {ThumbnailRole});
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
    };
}

QVariant FolderModel::data(const QModelIndex &index, int role) const
{
    if (role < NameRole)
        return QSortFilterProxyModel::data(index, role);
    const KFileItem item = m_dirModel->itemForIndex(mapToSource(index));
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
        return thumbnailFor(item.url());
    case SelectedRole:
        return m_selected.contains(item.url());
    case HiddenRole:
        return item.isHidden();
    case CanPreviewRole:
        return previewSupported(item);
    case EmblemRole:
        return item.isLink() ? QStringLiteral("emblem-symbolic-link") : QString();
    }
    return {};
}

bool FolderModel::lessThan(const QModelIndex &left, const QModelIndex &right) const
{
    const KFileItem a = m_dirModel->itemForIndex(left);
    const KFileItem b = m_dirModel->itemForIndex(right);
    const auto key = FileLogic::SortKey(m_sortKey);
    return FileLogic::compareEntries(sortEntry(a, key), sortEntry(b, key), key, m_descending, m_foldersFirst, m_collator) < 0;
}

bool FolderModel::filterAcceptsRow(int sourceRow, const QModelIndex &sourceParent) const
{
    const KFileItem item = m_dirModel->itemForIndex(m_dirModel->index(sourceRow, 0, sourceParent));
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
    return m_dirModel->itemForIndex(mapToSource(index(row, 0)));
}

KFileItem FolderModel::rootItem() const
{
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
    const QModelIndex source = m_dirModel->indexForUrl(url);
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
    m[QStringLiteral("name")] = row < 0 ? title() : item.text();
    m[QStringLiteral("url")] = item.url();
    m[QStringLiteral("iconName")] = resolvedIconName(item);
    m[QStringLiteral("thumbnail")] = thumbnailFor(item.url());
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
    return m;
}

void FolderModel::requestPreview(int row)
{
    const KFileItem item = itemAt(row);
    if (item.isNull() || !previewSupported(item))
        return;
    if (m_previews.request(item.url()) && !m_previewTimer.isActive())
        m_previewTimer.start();
}

void FolderModel::cancelPreview(const QUrl &url)
{
    m_previews.cancel(url);
}

void FolderModel::startPreviews()
{
    if (m_previewJob || m_previews.isEmpty())
        return;
    KFileItemList batch;
    const QList<QUrl> urls = m_previews.takeBatch(kPreviewBatchSize);
    for (const QUrl &url : urls) {
        const KFileItem item = itemAt(rowForUrl(url));
        if (item.isNull())
            m_previews.forget(url);
        else
            batch.append(item);
    }
    if (batch.isEmpty()) {
        if (!m_previews.isEmpty())
            QTimer::singleShot(0, this, &FolderModel::startPreviews);
        return;
    }
    auto *job = KIO::filePreview(batch, QSize(m_previewSize, m_previewSize), &previewPlugins());
    m_previewJob = job;
    connect(job, &KIO::PreviewJob::generated, this, [this](const KFileItem &item, const QImage &image) {
        if (image.isNull())
            return;
        const QUrl url = item.url();
        qCDebug(lcFiles) << "thumbnail" << item.name() << "stored" << m_thumbs.size() + 1;
        const QString old = m_thumbs.value(url);
        if (!old.isEmpty())
            ThumbnailStore::remove(old);
        m_thumbs.insert(url, ThumbnailStore::insert(image));
        const int r = rowForUrl(url);
        if (r >= 0)
            emit dataChanged(index(r, 0), index(r, 0), {ThumbnailRole});
        // Least recently loaded thumbnails go first; they may be asked for again when shown.
        const QList<QUrl> evicted = m_thumbLru.add(url);
        for (const QUrl &gone : evicted) {
            const QString key = m_thumbs.take(gone);
            if (!key.isEmpty())
                ThumbnailStore::remove(key);
            m_previews.forget(gone);
            const int gr = rowForUrl(gone);
            if (gr >= 0)
                emit dataChanged(index(gr, 0), index(gr, 0), {ThumbnailRole});
        }
    });
    connect(job, &KJob::result, this, [this] {
        // The finished job is only deleteLater()'d: release the slot now so the next batch can start.
        m_previewJob.clear();
        if (!m_previews.isEmpty())
            QTimer::singleShot(0, this, &FolderModel::startPreviews);
    });
}

void FolderModel::clearPreviews()
{
    m_previewTimer.stop();
    if (m_previewJob) {
        m_previewJob->kill(KJob::Quietly);
        m_previewJob.clear();
    }
    for (const QString &key : std::as_const(m_thumbs))
        ThumbnailStore::remove(key);
    m_thumbs.clear();
    m_thumbLru.clear();
    m_previews.clear();
}

QString FolderModel::thumbnailFor(const QUrl &url) const
{
    const QString key = m_thumbs.value(url);
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
    clearPreviews();
    m_dirModel->openUrl(m_url, KDirModel::Reload);
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
        const QString key = m_thumbs.take(url);
        if (!key.isEmpty())
            ThumbnailStore::remove(key);
        m_thumbLru.remove(url);
        m_previews.cancel(url);
        m_previews.forget(url);
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
