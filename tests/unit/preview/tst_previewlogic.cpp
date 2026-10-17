#include <gtest/gtest.h>

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QTemporaryDir>

#include "previewlogic.h"

using namespace preview;

namespace {
QString touch(const QTemporaryDir &dir, const QString &name, const QByteArray &data = "x")
{
    const QString path = dir.filePath(name);
    QFile f(path);
    EXPECT_TRUE(f.open(QIODevice::WriteOnly));
    f.write(data);
    return path;
}
} // namespace

TEST(PreviewLogic, AcceptsPathsAndFileUrls)
{
    QString why;
    EXPECT_EQ(localPathFromArgument(QStringLiteral("/tmp/a.png"), QStringLiteral("/"), &why), QStringLiteral("/tmp/a.png"));
    EXPECT_EQ(localPathFromArgument(QStringLiteral("file:///tmp/a%20b.png"), QStringLiteral("/"), &why), QStringLiteral("/tmp/a b.png"));
    EXPECT_EQ(localPathFromArgument(QStringLiteral("file://localhost/tmp/a.png"), QStringLiteral("/"), &why), QStringLiteral("/tmp/a.png"));
    EXPECT_EQ(localPathFromArgument(QStringLiteral("x/../y.png"), QStringLiteral("/tmp"), &why), QStringLiteral("/tmp/y.png"));
}

TEST(PreviewLogic, RejectsOtherSchemesAndHosts)
{
    for (const char *bad : {"http://example.org/a.png", "https://example.org/a.pdf", "ftp://h/x", "smb://h/s/x", "data:text/plain,hi",
                            "file://example.org/etc/passwd", "file:///tmp/a.png?x=1", "file:///tmp/a.png#frag", "gopher://h/", "   ", ""}) {
        QString why;
        EXPECT_TRUE(localPathFromArgument(QString::fromLatin1(bad), QStringLiteral("/"), &why).isEmpty()) << bad;
        EXPECT_FALSE(why.isEmpty()) << bad;
    }
}

TEST(PreviewLogic, ColonInExistingFileNameIsAPath)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    touch(dir, QStringLiteral("a:b.txt"));
    EXPECT_EQ(localPathFromArgument(QStringLiteral("a:b.txt"), dir.path()), dir.filePath(QStringLiteral("a:b.txt")));
}

TEST(PreviewLogic, ResolveArgumentsKeepsRegularFilesOnly)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const QString a = touch(dir, QStringLiteral("a.txt"));
    QDir(dir.path()).mkdir(QStringLiteral("sub"));
    const Arguments r = resolveArguments({a, a, dir.filePath(QStringLiteral("sub")), dir.filePath(QStringLiteral("missing.png")),
                                          QStringLiteral("http://x/y.png"), QStringLiteral("/dev/zero")}, dir.path());
    EXPECT_EQ(r.paths, QStringList{a});
    EXPECT_EQ(r.errors.size(), 4);
}

TEST(PreviewLogic, ResolveArgumentsCapsTheCount)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    QStringList args;
    for (int i = 0; i < kMaxFiles + 5; ++i)
        args << touch(dir, QStringLiteral("f%1.txt").arg(i));
    const Arguments r = resolveArguments(args, dir.path());
    EXPECT_EQ(r.paths.size(), kMaxFiles);
    EXPECT_EQ(r.errors.size(), 1);
}

TEST(PreviewLogic, RoutesByType)
{
    EXPECT_EQ(classify(QStringLiteral("/x/a.png")), Kind::Image);
    EXPECT_EQ(classify(QStringLiteral("/x/a.JPG")), Kind::Image);
    EXPECT_EQ(classify(QStringLiteral("/x/a.tiff")), Kind::Image);
    EXPECT_EQ(classify(QStringLiteral("/x/a.gif")), Kind::Image);
    EXPECT_EQ(classify(QStringLiteral("/x/a.pdf")), Kind::Pdf);
    EXPECT_EQ(classify(QStringLiteral("/x/a.txt")), Kind::Text);
    EXPECT_EQ(classify(QStringLiteral("/x/a.py")), Kind::Text);
    EXPECT_EQ(classify(QStringLiteral("/x/a.cpp")), Kind::Text);
    EXPECT_EQ(classify(QStringLiteral("/x/a.json")), Kind::Text);
    EXPECT_EQ(classify(QStringLiteral("/x/a.md")), Kind::Text);
    EXPECT_EQ(classify(QStringLiteral("/x/a.mp4")), Kind::Video);
    EXPECT_EQ(classify(QStringLiteral("/x/a.webm")), Kind::Video);
    EXPECT_EQ(classify(QStringLiteral("/x/a.mp3")), Kind::Audio);
    EXPECT_EQ(classify(QStringLiteral("/x/a.flac")), Kind::Audio);
    EXPECT_EQ(classify(QStringLiteral("/x/a.wav")), Kind::Audio);
    EXPECT_EQ(classify(QStringLiteral("/x/a.zip")), Kind::Unsupported);
    EXPECT_EQ(classify(QStringLiteral("/x/a.exe")), Kind::Unsupported);
    EXPECT_EQ(classify(QStringLiteral("/x/a.m3u")), Kind::Text);
    EXPECT_EQ(classify(QStringLiteral("/x/a.m3u8")), Kind::Text);
    EXPECT_EQ(classify(QStringLiteral("/x/a.pls")), Kind::Text);
    EXPECT_EQ(classify(QStringLiteral("/x/a.xspf")), Kind::Text);
    EXPECT_EQ(classify(QStringLiteral("/x/a.asx")), Kind::Text);
    EXPECT_EQ(classify(QStringLiteral("/x/a.ASX")), Kind::Text);
    EXPECT_EQ(classify(QStringLiteral("/x/a.wpl")), Kind::Text);
    EXPECT_EQ(classify(QStringLiteral("/x/a.vlc")), Kind::Text);
    EXPECT_EQ(kindName(Kind::Pdf), QStringLiteral("pdf"));
    EXPECT_EQ(kindName(Kind::Unsupported), QStringLiteral("unsupported"));
}

