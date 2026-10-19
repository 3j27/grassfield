#include "filesapp.h"

#include "filelogic.h"
#include "foldermodel.h"
#include "placesmodel.h"
#include "taglogic.h"
#include "tagstore.h"

#include <QClipboard>
#include <QDir>
#include <QFileInfo>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMimeData>
#include <QMimeDatabase>
#include <QProcess>
#include <QRegularExpression>
#include <QStorageInfo>

#include <KApplicationTrader>
#include <KIO/ApplicationLauncherJob>
#include <KIO/CopyJob>
#include <KIO/DeleteJob>
#include <KIO/DirectorySizeJob>
#include <KIO/EmptyTrashJob>
#include <KIO/FileUndoManager>
#include <KIO/JobUiDelegateFactory>
#include <KIO/MkdirJob>
#include <KIO/OpenUrlJob>
#include <KIO/Paste>
#include <KIO/PasteJob>
#include <KIO/RestoreJob>
#include <KIO/SimpleJob>
#include <KUrlMimeData>

namespace
{
const QString kGnomeCopied = QStringLiteral("x-special/gnome-copied-files");

FolderModel *asFolder(QObject *object)
{
    return qobject_cast<FolderModel *>(object);
}

// KIO's delegate provides its conflict ("file exists") and Open With dialogs; errors are shown by the
// app itself (operationFailed), so automatic error dialogs stay off.
void attachDelegate(KJob *job)
{
    job->setUiDelegate(KIO::createDefaultJobUiDelegate(KJobUiDelegate::AutoHandlingDisabled, nullptr));
}

QUrl childUrl(const QUrl &directory, const QString &name)
{
    QUrl u = directory.adjusted(QUrl::StripTrailingSlash);
    u.setPath(u.path() + QLatin1Char('/') + name);
    return u;
}

bool localExists(const QUrl &url)
{
    return url.isLocalFile() && QFileInfo::exists(url.toLocalFile());
}

// Scripted scenarios set GRASSFIELD_FILES_NO_LAUNCH=1: opening reports an error instead of starting
// applications (a test must never launch the owner's apps). Logged so the scenario can assert it.
bool launchingBlocked()
{
    if (qEnvironmentVariableIntValue("GRASSFIELD_FILES_NO_LAUNCH") != 1)
        return false;
    qInfo("grassfield-files: launch blocked (GRASSFIELD_FILES_NO_LAUNCH=1)");
    return true;
}

// Files handed to one Glance at most.
constexpr int kMaxGlanceFiles = 50;

// Tags listed in the sidebar's Tags section at most.
constexpr int kMaxKnownTags = 64;
constexpr int kMaxHiddenTags = 256;

// Singular/plural pair (no translation catalogs with numerus forms yet, like the Settings app).
QString countText(const QString &one, const QString &many, qsizetype n)
{
    return n == 1 ? one : many.arg(n);
}

QList<QUrl> clipboardUrls()
{
    const QMimeData *data = QGuiApplication::clipboard()->mimeData();
    return data ? KUrlMimeData::urlsFromMimeData(data) : QList<QUrl>();
}
} // namespace

FilesApp::FilesApp(const QList<QUrl> &initialUrls, QObject *parent)
    : QObject(parent)
    , m_initialUrls(initialUrls)
    , m_places(new PlacesModel(this))
    , m_settings(QStringLiteral("Grassfield"), QStringLiteral("Files"))
{
    auto *undo = KIO::FileUndoManager::self();
    connect(undo, &KIO::FileUndoManager::undoAvailable, this, &FilesApp::undoChanged);
    connect(undo, &KIO::FileUndoManager::redoAvailable, this, &FilesApp::undoChanged);
    connect(undo, &KIO::FileUndoManager::undoTextChanged, this, &FilesApp::undoChanged);
    connect(undo, &KIO::FileUndoManager::redoTextChanged, this, &FilesApp::undoChanged);
    connect(QGuiApplication::clipboard(), &QClipboard::dataChanged, this, &FilesApp::clipboardChanged);
    connect(m_places, &PlacesModel::error, this, &FilesApp::operationFailed);

    // Appearance follows grassfield.json like every Grassfield surface (read only).
    const QString file = configFile();
    // Never create the directory: this app only reads the file (defaults apply until it exists).
    const QString configDir = QFileInfo(file).absolutePath();
    if (QFileInfo(configDir).isDir())
        m_watcher.addPath(configDir);
    if (QFileInfo::exists(file))
        m_watcher.addPath(file);
    const auto reread = [this] {
        const QString f = configFile();
        if (QFileInfo::exists(f) && !m_watcher.files().contains(f))
            m_watcher.addPath(f);
        readAppearance();
    };
    connect(&m_watcher, &QFileSystemWatcher::fileChanged, this, reread);
    connect(&m_watcher, &QFileSystemWatcher::directoryChanged, this, reread);
    readAppearance();

    // The sidebar's Tags section: the tags seen in use (on shown items, set or searched in Files), kept across sessions.
    m_knownTags = TagLogic::displayOrder(m_settings.value(QStringLiteral("tags/known")).toStringList()).mid(0, kMaxKnownTags);
    m_hiddenTags = m_settings.value(QStringLiteral("tags/hidden")).toStringList().mid(0, kMaxHiddenTags);
    publishKnownTags();
}

