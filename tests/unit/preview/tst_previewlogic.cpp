#include <gtest/gtest.h>

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
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

namespace {
QStringList names(const QStringList &paths)
{
    QStringList out;
    for (const QString &p : paths)
        out << QFileInfo(p).fileName();
    return out;
}
} // namespace

TEST(PreviewLogic, BrowseFolderUsesTheFilesOrder)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    // Numeric, case-insensitive name order (what Grassfield Files shows), images only, hidden files left out.
    for (const char *n : {"img10.png", "img2.png", "Img1.png", ".hidden.png", "notes.txt", "photo.jpg"})
        touch(dir, QString::fromLatin1(n));
    QDir(dir.path()).mkdir(QStringLiteral("sub.png"));
    const QString opened = dir.filePath(QStringLiteral("img2.png"));
    const Browse b = browseFolder(opened, BrowseKinds::ImagesOnly, SortSpec{});
    EXPECT_EQ(names(b.paths), (QStringList{QStringLiteral("Img1.png"), QStringLiteral("img2.png"), QStringLiteral("img10.png"), QStringLiteral("photo.jpg")}));
    EXPECT_EQ(b.index, 1);
    EXPECT_EQ(b.paths.at(b.index), opened);
}

TEST(PreviewLogic, BrowseFolderHonoursDirectionAndKinds)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    for (const char *n : {"a.png", "b.png", "c.txt"})
        touch(dir, QString::fromLatin1(n));
    SortSpec descending;
    descending.descending = true;
    const Browse images = browseFolder(dir.filePath(QStringLiteral("a.png")), BrowseKinds::ImagesOnly, descending);
    EXPECT_EQ(names(images.paths), (QStringList{QStringLiteral("b.png"), QStringLiteral("a.png")}));
    EXPECT_EQ(images.index, 1);
    // A Glance browses every kind it can show.
    const Browse all = browseFolder(dir.filePath(QStringLiteral("a.png")), BrowseKinds::Previewable, SortSpec{});
    EXPECT_EQ(names(all.paths), (QStringList{QStringLiteral("a.png"), QStringLiteral("b.png"), QStringLiteral("c.txt")}));
}

TEST(PreviewLogic, BrowseFolderKeepsTheOpenedFileEvenIfAlone)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const QString only = touch(dir, QStringLiteral("only.png"));
    const Browse b = browseFolder(only, BrowseKinds::ImagesOnly, SortSpec{});
    EXPECT_EQ(b.paths, QStringList{only});
    EXPECT_EQ(b.index, 0);
    // A hidden file opened on purpose stays in the list.
    const QString hidden = touch(dir, QStringLiteral(".h.png"));
    const Browse h = browseFolder(hidden, BrowseKinds::ImagesOnly, SortSpec{});
    EXPECT_TRUE(h.paths.contains(hidden));
}

TEST(PreviewLogic, BrowseFolderIsAWindowOfAtMostMaxFiles)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    for (int i = 0; i < kMaxFiles + 60; ++i)
        touch(dir, QStringLiteral("p%1.png").arg(i, 4, 10, QLatin1Char('0')));
    const QString opened = dir.filePath(QStringLiteral("p0100.png"));
    const Browse b = browseFolder(opened, BrowseKinds::ImagesOnly, SortSpec{});
    EXPECT_EQ(b.paths.size(), kMaxFiles);
    EXPECT_EQ(b.paths.at(b.index), opened);
    const Browse first = browseFolder(dir.filePath(QStringLiteral("p0000.png")), BrowseKinds::ImagesOnly, SortSpec{});
    EXPECT_EQ(first.index, 0);
    const Browse last = browseFolder(dir.filePath(QStringLiteral("p0259.png")), BrowseKinds::ImagesOnly, SortSpec{});
    EXPECT_EQ(last.index, kMaxFiles - 1);
}

namespace {
QStringList baseNames(const QStringList &paths)
{
    QStringList out;
    for (const QString &p : paths)
        out << QFileInfo(p).fileName();
    return out;
}
QStringList abcd(const QTemporaryDir &dir)
{
    QStringList paths;
    for (const char *n : {"a.png", "b.png", "c.png", "d.png"})
        paths << touch(dir, QString::fromLatin1(n));
    return paths;
}
const QStringList kAbcd{QStringLiteral("a.png"), QStringLiteral("b.png"), QStringLiteral("c.png"), QStringLiteral("d.png")};
} // namespace

TEST(PreviewLogic, BrowseFolderHiddenOpenedFileIsListedAtItsSortedPosition)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    abcd(dir);
    const QString hidden = touch(dir, QStringLiteral(".b0.png"));
    const Browse b = browseFolder(hidden, BrowseKinds::ImagesOnly, SortSpec{});
    EXPECT_EQ(b.paths.size(), 5);
    ASSERT_GE(b.index, 0);
    ASSERT_LT(b.index, b.paths.size());
    EXPECT_EQ(b.paths.at(b.index), hidden);
    // The visible files keep their order and none of them is replaced by the opened one.
    QStringList others = baseNames(b.paths);
    others.removeAt(b.index);
    EXPECT_EQ(others, kAbcd);
    // From a visible file the hidden one stays out.
    EXPECT_EQ(baseNames(browseFolder(dir.filePath(QStringLiteral("a.png")), BrowseKinds::ImagesOnly, SortSpec{}).paths), kAbcd);
}

