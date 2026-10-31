#include "printpreview.h"

#include "printsystem.h"

#include <QCoreApplication>
#include <QDir>
#include <QElapsedTimer>
#include <QEventLoop>
#include <QFile>
#include <QHash>
#include <QMutex>
#include <QPainter>
#include <QPdfDocument>
#include <QProcess>
#include <QProcessEnvironment>
#include <QTimer>

#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/landlock.h>
#include <linux/seccomp.h>

#include <fcntl.h>
#include <sched.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/stat.h>
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
// The child's data in use (RLIMIT_DATA): a page of 2048 pixels needs less than 192 MiB (measured with the test documents); one
// child at a time, so grassfield-portal and a child stay within the unit's MemoryMax (1 GiB). Not the address space: pdfium
// reserves tens of GiB it never uses (PartitionAlloc's pools).
constexpr rlim_t kChildDataBytes = rlim_t(512) << 20;

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

// One child at a time, for the whole process (its memory adds to grassfield-portal's in the unit's budget).
QMutex s_rendering;

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

namespace {

// Landlock (ADR-0035 6-20): reading files and folders under /usr only (the fonts pdfium looks for: /usr/share/fonts,
// /usr/share/X11/fonts, /usr/local/share/fonts), nothing written anywhere, no TCP; signals and abstract sockets scoped to the
// child where the kernel has ABI 6. The rights handled follow the kernel's ABI, so every right it knows is denied unless listed.
bool restrictFiles()
{
    const long abi = ::syscall(SYS_landlock_create_ruleset, nullptr, 0, LANDLOCK_CREATE_RULESET_VERSION);
    if (abi < 1)
        return false;
    struct {
        quint64 fs;
        quint64 net;
        quint64 scoped;
    } attr{};
    // ABI 1: execute, write, read a file, read a folder, remove, make each kind of entry (bits 0 to 12).
    attr.fs = (quint64(1) << 13) - 1;
    if (abi >= 2)
        attr.fs |= quint64(1) << 13; // refer (a link or a rename across folders)
    if (abi >= 3)
        attr.fs |= quint64(1) << 14; // truncate
    if (abi >= 5)
        attr.fs |= quint64(1) << 15; // ioctl on a device
    if (abi >= 4)
        attr.net = quint64(1) << 0 | quint64(1) << 1; // bind, connect a TCP socket
    if (abi >= 6)
        attr.scoped = quint64(1) << 0 | quint64(1) << 1; // abstract unix sockets, signals
    // The fields an older kernel does not know are zero, which it accepts.
    const int ruleset = int(::syscall(SYS_landlock_create_ruleset, &attr, sizeof attr, 0));
    if (ruleset < 0)
        return false;
    bool ok = false;
    const int usr = ::open("/usr", O_PATH | O_DIRECTORY | O_CLOEXEC);
    if (usr >= 0) {
        landlock_path_beneath_attr beneath{};
        beneath.allowed_access = LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_READ_DIR;
        beneath.parent_fd = usr;
        ok = ::syscall(SYS_landlock_add_rule, ruleset, LANDLOCK_RULE_PATH_BENEATH, &beneath, 0) == 0
            && ::syscall(SYS_landlock_restrict_self, ruleset, 0) == 0;
        ::close(usr);
    }
    ::close(ruleset);
    return ok;
}

// The seccomp allow-list (ADR-0035 6-20), measured with a ptrace recorder on the calls the child makes once confined (Qt Core,
// Qt PDF, glibc; and AddressSanitizer's in a test build), three documents (shapes, embedded and standard fonts), 800 and 2048
// pixels: anything else fails with EPERM (clone3 with ENOSYS, so that glibc makes its threads with clone).
bool installFilter()
{
#if !(defined(__x86_64__) || defined(__aarch64__)) || __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
    return false; // no list written for this architecture: no preview
#else
#if defined(__x86_64__)
    constexpr uint32_t arch = AUDIT_ARCH_X86_64;
#else
    constexpr uint32_t arch = AUDIT_ARCH_AARCH64;
#endif
    constexpr uint32_t kAllow = SECCOMP_RET_ALLOW;
    constexpr uint32_t kRefuse = SECCOMP_RET_ERRNO | EPERM;
    std::vector<sock_filter> f;
    const auto add = [&f](sock_filter s) { f.push_back(s); };
    const auto loadNumber = [&add] { add(BPF_STMT(BPF_LD | BPF_W | BPF_ABS, uint32_t(offsetof(struct seccomp_data, nr)))); };
    // The low half of an argument (little-endian; the values checked fit in 32 bits).
    const auto loadArgument = [&add](int index) {
        add(BPF_STMT(BPF_LD | BPF_W | BPF_ABS, uint32_t(offsetof(struct seccomp_data, args) + 8 * index)));
    };
    add(BPF_STMT(BPF_LD | BPF_W | BPF_ABS, uint32_t(offsetof(struct seccomp_data, arch))));
    add(BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, arch, 1, 0));
    add(BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS));
    loadNumber();
