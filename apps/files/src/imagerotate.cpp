#include "imagerotate.h"

#include <QBuffer>
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QImage>
#include <QImageReader>
#include <QImageWriter>
#include <QTemporaryFile>
#include <QTransform>

#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>

namespace ImageRotate
{
namespace
{
// Orientation as (mirrored, quarter turns clockwise): the picture is mirrored horizontally first, then turned.
struct Pose {
    bool mirrored;
    int turns;
};
// Indexed by orientation 1..8 (EXIF 2.32, tag 0x0112).
constexpr Pose kPoses[9] = {{false, 0}, {false, 0}, {true, 0}, {false, 2}, {true, 2}, {true, 3}, {false, 1}, {true, 1}, {false, 3}};

int orientationOf(Pose p)
{
    for (int o = 1; o <= 8; o++) {
        if (kPoses[o].mirrored == p.mirrored && kPoses[o].turns == p.turns)
            return o;
    }
    return 1;
}

quint16 read16(const QByteArray &b, qint64 at, bool big)
{
    const auto u = [&](qint64 i) { return quint16(quint8(b.at(i))); };
    return big ? quint16(u(at) << 8 | u(at + 1)) : quint16(u(at + 1) << 8 | u(at));
}

quint32 read32(const QByteArray &b, qint64 at, bool big)
{
    const auto u = [&](qint64 i) { return quint32(quint8(b.at(i))); };
    return big ? (u(at) << 24 | u(at + 1) << 16 | u(at + 2) << 8 | u(at + 3)) : (u(at + 3) << 24 | u(at + 2) << 16 | u(at + 1) << 8 | u(at));
}

QString tr(const char *text)
{
    return QCoreApplication::translate("ImageRotate", text);
}

// A file descriptor closed when it goes out of scope.
struct Fd {
    int fd = -1;
    ~Fd()
    {
        if (fd >= 0)
            ::close(fd);
    }
};

QString errnoText()
{
    return QString::fromLocal8Bit(std::strerror(errno));
}

// The whole file behind `fd` (its size `size`): a short read (an I/O error on a removable or network disk) is refused, so a
// truncated copy can never replace the picture.
bool readWhole(int fd, qint64 size, QByteArray *out)
{
    out->resize(size);
    qint64 done = 0;
    while (done < size) {
        const ssize_t n = ::pread(fd, out->data() + done, size_t(size - done), done);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0)
            return false;
        done += n;
    }
    return true;
}

// Whether the file behind `fd` still has the size and modification time it had when it was read (`st`), and, with
// `samePath`, whether `path` still names it: an editor's save or a rename meanwhile leaves the file as it is.
bool unchanged(int fd, const struct stat &st, const QString &path, bool samePath)
{
    struct stat now {};
    if (::fstat(fd, &now) != 0 || now.st_size != st.st_size || now.st_mtim.tv_sec != st.st_mtim.tv_sec
        || now.st_mtim.tv_nsec != st.st_mtim.tv_nsec)
        return false;
    if (!samePath)
        return true;
    struct stat named {};
    return ::lstat(QFile::encodeName(path).constData(), &named) == 0 && named.st_dev == st.st_dev && named.st_ino == st.st_ino;
}

// Writes `bytes` over `path` atomically: a new file in the same folder, given the old one's group, extended attributes
// (user.* such as Files' tags, and the access lists system.posix_acl_*) read from `fd` and permissions, written to disk
// (fsync) and renamed over it if the file did not change meanwhile. security.* labels belong to the system (a new file
// gets its folder's); any other attribute, or one that cannot be read or kept, stops the change, so nothing is lost
// silently.
QString replaceKeepingAttributes(int fd, const struct stat &st, const QString &path, const QByteArray &bytes)
{
    QTemporaryFile tmp(QFileInfo(path).absolutePath() + QStringLiteral("/.grassfield-rotate-XXXXXX"));
    tmp.setAutoRemove(true);
    if (!tmp.open())
        return tmp.errorString();
    if (tmp.write(bytes) != bytes.size() || !tmp.flush())
        return tmp.errorString();
    // A shared picture keeps its group (the new file has the user's, or the folder's set-group one).
    if (::fchown(tmp.handle(), uid_t(-1), st.st_gid) != 0)
        return tr("its group could not be kept, so it was left as it is");
    // The folder's default access list is not the picture's: the picture's own, if any, is copied below.
    if (::fremovexattr(tmp.handle(), "system.posix_acl_access") != 0 && errno != ENODATA && errno != ENOTSUP && errno != EOPNOTSUPP)
        return tr("its tags could not be kept, so it was left as it is");
    const ssize_t listSize = ::flistxattr(fd, nullptr, 0);
    if (listSize < 0 && errno != ENOTSUP)
        return tr("its tags could not be read, so it was left as it is");
    if (listSize > 0) {
        QByteArray names(int(listSize), '\0');
        const ssize_t got = ::flistxattr(fd, names.data(), size_t(names.size()));
        if (got < 0)
            return tr("its tags could not be read, so it was left as it is");
        for (const QByteArray &name : names.left(int(got)).split('\0')) {
            if (name.isEmpty() || name.startsWith("security."))
                continue;
            if (!(name.startsWith("user.") || name.startsWith("system.posix_acl_")))
                return tr("some of its attributes could not be kept, so it was left as it is");
            const ssize_t valueSize = ::fgetxattr(fd, name.constData(), nullptr, 0);
            if (valueSize < 0)
                return tr("its tags could not be read, so it was left as it is");
            QByteArray value(int(valueSize), '\0');
            if (::fgetxattr(fd, name.constData(), value.data(), size_t(value.size())) != valueSize)
                return tr("its tags could not be read, so it was left as it is");
            if (::fsetxattr(tmp.handle(), name.constData(), value.constData(), size_t(value.size()), 0) != 0)
                return tr("its tags could not be kept, so it was left as it is");
        }
    }
    // After the access list (whose mask is the group bits of the mode).
    if (::fchmod(tmp.handle(), st.st_mode & 07777) != 0)
        return errnoText();
    if (::fsync(tmp.handle()) != 0)
        return errnoText();
    if (!unchanged(fd, st, path, true))
        return tr("it changed while it was being turned, so it was left as it is");
    const QByteArray tmpName = QFile::encodeName(tmp.fileName());
    if (::rename(tmpName.constData(), QFile::encodeName(path).constData()) != 0)
        return errnoText();
    tmp.setAutoRemove(false);
    return QString();
}

// An animated PNG (APNG) has an acTL chunk before its first IDAT; Qt reads only its still frame.
bool isAnimatedPng(const QByteArray &bytes)
{
    qint64 at = 8; // the signature
    while (at + 8 <= bytes.size()) {
        const quint32 length = read32(bytes, at, true);
        const QByteArray type = bytes.mid(at + 4, 4);
        if (type == "acTL")
            return true;
        if (type == "IDAT" || type == "IEND")
            return false;
        at += 12 + qint64(length);
    }
    return false;
}
} // namespace

