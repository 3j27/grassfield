// Video wallpapers of grassfield-wallpaper (ADR-0016 W7): the pure rules (argument vectors, probe parsing, sizes, progress,
// worst-case statistics) and, when ffmpeg is installed, a real probe and transcode of a generated clip (nothing is committed).
#include <gtest/gtest.h>

#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QProcess>
#include <QTemporaryDir>

#include "videotool.h"

using namespace wallpaper;
using namespace wallpaper::video;

namespace {

bool haveFfmpeg()
{
    return QFileInfo::exists(QStringLiteral("/usr/bin/ffmpeg")) && QFileInfo::exists(QStringLiteral("/usr/bin/ffprobe"));
}

// A generated clip: lavfi testsrc2 with an audio track, `seconds` long, at `size` and `fps`.
QString makeClip(const QTemporaryDir &dir, const QString &name, int seconds, const QString &size, int fps, const QString &extra = QString())
{
    const QString path = dir.filePath(name);
    QStringList args = {QStringLiteral("-v"), QStringLiteral("error"), QStringLiteral("-f"), QStringLiteral("lavfi"), QStringLiteral("-i"),
                        QStringLiteral("testsrc2=size=%1:rate=%2:duration=%3").arg(size).arg(fps).arg(seconds), QStringLiteral("-f"), QStringLiteral("lavfi"), QStringLiteral("-i"),
                        QStringLiteral("sine=duration=%1").arg(seconds), QStringLiteral("-c:v"), QStringLiteral("libx264"), QStringLiteral("-pix_fmt"), QStringLiteral("yuv420p"),
                        QStringLiteral("-c:a"), QStringLiteral("aac"), QStringLiteral("-shortest"), QStringLiteral("-y")};
    if (!extra.isEmpty())
        args << extra.split(QLatin1Char(' '));
    args << path;
    EXPECT_EQ(QProcess::execute(QStringLiteral("/usr/bin/ffmpeg"), args), 0);
    return path;
}

QString videoDir(const QTemporaryDir &dir)
{
    return dir.filePath(QStringLiteral("cache/wallpapers/video"));
}

} // namespace

TEST(VideoTool, OutputSizeFitsInsideAndNeverEnlarges)
{
    EXPECT_EQ(outputSize(QSize(3840, 2160), QSize(1920, 1080)), QSize(1920, 1080));
    EXPECT_EQ(outputSize(QSize(1280, 720), QSize(1920, 1080)), QSize(1280, 720));
    EXPECT_EQ(outputSize(QSize(2000, 2000), QSize(1920, 1080)), QSize(1080, 1080));
    EXPECT_EQ(outputSize(QSize(1001, 999), QSize(2000, 2000)), QSize(1000, 998)); // even sides
    EXPECT_EQ(outputSize(QSize(1080, 1920), QSize(1920, 1080)), QSize(606, 1080));
    EXPECT_EQ(outputSize(QSize(0, 0), QSize(10, 10)), QSize(2, 2));
}

TEST(VideoTool, TranscodeArgumentsAreTheAdrOnes)
{
    const QStringList a = transcodeArgs(QStringLiteral("/v/in.mkv"), QStringLiteral("/c/out.mp4"), QSize(1920, 1080), 60.0, 600, 1000000);
    EXPECT_TRUE(a.contains(QStringLiteral("-an")));
    EXPECT_TRUE(a.contains(QStringLiteral("libx264")));
    EXPECT_TRUE(a.contains(QStringLiteral("yuv420p")));
    EXPECT_TRUE(a.contains(QStringLiteral("+faststart")));
    EXPECT_EQ(a[a.indexOf(QStringLiteral("-t")) + 1], QStringLiteral("600"));
    EXPECT_EQ(a[a.indexOf(QStringLiteral("-fs")) + 1], QStringLiteral("1000000"));
    EXPECT_EQ(a[a.indexOf(QStringLiteral("-protocol_whitelist")) + 1], QStringLiteral("file"));
    EXPECT_EQ(a[a.indexOf(QStringLiteral("-i")) + 1], QStringLiteral("/v/in.mkv"));
    EXPECT_EQ(a.last(), QStringLiteral("/c/out.mp4"));
    const QString filter = a[a.indexOf(QStringLiteral("-vf")) + 1];
    EXPECT_TRUE(filter.startsWith(QStringLiteral("scale=1920:1080")));
    EXPECT_TRUE(filter.contains(QStringLiteral("fps=30")));
    // At 24 fps the rate is kept.
    const QStringList b = transcodeArgs(QStringLiteral("/v/in.mkv"), QStringLiteral("/c/out.mp4"), QSize(640, 360), 24.0, 600, 1000000);
    EXPECT_FALSE(b[b.indexOf(QStringLiteral("-vf")) + 1].contains(QStringLiteral("fps=")));
    // A path that looks like an option is still the value of -i.
    const QStringList c = ffprobeArgs(QStringLiteral("/-evil name.mp4"));
    EXPECT_EQ(c.last(), QStringLiteral("/-evil name.mp4"));
    EXPECT_EQ(c[c.indexOf(QStringLiteral("-i")) + 1], c.last());
}