#if defined(__x86_64__)
    // The x32 numbers of the same calls: refused.
    add(BPF_JUMP(BPF_JMP | BPF_JGE | BPF_K, 0x40000000u, 0, 1));
    add(BPF_STMT(BPF_RET | BPF_K, kRefuse));
#endif
    const auto allow = [&add, kAllow](long nr) {
        add(BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, uint32_t(nr), 0, 1));
        add(BPF_STMT(BPF_RET | BPF_K, kAllow));
    };
    // Allowed only when argument `index` is one of `values`.
    const auto allowWhen = [&](long nr, int index, const std::vector<uint32_t> &values) {
        const uint8_t k = uint8_t(values.size());
        add(BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, uint32_t(nr), 0, uint8_t(k + 3)));
        loadArgument(index);
        for (uint8_t i = 0; i < k; ++i)
            add(BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, values[i], uint8_t(k - i), 0));
        add(BPF_STMT(BPF_RET | BPF_K, kRefuse));
        add(BPF_STMT(BPF_RET | BPF_K, kAllow));
        loadNumber();
    };
    // Allowed only when none of `bits` is set in argument `index`.
    const auto allowWithout = [&](long nr, int index, uint32_t bits) {
        add(BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, uint32_t(nr), 0, 4));
        loadArgument(index);
        add(BPF_JUMP(BPF_JMP | BPF_JSET | BPF_K, bits, 1, 0));
        add(BPF_STMT(BPF_RET | BPF_K, kAllow));
        add(BPF_STMT(BPF_RET | BPF_K, kRefuse));
        loadNumber();
    };
    const auto answer = [&add](long nr, int error) {
        add(BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, uint32_t(nr), 0, 1));
        add(BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | (uint32_t(error) & SECCOMP_RET_DATA)));
    };
    const uint32_t self = uint32_t(::getpid());

    // Memory, the descriptors it has, time, its own threads and signals, the files Landlock lets it read.
    for (long nr : {long(SYS_read), long(SYS_write), long(SYS_readv), long(SYS_writev), long(SYS_pread64), long(SYS_close), long(SYS_lseek),
                    long(SYS_fstat), long(SYS_newfstatat), long(SYS_statx), long(SYS_getdents64), long(SYS_faccessat), long(SYS_mmap),
                    long(SYS_mprotect), long(SYS_munmap), long(SYS_mremap), long(SYS_madvise), long(SYS_brk), long(SYS_rt_sigaction),
                    long(SYS_rt_sigprocmask), long(SYS_rt_sigreturn), long(SYS_sigaltstack), long(SYS_futex), long(SYS_set_robust_list),
                    long(SYS_rseq), long(SYS_sched_yield), long(SYS_nanosleep), long(SYS_clock_nanosleep), long(SYS_clock_gettime),
                    long(SYS_gettimeofday), long(SYS_getpid), long(SYS_gettid), long(SYS_getuid), long(SYS_geteuid), long(SYS_getgid),
                    long(SYS_getegid), long(SYS_getrandom), long(SYS_eventfd2), long(SYS_pipe2), long(SYS_ppoll), long(SYS_exit),
                    long(SYS_exit_group), long(SYS_restart_syscall), long(SYS_membarrier)})
        allow(nr);
#ifdef SYS_stat
    for (long nr : {long(SYS_stat), long(SYS_lstat), long(SYS_poll), long(SYS_access)})
        allow(nr);
#endif
    // Opening only to read (Landlock decides where).
    allowWithout(SYS_openat, 2, uint32_t(O_WRONLY | O_RDWR | O_CREAT | O_TRUNC | O_APPEND));
#ifdef SYS_open
    allowWithout(SYS_open, 1, uint32_t(O_WRONLY | O_RDWR | O_CREAT | O_TRUNC | O_APPEND));
#endif
    // A thread of its own process only: no new process, no namespace (the security review of step 6b, BLOCKER 1).
    add(BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, uint32_t(SYS_clone), 0, 5));
    loadArgument(0);
    add(BPF_JUMP(BPF_JMP | BPF_JSET | BPF_K,
                 uint32_t(CLONE_NEWNS | CLONE_NEWCGROUP | CLONE_NEWUTS | CLONE_NEWIPC | CLONE_NEWUSER | CLONE_NEWPID | CLONE_NEWNET), 2, 0));
    add(BPF_JUMP(BPF_JMP | BPF_JSET | BPF_K, uint32_t(CLONE_THREAD), 0, 1));
    add(BPF_STMT(BPF_RET | BPF_K, kAllow));
    add(BPF_STMT(BPF_RET | BPF_K, kRefuse));
    loadNumber();
    // clone3's flags are behind a pointer: unknown, so that glibc falls back to clone.
