#include "placesmodel.h"

#include "applicationslogic.h"
#include "recents.h"
#include "runmode.h"
#include "taglogic.h"

#include <QDir>
#include <QIcon>
#include <QStandardPaths>

#include <KCoreDirLister>
#include <KProtocolInfo>
#include <Solid/Device>
#include <Solid/DeviceNotifier>
#include <Solid/OpticalDrive>
#include <Solid/StorageAccess>
#include <Solid/StorageDrive>
#include <Solid/StorageVolume>

namespace
{
// A dev session (runmode.h; nested, on the owner's machine) must never see or touch the owner's real trash:
// KIO's trash:/ is served by the session, so the Trash place and its listing are off (ADR-0011).
bool devSession()
{
    return grassfield::apps::runmode::dev();
}

QString symbolic(const QString &icon, const QString &fallback)
{
    const QString name = icon + QStringLiteral("-symbolic");
    return QIcon::hasThemeIcon(name) ? name : fallback;
}

Solid::StorageDrive *driveOf(const Solid::Device &device)
{
    Solid::Device d = device;
    while (d.isValid() && !d.is<Solid::StorageDrive>())
        d = d.parent();
    return d.isValid() ? d.as<Solid::StorageDrive>() : nullptr;
}
} // namespace

PlacesModel::PlacesModel(QObject *parent, const DiskProbe::Options &disk)
    : QAbstractListModel(parent)
    , m_disk(disk)
{
    connect(&m_disk, &DiskProbe::answered, this, [this](int token, const QHash<QString, int> &kinds) {
        if (!m_folderTokens.remove(token))
            return;
        bool changed = false;
        for (auto it = kinds.cbegin(); it != kinds.cend(); ++it) {
            if (m_folderKinds.value(it.key(), 2) != it.value())
                changed = true;
            m_folderKinds.insert(it.key(), it.value());
        }
        if (changed)
            relist();
    });
    // A folder that did not answer comes back when its read returns (the Finder shows a server that is back).
    connect(&m_disk, &DiskProbe::answeredLate, this, [this](const QString &path, int kind) {
        if (!m_folderKinds.contains(path) || m_folderKinds.value(path) == kind)
            return;
        m_folderKinds.insert(path, kind);
        relist();
    });
    rebuild();
    auto *notifier = Solid::DeviceNotifier::instance();
    connect(notifier, &Solid::DeviceNotifier::deviceAdded, this, &PlacesModel::rebuild);
    connect(notifier, &Solid::DeviceNotifier::deviceRemoved, this, &PlacesModel::rebuild);

    // The Trash entry shows full/empty from a KIO listing of trash:/ (kept up to date by KDirWatch).
    if (devSession())
        return;
    m_trashLister = new KCoreDirLister(this);
    m_trashLister->setAutoErrorHandlingEnabled(false);
    m_trashLister->setDelayedMimeTypes(true);
    const auto update = [this] {
        const bool empty = m_trashLister->items().isEmpty();
        if (empty == m_trashEmpty)
            return;
        m_trashEmpty = empty;
        emit trashEmptyChanged();
        for (int i = 0; i < m_places.size(); ++i) {
            if (m_places[i].kind == QLatin1String("trash")) {
                m_places[i].iconName = empty ? QStringLiteral("user-trash-symbolic") : symbolic(QStringLiteral("user-trash-full"), QStringLiteral("user-trash-symbolic"));
                emit dataChanged(index(i), index(i), {IconNameRole});
            }
        }
    };
    connect(m_trashLister, &KCoreDirLister::itemsAdded, this, update);
    connect(m_trashLister, &KCoreDirLister::itemsDeleted, this, update);
    connect(m_trashLister, qOverload<>(&KCoreDirLister::completed), this, update);
    connect(m_trashLister, qOverload<>(&KCoreDirLister::clear), this, update);
    m_trashLister->openUrl(QUrl(QStringLiteral("trash:/")));
}

bool PlacesModel::networkAvailable() const
{
    return KProtocolInfo::isKnownProtocol(QStringLiteral("smb")) || KProtocolInfo::isKnownProtocol(QStringLiteral("sftp"));
}