QString FilesApp::configFile() const
{
    const QString dev = qEnvironmentVariable("GRASSFIELD_CONFIG_HOME");
    if (!dev.isEmpty())
        return dev + QStringLiteral("/grassfield.json");
    const QString xdg = qEnvironmentVariable("XDG_CONFIG_HOME");
    return (xdg.isEmpty() ? QDir::homePath() + QStringLiteral("/.config") : xdg) + QStringLiteral("/grassfield/grassfield.json");
}

void FilesApp::readAppearance()
{
    QFile f(configFile());
    QJsonObject root;
    if (f.open(QIODevice::ReadOnly))
        root = QJsonDocument::fromJson(f.read(4 * 1024 * 1024)).object();
    // Same rule as the shell and Settings: anything but "light" renders dark.
    const bool dark = root.value(QStringLiteral("appearance")).toString() != QLatin1String("light");
    const bool reduce = root.value(QStringLiteral("accessibility")).toObject().value(QStringLiteral("reduceMotion")).toBool(false);
    // Icon appearance: the same validation as the shell (unknown values fall back to the defaults).
    const QJsonObject icons = root.value(QStringLiteral("icons")).toObject();
    QString mode = icons.value(QStringLiteral("mode")).toString();
    if (!QStringList{QStringLiteral("dark"), QStringLiteral("clear"), QStringLiteral("tinted")}.contains(mode))
        mode = QStringLiteral("default");
    QString tint = icons.value(QStringLiteral("tint")).toString();
    static const QRegularExpression hex(QStringLiteral("^#[0-9a-fA-F]{6}$"));
    if (!hex.match(tint).hasMatch())
        tint = QStringLiteral("accent");
    if (dark != m_dark || reduce != m_reduceMotion || mode != m_iconMode || tint != m_iconTint) {
        m_dark = dark;
        m_reduceMotion = reduce;
        m_iconMode = mode;
        m_iconTint = tint;
        emit appearanceChanged();
    }
}

QObject *FilesApp::places() const
{
    return m_places;
}

QString FilesApp::homePath() const
{
    return QDir::homePath();
}

bool FilesApp::canUndo() const
{
    return KIO::FileUndoManager::self()->isUndoAvailable();
}

QString FilesApp::undoText() const
{
    return KIO::FileUndoManager::self()->undoText();
}

bool FilesApp::canRedo() const
{
    return KIO::FileUndoManager::self()->isRedoAvailable();
}

QString FilesApp::redoText() const
{
    return KIO::FileUndoManager::self()->redoText();
}

bool FilesApp::canPaste() const
{
    const QMimeData *data = QGuiApplication::clipboard()->mimeData();
    return data && KIO::canPasteMimeData(data);
}

int FilesApp::clipboardCount() const
{
    return int(clipboardUrls().size());
}

QString FilesApp::viewMode() const
{
    const QString mode = m_settings.value(QStringLiteral("view/mode"), QStringLiteral("icons")).toString();
    return mode == QLatin1String("list") || mode == QLatin1String("columns") || mode == QLatin1String("gallery") ? mode : QStringLiteral("icons");
}

void FilesApp::setViewMode(const QString &mode)
{
    if (mode == viewMode())
        return;
    m_settings.setValue(QStringLiteral("view/mode"), mode);
    emit prefsChanged();
}

int FilesApp::sortKey() const
{
    return qBound(0, m_settings.value(QStringLiteral("view/sortKey"), 0).toInt(), 3);
}

void FilesApp::setSortKey(int key)
{
    if (key == sortKey())
        return;
    m_settings.setValue(QStringLiteral("view/sortKey"), key);
    emit prefsChanged();
}

bool FilesApp::sortDescending() const
{
    return m_settings.value(QStringLiteral("view/sortDescending"), false).toBool();
}

void FilesApp::setSortDescending(bool on)
{
    if (on == sortDescending())
        return;
    m_settings.setValue(QStringLiteral("view/sortDescending"), on);
    emit prefsChanged();
}

