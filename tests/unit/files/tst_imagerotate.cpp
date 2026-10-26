// Unit tests for apps/files/src/imagerotate.{h,cpp} (gtest): the preview pane's Rotate Left / Rotate Right
// (docs/specs/files.md "Preview pane"). Built and run by scripts/dev/test.sh. The file tests only write under
// GRASSFIELD_TEST_TMP, a directory inside the repository's .dev/ (set by scripts/dev/test.sh); they skip without it.
#include "imagerotate.h"

#include <QBuffer>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QImage>
#include <QImageReader>
#include <QTemporaryDir>

#include <memory>
#include <sys/stat.h>
#include <sys/xattr.h>

#include <gtest/gtest.h>

using namespace ImageRotate;

namespace
{
std::unique_ptr<QTemporaryDir> sandbox()
{
    const QString base = qEnvironmentVariable("GRASSFIELD_TEST_TMP");
    if (base.isEmpty() || !QDir::cleanPath(base).contains(QLatin1String("/.dev/")))
        return nullptr;
    QDir().mkpath(base);
    auto dir = std::make_unique<QTemporaryDir>(base + QStringLiteral("/imagerotate-XXXXXX"));
    return dir->isValid() ? std::move(dir) : nullptr;
}

// A 40 x 20 picture: left half red, right half blue.
QImage picture()
{
    QImage image(40, 20, QImage::Format_RGB32);
    for (int y = 0; y < 20; y++) {
        for (int x = 0; x < 40; x++)
            image.setPixel(x, y, x < 20 ? qRgb(255, 0, 0) : qRgb(0, 0, 255));
    }
    return image;
}

QByteArray encoded(const QImage &image, const char *format)
{
    QByteArray bytes;
    QBuffer buffer(&bytes);
    buffer.open(QIODevice::WriteOnly);
    image.save(&buffer, format);
    return bytes;
}

QByteArray readAll(const QString &path)
{
    QFile f(path);
    return f.open(QIODevice::ReadOnly) ? f.readAll() : QByteArray();
}
} // namespace

TEST(ImageRotate, AQuarterTurnFollowsTheExifTable)
{
    EXPECT_EQ(turned(1, true), 6);
    EXPECT_EQ(turned(6, true), 3);
    EXPECT_EQ(turned(3, true), 8);
    EXPECT_EQ(turned(8, true), 1);
    EXPECT_EQ(turned(1, false), 8);
    EXPECT_EQ(turned(8, false), 3);
    // Mirrored pictures stay mirrored.
    EXPECT_EQ(turned(2, true), 7);
    EXPECT_EQ(turned(7, true), 4);
    EXPECT_EQ(turned(4, true), 5);
    EXPECT_EQ(turned(5, true), 2);
    EXPECT_EQ(turned(0, true), 6) << "an unknown value reads as 1";
    for (int o = 1; o <= 8; o++)
        EXPECT_EQ(turned(turned(o, true), false), o);
}

TEST(ImageRotate, OnlyLosslessKindsTurn)
{
    EXPECT_EQ(methodFor("image/jpeg"), Method::Orientation);
    EXPECT_EQ(methodFor("image/png"), Method::Reencode);
    EXPECT_EQ(methodFor("image/tiff"), Method::Reencode);
    EXPECT_EQ(methodFor("image/bmp"), Method::Reencode);
    EXPECT_EQ(methodFor("image/webp"), Method::None);
    EXPECT_EQ(methodFor("image/gif"), Method::None);
    EXPECT_EQ(methodFor("application/pdf"), Method::None);
}

TEST(ImageRotate, TheMinimalSegmentParses)
{
    const QByteArray jpeg = QByteArray("\xFF\xD8", 2) + exifSegment(6) + QByteArray("\xFF\xDA\x00\x02", 4);
    const JpegOrientation where = findOrientation(jpeg);
    EXPECT_TRUE(where.valid);
    EXPECT_TRUE(where.exif);
    EXPECT_TRUE(where.bigEndian);
    EXPECT_EQ(where.value, 6);
    ASSERT_GE(where.offset, 0);
    EXPECT_EQ(quint8(jpeg.at(where.offset + 1)), 6);
}

TEST(ImageRotate, ALittleEndianTagIsFound)
{
    // II TIFF, IFD0 with one entry: orientation 3.
    QByteArray tiff("II\x2A\x00\x08\x00\x00\x00", 8);
    tiff.append("\x01\x00", 2);
    tiff.append("\x12\x01\x03\x00\x01\x00\x00\x00\x03\x00\x00\x00", 12);
    tiff.append("\x00\x00\x00\x00", 4);
    const QByteArray body = QByteArray("Exif\0\0", 6) + tiff;
    QByteArray segment("\xFF\xE1", 2);
    segment.append(char(0));
    segment.append(char(body.size() + 2));
    const QByteArray jpeg = QByteArray("\xFF\xD8", 2) + segment + body + QByteArray("\xFF\xDA\x00\x02", 4);
    const JpegOrientation where = findOrientation(jpeg);
    EXPECT_TRUE(where.valid);
    EXPECT_FALSE(where.bigEndian);
    EXPECT_EQ(where.value, 3);
}