void PlacesModel::rebuild()
{
    relist();
    QStringList folders;
    for (const Place &p : std::as_const(m_places))
        if (p.kind == QLatin1String("folder"))
            folders << p.url.toLocalFile();
    // The standard folders the list may not show (one answered missing before) are asked again too. One call each: a hung
    // one keeps no other from its answer.
    for (auto it = m_folderKinds.cbegin(); it != m_folderKinds.cend(); ++it)
        if (!folders.contains(it.key()))
            folders << it.key();
    m_folderTokens.clear();
    for (const QString &folder : std::as_const(folders))
        m_folderTokens.insert(m_disk.probe({folder}));
}

void PlacesModel::relist()
{
    QList<Place> places;
    const QString home = QDir::homePath();
    // Recents first, under no heading (macOS 27 Finder; decision F-5).
    Place recents;
    recents.section = QStringLiteral("recents");
    recents.name = tr("Recents");
    recents.url = Recents::locationUrl();
    recents.iconName = symbolic(QStringLiteral("document-open-recent"), QStringLiteral("folder-symbolic"));
    recents.kind = QStringLiteral("recents");
    places.append(recents);
    struct Standard {
        QStandardPaths::StandardLocation location;
        QString name;
        QString icon;
    };
    const QList<Standard> standard = {
        {QStandardPaths::HomeLocation, tr("Home"), QStringLiteral("user-home-symbolic")},
        {QStandardPaths::DesktopLocation, tr("Desktop"), QStringLiteral("user-desktop-symbolic")},
        {QStandardPaths::DocumentsLocation, tr("Documents"), QStringLiteral("folder-documents-symbolic")},
        {QStandardPaths::DownloadLocation, tr("Downloads"), QStringLiteral("folder-download-symbolic")},
        {QStandardPaths::PicturesLocation, tr("Pictures"), QStringLiteral("folder-pictures-symbolic")},
        {QStandardPaths::MusicLocation, tr("Music"), QStringLiteral("folder-music-symbolic")},
        {QStandardPaths::MoviesLocation, tr("Videos"), QStringLiteral("folder-videos-symbolic")},
    };
    for (const Standard &s : standard) {
        // Finder's Favorites: the Applications folder comes before Desktop, Documents and Downloads.
        if (s.location == QStandardPaths::DesktopLocation) {
            Place apps;
            apps.section = QStringLiteral("favorites");
            apps.name = tr("Applications");
            apps.url = ApplicationsLogic::locationUrl();
            apps.iconName = symbolic(QStringLiteral("folder-applications"), symbolic(QStringLiteral("applications-all"), QStringLiteral("folder-symbolic")));
            apps.kind = QStringLiteral("applications");
            places.append(apps);
        }
        const QString path = QDir::cleanPath(QStandardPaths::writableLocation(s.location));
        // Only folders that exist (the disk's answer; a folder not asked yet is listed); xdg-user-dirs maps missing ones to
        // $HOME, which is listed once (compared as paths: the disk is not read on this thread).
        if (path.isEmpty() || path == QLatin1String(".") || (s.location != QStandardPaths::HomeLocation && path == QDir::cleanPath(home)))
            continue;
        const int kind = m_folderKinds.value(path, 2);
        if (kind == 0 || kind == 1)
            continue;
        Place p;
        p.section = QStringLiteral("favorites");
        p.name = s.name;
        p.url = QUrl::fromLocalFile(path);
        p.iconName = s.icon;
        p.kind = QStringLiteral("folder");
        p.unavailable = kind == DiskProbe::kNotResponding;
        places.append(p);
    }

    // Saved searches the user added to the sidebar, after the folders (the Finder's Favorites).
    for (const SavedSearch &search : std::as_const(m_savedSearches)) {
        Place p;
        p.section = QStringLiteral("favorites");
        p.name = search.name;
        p.url = search.url;
        p.iconName = symbolic(QStringLiteral("folder-saved-search"), QStringLiteral("folder-symbolic"));
        p.kind = QStringLiteral("savedSearch");
        p.tag = search.file;
        places.append(p);
    }

    Place computer;
    computer.section = QStringLiteral("locations");
    computer.name = tr("Computer");
    computer.url = QUrl::fromLocalFile(QStringLiteral("/"));
    computer.iconName = symbolic(QStringLiteral("drive-harddisk"), QStringLiteral("folder-symbolic"));
    computer.kind = QStringLiteral("volume");
    places.append(computer);
    places += devicePlaces();

    if (networkAvailable()) {
        Place network;
        network.section = QStringLiteral("locations");
        network.name = tr("Network");
        network.url = QUrl(QStringLiteral("remote:/"));
        network.iconName = symbolic(QStringLiteral("network-workgroup"), QStringLiteral("folder-remote-symbolic"));
        network.kind = QStringLiteral("network");
        places.append(network);
    }

    if (!devSession()) {
        Place trash;
        trash.section = QStringLiteral("locations");
        trash.name = tr("Trash");
        trash.url = QUrl(QStringLiteral("trash:/"));
        trash.iconName = m_trashEmpty ? QStringLiteral("user-trash-symbolic") : symbolic(QStringLiteral("user-trash-full"), QStringLiteral("user-trash-symbolic"));
        trash.kind = QStringLiteral("trash");
        places.append(trash);
    }

    for (const QString &tag : std::as_const(m_tags)) {
        Place p;
        p.section = QStringLiteral("tags");
        p.name = TagLogic::displayName(tag);
        p.kind = QStringLiteral("tag");
        p.tag = tag;
        p.tagColor = TagLogic::colorIndex(tag);
        places.append(p);
    }

    beginResetModel();
    m_places = places;
    endResetModel();
}