bool FilesApp::foldersFirst() const
{
    return m_settings.value(QStringLiteral("view/foldersFirst"), true).toBool();
}

void FilesApp::setFoldersFirst(bool on)
{
    if (on == foldersFirst())
        return;
    m_settings.setValue(QStringLiteral("view/foldersFirst"), on);
    emit prefsChanged();
}

bool FilesApp::showHidden() const
{
    return m_settings.value(QStringLiteral("view/showHidden"), false).toBool();
}

void FilesApp::setShowHidden(bool on)
{
    if (on == showHidden())
        return;
    m_settings.setValue(QStringLiteral("view/showHidden"), on);
    emit prefsChanged();
}

bool FilesApp::galleryInfo() const
{
    return m_settings.value(QStringLiteral("view/galleryInfo"), true).toBool();
}

void FilesApp::setGalleryInfo(bool on)
{
    if (on == galleryInfo())
        return;
    m_settings.setValue(QStringLiteral("view/galleryInfo"), on);
    emit prefsChanged();
}

QObject *FilesApp::createFolderModel(QObject *parent)
{
    auto *model = new FolderModel(parent ? parent : this);
    connect(model, &FolderModel::tagsSeen, this, &FilesApp::noteTags);
    connect(this, &FilesApp::tagsChanged, model, &FolderModel::tagsChanged);
    return model;
}

QVariantList FilesApp::pathSegments(const QUrl &url) const
{
    QVariantList out;
    // A tag search: the segments of its folder, then the tag.
    const bool search = TagLogic::isSearchUrl(url);
    const QUrl folder = search ? TagLogic::searchFolder(url) : url;
    const QList<FileLogic::Segment> segments = FileLogic::pathSegments(folder, QDir::homePath(), tr("Computer"), tr("Trash"));
    for (const FileLogic::Segment &s : segments)
        out.append(QVariantMap{{QStringLiteral("label"), s.label}, {QStringLiteral("url"), s.url}});
    if (search)
        out.append(QVariantMap{{QStringLiteral("label"), TagLogic::displayName(TagLogic::searchTag(url))}, {QStringLiteral("url"), url}});
    return out;
}

QString FilesApp::formatSize(qint64 bytes) const
{
    return FileLogic::formatSize(bytes);
}

bool FilesApp::isValidFileName(const QString &name) const
{
    return FileLogic::isValidFileName(name);
}

int FilesApp::baseNameLength(const QString &name, bool isDir) const
{
    return FileLogic::baseNameLength(name, isDir);
}

bool FilesApp::defaultDescending(int sortKey) const
{
    return FileLogic::defaultDescending(FileLogic::SortKey(qBound(0, sortKey, 3)));
}

QString FilesApp::uriList(const QList<QUrl> &urls) const
{
    QStringList lines;
    for (const QUrl &u : urls)
        lines << QString::fromUtf8(u.toEncoded());
    return lines.join(QStringLiteral("\r\n")) + QStringLiteral("\r\n");
}

bool FilesApp::sameUrl(const QUrl &a, const QUrl &b) const
{
    return a.isValid() && a.adjusted(QUrl::StripTrailingSlash | QUrl::NormalizePathSegments) == b.adjusted(QUrl::StripTrailingSlash | QUrl::NormalizePathSegments);
}

bool FilesApp::isDirectChild(const QUrl &parent, const QUrl &child) const
{
    return child.isValid() && sameUrl(child.adjusted(QUrl::RemoveFilename | QUrl::StripTrailingSlash), parent);
}

QUrl FilesApp::resolveLocation(const QString &text, const QUrl &base) const
{
    const QString t = text.trimmed();
    if (t.isEmpty())
        return {};
    QString path;
    if (t == QLatin1String("~"))
        path = QDir::homePath();
    else if (t.startsWith(QLatin1String("~/")))
        path = QDir::homePath() + t.mid(1);
    else if (t.startsWith(QLatin1Char('/')))
        path = t;
    else if (t.contains(QLatin1String(":/")) || t.endsWith(QLatin1Char(':'))) {
        QUrl url(t.endsWith(QLatin1Char(':')) ? t + QLatin1Char('/') : t);
        if (url.isLocalFile())
            path = url.toLocalFile();
        else
            return url.isValid() ? url : QUrl();
    } else if (base.isLocalFile())
        path = QDir(base.toLocalFile()).filePath(t);
    else {
        QUrl url = base.adjusted(QUrl::StripTrailingSlash);
        url.setPath(url.path() + QLatin1Char('/') + t);
        return url;
    }
    const QFileInfo info(QDir::cleanPath(path));
    return info.isDir() ? QUrl::fromLocalFile(info.absoluteFilePath()) : QUrl();
}