TEST(VideoTool, ProbeParsing)
{
    const QByteArray good = R"({"streams":[{"codec_type":"audio"},{"codec_type":"video","codec_name":"h264","width":1920,"height":1080,"avg_frame_rate":"30000/1001"}],"format":{"duration":"12.5"}})";
    Info i;
    QString why;
    ASSERT_EQ(parseProbe(good, 600, &i, &why), Ok);
    EXPECT_EQ(i.width, 1920);
    EXPECT_EQ(i.codec, QStringLiteral("h264"));
    EXPECT_TRUE(i.audio);
    EXPECT_NEAR(i.fps, 29.97, 0.01);
    EXPECT_NEAR(i.duration, 12.5, 0.001);
    // Rotation swaps the displayed size.
    const QByteArray rotated = R"({"streams":[{"codec_type":"video","codec_name":"h264","width":1920,"height":1080,"side_data_list":[{"rotation":-90}]}],"format":{"duration":"3"}})";
    ASSERT_EQ(parseProbe(rotated, 600, &i, &why), Ok);
    EXPECT_EQ(QSize(i.width, i.height), QSize(1080, 1920));
    EXPECT_EQ(parseProbe(R"({"streams":[{"codec_type":"audio"}],"format":{"duration":"3"}})", 600, &i, &why), Unsupported);
    EXPECT_EQ(parseProbe(R"({"streams":[{"codec_type":"video","width":10,"height":10,"disposition":{"attached_pic":1}}],"format":{"duration":"3"}})", 600, &i, &why), Unsupported);
    EXPECT_EQ(parseProbe(R"({"streams":[{"codec_type":"video","width":64,"height":64}],"format":{"duration":"601"}})", 600, &i, &why), TooLongVideo);
    EXPECT_EQ(parseProbe(R"({"streams":[{"codec_type":"video","width":64,"height":64}],"format":{}})", 600, &i, &why), Unreadable);
    EXPECT_EQ(parseProbe(R"({"streams":[{"codec_type":"video","width":99999,"height":64}],"format":{"duration":"3"}})", 600, &i, &why), TooLargePicture);
    EXPECT_EQ(parseProbe("not json", 600, &i, &why), Unreadable);
}

TEST(VideoTool, ProgressLines)
{
    EXPECT_NEAR(progressOf(QStringLiteral("out_time_us=5000000"), 10.0), 0.5, 1e-9);
    EXPECT_EQ(progressOf(QStringLiteral("out_time_us=N/A"), 10.0), -1);
    EXPECT_EQ(progressOf(QStringLiteral("frame=12"), 10.0), -1);
    EXPECT_EQ(progressOf(QStringLiteral("out_time_us=5000000"), 0.0), -1);
    EXPECT_EQ(progressOf(QStringLiteral("out_time_us=99000000"), 10.0), 1.0);
}