Method methodFor(const QByteArray &mimeType)
{
    if (mimeType == "image/jpeg")
        return Method::Orientation;
    // TIFF is not among them: Qt writes it uncompressed and without its tags.
    if (mimeType == "image/png" || mimeType == "image/bmp")
        return Method::Reencode;
    return Method::None;
}

int turned(int orientation, bool clockwise)
{
    const Pose p = kPoses[orientation >= 1 && orientation <= 8 ? orientation : 1];
    return orientationOf({p.mirrored, (p.turns + (clockwise ? 1 : 3)) % 4});
}

JpegOrientation findOrientation(const QByteArray &head)
{
    JpegOrientation r;
    if (head.size() < 4 || quint8(head.at(0)) != 0xFF || quint8(head.at(1)) != 0xD8)
        return r;
    qint64 at = 2;
    while (at + 4 <= head.size()) {
        if (quint8(head.at(at)) != 0xFF)
            return r; // not a marker: a broken file
        const quint8 marker = quint8(head.at(at + 1));
        if (marker == 0xFF) {
            at++; // fill byte
            continue;
        }
        if (marker == 0xDA || marker == 0xD9) // start of scan or end of image: no more metadata
            break;
        const qint64 length = read16(head, at + 2, true);
        if (length < 2 || at + 2 + length > head.size())
            return r;
        if (marker == 0xE0 && r.insertAt == at)
            r.insertAt = at + 2 + length; // after a JFIF segment
        if (marker == 0xE1 && length >= 8 && head.mid(at + 4, 6) == QByteArray("Exif\0\0", 6)) {
            r.exif = true;
            const qint64 tiff = at + 10;
            const qint64 end = at + 2 + length;
            if (tiff + 8 > end)
                return r;
            const QByteArray order = head.mid(tiff, 2);
            if (order != "II" && order != "MM")
                return r;
            r.bigEndian = order == "MM";
            if (read16(head, tiff + 2, r.bigEndian) != 42)
                return r;
            const qint64 ifd = tiff + read32(head, tiff + 4, r.bigEndian);
            if (ifd + 2 > end)
                return r;
            const int count = read16(head, ifd, r.bigEndian);
            for (int i = 0; i < count; i++) {
                const qint64 entry = ifd + 2 + 12 * i;
                if (entry + 12 > end)
                    return r;
                if (read16(head, entry, r.bigEndian) == 0x0112 && read16(head, entry + 2, r.bigEndian) == 3 && read32(head, entry + 4, r.bigEndian) == 1) {
                    r.offset = entry + 8;
                    const int value = read16(head, entry + 8, r.bigEndian);
                    r.value = value >= 1 && value <= 8 ? value : 1;
                    break;
                }
            }
        }
        at += 2 + length;
    }
    r.valid = true;
    return r;
}