void FilesApp::open(const QList<QUrl> &urls)
{
    if (!urls.isEmpty() && launchingBlocked()) {
        emit operationFailed(tr("Opening files is disabled in this session (GRASSFIELD_FILES_NO_LAUNCH)."));
        return;
    }
    for (const QUrl &url : urls) {
        auto *job = new KIO::OpenUrlJob(url, this);
        attachDelegate(job);
        // Never run programs or scripts from the file manager: they open in their associated app.
        job->setRunExecutables(false);
        connect(job, &KJob::result, this, [this, job] {
            if (job->error() && job->error() != KIO::ERR_USER_CANCELED)
                emit operationFailed(job->errorString());
        });
        job->start();
    }
}

QVariantList FilesApp::applicationsFor(const QList<QUrl> &urls) const
{
    QVariantList out;
    if (urls.isEmpty())
        return out;
    const QUrl &first = urls.first();
    QMimeDatabase db;
    const QMimeType type = first.isLocalFile() ? db.mimeTypeForFile(first.toLocalFile()) : db.mimeTypeForUrl(first);
    const KService::List services = KApplicationTrader::queryByMimeType(type.name());
    for (const KService::Ptr &s : services) {
        if (s->desktopEntryName() == QLatin1String("org.grassfield.files"))
            continue;
        out.append(QVariantMap{{QStringLiteral("id"), s->storageId()}, {QStringLiteral("name"), s->name()}});
    }
    return out;
}

void FilesApp::openWith(const QString &storageId, const QList<QUrl> &urls)
{
    const KService::Ptr service = KService::serviceByStorageId(storageId);
    if (!service) {
        emit operationFailed(tr("The application is no longer installed."));
        return;
    }
    if (launchingBlocked()) {
        emit operationFailed(tr("Opening files is disabled in this session (GRASSFIELD_FILES_NO_LAUNCH)."));
        return;
    }
    auto *job = new KIO::ApplicationLauncherJob(service, this);
    job->setUrls(urls);
    attachDelegate(job);
    connect(job, &KJob::result, this, [this, job] {
        if (job->error() && job->error() != KIO::ERR_USER_CANCELED)
            emit operationFailed(job->errorString());
    });
    job->start();
}

void FilesApp::glance(const QList<QUrl> &urls)
{
    // Glance shows local regular files only (it validates them again): folders and remote items are skipped.
    QStringList paths;
    for (const QUrl &url : urls) {
        if (url.isLocalFile() && QFileInfo(url.toLocalFile()).isFile() && paths.size() < kMaxGlanceFiles)
            paths << url.toLocalFile();
    }
    if (paths.isEmpty() || launchingBlocked())
        return;
    // GRASSFIELD_PREVIEW_CMD (dev) wins, then a grassfield-preview next to this binary, then the PATH.
    QStringList command = qEnvironmentVariable("GRASSFIELD_PREVIEW_CMD").split(QLatin1Char(' '), Qt::SkipEmptyParts);
    if (command.isEmpty()) {
        const QString sibling = QCoreApplication::applicationDirPath() + QStringLiteral("/grassfield-preview");
        command << (QFileInfo(sibling).isExecutable() ? sibling : QStringLiteral("grassfield-preview"));
    }
    const QString program = command.takeFirst();
    command.removeAll(QStringLiteral("--glance"));
    const QStringList args = command + QStringList{QStringLiteral("--glance"), QStringLiteral("--")} + paths;
    if (!QProcess::startDetached(program, args))
        emit operationFailed(tr("Glance could not be started: grassfield-preview was not found."));
}

void FilesApp::copyToClipboard(const QList<QUrl> &urls, bool cut)
{
    if (urls.isEmpty())
        return;
    auto *data = new QMimeData;
    data->setUrls(urls);
    KIO::setClipboardDataCut(data, cut);
    // GNOME file managers read their own format.
    QStringList gnome{cut ? QStringLiteral("cut") : QStringLiteral("copy")};
    for (const QUrl &u : urls)
        gnome << QString::fromUtf8(u.toEncoded());
    data->setData(kGnomeCopied, gnome.join(QLatin1Char('\n')).toUtf8());
    QGuiApplication::clipboard()->setMimeData(data);
}

