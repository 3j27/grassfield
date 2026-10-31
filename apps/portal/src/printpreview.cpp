#include "printpreview.h"

#include "printsystem.h"

#include <QCoreApplication>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QHash>
#include <QMutex>
#include <QPainter>
#include <QPdfDocument>
#include <QProcess>
#include <QProcessEnvironment>

#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>

#include <fcntl.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <cerrno>
#include <cmath>
#include <csignal>
#include <cstddef>
#include <cstring>
#include <vector>

namespace grassfield::portal {

namespace {

constexpr int kMaxPages = 1000000;
constexpr double kMaxPagePoints = 100000;

bool writeAll(int fd, const char *data, size_t size)
{
    while (size > 0) {
        const ssize_t n = ::write(fd, data, size);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0)
            return false;
        data += n;
        size -= size_t(n);
    }
    return true;
}

} // namespace

Spooled spoolDocument(int fd, const QString &folder, int idleMs, qint64 maxBytes, const std::function<bool()> &stopped)
{
    Spooled out;
    // A file is read where it is (its position untouched: the call can still go to x-d-p-gtk as it came); a pipe as it flows.
    bool positional = true;
    qint64 offset = 0;
    const auto next = [&](char *into, size_t size, QString *error) -> ssize_t {
        while (positional) {
            if (stopped && stopped()) {
                *error = QStringLiteral("cancelled");
                return -1;
            }
            const ssize_t n = ::pread(fd, into, size, offset);
            if (n < 0 && errno == EINTR)
                continue;
            if (n < 0 && errno == ESPIPE && offset == 0) {
                positional = false;
                break;
            }
            if (n < 0) {
                *error = QStringLiteral("cannot read the document");
                return -1;
            }
            offset += n;
            return n;
        }
        out.consumed = true;
        return readChunk(fd, into, size, idleMs, stopped, error);
    };
    std::vector<char> chunk(65536);
    QByteArray head;
    while (head.size() < 5 && out.error.isEmpty()) {
        const ssize_t n = next(chunk.data(), chunk.size(), &out.error);
        if (n <= 0)
            break;
        head.append(chunk.data(), qsizetype(n));
    }
    if (!out.error.isEmpty()) {
        ::close(fd);
        return out;
    }
    if (!head.startsWith("%PDF-")) {
        out.notPdf = true;
        ::close(fd);
        return out;
    }
    const QByteArray dir = QFile::encodeName(folder.isEmpty() ? QDir::tempPath() : folder);
    // An unlinked file of this process's: no name another program could open or replace.
    int spool = ::open(dir.constData(), O_TMPFILE | O_RDWR | O_EXCL | O_CLOEXEC, 0600);
    if (spool < 0 && (errno == EOPNOTSUPP || errno == EISDIR || errno == EINVAL)) {
        // A file system without O_TMPFILE: a file made here (O_EXCL, 0600) and unlinked at once.
        QByteArray name = dir + "/.grassfield-print-XXXXXX";
        spool = ::mkostemp(name.data(), O_CLOEXEC);
        if (spool >= 0)
            ::unlink(name.constData());
    }
    if (spool < 0) {
        out.error = QStringLiteral("cannot keep the document: %1").arg(QString::fromLocal8Bit(std::strerror(errno)));
        ::close(fd);
        return out;
    }
    qint64 total = head.size();
    if (total > maxBytes)
        out.error = QStringLiteral("the document is too large");
    else if (!writeAll(spool, head.constData(), size_t(head.size())))
        out.error = QStringLiteral("cannot keep the document: %1").arg(QString::fromLocal8Bit(std::strerror(errno)));
    while (out.error.isEmpty()) {
        const ssize_t n = next(chunk.data(), chunk.size(), &out.error);
        if (n <= 0)
            break;
        total += n;
        if (total > maxBytes) {
            out.error = QStringLiteral("the document is too large");
            break;
        }
        if (!writeAll(spool, chunk.data(), size_t(n)))
            out.error = QStringLiteral("cannot keep the document: %1").arg(QString::fromLocal8Bit(std::strerror(errno)));
    }
    ::close(fd);
    if (!out.error.isEmpty()) {
        ::close(spool);
        return out;
    }
    out.fd = spool;
    out.size = total;
    return out;
}