// Playlists are text whatever Qt calls them: the canonical type (audio/x-ms-asx for every ASX suffix),
// its aliases and the content of extensionless files.
TEST(PreviewLogic, PlaylistsAreTextWhateverTheMimeName)
{
    for (const char *ext : {"asx", "wvx", "wax", "wmx", "WVX", "m3u", "m3u8", "pls", "xspf", "wpl", "vlc"})
        EXPECT_EQ(classify(QStringLiteral("/x/a.") + QString::fromLatin1(ext)), Kind::Text) << ext;
    // A real ASF container is not a playlist (its alias video/x-ms-asf-plugin must not make it one).
    EXPECT_NE(classify(QStringLiteral("/x/a.asf")), Kind::Text);

    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const struct { const char *name; const char *data; } samples[] = {
        {"asx-plain", "<ASX version=\"3.0\"><Entry><Ref href=\"http://example.invalid/a\"/></Entry></ASX>"},
        {"asx-xml", "<?xml version=\"1.0\"?>\n<asx version=\"3.0\"><entry><ref href=\"mms://example.invalid/a\"/></entry></asx>"},
        {"asx-lead-space", "\n  <asx version=\"3.0\"></asx>"},
        {"m3u", "#EXTM3U\nhttp://example.invalid/a.mp3\n"},
        {"pls", "[playlist]\nFile1=http://example.invalid/a\n"},
        {"xspf", "<?xml version=\"1.0\"?><playlist version=\"1\" xmlns=\"http://xspf.org/ns/0/\"></playlist>"},
        {"wpl", "<?wpl version=\"1.0\"?><smil><body><seq><media src=\"http://example.invalid/a\"/></seq></body></smil>"},
    };
    for (const auto &s : samples)
        EXPECT_EQ(classify(touch(dir, QString::fromLatin1(s.name), s.data)), Kind::Text) << s.name;
    // The same content under a media suffix is still a playlist.
    EXPECT_EQ(classify(touch(dir, QStringLiteral("clip.mp3"), "<asx version=\"3.0\"></asx>")), Kind::Text);
    // A plain binary stays unsupported.
    EXPECT_EQ(classify(touch(dir, QStringLiteral("blob"), QByteArray("\x00\x01\x02\x03", 4))), Kind::Unsupported);
}

TEST(PreviewLogic, ImageSizeCaps)
{
    EXPECT_TRUE(imageSizeAllowed(QSize(4000, 3000)));
    EXPECT_TRUE(imageSizeAllowed(QSize(8192, 8192)));      // 256 MiB exactly at 4 bytes per pixel
    EXPECT_FALSE(imageSizeAllowed(QSize(8193, 8192)));     // allocation limit
    EXPECT_FALSE(imageSizeAllowed(QSize(50000, 50000)));   // hostile header
    EXPECT_FALSE(imageSizeAllowed(QSize(kMaxImageSide + 1, 1)));
    EXPECT_FALSE(imageSizeAllowed(QSize(0, 10)));
    EXPECT_FALSE(imageSizeAllowed(QSize()));
}

TEST(PreviewLogic, PngHeaderSize)
{
    QByteArray head("\x89PNG\r\n\x1a\n\0\0\0\x0dIHDR", 16);
    head.append(QByteArray("\0\0\xc3\x50\0\0\xc3\x50\x08\x02\0\0\0", 13)); // 50000 x 50000
    EXPECT_EQ(pngSize(head), QSize(50000, 50000));
    EXPECT_FALSE(imageSizeAllowed(pngSize(head)));
    EXPECT_FALSE(pngSize(QByteArray("GIF89a")).isValid());
    EXPECT_FALSE(pngSize(head.left(20)).isValid());
    QByteArray zero = head;
    zero[19] = 0; zero[18] = 0; zero[17] = 0; zero[16] = 0;
    EXPECT_FALSE(pngSize(zero).isValid());
}

TEST(PreviewLogic, TextCaps)
{
    EXPECT_TRUE(textSizeAllowed(0));
    EXPECT_TRUE(textSizeAllowed(kMaxTextBytes));
    EXPECT_FALSE(textSizeAllowed(kMaxTextBytes + 1));
    EXPECT_FALSE(textSizeAllowed(-1));
    EXPECT_TRUE(looksBinary(QByteArray("ab\0cd", 5)));
    EXPECT_FALSE(looksBinary(QByteArray("plain text\n")));
}

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}

TEST(PreviewLogic, SystemPathsRefused)
{
    EXPECT_TRUE(isSystemPath(QStringLiteral("/proc/self/status")));
    EXPECT_TRUE(isSystemPath(QStringLiteral("/sys/class")));
    EXPECT_TRUE(isSystemPath(QStringLiteral("/dev/null")));
    EXPECT_FALSE(isSystemPath(QStringLiteral("/home/u/devices.txt")));
    EXPECT_FALSE(isSystemPath(QStringLiteral("/procfile")));
    const Arguments a = resolveArguments({QStringLiteral("/proc/self/status"), QStringLiteral("/proc/version")}, QStringLiteral("/"));
    EXPECT_TRUE(a.paths.isEmpty());
    EXPECT_EQ(a.errors.size(), 2);
}