void FilesApp::paste(const QUrl &destination, QObject *folder)
{
    const QMimeData *data = QGuiApplication::clipboard()->mimeData();
    if (!data || !KIO::canPasteMimeData(data))
        return;
    const bool cut = KIO::isClipboardDataCut(data);
    const QList<QUrl> urls = KUrlMimeData::urlsFromMimeData(data);
    // Copying items into their own folder makes "name copy" duplicates instead of a conflict.
    if (!cut && !urls.isEmpty()) {
        bool sameFolder = true;
        for (const QUrl &u : urls)
            sameFolder &= u.adjusted(QUrl::RemoveFilename | QUrl::StripTrailingSlash) == destination.adjusted(QUrl::StripTrailingSlash);
        if (sameFolder) {
            duplicate(urls, folder);
            return;
        }
    }
    // KIO::paste records the copy or move in FileUndoManager itself.
    KIO::PasteJob *job = KIO::paste(data, destination, KIO::HideProgressInfo);
    if (!job)
        return;
    attachDelegate(job);
    QPointer<QObject> target = folder;
    connect(job, &KIO::PasteJob::itemCreated, this, [target](const QUrl &url) {
        if (auto *f = asFolder(target))
            f->expect(url, false);
    });
    if (cut) {
        connect(job, &KJob::result, this, [job] {
            // A cut selection is consumed by its paste.
            if (!job->error())
                QGuiApplication::clipboard()->clear();
        });
    }
    track(job, countText(cut ? tr("Moving 1 item…") : tr("Copying 1 item…"), cut ? tr("Moving %1 items…") : tr("Copying %1 items…"), urls.size()));
}

void FilesApp::trash(const QList<QUrl> &urls)
{
    if (urls.isEmpty())
        return;
    KIO::CopyJob *job = KIO::trash(urls, KIO::HideProgressInfo);
    attachDelegate(job);
    KIO::FileUndoManager::self()->recordJob(KIO::FileUndoManager::Trash, urls, QUrl(QStringLiteral("trash:/")), job);
    track(job, countText(tr("Moving 1 item to the Trash…"), tr("Moving %1 items to the Trash…"), urls.size()));
}

void FilesApp::restore(const QList<QUrl> &urls)
{
    QList<QUrl> trashed;
    for (const QUrl &u : urls) {
        if (u.scheme() == QLatin1String("trash"))
            trashed << u;
    }
    if (trashed.isEmpty())
        return;
    KIO::RestoreJob *job = KIO::restoreFromTrash(trashed, KIO::HideProgressInfo);
    attachDelegate(job);
    track(job, countText(tr("Putting back 1 item…"), tr("Putting back %1 items…"), trashed.size()));
}

void FilesApp::deletePermanently(const QList<QUrl> &urls)
{
    QList<QUrl> trashed;
    for (const QUrl &u : urls) {
        if (u.scheme() == QLatin1String("trash"))
            trashed << u;
    }
    if (trashed.isEmpty())
        return;
    KIO::DeleteJob *job = KIO::del(trashed, KIO::HideProgressInfo);
    attachDelegate(job);
    track(job, countText(tr("Deleting 1 item…"), tr("Deleting %1 items…"), trashed.size()));
}

void FilesApp::emptyTrash()
{
    // Dev sessions never touch the real trash (trash:/ is the owner's), even when reached by typing the URL.
    if (devSession())
        return;
    KIO::EmptyTrashJob *job = KIO::emptyTrash();
    attachDelegate(job);
    track(job, tr("Emptying the Trash…"));
}

void FilesApp::newFolder(const QUrl &directory, QObject *folder)
{
    const QString name = FileLogic::uniqueName(tr("untitled folder"), [&directory](const QString &n) { return localExists(childUrl(directory, n)); });
    const QUrl url = childUrl(directory, name);
    KIO::MkdirJob *job = KIO::mkdir(url);
    attachDelegate(job);
    KIO::FileUndoManager::self()->recordJob(KIO::FileUndoManager::Mkdir, {}, url, job);
    QPointer<QObject> target = folder;
    connect(job, &KJob::result, this, [this, job, url, target] {
        if (job->error()) {
            emit operationFailed(job->errorString());
            return;
        }
        if (auto *f = asFolder(target))
            f->expect(url, true);
    });
}

void FilesApp::rename(const QUrl &url, const QString &newName, QObject *folder)
{
    if (newName == url.fileName())
        return;
    if (!FileLogic::isValidFileName(newName)) {
        emit operationFailed(tr("The name “%1” can’t be used. Names can’t be empty, “.” or “..”, contain “/”, or be longer than 255 bytes.").arg(newName));
        return;
    }
    const QUrl destination = childUrl(url.adjusted(QUrl::RemoveFilename | QUrl::StripTrailingSlash), newName);
    // A case-only change on a case-sensitive filesystem is a different name and fine.
    if (localExists(destination) && QFileInfo(destination.toLocalFile()).canonicalFilePath() != QFileInfo(url.toLocalFile()).canonicalFilePath()) {
        emit operationFailed(tr("The name “%1” is already taken. Please choose a different name.").arg(newName));
        return;
    }
    // KIO::moveAs (a CopyJob) rather than KIO::rename: FileUndoManager records CopyJob operations only.
    KIO::CopyJob *job = KIO::moveAs(url, destination, KIO::HideProgressInfo);
    attachDelegate(job);
    KIO::FileUndoManager::self()->recordJob(KIO::FileUndoManager::Rename, {url}, destination, job);
    QPointer<QObject> target = folder;
    connect(job, &KJob::result, this, [this, job, destination, target] {
        if (job->error()) {
            emit operationFailed(job->errorString());
            return;
        }
        if (auto *f = asFolder(target))
            f->expect(destination, false);
    });
}