QList<PlacesModel::Place> PlacesModel::devicePlaces()
{
    QList<Place> out;
    const QList<Solid::Device> devices = Solid::Device::listFromType(Solid::DeviceInterface::StorageAccess);
    for (const Solid::Device &device : devices) {
        const auto *access = device.as<Solid::StorageAccess>();
        const auto *volume = device.as<Solid::StorageVolume>();
        if (!access || access->isIgnored())
            continue;
        if (volume && (volume->isIgnored() || volume->usage() != Solid::StorageVolume::FileSystem))
            continue;
        const auto *drive = driveOf(device);
        Place p;
        p.section = QStringLiteral("locations");
        p.name = volume && !volume->label().isEmpty() ? volume->label() : device.description();
        p.udi = device.udi();
        p.mounted = access->isAccessible();
        p.url = p.mounted ? QUrl::fromLocalFile(access->filePath()) : QUrl();
        p.iconName = symbolic(device.icon(), symbolic(QStringLiteral("drive-removable-media"), QStringLiteral("folder-symbolic")));
        p.kind = QStringLiteral("volume");
        p.ejectable = p.mounted && drive && (drive->isRemovable() || drive->isHotpluggable());
        out.append(p);
        // Follow mounts and unmounts done elsewhere.
        connect(access, &Solid::StorageAccess::accessibilityChanged, this, &PlacesModel::rebuild, Qt::UniqueConnection);
    }
    return out;
}

int PlacesModel::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : int(m_places.size());
}

QVariant PlacesModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() >= m_places.size())
        return {};
    const Place &p = m_places.at(index.row());
    switch (role) {
    case Qt::DisplayRole:
    case NameRole:
        return p.name;
    case SectionRole:
        return p.section;
    case UrlRole:
        return p.url;
    case IconNameRole:
        return p.iconName;
    case KindRole:
        return p.kind;
    case UdiRole:
        return p.udi;
    case MountedRole:
        return p.mounted;
    case EjectableRole:
        return p.ejectable;
    case BusyRole:
        return p.busy;
    case TagRole:
        return p.tag;
    case TagColorRole:
        return p.tagColor;
    case UnavailableRole:
        return p.unavailable;
    }
    return {};
}

