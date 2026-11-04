#pragma once

#include <QByteArray>
#include <QDBusObjectPath>
#include <QList>
#include <QMap>
#include <QString>
#include <QStringList>
#include <QVariantMap>

// Which udisks2 filesystems the sidebar's Locations lists, and what they are called (macOS: every volume the user can open,
// internal disks included; a volume is named by its label, else by its size, "500 GB Volume"). Pure rules over the tree
// udisks2's ObjectManager returns (GetManagedObjects), so a fake tree tests them; PlacesModel reads the real one.
// Solid (which lists removable media and mounted volumes) leaves out the other internal drives' filesystems; this adds them.
// Nothing here formats, partitions or writes: the rules only read properties.
namespace VolumeLogic
{
using InterfaceMap = QMap<QString, QVariantMap>;
using ObjectMap = QMap<QDBusObjectPath, InterfaceMap>;

struct Volume {
    QString path; // the udisks2 object path (the same string as Solid's UDI)
    QString device; // /dev/nvme1n1p1
    QString name;
    QString icon; // "drive-harddisk" | "drive-removable-media" (theme names without -symbolic)
    quint64 size = 0;
    QString mountPoint; // the first mount point; empty while unmounted
    bool operator==(const Volume &o) const
    {
        return path == o.path && device == o.device && name == o.name && icon == o.icon && size == o.size && mountPoint == o.mountPoint;
    }
};

// A size the way macOS writes it: decimal units, "500 GB", "1.5 TB", "256 MB".
QString sizeText(quint64 bytes);
// The label, else "<size> Volume" ("Volume" when the size is unknown).
QString volumeName(const QString &label, quint64 size);
// A mount point that belongs to the system itself: the root, the boot and EFI partitions, /usr, /var, /home (the Home entry
// shows it), the Nix store and snaps. A device mounted there is the system's, and the Computer entry stands for it.
bool isSystemMountPoint(const QString &path);
// A partition type (GPT GUID or MBR hex such as "0xef") that is never a volume to open: EFI, boot, BIOS boot, swap, reserved,
// recovery.
bool isHiddenPartitionType(const QString &type);
// The volumes of the tree the sidebar lists, in device order: a filesystem (not swap, squashfs or a raw member), not hinted
// ignored, not a hidden, system or reserved partition, not mounted on a system path.
QList<Volume> volumes(const ObjectMap &objects);
} // namespace VolumeLogic