void FilesApp::duplicate(const QList<QUrl> &urls, QObject *folder)
{
    QPointer<QObject> target = folder;
    for (const QUrl &url : urls) {
        if (url.scheme() == QLatin1String("trash"))
            continue;
        const QUrl directory = url.adjusted(QUrl::RemoveFilename | QUrl::StripTrailingSlash);
        const bool isDir = url.isLocalFile() && QFileInfo(url.toLocalFile()).isDir();
        const QString name = FileLogic::duplicateName(url.fileName(), isDir, tr("copy"), [&directory](const QString &n) { return localExists(childUrl(directory, n)); });
        const QUrl destination = childUrl(directory, name);
        KIO::CopyJob *job = KIO::copyAs(url, destination, KIO::HideProgressInfo);
        attachDelegate(job);
        KIO::FileUndoManager::self()->recordCopyJob(job);
        connect(job, &KJob::result, this, [job, destination, target] {
            if (!job->error()) {
                if (auto *f = asFolder(target))
                    f->expect(destination, false);
            }
        });
        track(job, tr("Duplicating “%1”…").arg(url.fileName()));
    }
}

void FilesApp::drop(const QList<QUrl> &urls, const QUrl &destination, QObject *folder)
{
    if (urls.isEmpty() || !destination.isValid())
        return;
    if (destination.scheme() == QLatin1String("trash")) {
        trash(urls);
        return;
    }
    // A drop on a tag search (its background, its path segment) tags the items, like a drop on the sidebar tag.
    if (TagLogic::isSearchUrl(destination)) {
        addTag(urls, TagLogic::searchTag(destination));
        return;
    }
    const QUrl dest = destination.adjusted(QUrl::StripTrailingSlash);
    QList<QUrl> sources;
    for (const QUrl &u : urls) {
        const QUrl clean = u.adjusted(QUrl::StripTrailingSlash);
        if (clean == dest || clean.isParentOf(dest)) {
            emit operationFailed(tr("“%1” can’t be moved or copied into itself.").arg(clean.fileName()));
            return;
        }
        // Dropping an item on the folder it is already in does nothing.
        if (clean.adjusted(QUrl::RemoveFilename | QUrl::StripTrailingSlash) != dest)
            sources << clean;
    }
    if (sources.isEmpty())
        return;
    const Qt::KeyboardModifiers mods = QGuiApplication::queryKeyboardModifiers();
    bool copy = mods & (Qt::ControlModifier | Qt::AltModifier);
    if (!copy) {
        // Across filesystems a drop copies, like the macOS file manager.
        const QString destDevice = dest.isLocalFile() ? QString::fromUtf8(QStorageInfo(dest.toLocalFile()).device()) : QString();
        for (const QUrl &u : std::as_const(sources)) {
            if (!u.isLocalFile() || destDevice.isEmpty() || QString::fromUtf8(QStorageInfo(u.toLocalFile()).device()) != destDevice)
                copy = true;
        }
    }
    KIO::CopyJob *job = copy ? KIO::copy(sources, dest, KIO::HideProgressInfo) : KIO::move(sources, dest, KIO::HideProgressInfo);
    attachDelegate(job);
    if (copy)
        KIO::FileUndoManager::self()->recordCopyJob(job);
    else
        KIO::FileUndoManager::self()->recordJob(KIO::FileUndoManager::Move, sources, dest, job);
    QPointer<QObject> target = folder;
    for (const QUrl &u : std::as_const(sources)) {
        if (auto *f = asFolder(target))
            f->expect(childUrl(dest, u.fileName()), false);
    }
    track(job, countText(copy ? tr("Copying 1 item…") : tr("Moving 1 item…"), copy ? tr("Copying %1 items…") : tr("Moving %1 items…"), sources.size()));
}

void FilesApp::undo()
{
    KIO::FileUndoManager::self()->undo();
}

void FilesApp::redo()
{
    KIO::FileUndoManager::self()->redo();
}

