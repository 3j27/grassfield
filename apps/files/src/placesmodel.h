#pragma once

#include <QAbstractListModel>
#include <QList>
#include <QUrl>

class KCoreDirLister;

// Sidebar entries: Favorites (standard user folders that exist), Locations (the system volume and
// Solid storage volumes, Network only when a KIO smb/sftp worker is installed, Trash).
// Mount and eject go through Solid::StorageAccess (udisks2 + polkit); nothing is mounted by hand.
class PlacesModel : public QAbstractListModel
{
    Q_OBJECT
    Q_PROPERTY(bool trashEmpty READ trashEmpty NOTIFY trashEmptyChanged)
    Q_PROPERTY(bool networkAvailable READ networkAvailable CONSTANT)

public:
    enum Roles { SectionRole = Qt::UserRole + 1, NameRole, UrlRole, IconNameRole, KindRole, UdiRole, MountedRole, EjectableRole, BusyRole };
    Q_ENUM(Roles)

    explicit PlacesModel(QObject *parent = nullptr);

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

signals:
    void trashEmptyChanged();
    void mounted(const QUrl &url);
    void error(const QString &message);

private:
    struct Place {
        QString section; // "favorites" | "locations"
        QString name;
        QUrl url;
        QString iconName;
        QString kind; // "folder" | "volume" | "network" | "trash"
        QString udi;
        bool mounted = true;
        bool ejectable = false;
        bool busy = false;
    };

    void rebuild();
    void setBusy(const QString &udi, bool busy);
    QList<Place> devicePlaces();

    QList<Place> m_places;
    KCoreDirLister *m_trashLister = nullptr;
    bool m_trashEmpty = true;
};
