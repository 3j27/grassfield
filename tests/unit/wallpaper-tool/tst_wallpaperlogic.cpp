#include <gtest/gtest.h>

#include <QBuffer>
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QImage>
#include <QImageWriter>
#include <QPainter>
#include <QTemporaryDir>

#include <sys/stat.h>
#include <unistd.h>

#include "wallpaperlogic.h"

using namespace wallpaper;

namespace {

QString savePng(const QTemporaryDir &dir, const QString &name, const QImage &img)
{
    const QString path = dir.filePath(name);
    EXPECT_TRUE(img.save(path, "PNG"));
    return path;
}

// Left half red, right half blue, a white top strip: orientation and fit checks read these.
QImage halves(int w, int h)
{
    QImage img(w, h, QImage::Format_RGB32);
    img.fill(Qt::blue);
    QPainter p(&img);
    p.fillRect(0, 0, w / 2, h, Qt::red);
    p.end();
    return img;
}

} // namespace

TEST(WallpaperTool, ParsesFitAndSize)
{
    Fit f;
    EXPECT_TRUE(parseFit(QStringLiteral("tile"), &f));
    EXPECT_EQ(f, Fit::Tile);
    EXPECT_FALSE(parseFit(QStringLiteral("zoom"), &f));
    EXPECT_FALSE(parseFit(QString(), &f));
    QSize s;
    EXPECT_TRUE(parseSize(QStringLiteral("1920x1080"), &s));
    EXPECT_EQ(s, QSize(1920, 1080));
    for (const char *bad : {"", "0x10", "10x0", "-1x5", "20000x10", "10x", "x10", "1x2x3", "axb", "9000x9000", "1920*1080"})
        EXPECT_FALSE(parseSize(QString::fromLatin1(bad), &s)) << bad;
}

TEST(WallpaperTool, CheckFileRefusesWhatIsNotARegularFile)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    EXPECT_EQ(checkFile(dir.filePath(QStringLiteral("missing.png")), kMaxFileBytes), NotFound);
    EXPECT_EQ(checkFile(dir.path(), kMaxFileBytes), NotRegular);
    const QString fifo = dir.filePath(QStringLiteral("pipe.png"));
    ASSERT_EQ(::mkfifo(QFile::encodeName(fifo).constData(), 0600), 0);
    EXPECT_EQ(checkFile(fifo, kMaxFileBytes), NotRegular); // must return at once, not block on open
    const QString loopA = dir.filePath(QStringLiteral("a.png"));
    ASSERT_EQ(::symlink("a.png", QFile::encodeName(loopA).constData()), 0);
    EXPECT_EQ(checkFile(loopA, kMaxFileBytes), Unreadable);
    QFile f(dir.filePath(QStringLiteral("ok.png")));
    ASSERT_TRUE(f.open(QIODevice::WriteOnly));
    f.write(QByteArray(100, 'x'));
    f.close();
    qint64 bytes = 0, mtime = 0;
    EXPECT_EQ(checkFile(f.fileName(), kMaxFileBytes, &bytes, &mtime), Ok);
    EXPECT_EQ(bytes, 100);
    EXPECT_GT(mtime, 0);
    EXPECT_EQ(checkFile(f.fileName(), 50), TooLargeFile);
}

TEST(WallpaperTool, ProbeRefusesCorruptEmptyAndWrongFiles)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    QSize size;
    const QString good = savePng(dir, QStringLiteral("good.png"), halves(40, 20));
    EXPECT_EQ(probePicture(good, &size), Ok);
    EXPECT_EQ(size, QSize(40, 20));

    QFile empty(dir.filePath(QStringLiteral("empty.png")));
    ASSERT_TRUE(empty.open(QIODevice::WriteOnly));
    empty.close();
    EXPECT_NE(probePicture(empty.fileName(), &size), Ok);

    QFile text(dir.filePath(QStringLiteral("text.jpg")));
    ASSERT_TRUE(text.open(QIODevice::WriteOnly));
    text.write("this is not a picture at all\n");
    text.close();
    EXPECT_NE(probePicture(text.fileName(), &size), Ok);

    // A truncated PNG: the header reads, the data does not.
    QFile whole(good);
    ASSERT_TRUE(whole.open(QIODevice::ReadOnly));
    const QByteArray bytes = whole.readAll();
    QFile cut(dir.filePath(QStringLiteral("cut.png")));
    ASSERT_TRUE(cut.open(QIODevice::WriteOnly));
    cut.write(bytes.left(bytes.size() / 2));
    cut.close();
    QImage out;
    EXPECT_EQ(loadPicture(cut.fileName(), QSize(40, 20), Fit::Fill, &out), Unreadable);
    EXPECT_TRUE(out.isNull());
}