void FilesApp::directorySize(const QUrl &url, const QJSValue &callback)
{
    KIO::DirectorySizeJob *job = KIO::directorySize(url);
    QJSValue cb = callback;
    connect(job, &KJob::result, this, [job, cb]() mutable {
        if (!cb.isCallable())
            return;
        if (job->error())
            cb.call({QJSValue(-1), QJSValue(0), QJSValue(0)});
        else
            cb.call({QJSValue(double(job->totalSize())), QJSValue(double(job->totalFiles())), QJSValue(double(job->totalSubdirs()))});
    });
}

QStringList FilesApp::colorTagNames() const
{
    QStringList names;
    for (int i = 0; i < TagLogic::kColorCount; ++i)
        names.append(TagLogic::displayName(TagLogic::colorKey(i)));
    return names;
}

QString FilesApp::tagsReason(const QUrl &url, TagStore::Support support) const
{
    switch (support) {
    case TagStore::Support::Supported:
        break;
    case TagStore::Support::Missing:
        return tr("“%1” is no longer there.").arg(url.fileName());
    case TagStore::Support::Link:
        return tr("Links can’t carry tags.");
    case TagStore::Support::NotRegular:
        return tr("Only files and folders can be tagged.");
    case TagStore::Support::ReadOnly:
        return tr("Read-only items can’t be tagged.");
    case TagStore::Support::NoXattr:
        return tr("This volume can’t store tags.");
    }
    return QString();
}

QString FilesApp::schemeReason(const QUrl &url) const
{
    if (url.scheme() == QLatin1String("trash"))
        return tr("Items in the Trash can’t be tagged.");
    if (!url.isLocalFile())
        return tr("Tags are available for files on this computer only.");
    return QString();
}

QString FilesApp::tagsUnavailable(const QList<QUrl> &urls) const
{
    // Answered from the short-lived cache (the selection is asked on every selection change); a write decides afresh.
    for (const QUrl &url : urls) {
        const QString scheme = schemeReason(url);
        if (!scheme.isEmpty())
            return scheme;
        const QString why = tagsReason(url, m_tagCache.info(url.toLocalFile()).support);
        if (!why.isEmpty())
            return why;
    }
    return QString();
}

QVariantList FilesApp::colorTagStates(const QList<QUrl> &urls) const
{
    QList<QStringList> lists;
    for (const QUrl &url : urls) {
        if (url.isLocalFile())
            lists.append(m_tagCache.info(url.toLocalFile()).tags);
    }
    QVariantList out;
    const QList<int> states = TagLogic::colorStates(lists);
    for (int s : states)
        out.append(s);
    return out;
}

QStringList FilesApp::tagNamesOf(const QUrl &url) const
{
    QStringList names;
    if (!url.isLocalFile())
        return names;
    const QStringList tags = TagLogic::displayOrder(TagStore::read(url.toLocalFile()));
    for (const QString &tag : tags)
        names.append(TagLogic::displayName(tag));
    return names;
}

void FilesApp::toggleColorTag(const QList<QUrl> &urls, int index)
{
    const QString key = TagLogic::colorKey(index);
    if (key.isEmpty() || urls.isEmpty())
        return;
    // The same rule as the menu's checkmark (colour names match without regard to case: another application's "red" is
    // Red), read afresh. A read that fails stops everything: nothing is written from a guess.
    bool all = true;
    for (const QUrl &url : urls) {
        if (!url.isLocalFile()) {
            all = false;
            continue;
        }
        QByteArray stored;
        QString error;
        if (!TagStore::readRawChecked(url.toLocalFile(), &stored, &error)) {
            emit operationFailed(tr("The tags of “%1” couldn’t be read: %2").arg(url.fileName(), error));
            return;
        }
        all = all && TagLogic::ownsTag(stored, key);
    }
    rewriteTags(urls, key, !all);
}

void FilesApp::addTag(const QList<QUrl> &urls, const QString &tag)
{
    if (tag.trimmed().isEmpty())
        return;
    rewriteTags(urls, tag, true);
}

