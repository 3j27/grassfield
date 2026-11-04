// Which udisks2 filesystems Files' sidebar lists and what they are called (VolumeLogic), over a fake ObjectManager tree
// shaped like a desktop PC: several internal disks, an external drive, and everything that must stay out of the list.
#include "volumelogic.h"

#include <gtest/gtest.h>

namespace {

using namespace VolumeLogic;

const QString kBlock = QStringLiteral("org.freedesktop.UDisks2.Block");
const QString kFs = QStringLiteral("org.freedesktop.UDisks2.Filesystem");
const QString kPart = QStringLiteral("org.freedesktop.UDisks2.Partition");
const QString kDrive = QStringLiteral("org.freedesktop.UDisks2.Drive");

struct Fake {
    QString device;
    QString label;
    quint64 size = 500'000'000'000ULL;
    QString idType = QStringLiteral("ext4");
    QString usage = QStringLiteral("filesystem");
    QStringList mounts;
    QString drive;
    bool hintIgnore = false;
    bool filesystem = true;
    QString partType; // empty: not a partition
    quint64 partFlags = 0;
};

void add(ObjectMap &tree, const QString &name, const Fake &f)
{
    InterfaceMap ifaces;
    QVariantMap block;
    block[QStringLiteral("Device")] = f.device.toUtf8() + QByteArray(1, '\0');
    block[QStringLiteral("IdLabel")] = f.label;
    block[QStringLiteral("Size")] = qulonglong(f.size);
    block[QStringLiteral("IdType")] = f.idType;
    block[QStringLiteral("IdUsage")] = f.usage;
    block[QStringLiteral("HintIgnore")] = f.hintIgnore;
    block[QStringLiteral("Drive")] = QVariant::fromValue(QDBusObjectPath(f.drive.isEmpty() ? QStringLiteral("/") : f.drive));
    ifaces[kBlock] = block;
    if (f.filesystem) {
        QList<QByteArray> mounts;
        for (const QString &m : f.mounts)
            mounts << m.toUtf8() + QByteArray(1, '\0');
        ifaces[kFs] = {{QStringLiteral("MountPoints"), QVariant::fromValue(mounts)}};
    }
    if (!f.partType.isEmpty())
        ifaces[kPart] = {{QStringLiteral("Type"), f.partType}, {QStringLiteral("Flags"), qulonglong(f.partFlags)}};
    tree[QDBusObjectPath(QStringLiteral("/org/freedesktop/UDisks2/block_devices/") + name)] = ifaces;
}

void addDrive(ObjectMap &tree, const QString &name, bool removable)
{
    tree[QDBusObjectPath(QStringLiteral("/org/freedesktop/UDisks2/drives/") + name)][kDrive] = {{QStringLiteral("Removable"), removable}};
}

QStringList devices(const QList<Volume> &v)
{
    QStringList out;
    for (const Volume &x : v)
        out << x.device;
    return out;
}

const QString kSsd = QStringLiteral("/org/freedesktop/UDisks2/drives/Samsung_SSD");
const QString kUsb = QStringLiteral("/org/freedesktop/UDisks2/drives/USB_Stick");
const QString kEfi = QStringLiteral("c12a7328-f81f-11d2-ba4b-00a0c93ec93b");

// A desktop PC: the system disk (EFI, root with a /home subvolume, swap), a second disk with two data partitions (one
// unmounted, one with a label), a Windows disk with its recovery and reserved partitions, and a USB stick.
ObjectMap desktop()
{
    ObjectMap t;
    addDrive(t, QStringLiteral("Samsung_SSD"), false);
    addDrive(t, QStringLiteral("USB_Stick"), true);
    add(t, QStringLiteral("nvme0n1p1"), {.device = QStringLiteral("/dev/nvme0n1p1"), .size = 1'000'000'000, .idType = QStringLiteral("vfat"), .mounts = {QStringLiteral("/boot")}, .drive = kSsd, .partType = kEfi});
    add(t, QStringLiteral("nvme0n1p2"), {.device = QStringLiteral("/dev/nvme0n1p2"), .idType = QStringLiteral("btrfs"), .mounts = {QStringLiteral("/"), QStringLiteral("/home"), QStringLiteral("/var/log")}, .drive = kSsd});
    add(t, QStringLiteral("nvme0n1p3"), {.device = QStringLiteral("/dev/nvme0n1p3"), .size = 16'000'000'000, .idType = QStringLiteral("swap"), .usage = QStringLiteral("other"), .filesystem = false});
    add(t, QStringLiteral("sda1"), {.device = QStringLiteral("/dev/sda1"), .label = QStringLiteral("Games"), .size = 2'000'000'000'000, .idType = QStringLiteral("ext4"), .drive = kSsd});
    add(t, QStringLiteral("sda2"), {.device = QStringLiteral("/dev/sda2"), .size = 500'000'000'000, .idType = QStringLiteral("ntfs"), .mounts = {QStringLiteral("/run/media/u/abc")}, .drive = kSsd});
    add(t, QStringLiteral("sdb1"), {.device = QStringLiteral("/dev/sdb1"), .size = 100'000'000, .idType = QStringLiteral("vfat"), .drive = kSsd, .partType = kEfi});
    add(t, QStringLiteral("sdb2"), {.device = QStringLiteral("/dev/sdb2"), .size = 16'000'000, .idType = QStringLiteral("ntfs"), .drive = kSsd, .partType = QStringLiteral("e3c9e316-0b5c-4db8-817d-f92df00215ae")});
    add(t, QStringLiteral("sdb3"), {.device = QStringLiteral("/dev/sdb3"), .size = 250'000'000'000, .idType = QStringLiteral("ntfs"), .drive = kSsd, .partType = QStringLiteral("ebd0a0a2-b9e5-4433-87c0-68b6b72699c7")});
    add(t, QStringLiteral("sdb4"), {.device = QStringLiteral("/dev/sdb4"), .size = 800'000'000, .idType = QStringLiteral("ntfs"), .drive = kSsd, .partType = QStringLiteral("de94bba4-06d1-4d40-a16a-bfd50179d6ac")});
    add(t, QStringLiteral("sdc1"), {.device = QStringLiteral("/dev/sdc1"), .label = QStringLiteral("BACKUP"), .size = 64'000'000'000, .idType = QStringLiteral("exfat"), .drive = kUsb});
    return t;
}
} // namespace

TEST(VolumeLogic, ListsEveryOpenableFilesystemAndNothingElse)
{
    const QList<Volume> v = volumes(desktop());
    // The EFI, root (with its /home and /var subvolume mounts), swap, Microsoft reserved and recovery partitions are out.
    EXPECT_EQ(devices(v), (QStringList{"/dev/sda1", "/dev/sda2", "/dev/sdb3", "/dev/sdc1"}));
}

TEST(VolumeLogic, NamesByLabelElseBySize)
{
    const QList<Volume> v = volumes(desktop());
    ASSERT_EQ(v.size(), 4);
    EXPECT_EQ(v[0].name, "Games");
    EXPECT_EQ(v[1].name, "500 GB Volume");
    EXPECT_EQ(v[2].name, "250 GB Volume");
    EXPECT_EQ(v[3].name, "BACKUP");
}

TEST(VolumeLogic, MountStateAndIcons)
{
    const QList<Volume> v = volumes(desktop());
    ASSERT_EQ(v.size(), 4);
    EXPECT_TRUE(v[0].mountPoint.isEmpty());
    EXPECT_EQ(v[1].mountPoint, "/run/media/u/abc");
    EXPECT_EQ(v[0].icon, "drive-harddisk");
    EXPECT_EQ(v[3].icon, "drive-removable-media");
    EXPECT_EQ(v[0].path, "/org/freedesktop/UDisks2/block_devices/sda1");
}

TEST(VolumeLogic, SizeNames)
{
    EXPECT_EQ(sizeText(500'000'000'000ULL), "500 GB");
    EXPECT_EQ(sizeText(1'000'000'000'000ULL), "1 TB");
    EXPECT_EQ(sizeText(1'500'000'000'000ULL), "1.5 TB");
    EXPECT_EQ(sizeText(2'000'000'000'000ULL), "2 TB");
    EXPECT_EQ(sizeText(512'110'190'592ULL), "512 GB");
    EXPECT_EQ(sizeText(8'000'000'000ULL), "8 GB");
    EXPECT_EQ(sizeText(256'000'000ULL), "256 MB");
    EXPECT_EQ(volumeName(QString(), 500'000'000'000ULL), "500 GB Volume");
    EXPECT_EQ(volumeName(QStringLiteral("  "), 64'000'000'000ULL), "64 GB Volume");
    EXPECT_EQ(volumeName(QStringLiteral("Data"), 64'000'000'000ULL), "Data");
    EXPECT_EQ(volumeName(QString(), 0), "Volume");
}

TEST(VolumeLogic, RulesForOneDevice)
{
    auto listed = [](const Fake &f) {
        ObjectMap t;
        add(t, QStringLiteral("x1"), f);
        return volumes(t).size() == 1;
    };
    Fake plain;
    plain.device = QStringLiteral("/dev/sdx1");
    EXPECT_TRUE(listed(plain));
    Fake ignored = plain;
    ignored.hintIgnore = true;
    EXPECT_FALSE(listed(ignored));
    Fake raw = plain;
    raw.usage = QStringLiteral("raid");
    EXPECT_FALSE(listed(raw));
    Fake squash = plain;
    squash.idType = QStringLiteral("squashfs");
    EXPECT_FALSE(listed(squash));
    Fake zram = plain;
    zram.device = QStringLiteral("/dev/zram0");
    EXPECT_FALSE(listed(zram));
    Fake bare = plain;
    bare.filesystem = false; // no Filesystem interface: nothing to mount
    EXPECT_FALSE(listed(bare));
    Fake hidden = plain;
    hidden.partType = QStringLiteral("ebd0a0a2-b9e5-4433-87c0-68b6b72699c7");
    hidden.partFlags = quint64(1) << 62;
    EXPECT_FALSE(listed(hidden));
    Fake required = plain;
    required.partType = QStringLiteral("0x83");
    required.partFlags = 1;
    EXPECT_FALSE(listed(required));
    Fake mbrEfi = plain;
    mbrEfi.partType = QStringLiteral("0xEF");
    EXPECT_FALSE(listed(mbrEfi));
    Fake mbrData = plain;
    mbrData.partType = QStringLiteral("0x83");
    EXPECT_TRUE(listed(mbrData));
    Fake data = plain;
    data.mounts = {QStringLiteral("/mnt/data")};
    EXPECT_TRUE(listed(data));
    Fake nixStore = plain;
    nixStore.mounts = {QStringLiteral("/mnt/data"), QStringLiteral("/nix/store")};
    EXPECT_FALSE(listed(nixStore));
}

TEST(VolumeLogic, SystemMountPoints)
{
    for (const char *p : {"/", "/boot", "/boot/efi", "/efi", "/home", "/home/", "/var/log", "/usr", "/nix/store", "/snap/core"})
        EXPECT_TRUE(isSystemMountPoint(QString::fromLatin1(p))) << p;
    for (const char *p : {"/mnt/data", "/run/media/u/stick", "/media/x", "/data", "/home2", "/homework"})
        EXPECT_FALSE(isSystemMountPoint(QString::fromLatin1(p))) << p;
}

TEST(VolumeLogic, EmptyTreeAndMalformedObjects)
{
    EXPECT_TRUE(volumes({}).isEmpty());
    ObjectMap t;
    t[QDBusObjectPath(QStringLiteral("/org/freedesktop/UDisks2/block_devices/odd"))] = {{kBlock, {}}};
    EXPECT_TRUE(volumes(t).isEmpty());
}

TEST(VolumeLogic, NumbersSortAsNumbers)
{
    ObjectMap t;
    for (const char *n : {"sda10", "sda2", "sda1"}) {
        Fake f;
        f.device = QStringLiteral("/dev/") + QLatin1String(n);
        add(t, QLatin1String(n), f);
    }
    EXPECT_EQ(devices(volumes(t)), (QStringList{"/dev/sda1", "/dev/sda2", "/dev/sda10"}));
}