TEST(WallpaperTool, RefusesAHugeDeclaredSizeBeforeDecoding)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    // A valid 1x1 PNG whose IHDR claims 50000x50000: the header is read, nothing is allocated.
    QImage tiny(1, 1, QImage::Format_RGB32);
    tiny.fill(Qt::red);
    QBuffer buf;
    buf.open(QIODevice::WriteOnly);
    ASSERT_TRUE(tiny.save(&buf, "PNG"));
    QByteArray png = buf.data();
    const int ihdr = png.indexOf("IHDR");
    ASSERT_GT(ihdr, 0);
    auto put32 = [&](int at, quint32 v) {
        png[at] = char(v >> 24);
        png[at + 1] = char(v >> 16);
        png[at + 2] = char(v >> 8);
        png[at + 3] = char(v);
    };
    put32(ihdr + 4, 50000);
    put32(ihdr + 8, 50000);
    QFile f(dir.filePath(QStringLiteral("huge.png")));
    ASSERT_TRUE(f.open(QIODevice::WriteOnly));
    f.write(png);
    f.close();
    QSize size;
    const ExitCode code = probePicture(f.fileName(), &size);
    // Either the reader refuses the header (unreadable: bad CRC) or reports the size and we refuse it: never Ok.
    EXPECT_TRUE(code == TooLargePicture || code == Unreadable) << code;
    QImage out;
    EXPECT_NE(loadPicture(f.fileName(), QSize(100, 100), Fit::Fill, &out), Ok);
    EXPECT_TRUE(out.isNull());
}

TEST(WallpaperTool, FitModesHavePixelsWhereTheyShould)
{
    const QSize target(200, 100);
    const QImage src = halves(100, 100); // square: left red, right blue
    const QColor backdrop(10, 200, 30);

    // Fill: covers everything, the centre crop of a square on a wide canvas keeps the red/blue split in the middle.
    QImage fill = compose(src, target, Fit::Fill, backdrop);
    EXPECT_EQ(fill.size(), target);
    EXPECT_EQ(QColor(fill.pixel(10, 50)).red(), 255);
    EXPECT_EQ(QColor(fill.pixel(190, 50)).blue(), 255);
    for (int x : {0, 199})
        EXPECT_NE(QColor(fill.pixel(x, 50)), backdrop);

    // Fit: the square sits in the middle, the backdrop shows left and right.
    QImage fit = compose(src, target, Fit::Fit, backdrop);
    EXPECT_EQ(QColor(fit.pixel(5, 50)), backdrop);
    EXPECT_EQ(QColor(fit.pixel(194, 50)), backdrop);
    EXPECT_EQ(QColor(fit.pixel(60, 50)).red(), 255);
    EXPECT_EQ(QColor(fit.pixel(140, 50)).blue(), 255);

    // Stretch: red on the left half of the canvas, blue on the right.
    QImage stretch = compose(src, target, Fit::Stretch, backdrop);
    EXPECT_EQ(QColor(stretch.pixel(20, 50)).red(), 255);
    EXPECT_EQ(QColor(stretch.pixel(180, 50)).blue(), 255);

    // Center: 1:1, so the 100 px square is 50 px from each side.
    QImage center = compose(src, target, Fit::Center, backdrop);
    EXPECT_EQ(QColor(center.pixel(10, 50)), backdrop);
    EXPECT_EQ(QColor(center.pixel(70, 50)).red(), 255);
    EXPECT_EQ(QColor(center.pixel(130, 50)).blue(), 255);

    // Tile: the 100 px picture repeats twice.
    QImage tile = compose(src, target, Fit::Tile, backdrop);
    EXPECT_EQ(QColor(tile.pixel(10, 50)).red(), 255);
    EXPECT_EQ(QColor(tile.pixel(60, 50)).blue(), 255);
    EXPECT_EQ(QColor(tile.pixel(110, 50)).red(), 255);
    EXPECT_EQ(QColor(tile.pixel(160, 50)).blue(), 255);
}

TEST(WallpaperTool, FitModesAtTheReferenceSizes)
{
    const QImage src = halves(3000, 2000);
    for (const QSize target : {QSize(1920, 1080), QSize(2560, 1600)}) {
        for (Fit fit : {Fit::Fill, Fit::Fit, Fit::Stretch, Fit::Center, Fit::Tile}) {
            const QImage out = compose(src, target, fit, QColor(Qt::black));
            EXPECT_EQ(out.size(), target);
            EXPECT_EQ(out.format(), QImage::Format_RGB32);
        }
    }
}