int reopenSpool(int spoolFd)
{
    if (spoolFd < 0)
        return -1;
    const QByteArray path = "/proc/self/fd/" + QByteArray::number(spoolFd);
    return ::open(path.constData(), O_RDONLY | O_CLOEXEC);
}

bool confineRenderer()
{
#if !(defined(__x86_64__) || defined(__aarch64__)) || __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
    return false; // no filter written for this architecture: no preview
#else
#if defined(__x86_64__)
    constexpr uint32_t arch = AUDIT_ARCH_X86_64;
#else
    constexpr uint32_t arch = AUDIT_ARCH_AARCH64;
#endif
    std::vector<sock_filter> f;
    const auto add = [&f](sock_filter s) { f.push_back(s); };
    const auto loadNumber = [&add] { add(BPF_STMT(BPF_LD | BPF_W | BPF_ABS, uint32_t(offsetof(struct seccomp_data, nr)))); };
    add(BPF_STMT(BPF_LD | BPF_W | BPF_ABS, uint32_t(offsetof(struct seccomp_data, arch))));
    add(BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, arch, 1, 0));
    add(BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS));
    loadNumber();
#if defined(__x86_64__)
    // The x32 numbers of the same calls: refused.
    add(BPF_JUMP(BPF_JMP | BPF_JGE | BPF_K, 0x40000000u, 0, 1));
    add(BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EPERM));
#endif
    const auto deny = [&add](long nr, int error) {
        add(BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, uint32_t(nr), 0, 1));
        add(BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | (uint32_t(error) & SECCOMP_RET_DATA)));
    };
    // An open that may write, create, truncate or append is refused; a read-only one (the fonts) goes on. The flags are the low
    // half of the argument (little-endian); the call's number is loaded again after.
    const auto denyWritingOpen = [&add, &loadNumber](long nr, int flagsArgument) {
        add(BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, uint32_t(nr), 0, 3));
        add(BPF_STMT(BPF_LD | BPF_W | BPF_ABS, uint32_t(offsetof(struct seccomp_data, args) + 8 * flagsArgument)));
        add(BPF_JUMP(BPF_JMP | BPF_JSET | BPF_K, uint32_t(O_WRONLY | O_RDWR | O_CREAT | O_TRUNC | O_APPEND), 0, 1));
        add(BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EPERM));
        loadNumber();
    };
    denyWritingOpen(SYS_openat, 2);
#ifdef SYS_open
    denyWritingOpen(SYS_open, 1);
#endif
    // openat2's flags are behind a pointer: refused as unknown, so that a caller falls back to openat.
#ifdef SYS_openat2
    deny(SYS_openat2, ENOSYS);
