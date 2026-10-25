// Unit tests for apps/files/src/appicons.h: what Files decodes of an application's absolute Icon= path. Every fixture is made
// in a temporary tree; the decode runs with QT_QPA_PLATFORM=offscreen (set below) and a refused file must come back at once:
// the reviewer's probes were a FIFO named by an SVG <image href> (the decode blocked for 20 s), a PDF named .png (rendered by
// Qt's PDF plugin), and a PNG of a few KB that allocates hundreds of MB. A test that would block is stopped by the test
// runner's timeout (scripts/dev/test.sh), not left to hang a build.
#include <gtest/gtest.h>

#include <QBuffer>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QImage>
#include <QTemporaryDir>

#include <sys/stat.h>

#include "appicons.h"

namespace
{
class OffscreenApp : public ::testing::Environment
{
public:
    void SetUp() override
    {
        qputenv("QT_QPA_PLATFORM", "offscreen");
        qputenv("QT_QPA_PLATFORMTHEME", "none");
        static int argc = 1;
        static char name[] = "tst_appicons";
        static char *argv[] = {name, nullptr};
        m_app = new QGuiApplication(argc, argv);
    }
    void TearDown() override { delete m_app; }

private:
    QGuiApplication *m_app = nullptr;
};
const auto *const env = ::testing::AddGlobalTestEnvironment(new OffscreenApp);

QByteArray pngBytes(int w, int h, QImage::Format format = QImage::Format_ARGB32)
{
    QImage image(w, h, format);
    image.fill(Qt::red);
    QByteArray bytes;
    QBuffer buffer(&bytes);
    buffer.open(QIODevice::WriteOnly);
    image.save(&buffer, "PNG");
    return bytes;
}

void write(const QString &path, const QByteArray &bytes)
{
    QFile f(path);
    ASSERT_TRUE(f.open(QIODevice::WriteOnly));
    f.write(bytes);
}

const QByteArray kSvgOpen = "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" width=\"48\" height=\"48\" "
                            "viewBox=\"0 0 48 48\">";

QByteArray svg(const QByteArray &body)
{
    return kSvgOpen + body + "</svg>";
}

const QSize kWant(64, 64);
} // namespace

TEST(AppIcons, APngAndAPlainSvgAreShown)
{
    const QImage png = AppIcons::decode(pngBytes(32, 32), kWant);
    ASSERT_FALSE(png.isNull());
    EXPECT_EQ(png.size(), QSize(32, 32));
    const QImage big = AppIcons::decode(pngBytes(1024, 1024), kWant);
    ASSERT_FALSE(big.isNull());
    EXPECT_LE(big.width(), 64); // scaled down to what was asked

    const QImage vector = AppIcons::decode(svg("<rect width=\"48\" height=\"48\" fill=\"#d00\"/>"), kWant);
    ASSERT_FALSE(vector.isNull());
    EXPECT_EQ(vector.size(), QSize(64, 64));
    EXPECT_NE(vector.pixelColor(10, 10).alpha(), 0);

    // Inner references, gradients and a BOM and XML declaration are ordinary icons.
    const QByteArray gradient = "\xEF\xBB\xBF<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        + svg("<defs><linearGradient id=\"g\"><stop offset=\"0\" stop-color=\"#fff\"/><stop offset=\"1\" stop-color=\"#000\"/></linearGradient>"
              "<rect id=\"r\" width=\"48\" height=\"48\"/></defs><use href=\"#r\" style=\"fill:url(#g)\"/><circle cx=\"9\" cy=\"9\" r=\"4\" fill=\"url( '#g' )\"/>");
    EXPECT_FALSE(AppIcons::decode(gradient, kWant).isNull());
}