TEST(WallpaperTool, ExifOrientationIsApplied)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    // Write a 60x20 picture (left red, right blue) with the EXIF orientation "rotate 90 clockwise to view" (6): the
    // displayed picture is 20x60 with red on top. Qt writes the tag from the writer's transformation.
    const QString path = dir.filePath(QStringLiteral("rot.jpg"));
    {
        QImageWriter w(path, "jpeg");
        w.setQuality(100);
        w.setTransformation(QImageIOHandler::TransformationRotate90);
        const QImage src = halves(60, 20);
        if (!w.write(src))
            GTEST_SKIP() << "this Qt cannot write an EXIF orientation: " << w.errorString().toStdString();
    }
    QSize size;
    ASSERT_EQ(probePicture(path, &size), Ok);
    EXPECT_EQ(size, QSize(20, 60)) << "the displayed size swaps the sides";
    QImage img;
    ASSERT_EQ(loadPicture(path, QSize(20, 60), Fit::Fill, &img), Ok);
    EXPECT_EQ(img.size(), QSize(20, 60));
    // Whatever way the writer rotated the stored data, the two colours are stacked, not side by side.
    const QColor top(img.pixel(10, 5)), bottom(img.pixel(10, 55));
    EXPECT_NE(top.red() > 128, bottom.red() > 128);
}

TEST(WallpaperTool, StripStatsSeeTheTopRowsOnly)
{
    QImage img(100, 100, QImage::Format_RGB32);
    img.fill(Qt::black);
    QPainter p(&img);
    p.fillRect(50, 0, 50, 24, Qt::white); // top strip, right half white
    p.fillRect(0, 24, 100, 76, Qt::white); // below the strip: must not count
    p.end();
    const QJsonObject s = stripStats(img, 24);
    EXPECT_EQ(s.value(QStringLiteral("rows")).toInt(), 24);
    const QJsonObject left = s.value(QStringLiteral("left")).toObject(), right = s.value(QStringLiteral("right")).toObject(), all = s.value(QStringLiteral("all")).toObject();
    EXPECT_NEAR(left.value(QStringLiteral("mean")).toDouble(), 0.0, 1e-9);
    EXPECT_NEAR(right.value(QStringLiteral("mean")).toDouble(), 1.0, 1e-9);
    EXPECT_NEAR(all.value(QStringLiteral("mean")).toDouble(), 0.5, 1e-9);
    EXPECT_NEAR(all.value(QStringLiteral("p5")).toDouble(), 0.0, 1e-3);
    EXPECT_NEAR(all.value(QStringLiteral("p95")).toDouble(), 1.0, 1e-3);
    // Mid grey 0x80 is 0.2158 in linear light.
    QImage grey(10, 10, QImage::Format_RGB32);
    grey.fill(QColor(128, 128, 128));
    EXPECT_NEAR(stripStats(grey, 5).value(QStringLiteral("all")).toObject().value(QStringLiteral("mean")).toDouble(), 0.2158, 2e-3);
    // More rows than the image has.
    EXPECT_EQ(stripStats(grey, 500).value(QStringLiteral("rows")).toInt(), 10);
}

TEST(WallpaperTool, MeanColour)
{
    QImage img(10, 10, QImage::Format_RGB32);
    img.fill(QColor(10, 20, 30));
    EXPECT_EQ(meanColor(img), QStringLiteral("#0a141e"));
}

TEST(WallpaperTool, CacheKeyDependsOnEveryInput)
{
    const QSize s(1920, 1080);
    const QString base = cacheKey(QStringLiteral("/a/b.jpg"), 100, 5, s, Fit::Fill, QColor(Qt::black), 24);
    EXPECT_EQ(base.size(), 32);
    EXPECT_EQ(base, cacheKey(QStringLiteral("/a/b.jpg"), 100, 5, s, Fit::Fill, QColor(Qt::black), 24));
    EXPECT_NE(base, cacheKey(QStringLiteral("/a/c.jpg"), 100, 5, s, Fit::Fill, QColor(Qt::black), 24));
    EXPECT_NE(base, cacheKey(QStringLiteral("/a/b.jpg"), 101, 5, s, Fit::Fill, QColor(Qt::black), 24));
    EXPECT_NE(base, cacheKey(QStringLiteral("/a/b.jpg"), 100, 6, s, Fit::Fill, QColor(Qt::black), 24));
    EXPECT_NE(base, cacheKey(QStringLiteral("/a/b.jpg"), 100, 5, QSize(2560, 1600), Fit::Fill, QColor(Qt::black), 24));
    EXPECT_NE(base, cacheKey(QStringLiteral("/a/b.jpg"), 100, 5, s, Fit::Fit, QColor(Qt::black), 24));
    EXPECT_NE(base, cacheKey(QStringLiteral("/a/b.jpg"), 100, 5, s, Fit::Fill, QColor(Qt::white), 24));
    EXPECT_NE(base, cacheKey(QStringLiteral("/a/b.jpg"), 100, 5, s, Fit::Fill, QColor(Qt::black), 30));
}

