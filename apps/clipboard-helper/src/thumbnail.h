// Image thumbnails and previews (ADR-0034 §1f): an image from the clipboard is decoded only here, in a worker process (the same
// binary, `--thumbnail <png|jpeg|webp> <max px>`) that gets one image on stdin and nothing of the history, decodes it with the format
// given and every format detection off, under rlimits and a 2 s wall deadline, and writes a PNG of at most <max px> on its long side
// to stdout.
#pragma once

#include <QByteArray>
#include <QImage>
#include <QObject>
#include <QProcess>
#include <QString>
#include <QTimer>

#include <functional>

namespace Thumbnail
{
constexpr int kDeadlineMs = 2000;
constexpr qint64 kAddressSpace = 1024LL * 1024 * 1024;
constexpr int kCpuSeconds = 2;
constexpr int kAllocationLimitMb = 256;

// Decodes `data` as `format` only (png, jpeg or webp) and scales it to at most `maxPx` on its long side. Null image and `error`
// when the format is not allowed, the reader cannot read it, the size is unknown or over 8,192 px a side or 64 megapixels.
QImage decode(const QByteArray &data, const QByteArray &format, int maxPx, QByteArray *error);
// PNG bytes of `image` (empty when over kThumbnailBytes).
QByteArray encodePng(const QImage &image);
// The worker's main: stdin -> stdout. Exit 0 on success.
int runWorker(const QByteArray &format, int maxPx);
} // namespace Thumbnail

// One worker run, from the helper. `done` gets the PNG, or nothing when the worker failed, was killed, was late or answered too
// much; it is called once.
class ThumbnailJob : public QObject
{
public:
    using Done = std::function<void(const QByteArray &png)>;
    ThumbnailJob(const QString &program, const QByteArray &format, int maxPx, const QByteArray &image, Done done, QObject *parent = nullptr);
    void start();

private:
    void finish(const QByteArray &png);
    QString m_program;
    QByteArray m_format;
    int m_maxPx;
    QByteArray m_image;
    QProcess m_process;
    QTimer m_deadline;
    QByteArray m_out;
    Done m_done;
    bool m_finished = false;
};