TEST(ImageRotate, BrokenFilesAreNotJpeg)
{
    EXPECT_FALSE(findOrientation(QByteArray("GIF89a")).valid);
    EXPECT_FALSE(findOrientation(QByteArray("\xFF\xD8\xFF\xE1\xFF\xFF", 6)).valid) << "a segment longer than the file";
}

TEST(ImageRotate, AJpegWithoutExifGetsOneAndKeepsItsTagsAndMode)
{
    auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (a directory under .dev/) is not set";
    const QString path = dir->filePath(QStringLiteral("photo.jpg"));
    ASSERT_TRUE(picture().save(path, "JPEG", 95));
    ASSERT_EQ(::chmod(QFile::encodeName(path).constData(), 0640), 0);
    const bool xattrs = ::lsetxattr(QFile::encodeName(path).constData(), "user.xdg.tags", "Red", 3, 0) == 0;
    const QByteArray before = readAll(path);
    EXPECT_EQ(rotate(path, "image/jpeg", true), QString());
    const QByteArray after = readAll(path);
    EXPECT_EQ(after.size(), before.size() + exifSegment(6).size()) << "only the segment was added";
    EXPECT_EQ(findOrientation(after).value, 6);
    QImageReader reader(path);
    EXPECT_EQ(reader.transformation(), QImageIOHandler::TransformationRotate90);
    reader.setAutoTransform(true);
    EXPECT_EQ(reader.read().size(), QSize(20, 40)) << "shown turned";
    struct stat st {};
    ASSERT_EQ(::stat(QFile::encodeName(path).constData(), &st), 0);
    EXPECT_EQ(st.st_mode & 0777, 0640u);
    if (xattrs) {
        char value[8] = {};
        EXPECT_EQ(::lgetxattr(QFile::encodeName(path).constData(), "user.xdg.tags", value, sizeof value), 3);
        EXPECT_EQ(QByteArray(value, 3), QByteArray("Red"));
    }
    EXPECT_TRUE(QDir(dir->path()).entryList(QDir::Hidden | QDir::Files).filter(QStringLiteral(".grassfield-rotate")).isEmpty()) << "no temporary file left";
}

TEST(ImageRotate, AJpegWithAnOrientationChangesInPlace)
{
    auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (a directory under .dev/) is not set";
    const QString path = dir->filePath(QStringLiteral("photo.jpg"));
    QByteArray jpeg = encoded(picture(), "JPEG");
    jpeg.insert(2, exifSegment(6));
    QFile f(path);
    ASSERT_TRUE(f.open(QIODevice::WriteOnly));
    f.write(jpeg);
    f.close();
    struct stat st1 {}, st2 {};
    ASSERT_EQ(::stat(QFile::encodeName(path).constData(), &st1), 0);
    EXPECT_EQ(rotate(path, "image/jpeg", true), QString());
    EXPECT_EQ(findOrientation(readAll(path)).value, 3);
    EXPECT_EQ(rotate(path, "image/jpeg", false), QString());
    EXPECT_EQ(rotate(path, "image/jpeg", false), QString());
    EXPECT_EQ(findOrientation(readAll(path)).value, 1) << "back upright after two anticlockwise turns";
    EXPECT_EQ(rotate(path, "image/jpeg", false), QString());
    EXPECT_EQ(findOrientation(readAll(path)).value, 8);
    ASSERT_EQ(::stat(QFile::encodeName(path).constData(), &st2), 0);
    EXPECT_EQ(st1.st_ino, st2.st_ino) << "the same file, two bytes changed";
    EXPECT_EQ(readAll(path).size(), jpeg.size());
}

TEST(ImageRotate, APngIsWrittenAgainTurned)
{
    auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (a directory under .dev/) is not set";
    const QString path = dir->filePath(QStringLiteral("shot.png"));
    ASSERT_TRUE(picture().save(path, "PNG"));
    EXPECT_EQ(rotate(path, "image/png", false), QString());
    const QImage turnedImage(path);
    ASSERT_EQ(turnedImage.size(), QSize(20, 40));
    // Anticlockwise: the red left half is now the bottom half.
    EXPECT_EQ(turnedImage.pixel(10, 35), qRgb(255, 0, 0));
    EXPECT_EQ(turnedImage.pixel(10, 5), qRgb(0, 0, 255));
}

TEST(ImageRotate, LinksAndOtherKindsAreRefused)
{
    auto dir = sandbox();
    if (!dir)
        GTEST_SKIP() << "GRASSFIELD_TEST_TMP (a directory under .dev/) is not set";
    const QString path = dir->filePath(QStringLiteral("shot.png"));
    ASSERT_TRUE(picture().save(path, "PNG"));
    const QString link = dir->filePath(QStringLiteral("link.png"));
    ASSERT_TRUE(QFile::link(path, link));
    EXPECT_FALSE(rotate(link, "image/png", true).isEmpty());
    EXPECT_FALSE(rotate(path, "image/gif", true).isEmpty());
    EXPECT_EQ(QImage(path).size(), QSize(40, 20)) << "untouched";
}
