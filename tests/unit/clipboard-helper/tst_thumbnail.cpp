// The image worker's decoding (ADR-0034 §1f): only the format given, every detection off, bounded sizes, bounded output.
#include "cliplogic.h"
#include "thumbnail.h"

#include <QBuffer>
#include <QCoreApplication>
#include <QImage>
#include <QImageWriter>

#include <gtest/gtest.h>

namespace
{
void app()
{
    static int argc = 1;
    static char name[] = "clipboard-helper-unit-tests";
    static char *argv[] = {name, nullptr};
    static QCoreApplication instance(argc, argv); // image plugins are found through it
}

QByteArray encoded(int w, int h, const char *format)
{
    QImage image(w, h, QImage::Format_RGB32);
    image.fill(Qt::darkCyan);
    QByteArray out;
    QBuffer buffer(&out);
    buffer.open(QIODevice::WriteOnly);
    QImageWriter writer(&buffer, format);
    writer.write(image);
    return out;
}
} // namespace

TEST(Thumbnail, DecodesAndScales)
{
    app();
    QByteArray error;
    QImage t = Thumbnail::decode(encoded(1000, 500, "png"), "png", 256, &error);
    ASSERT_FALSE(t.isNull()) << error.constData();
    EXPECT_EQ(t.width(), 256);
    EXPECT_EQ(t.height(), 128);
    t = Thumbnail::decode(encoded(100, 80, "jpeg"), "jpeg", 256, &error);
    ASSERT_FALSE(t.isNull()) << error.constData();
    EXPECT_EQ(t.size(), QSize(100, 80)) << "never enlarged";
    const QByteArray png = Thumbnail::encodePng(t);
    EXPECT_FALSE(png.isEmpty());
    EXPECT_LE(png.size(), ClipLogic::kThumbnailBytes);
}

TEST(Thumbnail, OnlyTheFormatGiven)
{
    app();
    QByteArray error;
    // A PNG offer whose bytes are something else never reaches that format's plugin.
    EXPECT_TRUE(Thumbnail::decode("%PDF-1.7\n1 0 obj\n", "png", 256, &error).isNull());
    EXPECT_TRUE(Thumbnail::decode("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"/>", "png", 256, &error).isNull());
    EXPECT_TRUE(Thumbnail::decode(encoded(10, 10, "jpeg"), "png", 256, &error).isNull()) << "JPEG bytes offered as PNG";
    EXPECT_TRUE(Thumbnail::decode(encoded(10, 10, "png"), "gif", 256, &error).isNull());
    EXPECT_EQ(error, QByteArray("format not allowed"));
    EXPECT_TRUE(Thumbnail::decode(encoded(10, 10, "png"), "svg", 256, &error).isNull());
}

TEST(Thumbnail, SizeLimits)
{
    app();
    QByteArray error;
    EXPECT_TRUE(Thumbnail::decode(encoded(ClipLogic::kMaxImageSide + 1, 2, "png"), "png", 256, &error).isNull());
    EXPECT_EQ(error, QByteArray("too large"));
    EXPECT_TRUE(Thumbnail::decode(QByteArray(), "png", 256, &error).isNull());
}