TEST(VideoTool, WorstStripTakesTheWorstOfEveryFrame)
{
    auto strip = [](double mean, double p5, double p95) {
        const QJsonObject h{{QStringLiteral("mean"), mean}, {QStringLiteral("p5"), p5}, {QStringLiteral("p95"), p95}};
        return QJsonObject{{QStringLiteral("rows"), 24}, {QStringLiteral("all"), h}, {QStringLiteral("left"), h}, {QStringLiteral("right"), h}};
    };
    const QJsonObject w = worstStrip({strip(0.2, 0.1, 0.4), strip(0.6, 0.3, 0.9)});
    EXPECT_NEAR(w.value(QStringLiteral("all")).toObject().value(QStringLiteral("mean")).toDouble(), 0.4, 1e-9);
    EXPECT_NEAR(w.value(QStringLiteral("all")).toObject().value(QStringLiteral("p5")).toDouble(), 0.1, 1e-9);
    EXPECT_NEAR(w.value(QStringLiteral("right")).toObject().value(QStringLiteral("p95")).toDouble(), 0.9, 1e-9);
    EXPECT_TRUE(worstStrip({}).isEmpty());
}

TEST(VideoTool, CacheFolderAndPoster)
{
    EXPECT_TRUE(video::outDirAllowed(QStringLiteral("/home/u/.cache/grassfield/wallpapers/video")));
    EXPECT_TRUE(video::outDirAllowed(QStringLiteral("/repo/.dev/cache/wallpapers/video")));
    EXPECT_FALSE(video::outDirAllowed(QStringLiteral("/home/u/Videos")));
    EXPECT_FALSE(video::outDirAllowed(QStringLiteral("/home/u/.cache/grassfield/wallpapers/video/../../..")));
    EXPECT_FALSE(video::outDirAllowed(QStringLiteral("wallpapers/video")));
    EXPECT_DOUBLE_EQ(posterSeconds(20), 2.0);
    EXPECT_DOUBLE_EQ(posterSeconds(600), 5.0);
    EXPECT_TRUE(isVideoPath(QStringLiteral("/a/b.MP4")));
    EXPECT_FALSE(isVideoPath(QStringLiteral("/a/b.jpg")));
    EXPECT_TRUE(isCacheName(QStringLiteral("0123456789abcdef0123456789abcdef.mp4")));
}

TEST(VideoTool, TranscodesAClipToH264AtMostTheOutputSize)
{
    if (!haveFfmpeg())
        GTEST_SKIP() << "ffmpeg is not installed";
    QTemporaryDir dir;
    const QString clip = makeClip(dir, QStringLiteral("clip.mp4"), 3, QStringLiteral("1280x720"), 60);
    TranscodeOptions o;
    o.src = clip;
    o.out = videoDir(dir);
    o.limit = QSize(640, 400);
    o.fit = Fit::Fit;
    o.color = QColor(Qt::black);
    QJsonObject r;
    QString why;
    double lastProgress = -1;
    ASSERT_EQ(transcode(o, [&](double f) { lastProgress = f; }, &r, &why), Ok) << why.toStdString();
    EXPECT_FALSE(r.value(QStringLiteral("cached")).toBool());
    EXPECT_DOUBLE_EQ(lastProgress, 1.0);
    const QString mp4 = r.value(QStringLiteral("video")).toString();
    Info made;
    ASSERT_EQ(probe(QStringLiteral("/usr/bin/ffprobe"), mp4, 600, &made, &why), Ok) << why.toStdString();
    EXPECT_EQ(made.codec, QStringLiteral("h264"));
    EXPECT_LE(made.width, 640);
    EXPECT_LE(made.height, 400);
    EXPECT_LE(made.fps, 30.5);
    EXPECT_FALSE(made.audio);
    // The poster is composed on the whole output; the strip is the worst of the poster and the sampled frames.
    QImage poster(r.value(QStringLiteral("file")).toString());
    EXPECT_EQ(poster.size(), QSize(640, 400));
    EXPECT_EQ(r.value(QStringLiteral("frames")).toInt(), 1 + kToneFrames);
    EXPECT_TRUE(r.value(QStringLiteral("strip")).toObject().contains(QStringLiteral("all")));
    EXPECT_EQ(QFileInfo(mp4).permissions() & (QFileDevice::ReadGroup | QFileDevice::ReadOther), QFileDevice::Permissions());
    // A second run is answered from the cache and encodes nothing.
    QJsonObject again;
    ASSERT_EQ(transcode(o, nullptr, &again, &why), Ok);
    EXPECT_TRUE(again.value(QStringLiteral("cached")).toBool());
    EXPECT_EQ(again.value(QStringLiteral("video")).toString(), mp4);
}