TEST(WallpaperTool, ListsOneLevelSortedWithoutHiddenOrUnsupported)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    for (const char *name : {"b.jpg", "a.PNG", "C.jpg", ".hidden.jpg", "notes.txt", "movie.mp4", "e.webp"}) {
        QFile f(dir.filePath(QString::fromLatin1(name)));
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
        f.write("x");
    }
    ASSERT_TRUE(QDir(dir.path()).mkdir(QStringLiteral("sub")));
    QFile deep(dir.filePath(QStringLiteral("sub/deep.jpg")));
    ASSERT_TRUE(deep.open(QIODevice::WriteOnly));
    deep.close();
    ASSERT_TRUE(QDir(dir.path()).mkdir(QStringLiteral("dir.jpg"))); // a directory named like a picture
    const QString fifo = dir.filePath(QStringLiteral("pipe.jpg"));
    ASSERT_EQ(::mkfifo(QFile::encodeName(fifo).constData(), 0600), 0);

    QStringList files;
    bool truncated = true;
    qint64 mtime = 0;
    ASSERT_EQ(listFolder(dir.path(), {QStringLiteral("jpg"), QStringLiteral("png"), QStringLiteral("webp")}, 100, &files, &truncated, &mtime), Ok);
    EXPECT_FALSE(truncated);
    EXPECT_GT(mtime, 0);
    QStringList names;
    for (const QString &f : files)
        names << QFileInfo(f).fileName();
    // UTF-16 order: upper case before lower case, as JavaScript sorts.
    EXPECT_EQ(names, (QStringList{QStringLiteral("C.jpg"), QStringLiteral("a.PNG"), QStringLiteral("b.jpg"), QStringLiteral("e.webp")}));
    for (const QString &f : files)
        EXPECT_TRUE(f.startsWith(dir.path() + QLatin1Char('/')));

    ASSERT_EQ(listFolder(dir.path(), {QStringLiteral("jpg"), QStringLiteral("png"), QStringLiteral("webp")}, 2, &files, &truncated, &mtime), Ok);
    EXPECT_TRUE(truncated);
    EXPECT_EQ(files.size(), 2);
}

TEST(WallpaperTool, ListErrors)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    QStringList files;
    bool truncated = false;
    qint64 mtime = 0;
    EXPECT_EQ(listFolder(dir.filePath(QStringLiteral("missing")), {QStringLiteral("jpg")}, 10, &files, &truncated, &mtime), NotFound);
    QFile f(dir.filePath(QStringLiteral("file.jpg")));
    ASSERT_TRUE(f.open(QIODevice::WriteOnly));
    f.close();
    EXPECT_EQ(listFolder(f.fileName(), {QStringLiteral("jpg")}, 10, &files, &truncated, &mtime), NotRegular);
    ASSERT_EQ(listFolder(dir.path(), {QStringLiteral("jpg")}, 10, &files, &truncated, &mtime), Ok);
    EXPECT_TRUE(files.isEmpty() || files.size() == 1);
}

TEST(WallpaperTool, SupportedSuffixesAreDecodable)
{
    const QStringList s = supportedSuffixes();
    EXPECT_TRUE(s.contains(QStringLiteral("png")));
    EXPECT_TRUE(s.contains(QStringLiteral("jpg")));
    EXPECT_FALSE(s.contains(QStringLiteral("svg")));
}

TEST(WallpaperTool, PruneKeepsTheNewestAndTheNamedFile)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    QStringList paths;
    for (int i = 0; i < 4; ++i) {
        QFile f(dir.filePath(QStringLiteral("f%1.bin").arg(i)));
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
        f.write(QByteArray(1000, 'x'));
        f.close();
        // Old enough to be removable (files from the last minute are never removed).
        ASSERT_TRUE(f.open(QIODevice::ReadWrite));
        f.setFileTime(QDateTime::currentDateTime().addSecs(-3600 + i * 60), QFileDevice::FileModificationTime);
        paths << f.fileName();
    }
    pruneCache(dir.path(), 2500, paths[0]);
    EXPECT_TRUE(QFile::exists(paths[0])) << "the kept file is never removed";
    EXPECT_FALSE(QFile::exists(paths[1])) << "the oldest of the rest goes first";
    EXPECT_TRUE(QFile::exists(paths[3]));
}

TEST(WallpaperTool, WriteAtomicLeavesNoTemporaryFile)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("out.json"));
    ASSERT_TRUE(writeAtomic(path, "{}"));
    ASSERT_TRUE(writeAtomic(path, "{\"a\":1}"));
    QFile f(path);
    ASSERT_TRUE(f.open(QIODevice::ReadOnly));
    EXPECT_EQ(f.readAll(), QByteArray("{\"a\":1}"));
    EXPECT_EQ(QDir(dir.path()).entryList(QDir::Files).size(), 1);
    EXPECT_FALSE(writeAtomic(dir.filePath(QStringLiteral("missing-dir/x")), "x"));
}

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