TEST(PreviewLogic, BrowseFolderUnreadableOpenedFileKeepsItsPlace)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const QStringList files = abcd(dir);
    for (int i = 0; i < files.size(); ++i) {
        ASSERT_TRUE(QFile::setPermissions(files.at(i), QFileDevice::Permissions()));
        if (QFileInfo(files.at(i)).isReadable())
            GTEST_SKIP() << "permissions are not enforced (running as root)";
        const Browse b = browseFolder(files.at(i), BrowseKinds::ImagesOnly, SortSpec{});
        EXPECT_EQ(baseNames(b.paths), kAbcd) << i;
        EXPECT_EQ(b.index, i);
        EXPECT_EQ(b.paths.at(b.index), files.at(i));
        QFile::setPermissions(files.at(i), QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    }
}

TEST(PreviewLogic, BrowseFolderSkipsUnreadableSiblings)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const QStringList files = abcd(dir);
    ASSERT_TRUE(QFile::setPermissions(files.at(2), QFileDevice::Permissions()));
    if (QFileInfo(files.at(2)).isReadable())
        GTEST_SKIP() << "permissions are not enforced (running as root)";
    const Browse b = browseFolder(files.at(1), BrowseKinds::ImagesOnly, SortSpec{});
    EXPECT_EQ(baseNames(b.paths), (QStringList{QStringLiteral("a.png"), QStringLiteral("b.png"), QStringLiteral("d.png")}));
    EXPECT_EQ(b.index, 1);
    QFile::setPermissions(files.at(2), QFileDevice::ReadOwner | QFileDevice::WriteOwner);
}

TEST(PreviewLogic, BrowseFolderFollowsSymlinksToFilesAndSkipsBrokenOnes)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const QStringList files = abcd(dir);
    ASSERT_TRUE(QFile::link(files.at(0), dir.filePath(QStringLiteral("link-to-a.png"))));
    ASSERT_TRUE(QFile::link(dir.filePath(QStringLiteral("missing.png")), dir.filePath(QStringLiteral("broken.png"))));
    const Browse b = browseFolder(files.at(3), BrowseKinds::ImagesOnly, SortSpec{});
    EXPECT_EQ(baseNames(b.paths), (QStringList{QStringLiteral("a.png"), QStringLiteral("b.png"), QStringLiteral("c.png"), QStringLiteral("d.png"),
                                               QStringLiteral("link-to-a.png")}));
    // A symlink can be the opened file; it keeps its own spelling.
    const QString link = dir.filePath(QStringLiteral("link-to-a.png"));
    const Browse l = browseFolder(link, BrowseKinds::ImagesOnly, SortSpec{});
    EXPECT_EQ(l.paths.at(l.index), link);
    EXPECT_EQ(l.paths.size(), 5);
    // A broken symlink is not a file: nothing to browse.
    const QString broken = dir.filePath(QStringLiteral("broken.png"));
    const Browse x = browseFolder(broken, BrowseKinds::ImagesOnly, SortSpec{});
    EXPECT_EQ(x.paths, QStringList{broken});
}

TEST(PreviewLogic, BrowseFolderFileThatDisappearsWhileBrowsing)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const QStringList files = abcd(dir);
    EXPECT_EQ(browseFolder(files.at(1), BrowseKinds::ImagesOnly, SortSpec{}).paths.size(), 4);
    // A sibling goes away: the next listing is without it and the opened file keeps a valid index.
    ASSERT_TRUE(QFile::remove(files.at(2)));
    const Browse b = browseFolder(files.at(1), BrowseKinds::ImagesOnly, SortSpec{});
    EXPECT_EQ(baseNames(b.paths), (QStringList{QStringLiteral("a.png"), QStringLiteral("b.png"), QStringLiteral("d.png")}));
    EXPECT_EQ(b.paths.at(b.index), files.at(1));
    // The opened file itself goes away: only its path is returned (the viewer shows its error in place).
    ASSERT_TRUE(QFile::remove(files.at(1)));
    const Browse gone = browseFolder(files.at(1), BrowseKinds::ImagesOnly, SortSpec{});
    EXPECT_EQ(gone.paths, QStringList{files.at(1)});
    EXPECT_EQ(gone.index, 0);
}

TEST(PreviewLogic, BrowseFolderCanBeCancelled)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const QStringList files = abcd(dir);
    const std::atomic_bool cancel{true};
    const Browse b = browseFolder(files.at(1), BrowseKinds::ImagesOnly, SortSpec{}, &cancel);
    EXPECT_EQ(b.paths, QStringList{files.at(1)});
}