TEST(VideoTool, RefusesTooLongNotAVideoAndNoVideo)
{
    if (!haveFfmpeg())
        GTEST_SKIP() << "ffmpeg is not installed";
    QTemporaryDir dir;
    const QString clip = makeClip(dir, QStringLiteral("clip.mp4"), 4, QStringLiteral("160x90"), 10);
    Info i;
    QString why;
    EXPECT_EQ(probe(QStringLiteral("/usr/bin/ffprobe"), clip, 2, &i, &why), TooLongVideo);
    QFile junk(dir.filePath(QStringLiteral("junk.mp4")));
    ASSERT_TRUE(junk.open(QIODevice::WriteOnly));
    junk.write(QByteArray(4096, 'x'));
    junk.close();
    EXPECT_EQ(probe(QStringLiteral("/usr/bin/ffprobe"), junk.fileName(), 600, &i, &why), Unsupported);
    const QString wav = dir.filePath(QStringLiteral("a.wav"));
    ASSERT_EQ(QProcess::execute(QStringLiteral("/usr/bin/ffmpeg"), {QStringLiteral("-v"), QStringLiteral("error"), QStringLiteral("-f"), QStringLiteral("lavfi"), QStringLiteral("-i"), QStringLiteral("sine=duration=1"), QStringLiteral("-y"), wav}), 0);
    EXPECT_EQ(probe(QStringLiteral("/usr/bin/ffprobe"), wav, 600, &i, &why), Unsupported);
    TranscodeOptions o;
    o.src = junk.fileName();
    o.out = videoDir(dir);
    o.limit = QSize(320, 200);
    QJsonObject r;
    EXPECT_EQ(transcode(o, nullptr, &r, &why), Unsupported);
    // An output folder that is not the video cache is refused before anything runs.
    o.out = dir.filePath(QStringLiteral("elsewhere"));
    EXPECT_EQ(transcode(o, nullptr, &r, &why), Usage);
    EXPECT_FALSE(QFileInfo::exists(o.out));
}

TEST(VideoTool, AMissingFfmpegIsItsOwnFailure)
{
    QTemporaryDir dir;
    QFile f(dir.filePath(QStringLiteral("x.mp4")));
    ASSERT_TRUE(f.open(QIODevice::WriteOnly));
    f.write(QByteArray(2048, 'x'));
    f.close();
    Info i;
    QString why;
    EXPECT_EQ(probe(QStringLiteral("/nonexistent/ffprobe"), f.fileName(), 600, &i, &why), FfmpegMissing);
}

TEST(VideoTool, ThumbnailOfAVideoIsOneFrame)
{
    if (!haveFfmpeg())
        GTEST_SKIP() << "ffmpeg is not installed";
    QTemporaryDir dir;
    const QString clip = makeClip(dir, QStringLiteral("clip.mp4"), 2, QStringLiteral("320x180"), 15);
    const QString out = dir.filePath(QStringLiteral("t.jpg"));
    QString why;
    ASSERT_EQ(thumbnail(clip, out, 320, &why), Ok) << why.toStdString();
    EXPECT_EQ(QImage(out).size(), QSize(320, 200));
}

TEST(VideoTool, ArgumentsWhitelistTheContainersAndBoundTheDecoder)
{
    for (const QStringList &a : {ffprobeArgs(QStringLiteral("/v/a.mp4")), frameArgs(QStringLiteral("/v/a.mp4"), 1.0), transcodeArgs(QStringLiteral("/v/a.mp4"), QStringLiteral("/c/o.mp4"), QSize(640, 360), 30, 600, 1000000)}) {
        const int i = a.indexOf(QStringLiteral("-format_whitelist"));
        ASSERT_GE(i, 0);
        EXPECT_EQ(a[i + 1], QString::fromLatin1(kDemuxers));
        EXPECT_FALSE(a[i + 1].contains(QStringLiteral("hls")));
        EXPECT_FALSE(a[i + 1].contains(QStringLiteral("concat")));
        EXPECT_EQ(a[a.indexOf(QStringLiteral("-protocol_whitelist")) + 1], QStringLiteral("file"));
    }
    for (const QStringList &a : {frameArgs(QStringLiteral("/v/a.mp4"), 1.0), transcodeArgs(QStringLiteral("/v/a.mp4"), QStringLiteral("/c/o.mp4"), QSize(640, 360), 30, 600, 1000000)}) {
        EXPECT_EQ(a[a.indexOf(QStringLiteral("-max_pixels")) + 1].toLongLong(), kMaxPixels);
        EXPECT_EQ(a[a.indexOf(QStringLiteral("-max_alloc")) + 1].toLongLong(), kMaxAlloc);
    }
}

