#include "thumbnail.h"
#include "cliplogic.h"

#include <QBuffer>
#include <QImageReader>
#include <QImageWriter>
#include <QProcessEnvironment>

#include <cerrno>
#include <csignal>
#include <cstdio>

#include <sys/prctl.h>
#include <sys/resource.h>
#include <unistd.h>

using namespace ClipLogic;

namespace Thumbnail
{
QImage decode(const QByteArray &data, const QByteArray &format, int maxPx, QByteArray *error)
{
    if (format != "png" && format != "jpeg" && format != "webp") {
        *error = "format not allowed";
        return {};
    }
    QBuffer buffer;
    buffer.setData(data);
    buffer.open(QIODevice::ReadOnly);
    // The format is given and every detection is off: the bytes can reach this one image plugin and no other (a PNG offer whose
    // bytes are a PDF, an SVG or a TIFF is refused, never handed to that format's plugin).
    QImageReader reader(&buffer, format);
    reader.setAutoDetectImageFormat(false);
    reader.setDecideFormatFromContent(false);
    QImageReader::setAllocationLimit(kAllocationLimitMb);
    if (!reader.canRead()) {
        *error = "not readable as the format given";
        return {};
    }
    const QSize size = reader.size();
    if (!size.isValid() || size.isEmpty()) {
        *error = "size unknown";
        return {};
    }
    if (size.width() > kMaxImageSide || size.height() > kMaxImageSide || qint64(size.width()) * size.height() > kMaxImagePixels) {
        *error = "too large";
        return {};
    }
    QSize target = size;
    if (size.width() > maxPx || size.height() > maxPx)
        target = size.scaled(maxPx, maxPx, Qt::KeepAspectRatio);
    if (target != size && reader.supportsOption(QImageIOHandler::ScaledSize))
        reader.setScaledSize(target);
    QImage image = reader.read();
    if (image.isNull()) {
        *error = "decoding failed";
        return {};
    }
    if (image.width() > maxPx || image.height() > maxPx)
        image = image.scaled(maxPx, maxPx, Qt::KeepAspectRatio, Qt::SmoothTransformation);
    return image;
}

QByteArray encodePng(const QImage &image)
{
    QByteArray out;
    QBuffer buffer(&out);
    buffer.open(QIODevice::WriteOnly);
    QImageWriter writer(&buffer, "png");
    if (!writer.write(image) || out.size() > kThumbnailBytes)
        return {};
    return out;
}

int runWorker(const QByteArray &format, int maxPx)
{
    QByteArray data;
    char chunk[65536];
    for (;;) {
        const ssize_t n = ::read(0, chunk, sizeof chunk);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0)
            break;
        data.append(chunk, n);
        if (data.size() > kImageCap)
            return 3;
    }
    QByteArray error;
    const QImage image = decode(data, format, qBound(16, maxPx, kPreviewPx), &error);
    if (image.isNull()) {
        std::fprintf(stderr, "grassfield-clipboard-helper thumbnail: %s\n", error.constData());
        return 2;
    }
    const QByteArray png = encodePng(image);
    if (png.isEmpty())
        return 4;
    qint64 written = 0;
    while (written < png.size()) {
        const ssize_t n = ::write(1, png.constData() + written, size_t(png.size() - written));
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0)
            return 5;
        written += n;
    }
    return 0;
}
} // namespace Thumbnail

ThumbnailJob::ThumbnailJob(const QString &program, const QByteArray &format, int maxPx, const QByteArray &image, Done done, QObject *parent)
    : QObject(parent)
    , m_program(program)
    , m_format(format)
    , m_maxPx(maxPx)
    , m_image(image)
    , m_done(std::move(done))
{
    m_deadline.setSingleShot(true);
    m_deadline.setInterval(Thumbnail::kDeadlineMs);
    connect(&m_deadline, &QTimer::timeout, this, [this] {
        m_process.kill();
        finish({});
    });
    connect(&m_process, &QProcess::readyReadStandardOutput, this, [this] {
        m_out += m_process.readAllStandardOutput();
        if (m_out.size() > kThumbnailBytes) {
            m_process.kill();
            finish({});
        }
    });
    connect(&m_process, &QProcess::finished, this, [this](int code, QProcess::ExitStatus status) {
        m_out += m_process.readAllStandardOutput();
        finish(status == QProcess::NormalExit && code == 0 && m_out.size() <= kThumbnailBytes ? m_out : QByteArray());
    });
    connect(&m_process, &QProcess::errorOccurred, this, [this](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart)
            finish({});
    });
}

void ThumbnailJob::start()
{
    // An environment holding only LC_ALL=C (an empty QProcessEnvironment would mean "inherit"): nothing of the helper's.
    QProcessEnvironment env;
    env.insert(QStringLiteral("LC_ALL"), QStringLiteral("C"));
    m_process.setProcessEnvironment(env);
    m_process.setProcessChannelMode(QProcess::SeparateChannels);
    m_process.setStandardErrorFile(QProcess::nullDevice());
    m_process.setUnixProcessParameters(QProcess::UnixProcessParameters{
        QProcess::UnixProcessFlag::CloseFileDescriptors | QProcess::UnixProcessFlag::ResetSignalHandlers
            | QProcess::UnixProcessFlag::IgnoreSigPipe,
        3});
    m_process.setChildProcessModifier([] {
        ::prctl(PR_SET_PDEATHSIG, SIGKILL);
        const rlimit as{rlim_t(Thumbnail::kAddressSpace), rlim_t(Thumbnail::kAddressSpace)};
        ::setrlimit(RLIMIT_AS, &as);
        const rlimit cpu{rlim_t(Thumbnail::kCpuSeconds), rlim_t(Thumbnail::kCpuSeconds)};
        ::setrlimit(RLIMIT_CPU, &cpu);
        const rlimit fsize{0, 0};
        ::setrlimit(RLIMIT_FSIZE, &fsize);
        ::setpriority(PRIO_PROCESS, 0, 15);
    });
    m_deadline.start();
    m_process.start(m_program, {QStringLiteral("--thumbnail"), QString::fromLatin1(m_format), QString::number(m_maxPx)});
    m_process.write(m_image);
    m_process.closeWriteChannel();
}

void ThumbnailJob::finish(const QByteArray &png)
{
    if (m_finished)
        return;
    m_finished = true;
    m_deadline.stop();
    if (m_done)
        m_done(png);
}