#endif
    for (long nr : {
#ifdef SYS_io_uring_setup
             long(SYS_io_uring_setup), long(SYS_io_uring_enter), long(SYS_io_uring_register),
#endif
             -1L}) {
        if (nr >= 0)
            deny(nr, ENOSYS);
    }
    const long refused[] = {
        // No socket: no bus, no network, no other process.
        SYS_socket, SYS_socketpair, SYS_connect, SYS_bind, SYS_listen, SYS_accept, SYS_accept4,
        // No program, no other process's memory.
        SYS_execve, SYS_execveat, SYS_ptrace, SYS_process_vm_readv, SYS_process_vm_writev,
        // No change to any file or folder.
        SYS_unlinkat, SYS_renameat, SYS_mkdirat, SYS_linkat, SYS_symlinkat, SYS_fchmod, SYS_fchmodat, SYS_fchown, SYS_fchownat,
        SYS_truncate, SYS_mknodat, SYS_utimensat, SYS_setxattr, SYS_lsetxattr, SYS_fsetxattr, SYS_removexattr, SYS_lremovexattr,
        SYS_fremovexattr, SYS_name_to_handle_at, SYS_open_by_handle_at,
#ifdef SYS_renameat2
        SYS_renameat2,
#endif
#ifdef SYS_fchmodat2
        SYS_fchmodat2,
#endif
#ifdef SYS_unlink
        SYS_unlink, SYS_rename, SYS_rmdir, SYS_mkdir, SYS_link, SYS_symlink, SYS_chmod, SYS_chown, SYS_lchown, SYS_mknod, SYS_creat,
        SYS_utime, SYS_utimes, SYS_futimesat,
#endif
        // No mount, namespace, kernel module, key, BPF program or other kernel facility.
        SYS_mount, SYS_umount2, SYS_pivot_root, SYS_chroot, SYS_unshare, SYS_setns, SYS_bpf, SYS_perf_event_open, SYS_keyctl, SYS_add_key,
        SYS_request_key, SYS_kexec_load, SYS_init_module, SYS_finit_module, SYS_delete_module, SYS_userfaultfd, SYS_fanotify_init,
        SYS_quotactl, SYS_swapon, SYS_swapoff,
#ifdef SYS_kexec_file_load
        SYS_kexec_file_load,
#endif
#ifdef SYS_open_tree
        SYS_open_tree, SYS_move_mount, SYS_fsopen, SYS_fsconfig, SYS_fsmount, SYS_fspick,
#endif
#ifdef SYS_mount_setattr
        SYS_mount_setattr,
#endif
#ifdef SYS_pidfd_getfd
        SYS_pidfd_getfd,
#endif
    };
    for (long nr : refused)
        deny(nr, EPERM);
    add(BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW));
    if (::prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0)
        return false;
    sock_fprog program{static_cast<unsigned short>(f.size()), f.data()};
    // Every thread of the process (TSYNC), else this one alone where the kernel has no seccomp() call.
    if (::syscall(SYS_seccomp, SECCOMP_SET_MODE_FILTER, SECCOMP_FILTER_FLAG_TSYNC, &program) == 0)
        return true;
    return errno == ENOSYS && ::prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &program, 0, 0) == 0;
#endif
}

bool isPreviewChildInvocation(int argc, char **argv)
{
    return argc >= 5 && std::strcmp(argv[1], "--print-preview") == 0;
}

int previewChildMain(int argc, char **argv)
{
    bool pageOk = false, widthOk = false, heightOk = false;
    const int page = QByteArray(argv[2]).toInt(&pageOk);
    const int width = QByteArray(argv[3]).toInt(&widthOk);
    const int height = QByteArray(argv[4]).toInt(&heightOk);
    if (!pageOk || !widthOk || !heightOk || page < 0 || width < 0 || height < 0 || width > kMaxPreviewSide || height > kMaxPreviewSide)
        return 2;
    // No window, no bus, no settings: Qt Core, Qt PDF and a painter on an image.
    QCoreApplication app(argc, argv);
    // Before a byte of the document is read.
    if (!confineRenderer())
        return 3;
    QPdfDocument document;
    if (document.load(QStringLiteral("/dev/stdin")) != QPdfDocument::Error::None)
        return 1;
    const int pages = document.pageCount();
    if (pages <= 0 || pages > kMaxPages || page >= pages)
        return 1;
    const QSizeF size = document.pagePointSize(page);
    if (!(size.width() > 0) || !(size.height() > 0) || size.width() > kMaxPagePoints || size.height() > kMaxPagePoints)
        return 1;
    QImage image;
    if (width > 0 && height > 0) {
        const QSize fitted = size.scaled(QSizeF(width, height), Qt::KeepAspectRatio).toSize().boundedTo(QSize(width, height)).expandedTo(QSize(1, 1));
        const QImage drawn = document.render(page, fitted);
        // On white, as on paper (pdfium leaves what the page does not paint transparent).
        image = QImage(fitted, QImage::Format_RGB32);
        image.fill(Qt::white);
        QPainter painter(&image);
        painter.drawImage(0, 0, drawn);
        painter.end();
    }
    const QByteArray header = QStringLiteral("GFPP1 %1 %2 %3 %4 %5\n")
                                  .arg(pages)
                                  .arg(size.width(), 0, 'f', 3)
                                  .arg(size.height(), 0, 'f', 3)
                                  .arg(image.width())
                                  .arg(image.height())
                                  .toLatin1();
    if (!writeAll(STDOUT_FILENO, header.constData(), size_t(header.size())))
        return 1;
    for (int y = 0; y < image.height(); ++y) {
        if (!writeAll(STDOUT_FILENO, reinterpret_cast<const char *>(image.constScanLine(y)), size_t(image.width()) * 4))
            return 1;
    }
    return 0;
}

