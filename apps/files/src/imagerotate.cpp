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
#include <sys/stat.h>
#include <sys/xattr.h>

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

// Writes `bytes` over `path` atomically (a new file renamed over it) with the old file's permissions and user extended
// attributes (Files' tags among them). Symbolic links are refused by the caller.
QString replaceKeepingAttributes(const QString &path, const QByteArray &bytes)
{
    const QByteArray native = QFile::encodeName(path);
    struct stat st {};
    if (::lstat(native.constData(), &st) != 0)
        return QString::fromLocal8Bit(std::strerror(errno));
    QTemporaryFile tmp(QFileInfo(path).absolutePath() + QStringLiteral("/.grassfield-rotate-XXXXXX"));
    tmp.setAutoRemove(true);
    if (!tmp.open())
        return tmp.errorString();
    if (tmp.write(bytes) != bytes.size() || !tmp.flush())
        return tmp.errorString();
    const QByteArray tmpName = QFile::encodeName(tmp.fileName());
    if (::fchmod(tmp.handle(), st.st_mode & 07777) != 0)
        return QString::fromLocal8Bit(std::strerror(errno));
    // Copy the user.* attributes (a file system without them simply has none to copy).
    const ssize_t listSize = ::llistxattr(native.constData(), nullptr, 0);
    if (listSize > 0) {
        QByteArray names(int(listSize), '\0');
        const ssize_t got = ::llistxattr(native.constData(), names.data(), size_t(names.size()));
        for (const QByteArray &name : names.left(int(qMax<ssize_t>(got, 0))).split('\0')) {
            if (!name.startsWith("user."))
                continue;
            const ssize_t valueSize = ::lgetxattr(native.constData(), name.constData(), nullptr, 0);
            if (valueSize < 0)
                continue;
            QByteArray value(int(valueSize), '\0');
            if (::lgetxattr(native.constData(), name.constData(), value.data(), size_t(value.size())) != valueSize)
                return tr("its tags could not be read, so it was left as it is");
            if (::fsetxattr(tmp.handle(), name.constData(), value.constData(), size_t(value.size()), 0) != 0)
                return tr("its tags could not be kept, so it was left as it is");
        }
    }
    if (::rename(tmpName.constData(), native.constData()) != 0)
        return QString::fromLocal8Bit(std::strerror(errno));
    tmp.setAutoRemove(false);
    return QString();
}
} // namespace

Method methodFor(const QByteArray &mimeType)
{
    if (mimeType == "image/jpeg")
        return Method::Orientation;
    if (mimeType == "image/png" || mimeType == "image/bmp" || mimeType == "image/tiff")
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
    const QFileInfo fi(path);
    if (fi.isSymLink() || !fi.isFile())
        return tr("only pictures themselves can be turned, not links to them");
    if (!fi.isWritable())
        return tr("you can’t change it");
    const Method method = methodFor(mimeType);
    if (method == Method::None)
        return tr("this kind of picture can’t be turned without losing quality");
    QFile f(path);
    if (method == Method::Orientation) {
        if (!f.open(QIODevice::ReadWrite))
            return f.errorString();
        // The metadata sits in the first segments; 256 KiB holds them (an EXIF segment is at most 64 KiB).
        const QByteArray head = f.read(256 * 1024);
        const JpegOrientation where = findOrientation(head);
        if (!where.valid)
            return tr("it is not a JPEG picture that can be read");
        const int next = turned(where.value, clockwise);
        if (where.offset >= 0) {
            const char value[2] = {where.bigEndian ? char(0) : char(next), where.bigEndian ? char(next) : char(0)};
            if (!f.seek(where.offset) || f.write(value, 2) != 2 || !f.flush())
                return f.errorString();
            return QString();
        }
        if (where.exif)
            return tr("its EXIF data has no orientation that can be changed");
        f.close();
        if (!f.open(QIODevice::ReadOnly))
            return f.errorString();
        QByteArray bytes = f.readAll();
        f.close();
        bytes.insert(where.insertAt, exifSegment(next));
        return replaceKeepingAttributes(path, bytes);
    }
    QImageReader reader(path);
    reader.setAutoTransform(false);
    const QByteArray format = reader.format();
    if (reader.imageCount() > 1)
        return tr("animated pictures are not turned");
    QImage image = reader.read();
    if (image.isNull())
        return reader.errorString();
    image = image.transformed(QTransform().rotate(clockwise ? 90 : -90));
    QByteArray bytes;
    QBuffer buffer(&bytes);
    buffer.open(QIODevice::WriteOnly);
    QImageWriter writer(&buffer, format);
    if (!writer.write(image))
        return writer.errorString();
    return replaceKeepingAttributes(path, bytes);
}
} // namespace ImageRotate