void FilesApp::rewriteTags(const QList<QUrl> &urls, const QString &tag, bool on)
{
    QList<QUrl> changed;
    QStringList failed;
    QString reason;
    QStringList written;
    for (const QUrl &url : urls) {
        QString why = schemeReason(url);
        if (why.isEmpty())
            why = tagsReason(url, TagStore::support(url.toLocalFile()));
        if (!why.isEmpty()) {
            failed.append(url.fileName());
            reason = why;
            continue;
        }
        const QString path = url.toLocalFile();
        m_tagCache.invalidate(path);
        // A failed read must not become "no tags": the write would replace what other applications stored.
        QByteArray before;
        QString readError;
        if (!TagStore::readRawChecked(path, &before, &readError)) {
            failed.append(url.fileName());
            reason = readError;
            continue;
        }
        const QByteArray after = TagLogic::applyTag(before, tag, on);
        if (after == before)
            continue;
        QString error;
        if (!TagStore::writeRaw(path, after, &error)) {
            failed.append(url.fileName());
            reason = error;
            continue;
        }
        changed.append(url);
        written += TagLogic::parse(after);
        m_tagCache.invalidate(path);
    }
    if (!changed.isEmpty()) {
        // Tagging again is the way back to the sidebar for a tag removed from it (there is no Tags settings pane).
        if (on)
            unhideTag(tag);
        noteTags(written);
        ++m_tagRevision;
        emit tagRevisionChanged();
        emit tagsChanged(changed);
    }
    if (failed.size() == 1)
        emit operationFailed(tr("The tags of “%1” couldn’t be changed: %2").arg(failed.first(), reason));
    else if (failed.size() > 1)
        emit operationFailed(tr("The tags of %1 items couldn’t be changed: %2").arg(failed.size()).arg(reason));
}

QString FilesApp::tagName(const QString &tag) const
{
    return TagLogic::displayName(tag);
}

int FilesApp::tagColor(const QString &tag) const
{
    return TagLogic::colorIndex(tag);
}

QUrl FilesApp::tagSearchUrl(const QString &tag, const QUrl &from) const
{
    QUrl folder;
    if (TagLogic::isSearchUrl(from))
        folder = TagLogic::searchFolder(from);
    else if (from.isLocalFile() && QFileInfo(from.toLocalFile()).isDir())
        folder = from;
    else
        folder = QUrl::fromLocalFile(QDir::homePath());
    return TagLogic::searchUrl(tag, folder);
}

bool FilesApp::isTagSearch(const QUrl &url) const
{
    return TagLogic::isSearchUrl(url);
}

QString FilesApp::searchedTag(const QUrl &url) const
{
    return TagLogic::searchTag(url);
}

void FilesApp::noteTags(const QStringList &tags)
{
    // A tag removed from the sidebar stays off it (macOS: Remove from Sidebar hides it; files keep the tag).
    const QStringList next = TagLogic::mergeKnown(m_knownTags, m_hiddenTags, tags, kMaxKnownTags);
    if (next == m_knownTags)
        return;
    m_knownTags = next;
    m_settings.setValue(QStringLiteral("tags/known"), m_knownTags);
    publishKnownTags();
}

void FilesApp::forgetTag(const QString &tag)
{
    if (tag.trimmed().isEmpty())
        return;
    if (!TagLogic::hasTag(m_hiddenTags, tag)) {
        m_hiddenTags = TagLogic::withTag(m_hiddenTags, tag, true);
        // The oldest entries go first when the list is full.
        while (m_hiddenTags.size() > kMaxHiddenTags)
            m_hiddenTags.removeFirst();
        m_settings.setValue(QStringLiteral("tags/hidden"), m_hiddenTags);
        emit hiddenTagsChanged();
    }
    const QStringList next = TagLogic::withTag(m_knownTags, tag, false);
    if (next == m_knownTags)
        return;
    m_knownTags = next;
    m_settings.setValue(QStringLiteral("tags/known"), m_knownTags);
    publishKnownTags();
}

void FilesApp::unhideTag(const QString &tag)
{
    if (!TagLogic::hasTag(m_hiddenTags, tag))
        return;
    m_hiddenTags = TagLogic::withTag(m_hiddenTags, tag, false);
    m_settings.setValue(QStringLiteral("tags/hidden"), m_hiddenTags);
    emit hiddenTagsChanged();
}

void FilesApp::showTag(const QString &tag)
{
    unhideTag(tag);
    // Listed at once, not only when an item holding it is shown next.
    noteTags({tag});
}

void FilesApp::publishKnownTags()
{
    m_places->setTags(m_knownTags);
}

void FilesApp::track(KJob *job, const QString &activity)
{
    m_jobs.append(job);
    m_activity = activity;
    m_activityPercent = -1;
    emit activityChanged();
    connect(job, &KJob::percentChanged, this, [this, job](KJob *, unsigned long percent) {
        if (!m_jobs.isEmpty() && m_jobs.last() == job) {
            m_activityPercent = int(percent);
            emit activityChanged();
        }
    });
    connect(job, &KJob::result, this, [this, job] {
        if (job->error() && job->error() != KIO::ERR_USER_CANCELED)
            emit operationFailed(job->errorString());
        m_jobs.removeAll(job);
        m_jobs.removeIf([](const QPointer<KJob> &p) { return p.isNull(); });
        m_activity = m_jobs.isEmpty() ? QString() : m_activity;
        m_activityPercent = -1;
        emit activityChanged();
    });
}
