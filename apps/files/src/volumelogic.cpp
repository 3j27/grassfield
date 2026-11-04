#include "volumelogic.h"

#include <QCollator>
#include <QCoreApplication>
#include <QDBusArgument>
#include <QSet>
#include <QVariant>

#include <algorithm>

namespace VolumeLogic
{
namespace
{
const QString kBlock = QStringLiteral("org.freedesktop.UDisks2.Block");
const QString kFilesystem = QStringLiteral("org.freedesktop.UDisks2.Filesystem");
const QString kPartition = QStringLiteral("org.freedesktop.UDisks2.Partition");
const QString kDrive = QStringLiteral("org.freedesktop.UDisks2.Drive");

// udisks2 sends paths and device nodes as NUL-ended byte arrays (ay, aay); a real reply holds them in a QDBusArgument.
QByteArray bytesOf(const QVariant &v)
{
    QByteArray b = v.metaType() == QMetaType::fromType<QDBusArgument>() ? qdbus_cast<QByteArray>(v.value<QDBusArgument>()) : v.toByteArray();
    const qsizetype nul = b.indexOf('\0');
    return nul >= 0 ? b.left(nul) : b;
}

QStringList mountPointsOf(const QVariant &v)
{
    QList<QByteArray> raw;
    if (v.metaType() == QMetaType::fromType<QDBusArgument>())
        raw = qdbus_cast<QList<QByteArray>>(v.value<QDBusArgument>());
    else if (v.canConvert<QList<QByteArray>>())
        raw = v.value<QList<QByteArray>>();
    else if (v.canConvert<QStringList>())
        for (const QString &s : v.toStringList())
            raw << s.toUtf8();
    QStringList out;
    for (const QByteArray &b : std::as_const(raw)) {
        const qsizetype nul = b.indexOf('\0');
        const QString s = QString::fromUtf8(nul >= 0 ? b.left(nul) : b);
        if (!s.isEmpty())
            out << s;
    }
    return out;
}

// Filesystems that are a packaging of something else, not a disk's volume.
bool isPackagedFilesystem(const QString &type)
{
    return type == QLatin1String("squashfs") || type == QLatin1String("erofs") || type == QLatin1String("swap");
}

constexpr quint64 kPartitionSystem = quint64(1) << 0; // "required partition" (the firmware or the system needs it)
constexpr quint64 kPartitionHidden = quint64(1) << 62;
} // namespace

QString sizeText(quint64 bytes)
{
    struct Unit {
        double base;
        const char *name;
    };
    static const Unit units[] = {{1e12, "TB"}, {1e9, "GB"}, {1e6, "MB"}, {1e3, "KB"}};
    for (const Unit &u : units) {
        if (double(bytes) < u.base && u.base != 1e3)
            continue;
        const double v = double(bytes) / u.base;
        // 500 GB, 1.5 TB: a decimal only below 10, and never a trailing zero.
        QString n = v >= 10 ? QString::number(qRound64(v)) : QString::number(v, 'f', 1);
        if (n.endsWith(QLatin1String(".0")))
            n.chop(2);
        return n + QLatin1Char(' ') + QLatin1String(u.name);
    }
    return QString();
}

QString volumeName(const QString &label, quint64 size)
{
    if (!label.trimmed().isEmpty())
        return label;
    if (size == 0)
        return QCoreApplication::translate("PlacesModel", "Volume");
    return QCoreApplication::translate("PlacesModel", "%1 Volume").arg(sizeText(size));
}

bool isSystemMountPoint(const QString &path)
{
    static const QSet<QString> exact = {QStringLiteral("/"), QStringLiteral("/boot"), QStringLiteral("/efi"), QStringLiteral("/home"),
                                        QStringLiteral("/usr"), QStringLiteral("/var"), QStringLiteral("/etc"), QStringLiteral("/opt"),
                                        QStringLiteral("/srv"), QStringLiteral("/nix"), QStringLiteral("/snap"), QStringLiteral("/tmp")};
    static const QStringList prefixes = {QStringLiteral("/boot/"), QStringLiteral("/efi/"), QStringLiteral("/usr/"), QStringLiteral("/var/"),
                                         QStringLiteral("/nix/"), QStringLiteral("/snap/")};
    QString p = path;
    while (p.size() > 1 && p.endsWith(QLatin1Char('/')))
        p.chop(1);
    if (exact.contains(p))
        return true;
    for (const QString &prefix : prefixes)
        if (p.startsWith(prefix))
            return true;
    return false;
}

bool isHiddenPartitionType(const QString &typeIn)
{
    static const QSet<QString> hidden = {
        // GPT: EFI system, BIOS boot, extended boot loader, Microsoft reserved, Windows recovery, Linux swap, Apple boot and
        // recovery.
        QStringLiteral("c12a7328-f81f-11d2-ba4b-00a0c93ec93b"),
        QStringLiteral("21686148-6449-6e6f-744e-656564454649"),
        QStringLiteral("bc13c2ff-59e6-4262-a352-b275fd6f7172"),
        QStringLiteral("e3c9e316-0b5c-4db8-817d-f92df00215ae"),
        QStringLiteral("de94bba4-06d1-4d40-a16a-bfd50179d6ac"),
        QStringLiteral("0657fd6d-a4ab-43c4-84e5-0933c84b4f4f"),
        QStringLiteral("426f6f74-0000-11aa-aa11-00306543ecac"),
        QStringLiteral("5265636f-7665-11aa-aa11-00306543ecac"),
        // MBR: EFI system, Linux swap, Windows recovery (0x27), Dell and other diagnostics (0x12), GPT protective, extended.
        QStringLiteral("0xef"),
        QStringLiteral("0x82"),
        QStringLiteral("0x27"),
        QStringLiteral("0x12"),
        QStringLiteral("0xee"),
        QStringLiteral("0x05"),
        QStringLiteral("0x0f"),
    };
    return hidden.contains(typeIn.trimmed().toLower());
}

QList<Volume> volumes(const ObjectMap &objects)
{
    QList<Volume> out;
    for (auto it = objects.cbegin(); it != objects.cend(); ++it) {
        const InterfaceMap &ifaces = it.value();
        if (!ifaces.contains(kBlock) || !ifaces.contains(kFilesystem))
            continue;
        const QVariantMap &block = ifaces.value(kBlock);
        if (block.value(QStringLiteral("HintIgnore")).toBool())
            continue;
        if (block.value(QStringLiteral("IdUsage")).toString() != QLatin1String("filesystem"))
            continue;
        const QString type = block.value(QStringLiteral("IdType")).toString();
        if (isPackagedFilesystem(type))
            continue;
        const QString device = QString::fromUtf8(bytesOf(block.value(QStringLiteral("Device"))));
        if (device.startsWith(QLatin1String("/dev/ram")) || device.startsWith(QLatin1String("/dev/zram")))
            continue;
        if (ifaces.contains(kPartition)) {
            const QVariantMap &part = ifaces.value(kPartition);
            if (isHiddenPartitionType(part.value(QStringLiteral("Type")).toString()))
                continue;
            const quint64 flags = part.value(QStringLiteral("Flags")).toULongLong();
            if (flags & (kPartitionSystem | kPartitionHidden))
                continue;
        }
        const QStringList mounts = mountPointsOf(ifaces.value(kFilesystem).value(QStringLiteral("MountPoints")));
        bool system = false;
        for (const QString &m : mounts)
            system = system || isSystemMountPoint(m);
        if (system)
            continue;
        // The drive says whether the disk is removable (a USB stick, a card), else it is internal.
        bool removable = false;
        const QString drive = block.value(QStringLiteral("Drive")).value<QDBusObjectPath>().path();
        const auto driveIt = objects.constFind(QDBusObjectPath(drive));
        if (driveIt != objects.cend() && driveIt->contains(kDrive))
            removable = driveIt->value(kDrive).value(QStringLiteral("Removable")).toBool();

        Volume v;
        v.path = it.key().path();
        v.device = device;
        v.size = block.value(QStringLiteral("Size")).toULongLong();
        v.name = volumeName(block.value(QStringLiteral("IdLabel")).toString(), v.size);
        v.icon = removable ? QStringLiteral("drive-removable-media") : QStringLiteral("drive-harddisk");
        v.mountPoint = mounts.value(0);
        out.append(v);
    }
    // Device order, numbers as numbers (nvme0n1p2 before nvme0n1p10).
    QCollator collator;
    collator.setNumericMode(true);
    std::sort(out.begin(), out.end(), [&collator](const Volume &a, const Volume &b) {
        const int c = collator.compare(a.device, b.device);
        return c != 0 ? c < 0 : a.path < b.path;
    });
    return out;
}
} // namespace VolumeLogic