TEST(VideoTool, APlaylistIsRefusedWhateverItIsCalled)
{
    if (!haveFfmpeg())
        GTEST_SKIP() << "ffmpeg is not installed";
    QTemporaryDir dir;
    const QString clip = makeClip(dir, QStringLiteral("clip.mp4"), 2, QStringLiteral("160x90"), 10);
    struct Case {
        const char *name;
        QByteArray body;
    };
    const Case cases[] = {
        {"hls.mp4", "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\nclip.mp4\n#EXT-X-ENDLIST\n"},
        {"concat.mkv", "ffconcat version 1.0\nfile clip.mp4\n"},
        {"abs.mov", QByteArray("ffconcat version 1.0\nfile '") + clip.toUtf8() + "'\n"},
    };
    for (const Case &c : cases) {
        QFile f(dir.filePath(QString::fromLatin1(c.name)));
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
        f.write(c.body);
        f.close();
        Info i;
        QString why;
        EXPECT_NE(probe(QStringLiteral("/usr/bin/ffprobe"), f.fileName(), 600, &i, &why), Ok) << c.name;
        TranscodeOptions o;
        o.src = f.fileName();
        o.out = videoDir(dir);
        o.limit = QSize(160, 100);
        QJsonObject r;
        EXPECT_NE(transcode(o, nullptr, &r, &why), Ok) << c.name;
    }
    // The containers of the supported suffixes still open.
    for (const char *name : {"b.mkv", "c.avi", "d.mov"}) {
        const QString p = makeClip(dir, QString::fromLatin1(name), 1, QStringLiteral("160x90"), 10);
        Info i;
        QString why;
        EXPECT_EQ(probe(QStringLiteral("/usr/bin/ffprobe"), p, 600, &i, &why), Ok) << name << " " << why.toStdString();
    }
}

TEST(VideoTool, ANormalFileIsNotHurtByTheMemoryCapOfTheChild)
{
    // The children run under RLIMIT_DATA (1, 3 and 6 GiB); a normal file works as before (that the cap bites is TheHeapCapStopsARunawayDecode).
    if (!haveFfmpeg())
        GTEST_SKIP() << "ffmpeg is not installed";
    QTemporaryDir dir;
    const QString clip = makeClip(dir, QStringLiteral("clip.mp4"), 1, QStringLiteral("160x90"), 10);
    Info i;
    QString why;
    EXPECT_EQ(probe(QStringLiteral("/usr/bin/ffprobe"), clip, 600, &i, &why), Ok) << "a normal file is not hurt by the cap: " << why.toStdString();
}