#ifdef SYS_clone3
    answer(SYS_clone3, ENOSYS);
#endif
    // Descriptor flags, never a lock, a lease or a notification.
    allowWhen(SYS_fcntl, 1, {F_GETFD, F_SETFD, F_GETFL, F_SETFL});
    // A thread's name and an anonymous mapping's name.
    allowWhen(SYS_prctl, 0, {PR_SET_NAME, PR_GET_NAME, 0x53564d41u /* PR_SET_VMA */});
    // A signal, a resource limit or the processors only for itself (0: itself).
    allowWhen(SYS_kill, 0, {self});
    allowWhen(SYS_tgkill, 0, {self});
    allowWhen(SYS_rt_tgsigqueueinfo, 0, {self});
    allowWhen(SYS_prlimit64, 0, {0, self});
    allowWhen(SYS_sched_getaffinity, 0, {0, self});
    // Anything else: refused.
    add(BPF_STMT(BPF_RET | BPF_K, kRefuse));
    sock_fprog program{static_cast<unsigned short>(f.size()), f.data()};
    // Every thread of the process (TSYNC): 0, or the id of a thread it could not join (then the child draws nothing).
    return ::syscall(SYS_seccomp, SECCOMP_SET_MODE_FILTER, SECCOMP_FILTER_FLAG_TSYNC, &program) == 0;
#endif
}

} // namespace

bool confineRenderer()
{
    // Both or nothing: the child draws nothing when either cannot be installed (ADR-0035 6-20: fail closed).
    return ::prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) == 0 && restrictFiles() && installFilter();
}

QStringList rendererEnvironment()
{
    QStringList env;
    // The locale only: never the bus address, the display, the session's or the user's own variables.
    for (const char *name : {"LANG", "LC_ALL", "LC_CTYPE"}) {
        const QByteArray value = qgetenv(name);
        if (!value.isEmpty())
            env << QString::fromLatin1(name) + QLatin1Char('=') + QString::fromLocal8Bit(value);
    }
#ifdef __SANITIZE_ADDRESS__
    // A sanitizer build (the tests): LeakSanitizer's check at exit uses ptrace, which the filter refuses.
    env << QStringLiteral("ASAN_OPTIONS=detect_leaks=0");
#endif
    return env;
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
    // The document is descriptor 0, never a path (Landlock lets no path outside /usr open).
    QFile input;
    if (!input.open(STDIN_FILENO, QIODevice::ReadOnly, QFileDevice::DontCloseHandle))
        return 1;
    QPdfDocument document;
    document.load(&input);
    if (document.status() == QPdfDocument::Status::Loading) {
        QEventLoop loop;
        QObject::connect(&document, &QPdfDocument::statusChanged, &loop, [&loop](QPdfDocument::Status status) {
            if (status != QPdfDocument::Status::Loading)
                loop.quit();
        });
        loop.exec();
    }
    if (document.status() != QPdfDocument::Status::Ready)
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
    // One child at a time: wait for the one drawing (its deadline bounds the wait), unless this one is stopped meanwhile.
    while (!s_rendering.tryLock(50)) {
        if (stopped && stopped())
            return {};
    }
    const struct Unlock {
        ~Unlock() { s_rendering.unlock(); }
    } unlock;
    const QSize want = max.isEmpty() ? QSize(0, 0) : max.boundedTo(QSize(kMaxPreviewSide, kMaxPreviewSide));
    QProcessEnvironment env;
    for (const QString &entry : rendererEnvironment())
        env.insert(entry.section(QLatin1Char('='), 0, 0), entry.section(QLatin1Char('='), 1));
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
    // In the forked child before exec (async-signal-safe calls only): a session of its own (no terminal, not grassfield-portal's
    // process group), no core file, limits on its data in use and CPU time, the OOM killer's first choice, and it dies with the
    // thread that started it.
    child.setChildProcessModifier([] {
        ::setsid();
#ifndef __SANITIZE_ADDRESS__ // a sanitizer build maps terabytes of shadow memory
        struct rlimit data = {kChildDataBytes, kChildDataBytes};
        ::setrlimit(RLIMIT_DATA, &data);
#endif
        struct rlimit cpu = {10, 10};
        ::setrlimit(RLIMIT_CPU, &cpu);
        struct rlimit core = {0, 0};
        ::setrlimit(RLIMIT_CORE, &core);
        const int oom = ::open("/proc/self/oom_score_adj", O_WRONLY | O_CLOEXEC);
        if (oom >= 0) {
            ssize_t written = ::write(oom, "1000", 4);
            (void)written;
            ::close(oom);
        }
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