TEST(AppIcons, AnSvgThatNamesAFifoIsRefusedAtOnce)
{
    QTemporaryDir tmp;
    ASSERT_TRUE(tmp.isValid());
    const QString root = QFileInfo(tmp.path()).canonicalFilePath();
    const QString fifo = root + QStringLiteral("/icon.fifo");
    ASSERT_EQ(::mkfifo(QFile::encodeName(fifo).constData(), 0600), 0);
    const QByteArray href = QFile::encodeName(fifo);
    // Both spellings of the reviewer's probe, and the other places an SVG can name a file.
    const QList<QByteArray> hostile = {
        svg("<image width=\"48\" height=\"48\" xlink:href=\"" + href + "\"/>"),
        svg("<image width=\"48\" height=\"48\" href=\"file://" + href + "\"/>"),
        svg("<image width=\"48\" height=\"48\" xlink:href=\"data:image/png;base64,iVBORw0KGgo=\"/>"), // pixels not bounded
        svg("<style>@import url(\"" + href + "\");</style><rect width=\"48\" height=\"48\"/>"),
        svg("<style>rect { fill: url(" + href + ") }</style><rect width=\"48\" height=\"48\"/>"),
        svg("<rect style=\"fill:u\\72l(" + href + ")\" width=\"48\" height=\"48\"/>"),
        svg("<rect fill=\"url(" + href + ")\" width=\"48\" height=\"48\"/>"),
        svg("<filter id=\"f\"><feImage xlink:href=\"" + href + "\"/></filter><rect filter=\"url(#f)\" width=\"48\" height=\"48\"/>"),
        svg("<set attributeName=\"xlink:href\" to=\"" + href + "\"/><image width=\"48\" height=\"48\" xlink:href=\"#x\"/>"),
        svg("<g xml:base=\"" + href + "\"><image xlink:href=\"icon\"/></g>"),
        "<!DOCTYPE svg [<!ENTITY x SYSTEM \"" + href + "\">]>" + svg("<text>&x;</text>"),
        "<?xml-stylesheet href=\"" + href + "\" type=\"text/css\"?>" + svg("<rect width=\"48\" height=\"48\"/>"),
        svg("<script>alert(1)</script>"),
        svg("<foreignObject width=\"48\" height=\"48\"><div/></foreignObject>"),
    };
    for (const QByteArray &doc : hostile) {
        QElapsedTimer timer;
        timer.start();
        EXPECT_TRUE(AppIcons::decode(doc, kWant).isNull()) << doc.constData();
        EXPECT_LT(timer.elapsed(), 1000) << doc.constData();
    }
    // Through the file path as well: the file, not only the bytes.
    write(root + QStringLiteral("/evil.svg"), hostile.first());
    QElapsedTimer timer;
    timer.start();
    EXPECT_TRUE(AppIcons::load(root + QStringLiteral("/evil.svg"), {root}, kWant).isNull());
    EXPECT_LT(timer.elapsed(), 1000);
    // A FIFO as the icon itself never blocks either.
    EXPECT_TRUE(AppIcons::load(fifo, {root}, kWant).isNull());
    EXPECT_LT(timer.elapsed(), 1000);
}

TEST(AppIcons, SvgThatCannotBeCheckedIsRefused)
{
    EXPECT_FALSE(AppIcons::svgIsSelfContained(QByteArray()));
    EXPECT_FALSE(AppIcons::svgIsSelfContained(QByteArray("\x1f\x8b\x08\x00 gzip", 9)));              // svgz
    EXPECT_FALSE(AppIcons::svgIsSelfContained(svg("<rect/>").replace("<svg", "<svg><svg")));        // not well formed
    EXPECT_FALSE(AppIcons::svgIsSelfContained("<?xml version=\"1.0\" encoding=\"UTF-16\"?>" + svg("<rect/>")));
    EXPECT_FALSE(AppIcons::svgIsSelfContained(svg(QByteArray(AppIcons::kMaxSvgBytes, ' '))));        // too big
    QByteArray deep;
    for (int i = 0; i <= AppIcons::kMaxSvgDepth; ++i)
        deep += "<g>";
    for (int i = 0; i <= AppIcons::kMaxSvgDepth; ++i)
        deep += "</g>";
    EXPECT_FALSE(AppIcons::svgIsSelfContained(svg(deep)));
    QByteArray uses = "<defs><rect id=\"r\" width=\"1\" height=\"1\"/></defs>";
    for (int i = 0; i <= AppIcons::kMaxSvgUses; ++i)
        uses += "<use href=\"#r\"/>";
    EXPECT_FALSE(AppIcons::svgIsSelfContained(svg(uses)));
    EXPECT_TRUE(AppIcons::svgIsSelfContained(svg("<rect width=\"1\" height=\"1\"/>")));
}