QHash<int, QByteArray> PlacesModel::roleNames() const
{
    return {{SectionRole, "section"}, {NameRole, "name"},       {UrlRole, "url"},
            {IconNameRole, "iconName"}, {KindRole, "kind"},     {UdiRole, "udi"},
            {MountedRole, "mounted"},   {EjectableRole, "ejectable"}, {BusyRole, "busy"},
            {TagRole, "tag"},           {TagColorRole, "tagColor"},   {UnavailableRole, "unavailable"}};
}

void PlacesModel::setSavedSearches(const QList<SavedSearch> &searches)
{
    const bool same = searches.size() == m_savedSearches.size()
                      && std::equal(searches.cbegin(), searches.cend(), m_savedSearches.cbegin(), [](const SavedSearch &a, const SavedSearch &b) {
                             return a.name == b.name && a.url == b.url && a.file == b.file;
                         });
    if (same)
        return;
    m_savedSearches = searches;
    relist();
}

void PlacesModel::setTags(const QStringList &tags)
{
    if (tags == m_tags)
        return;
    m_tags = tags;
    relist();
}

int PlacesModel::rowForUrl(const QUrl &url) const
{
    // A tag search highlights its tag.
    if (TagLogic::isSearchUrl(url)) {
        const QString tag = TagLogic::searchTag(url);
        for (int i = 0; i < m_places.size(); ++i) {
            if (m_places[i].kind == QLatin1String("tag") && TagLogic::sameTag(m_places[i].tag, tag))
                return i;
        }
        return -1;
    }
    const QUrl clean = url.adjusted(QUrl::StripTrailingSlash);
    for (int i = 0; i < m_places.size(); ++i) {
        if (m_places[i].url.isValid() && m_places[i].url.adjusted(QUrl::StripTrailingSlash) == clean)
            return i;
    }
    return -1;
}

void PlacesModel::setBusy(const QString &udi, bool busy)
{
    for (int i = 0; i < m_places.size(); ++i) {
        if (m_places[i].udi == udi) {
            m_places[i].busy = busy;
            emit dataChanged(index(i), index(i), {BusyRole});
        }
    }
}

void PlacesModel::mount(int row)
{
    if (row < 0 || row >= m_places.size() || m_places[row].udi.isEmpty())
        return;
    const QString udi = m_places[row].udi;
    Solid::Device device(udi);
    auto *access = device.as<Solid::StorageAccess>();
    if (!access)
        return;
    if (access->isAccessible()) {
        emit mounted(QUrl::fromLocalFile(access->filePath()));
        return;
    }
    connect(
        access, &Solid::StorageAccess::setupDone, this,
        [this, udi](Solid::ErrorType error, const QVariant &errorData, const QString &) {
            setBusy(udi, false);
            if (error != Solid::NoError) {
                emit this->error(errorData.toString().isEmpty() ? tr("The volume could not be mounted.") : errorData.toString());
                return;
            }
            Solid::Device d(udi);
            if (auto *a = d.as<Solid::StorageAccess>())
                emit mounted(QUrl::fromLocalFile(a->filePath()));
        },
        Qt::SingleShotConnection);
    setBusy(udi, true);
    access->setup();
}

void PlacesModel::eject(int row)
{
    if (row < 0 || row >= m_places.size() || m_places[row].udi.isEmpty())
        return;
    const QString udi = m_places[row].udi;
    Solid::Device device(udi);
    auto *access = device.as<Solid::StorageAccess>();
    if (!access)
        return;
    connect(
        access, &Solid::StorageAccess::teardownDone, this,
        [this, udi](Solid::ErrorType error, const QVariant &errorData, const QString &) {
            setBusy(udi, false);
            if (error != Solid::NoError) {
                emit this->error(errorData.toString().isEmpty() ? tr("The volume could not be ejected.") : errorData.toString());
                return;
            }
            // Optical media also leave the drive.
            Solid::Device d(udi);
            Solid::Device parent = d.parent();
            if (parent.isValid() && parent.is<Solid::OpticalDrive>())
                parent.as<Solid::OpticalDrive>()->eject();
        },
        Qt::SingleShotConnection);
    setBusy(udi, true);
    access->teardown();
}