TEST(VideoTool, ThreadsAreTheSameOnEveryMachine)
{
    EXPECT_EQ(threadCount(0), 1);
    EXPECT_EQ(threadCount(1), 1);
    EXPECT_EQ(threadCount(4), 4);
    EXPECT_EQ(threadCount(8), kMaxThreads);
    EXPECT_EQ(threadCount(32), kMaxThreads);
    EXPECT_EQ(threadCount(256), kMaxThreads);
    // Whatever count is asked for, the vector never carries more than kMaxThreads and always names the decoder, filter and encoder.
    const QStringList a = transcodeArgs(QStringLiteral("/v/a.mp4"), QStringLiteral("/c/o.mp4"), QSize(3840, 2160), 60, 600, 1000000, 64);
    int threads = 0, filters = 0;
    for (int i = 0; i + 1 < a.size(); ++i) {
        if (a[i] == QLatin1String("-threads")) {
            ++threads;
            EXPECT_LE(a[i + 1].toInt(), kMaxThreads);
            EXPECT_GE(a[i + 1].toInt(), 1);
        }
        if (a[i] == QLatin1String("-filter_threads")) {
            ++filters;
            EXPECT_EQ(a[i + 1].toInt(), kMaxThreads);
        }
    }
    EXPECT_EQ(threads, 2) << "one for the decoder (before -i), one for the encoder";
    EXPECT_EQ(filters, 1);
    EXPECT_LT(a.indexOf(QStringLiteral("-threads")), a.indexOf(QStringLiteral("-i")));
    EXPECT_GT(a.lastIndexOf(QStringLiteral("-threads")), a.indexOf(QStringLiteral("-i")));
    // A frame grab of a big source scales it down (never up); without a bound it does not scale.
    const QStringList f = frameArgs(QStringLiteral("/v/a.mp4"), 1.0, QSize(1280, 1280));
    EXPECT_TRUE(f[f.indexOf(QStringLiteral("-vf")) + 1].contains(QStringLiteral("min(iw,1280)")));
    EXPECT_FALSE(frameArgs(QStringLiteral("/v/a.mp4"), 1.0).contains(QStringLiteral("-vf")));
}

TEST(VideoTool, A4kAnd8kSourceTranscodeUnderTheRealHeapCapWithForcedThreads)
{
    if (!haveFfmpeg())
        GTEST_SKIP() << "ffmpeg is not installed";
    QTemporaryDir dir;
    // 4K 60 fps to 4K, with a thread count far above any machine's (clamped to kMaxThreads): the real cap (kTranscodeDataLimit).
    const QString k4 = makeClip(dir, QStringLiteral("k4.mp4"), 1, QStringLiteral("3840x2160"), 60, QStringLiteral("-preset ultrafast"));
    TranscodeOptions o;
    o.src = k4;
    o.out = videoDir(dir);
    o.limit = QSize(3840, 2160);
    o.threads = 256;
    QJsonObject r;
    QString why;
    ASSERT_EQ(transcode(o, nullptr, &r, &why), Ok) << why.toStdString();
    EXPECT_EQ(r.value(QStringLiteral("videoWidth")).toInt(), 3840);
    // An 8K display (5K, 6K and 8K displays all get a 4K video, which the shell scales): the video never exceeds 3840x2160, the
    // poster is composed on the display. A short 8K source here; the 60-frame 8K H.264, HEVC and AV1 runs are in VideoToolHeavy.
    const QString k8 = makeClip(dir, QStringLiteral("k8.mp4"), 1, QStringLiteral("7680x4320"), 2, QStringLiteral("-preset ultrafast"));
    o.src = k8;
    o.limit = QSize(7680, 4320);
    ASSERT_EQ(transcode(o, nullptr, &r, &why), Ok) << "8K source, 8K display: " << why.toStdString();
    EXPECT_EQ(r.value(QStringLiteral("videoWidth")).toInt(), 3840);
    EXPECT_EQ(r.value(QStringLiteral("videoHeight")).toInt(), 2160);
    EXPECT_EQ(r.value(QStringLiteral("width")).toInt(), 7680) << "the poster is the display's size";
}

TEST(VideoTool, TheHeapCapStopsARunawayDecode)
{
    if (!haveFfmpeg())
        GTEST_SKIP() << "ffmpeg is not installed";
    QTemporaryDir dir;
    const QString k4 = makeClip(dir, QStringLiteral("k4.mp4"), 1, QStringLiteral("3840x2160"), 30, QStringLiteral("-preset ultrafast"));
    TranscodeOptions o;
    o.src = k4;
    o.out = videoDir(dir);
    o.limit = QSize(3840, 2160);
    o.dataLimit = qint64(160) << 20; // far below what a 4K encode needs
    QJsonObject r;
    QString why;
    EXPECT_EQ(transcode(o, nullptr, &r, &why), TranscodeFailed) << why.toStdString();
    // The failure leaves nothing behind, and the same file passes with the real cap.
    EXPECT_TRUE(QDir(videoDir(dir)).entryList({QStringLiteral("*.mp4")}, QDir::Files | QDir::Hidden).isEmpty());
    o.dataLimit = kTranscodeDataLimit;
    EXPECT_EQ(transcode(o, nullptr, &r, &why), Ok) << why.toStdString();
}