Rendered renderPreview(const QStringList &command, int spoolFd, int page, const QSize &max, int deadlineMs, const std::function<bool()> &stopped)
{
    if (command.isEmpty() || spoolFd < 0 || page < 0)
        return {};
    const QSize want = max.isEmpty() ? QSize(0, 0) : max.boundedTo(QSize(kMaxPreviewSide, kMaxPreviewSide));
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    for (const char *name : {"DBUS_SESSION_BUS_ADDRESS", "DBUS_SYSTEM_BUS_ADDRESS", "WAYLAND_DISPLAY", "DISPLAY", "XDG_ACTIVATION_TOKEN",
                             "DESKTOP_STARTUP_ID"})
        env.remove(QString::fromLatin1(name));
    env.insert(QStringLiteral("QT_QPA_PLATFORM"), QStringLiteral("offscreen"));
#ifdef __SANITIZE_ADDRESS__
    // A sanitizer build (the tests): LeakSanitizer's check at exit uses ptrace, which the filter refuses.
    env.insert(QStringLiteral("ASAN_OPTIONS"), QStringLiteral("detect_leaks=0"));
#endif
    QProcess child;
    child.setProcessEnvironment(env);
    child.setProgram(command.first());
    child.setArguments(command.mid(1) << QString::number(page) << QString::number(want.width()) << QString::number(want.height()));
    // The private file, opened here read-only from its start (Qt opens it in this process and hands it to the child).
    child.setStandardInputFile(QStringLiteral("/proc/self/fd/%1").arg(spoolFd));
    child.setStandardErrorFile(QProcess::nullDevice());
    child.setWorkingDirectory(QStringLiteral("/"));
    // Only its standard input, output and error.
    child.setUnixProcessParameters(QProcess::UnixProcessFlag::CloseFileDescriptors | QProcess::UnixProcessFlag::ResetSignalHandlers);
    // In the forked child before exec (async-signal-safe calls only): no core file, limits on memory and CPU time, and it dies
    // with the thread that started it. The memory in use (RLIMIT_DATA), not the address space: Qt PDF's pdfium reserves tens of
    // GiB of address space it never uses (PartitionAlloc's pools; the child stopped at 32 GiB of RLIMIT_AS), and a page of
    // 2048 pixels needs less than 256 MiB.
    child.setChildProcessModifier([] {
#ifndef __SANITIZE_ADDRESS__ // a sanitizer build maps terabytes of shadow memory
        struct rlimit data = {1UL << 30, 1UL << 30};
        ::setrlimit(RLIMIT_DATA, &data);
#endif
        struct rlimit cpu = {10, 10};
        ::setrlimit(RLIMIT_CPU, &cpu);
        struct rlimit core = {0, 0};
        ::setrlimit(RLIMIT_CORE, &core);
        ::prctl(PR_SET_PDEATHSIG, SIGKILL);
    });
    child.start(QIODevice::ReadOnly);
    if (!child.waitForStarted(2000))
        return {};
    const qint64 cap = 128 + qint64(want.width()) * want.height() * 4;
    QByteArray out;
    QElapsedTimer clock;
    clock.start();
    bool killed = false;
    while (child.state() != QProcess::NotRunning) {
        if ((stopped && stopped()) || clock.elapsed() > deadlineMs || out.size() > cap) {
            child.kill();
            killed = true;
            child.waitForFinished(1000);
            break;
        }
        child.waitForReadyRead(50);
        out += child.readAllStandardOutput();
    }
    out += child.readAllStandardOutput();
    if (killed || child.exitStatus() != QProcess::NormalExit || child.exitCode() != 0 || out.size() > cap)
        return {};
    // The header, then exactly the pixels it announces.
    const qsizetype eol = out.indexOf('\n');
    if (eol <= 0 || eol > 127)
        return {};
    const QList<QByteArray> fields = out.left(eol).split(' ');
    if (fields.size() != 6 || fields.at(0) != "GFPP1")
        return {};
    bool ok[5] = {};
    Rendered r;
    r.pages = fields.at(1).toInt(&ok[0]);
    const double w = fields.at(2).toDouble(&ok[1]);
    const double h = fields.at(3).toDouble(&ok[2]);
    const int iw = fields.at(4).toInt(&ok[3]);
    const int ih = fields.at(5).toInt(&ok[4]);
    if (!ok[0] || !ok[1] || !ok[2] || !ok[3] || !ok[4] || r.pages <= 0 || r.pages > kMaxPages || !std::isfinite(w) || !std::isfinite(h)
        || !(w > 0) || !(h > 0) || w > kMaxPagePoints || h > kMaxPagePoints || iw < 0 || ih < 0 || iw > want.width() || ih > want.height()
        || (iw == 0) != (ih == 0) || out.size() - eol - 1 != qint64(iw) * ih * 4)
        return {};
    r.pageSize = QSizeF(w, h);
    if (iw > 0) {
        r.image = QImage(iw, ih, QImage::Format_RGB32);
        const char *pixels = out.constData() + eol + 1;
        for (int y = 0; y < ih; ++y) {
            auto *line = reinterpret_cast<quint32 *>(r.image.scanLine(y));
            std::memcpy(line, pixels + qsizetype(y) * iw * 4, size_t(iw) * 4);
            for (int x = 0; x < iw; ++x)
                line[x] |= 0xff000000u; // opaque, as RGB32 must be
        }
    }
    r.ok = true;
    return r;
}

namespace {
QMutex s_imagesMutex;
QHash<QString, QImage> s_images;
quint64 s_imageSerial = 0;
} // namespace

QString PreviewImages::insert(const QImage &image)
{
    QMutexLocker lock(&s_imagesMutex);
    const QString key = QString::number(++s_imageSerial);
    s_images.insert(key, image);
    return key;
}

QImage PreviewImages::value(const QString &key)
{
    QMutexLocker lock(&s_imagesMutex);
    return s_images.value(key);
}

void PreviewImages::remove(const QString &key)
{
    QMutexLocker lock(&s_imagesMutex);
    s_images.remove(key);
}

int PreviewImages::size()
{
    QMutexLocker lock(&s_imagesMutex);
    return int(s_images.size());
}

PrintPreviewProvider::PrintPreviewProvider()
    : QQuickImageProvider(QQuickImageProvider::Image)
{
}

QImage PrintPreviewProvider::requestImage(const QString &id, QSize *size, const QSize &requestedSize)
{
    Q_UNUSED(requestedSize)
    const QImage image = PreviewImages::value(id);
    if (size)
        *size = image.size();
    return image;
}

} // namespace grassfield::portal