TEST(AppIcons, OnlyPngAndSvgAreDecidedByTheirBytesNotTheirName)
{
    QTemporaryDir tmp;
    ASSERT_TRUE(tmp.isValid());
    const QString root = QFileInfo(tmp.path()).canonicalFilePath();
    // A PDF named .png (Qt's PDF plugin rendered it in 54 ms), and the other formats Qt can decode.
    write(root + QStringLiteral("/pdf.png"), "%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Count 0/Kids[]>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n");
    QByteArray jpeg;
    {
        QBuffer buffer(&jpeg);
        buffer.open(QIODevice::WriteOnly);
        QImage image(16, 16, QImage::Format_RGB32);
        image.fill(Qt::blue);
        image.save(&buffer, "JPEG");
    }
    write(root + QStringLiteral("/jpeg.png"), jpeg);
    write(root + QStringLiteral("/gif.png"), QByteArray("GIF89a") + QByteArray(40, 'x'));
    write(root + QStringLiteral("/text.png"), "not an image at all");
    write(root + QStringLiteral("/real.png"), pngBytes(16, 16));
    write(root + QStringLiteral("/real.xpm"), pngBytes(16, 16)); // the name does not matter, the bytes do
    for (const char *name : {"pdf.png", "jpeg.png", "gif.png", "text.png"})
        EXPECT_TRUE(AppIcons::load(root + QLatin1Char('/') + QLatin1String(name), {root}, kWant).isNull()) << name;
    EXPECT_FALSE(AppIcons::load(root + QStringLiteral("/real.png"), {root}, kWant).isNull());
    EXPECT_FALSE(AppIcons::load(root + QStringLiteral("/real.xpm"), {root}, kWant).isNull());
    // Outside the allowed roots nothing is read at all.
    EXPECT_TRUE(AppIcons::load(root + QStringLiteral("/real.png"), {QStringLiteral("/nonexistent")}, kWant).isNull());
}

TEST(AppIcons, ThePixelSizeIsReadBeforeTheImageIsDecoded)
{
    // At the limit: shown. One pixel over, in either direction, or far over: refused.
    EXPECT_FALSE(AppIcons::decode(pngBytes(AppIcons::kMaxSide, 1), kWant).isNull());
    EXPECT_TRUE(AppIcons::decode(pngBytes(AppIcons::kMaxSide + 1, 1), kWant).isNull());
    EXPECT_TRUE(AppIcons::decode(pngBytes(1, AppIcons::kMaxSide + 1), kWant).isNull());
    // A few KB of a solid colour that would need ~262 MB (8100 x 8100) or more, as in the review: never allocated.
    QElapsedTimer timer;
    timer.start();
    const QByteArray huge = pngBytes(8100, 8100, QImage::Format_Grayscale8);
    EXPECT_LT(huge.size(), 512 * 1024);
    timer.restart();
    EXPECT_TRUE(AppIcons::decode(huge, kWant).isNull());
    EXPECT_LT(timer.elapsed(), 200);
    // A header that claims 20000 x 20000 (the CRC is no longer right): refused, whichever check catches it.
    QByteArray claim = pngBytes(16, 16);
    claim.replace(16, 4, QByteArray("\x00\x00\x4e\x20", 4));
    claim.replace(20, 4, QByteArray("\x00\x00\x4e\x20", 4));
    EXPECT_TRUE(AppIcons::decode(claim, kWant).isNull());
}