TEST(VideoTool, TheVideoNeverExceeds4kWhateverTheDisplay)
{
    EXPECT_EQ(videoLimit(QSize(1920, 1080)), QSize(1920, 1080));
    EXPECT_EQ(videoLimit(QSize(3840, 2160)), QSize(3840, 2160));
    EXPECT_EQ(videoLimit(QSize(5120, 2880)), QSize(3840, 2160));
    EXPECT_EQ(videoLimit(QSize(7680, 4320)), QSize(3840, 2160));
    EXPECT_EQ(videoLimit(QSize(2880, 5120)), QSize(2880, 2160));
    // A 16:9 source on a 5K display is fitted inside 4K, never enlarged.
    EXPECT_EQ(outputSize(QSize(7680, 4320), videoLimit(QSize(5120, 2880))), QSize(3840, 2160));
    EXPECT_EQ(outputSize(QSize(1920, 1080), videoLimit(QSize(5120, 2880))), QSize(1920, 1080));
}

// ---- heavy (minutes): sources of 8K in three codecs, 60 frames, to a 4K video under the real cap with forced high thread counts.
// Skipped unless GRASSFIELD_HEAVY_TESTS=1 (tests/shell/wallpaper_video_heavy.sh sets it): generating the HEVC source alone takes about 50 s.
TEST(VideoToolHeavy, EightKSourcesInThreeCodecsTranscodeTo4kUnderTheRealCap)
{
    if (qEnvironmentVariable("GRASSFIELD_HEAVY_TESTS") != QLatin1String("1"))
        GTEST_SKIP() << "heavy: set GRASSFIELD_HEAVY_TESTS=1";
    if (!haveFfmpeg())
        GTEST_SKIP() << "ffmpeg is not installed";
    struct Source {
        const char *name;
        const char *codecArgs;
        const char *expectedCodec;
    };
    const Source sources[] = {
        {"h264.mp4", "-c:v libx264 -preset ultrafast -pix_fmt yuv420p", "h264"},
        {"hevc10.mp4", "-c:v libx265 -preset ultrafast -pix_fmt yuv420p10le -x265-params log-level=error", "hevc"},
        {"av1.mkv", "-c:v libsvtav1 -preset 12 -pix_fmt yuv420p", "av1"},
    };
    QTemporaryDir dir;
    for (const Source &src : sources) {
        const QString path = dir.filePath(QString::fromLatin1(src.name));
        const QStringList args = QStringList{QStringLiteral("-v"), QStringLiteral("error"), QStringLiteral("-f"), QStringLiteral("lavfi"), QStringLiteral("-i"), QStringLiteral("testsrc2=size=7680x4320:rate=30:duration=2")}
            + QString::fromLatin1(src.codecArgs).split(QLatin1Char(' ')) + QStringList{QStringLiteral("-y"), path};
        ASSERT_EQ(QProcess::execute(QStringLiteral("/usr/bin/ffmpeg"), args), 0) << src.name;
        TranscodeOptions o;
        o.src = path;
        o.out = videoDir(dir);
        o.limit = QSize(7680, 4320); // an 8K display: the video is still fitted inside 3840x2160
        o.threads = 256;             // clamped to kMaxThreads
        QJsonObject r;
        QString why;
        ASSERT_EQ(transcode(o, nullptr, &r, &why), Ok) << src.name << ": " << why.toStdString();
        EXPECT_EQ(r.value(QStringLiteral("codec")).toString(), QString::fromLatin1(src.expectedCodec));
        EXPECT_EQ(r.value(QStringLiteral("videoWidth")).toInt(), 3840) << src.name;
        EXPECT_EQ(r.value(QStringLiteral("videoHeight")).toInt(), 2160) << src.name;
        // And its thumbnail (one frame scaled down inside the grab) works under the frame cap.
        const QString thumb = dir.filePath(QStringLiteral("t-%1.jpg").arg(QString::fromLatin1(src.name)));
        EXPECT_EQ(thumbnail(path, thumb, 320, &why), Ok) << src.name << ": " << why.toStdString();
    }
}