QByteArray exifSegment(int orientation)
{
    // "Exif\0\0", a big-endian TIFF header, IFD0 with one entry (orientation, SHORT, 1) and no next IFD.
    QByteArray tiff;
    tiff.append("MM\x00\x2A\x00\x00\x00\x08", 8);
    tiff.append("\x00\x01", 2);
    tiff.append("\x01\x12\x00\x03\x00\x00\x00\x01", 8);
    tiff.append(char(0));
    tiff.append(char(orientation >= 1 && orientation <= 8 ? orientation : 1));
    tiff.append("\x00\x00", 2);
    tiff.append("\x00\x00\x00\x00", 4);
    QByteArray body = QByteArray("Exif\0\0", 6) + tiff;
    QByteArray segment("\xFF\xE1", 2);
    const int length = int(body.size()) + 2;
    segment.append(char(length >> 8));
    segment.append(char(length & 0xFF));
    return segment + body;
}

QString rotate(const QString &path, const QByteArray &mimeType, bool clockwise)
{
    const Method method = methodFor(mimeType);
    if (method == Method::None)
        return tr("this kind of picture can’t be turned without losing quality");
    // Everything below works on this descriptor: O_NOFOLLOW refuses a link, even one swapped in after any check.
    Fd file;
    file.fd = ::open(QFile::encodeName(path).constData(), O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (file.fd < 0) {
        if (errno == ELOOP)
            return tr("only pictures themselves can be turned, not links to them");
        if (errno == EACCES || errno == EPERM || errno == EROFS)
            return tr("you can’t change it");
        return errnoText();
    }
    struct stat st {};
    if (::fstat(file.fd, &st) != 0)
        return errnoText();
    if (!S_ISREG(st.st_mode))
        return tr("only pictures themselves can be turned, not links to them");
    QByteArray bytes;
    if (method == Method::Orientation) {
        // The metadata sits in the first segments; 256 KiB holds them (an EXIF segment is at most 64 KiB).
        QByteArray head;
        if (!readWhole(file.fd, qMin<qint64>(st.st_size, 256 * 1024), &head))
            return tr("it could not be read whole, so it was left as it is");
        const JpegOrientation where = findOrientation(head);
        if (!where.valid)
            return tr("it is not a JPEG picture that can be read");
        const int next = turned(where.value, clockwise);
        if (where.offset >= 0) {
            // Two bytes changed in place: the file keeps its owner, links and every attribute.
            if (!unchanged(file.fd, st, path, false))
                return tr("it changed while it was being turned, so it was left as it is");
            const char value[2] = {where.bigEndian ? char(0) : char(next), where.bigEndian ? char(next) : char(0)};
            if (::pwrite(file.fd, value, 2, where.offset) != 2 || ::fsync(file.fd) != 0)
                return errnoText();
            return QString();
        }
        if (where.exif)
            return tr("its EXIF data has no orientation that can be changed");
        if (!readWhole(file.fd, st.st_size, &bytes))
            return tr("it could not be read whole, so it was left as it is");
        bytes.insert(where.insertAt, exifSegment(next));
    } else {
        if (!readWhole(file.fd, st.st_size, &bytes))
            return tr("it could not be read whole, so it was left as it is");
        if (mimeType == "image/png" && isAnimatedPng(bytes))
            return tr("animated pictures are not turned");
        QBuffer source(&bytes);
        source.open(QIODevice::ReadOnly);
        QImageReader reader(&source);
        reader.setAutoTransform(false);
        const QByteArray format = reader.format();
        if (reader.imageCount() > 1)
            return tr("animated pictures are not turned");
        // A picture shown turned by its own orientation tag would come out turned twice.
        if (reader.transformation() != QImageIOHandler::TransformationNone)
            return tr("its orientation tag would no longer match, so it was left as it is");
        QImage image = reader.read();
        if (image.isNull())
            return reader.errorString();
        image = image.transformed(QTransform().rotate(clockwise ? 90 : -90));
        QByteArray out;
        QBuffer buffer(&out);
        buffer.open(QIODevice::WriteOnly);
        QImageWriter writer(&buffer, format);
        if (!writer.write(image))
            return writer.errorString();
        bytes = out;
    }
    // A new file replaces it: it would become the user's, and its other names (hard links) would keep the old picture.
    if (st.st_uid != ::geteuid())
        return tr("it belongs to someone else, so it was left as it is");
    if (st.st_nlink > 1)
        return tr("it has other names (hard links), so it was left as it is");
    return replaceKeepingAttributes(file.fd, st, path, bytes);
}
} // namespace ImageRotate
