#include "appstreamsource.h"

#include "childprocess.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QRegularExpression>
#include <QSaveFile>
#include <QTemporaryDir>

namespace grassfield::store {

namespace {

constexpr qint64 kPackageMax = 64 * 1024 * 1024;
constexpr qint64 kXmlMax = 64 * 1024 * 1024;
const QString kSwcatalog = QStringLiteral("usr/share/swcatalog");

QString readSmall(const QString &path)
{
    QFile f(path);
    return f.open(QIODevice::ReadOnly) ? QString::fromUtf8(f.read(256)).trimmed() : QString();
}

bool validVersion(const QString &v)
{
    static const QRegularExpression re(QStringLiteral(R"(\A[0-9][0-9A-Za-z.+_]*-[0-9]+(\.[0-9]+)?\z)"));
    return re.match(v).hasMatch();
}

} // namespace

AppStreamData readAppStream(const QString &swcatalogRoot, AppStreamData::Origin origin)
{
    AppStreamData data;
    const QDir xmlDir(swcatalogRoot + QStringLiteral("/xml"));
    const QStringList files = xmlDir.entryList({QStringLiteral("*.xml.gz")}, QDir::Files, QDir::Name);
    for (const QString &name : files) {
        QFile f(xmlDir.filePath(name));
        if (!f.open(QIODevice::ReadOnly) || f.size() > kXmlMax)
            continue;
        data.components += parseAppStream(gunzip(f.readAll(), kXmlMax));
    }
    if (!files.isEmpty()) {
        data.origin = origin;
        data.root = swcatalogRoot;
    }
    return data;
}

PackageFile packageFileFromPrint(const QByteArray &pacmanSp)
{
    static const QRegularExpression name(QStringLiteral(R"((?:\A|/)archlinux-appstream-data-([^/]+)-any\.pkg\.tar\.(?:zst|xz|gz)\z)"));
    const QList<QByteArray> lines = pacmanSp.trimmed().split('\n');
    const QString url = QString::fromUtf8(lines.isEmpty() ? QByteArray() : lines.last()).trimmed();
    const auto m = name.match(url);
    if (!m.hasMatch() || !validVersion(m.captured(1)))
        return {};
    return PackageFile{url, m.captured(1)};
}

AppStreamData readFetched(const QString &cacheDir)
{
    const QString version = readSmall(cacheDir + QStringLiteral("/appstream/current"));
    if (!validVersion(version))
        return {};
    AppStreamData data = readAppStream(cacheDir + QStringLiteral("/appstream/") + version + QLatin1Char('/') + kSwcatalog,
                                       AppStreamData::Origin::Fetched);
    data.version = data.origin == AppStreamData::Origin::None ? QString() : version;
    return data;
}

bool refreshFetched(const QString &cacheDir, const AppStreamTools &tools, QString *error)
{
    // An empty cache folder: pacman then names the mirror's URL, never a file:// of its own cache (S15).
    QTemporaryDir emptyCache;
    const ChildResult print = runChild(tools.pacman, {QStringLiteral("-Sp"), QStringLiteral("--cachedir"), emptyCache.path(),
                                                      QStringLiteral("archlinux-appstream-data")});
    const PackageFile file = packageFileFromPrint(print.ok() ? print.out : QByteArray());
    if (file.url.isEmpty()) {
        *error = QStringLiteral("pacman names no archlinux-appstream-data package file");
        return false;
    }
    const QString base = cacheDir + QStringLiteral("/appstream");
    if (readSmall(base + QStringLiteral("/current")) == file.version && QDir(base + QLatin1Char('/') + file.version).exists())
        return true; // already the version pacman's database names
    QDir().mkpath(base);
    QTemporaryDir work(base + QStringLiteral("/.work-XXXXXX"));
    if (!work.isValid() || !tools.download) {
        *error = QStringLiteral("no work folder");
        return false;
    }
    const QString pkg = work.filePath(QStringLiteral("package")), sig = pkg + QStringLiteral(".sig");
    if (!tools.download(file.url, pkg, kPackageMax, 300000) || !tools.download(file.url + QStringLiteral(".sig"), sig, 4096, 15000)) {
        *error = QStringLiteral("the package file or its signature could not be downloaded");
        return false;
    }
    // pacman's own rule: the signer must be fully trusted in pacman's keyring (S17). Nothing is unpacked before it passes.
    ChildOptions verifyOptions;
    verifyOptions.timeoutMs = 60000;
    verifyOptions.maxOut = 64 * 1024;
    const ChildResult verified = runChild(tools.pacmanKey, {QStringLiteral("--verify"), sig, pkg}, verifyOptions);
    if (!verified.ok()) {
        *error = QStringLiteral("the package file's signature does not pass pacman-key --verify");
        return false;
    }
    const QString unpacked = work.filePath(QStringLiteral("tree"));
    QDir().mkpath(unpacked);
    ChildOptions extract;
    extract.timeoutMs = 120000;
    // Only the swcatalog tree; no absolute path, no "..", no owner or permission from the archive.
    const ChildResult tar = runChild(tools.bsdtar, {QStringLiteral("-x"), QStringLiteral("-f"), pkg, QStringLiteral("-C"), unpacked,
                                                    QStringLiteral("--no-same-owner"), QStringLiteral("--no-same-permissions"),
                                                    QStringLiteral("--no-xattrs"), QStringLiteral("--no-acls"), kSwcatalog},
                                     extract);
    if (!tar.ok() || !QDir(unpacked + QLatin1Char('/') + kSwcatalog + QStringLiteral("/xml")).exists()) {
        *error = QStringLiteral("the package file could not be unpacked");
        return false;
    }
    const QString target = base + QLatin1Char('/') + file.version;
    QDir(target).removeRecursively();
    if (!QDir().rename(unpacked, target)) {
        *error = QStringLiteral("the cache folder cannot be written");
        return false;
    }
    const QString previous = readSmall(base + QStringLiteral("/current"));
    QSaveFile current(base + QStringLiteral("/current"));
    if (!current.open(QIODevice::WriteOnly) || current.write(file.version.toUtf8()) < 0 || !current.commit()) {
        *error = QStringLiteral("the cache folder cannot be written");
        return false;
    }
    if (validVersion(previous) && previous != file.version)
        QDir(base + QLatin1Char('/') + previous).removeRecursively();
    return true;
}

} // namespace grassfield::store
