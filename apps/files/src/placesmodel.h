#pragma once

#include "diskprobe.h"

#include <QAbstractListModel>
#include <QHash>
#include <QSet>
#include <QList>
#include <QStringList>
#include <QUrl>

class KCoreDirLister;

// Sidebar entries: Favorites (Home, Applications, the standard user folders that exist), Locations (the system volume and
// Solid storage volumes, Network only when a KIO smb/sftp worker is installed, Trash) and Tags (the tags in use,
// FilesApp: colour tags first; a tag entry has no URL of its own, the sidebar searches it in the shown folder).
// Mount and eject go through Solid::StorageAccess (udisks2 + polkit); nothing is mounted by hand. Whether each standard
// folder exists is asked off the GUI thread (DiskProbe, ADR-0035 4b-18): the list comes at once, a folder that is not there
// leaves it when the disk answers, and one that does not answer is listed dimmed ("unavailable"), as the Finder shows a
// server that went away, until its read returns (DiskProbe::answeredLate); Files and grassfield-portal's panels never wait on
// a hung mount for their sidebar.
class PlacesModel : public QAbstractListModel
{
    Q_OBJECT
    Q_PROPERTY(bool trashEmpty READ trashEmpty NOTIFY trashEmptyChanged)
    Q_PROPERTY(bool networkAvailable READ networkAvailable CONSTANT)

public:
    enum Roles {
        SectionRole = Qt::UserRole + 1,
        NameRole,
        UrlRole,
        IconNameRole,
        KindRole,
        UdiRole,
        MountedRole,
        EjectableRole,
        BusyRole,
        // Tag entries: the stored tag and its palette index (-1 for a tag without a colour).
        TagRole,
        TagColorRole,
        // A standard folder whose disk does not answer (a hung mount): listed, dimmed.
        UnavailableRole,
    };
    Q_ENUM(Roles)

    // `disk`: how the standard folders are asked about (the tests give a slow disk).
    explicit PlacesModel(QObject *parent = nullptr, const DiskProbe::Options &disk = {});

    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    bool trashEmpty() const { return m_trashEmpty; }
    bool networkAvailable() const;

    // Row whose URL is `url` or its closest ancestor among the entries (for the sidebar highlight), else -1.
    Q_INVOKABLE int rowForUrl(const QUrl &url) const;
    // Mount an unmounted volume; mounted(url) follows on success, error(message) on failure.
    Q_INVOKABLE void mount(int row);
    // Unmount (and eject when the drive supports it) a removable volume.
    Q_INVOKABLE void eject(int row);

    // The Tags section (stored tag names, display order).
    void setTags(const QStringList &tags);

signals:
    void trashEmptyChanged();
    void mounted(const QUrl &url);
    void error(const QString &message);

private:
    struct Place {
        QString section; // "recents" | "favorites" | "locations" | "tags"
        QString name;
        QUrl url;
        QString iconName;
        QString kind; // "recents" | "folder" | "applications" | "volume" | "network" | "trash" | "tag"
        QString udi;
        bool mounted = true;
        bool ejectable = false;
        bool busy = false;
        QString tag;
        int tagColor = -1;
        bool unavailable = false;
    };

    // The list again, then the standard folders asked about.
    void rebuild();
    // The list from what is known of the standard folders (no disk read).
    void relist();
    void setBusy(const QString &udi, bool busy);
    QList<Place> devicePlaces();

    QList<Place> m_places;
    QStringList m_tags;
    KCoreDirLister *m_trashLister = nullptr;
    bool m_trashEmpty = true;
    DiskProbe m_disk;
    // What the disk last said of each standard folder (DiskProbe kinds); a folder not asked yet is listed.
    QHash<QString, int> m_folderKinds;
    QSet<int> m_folderTokens;
};
