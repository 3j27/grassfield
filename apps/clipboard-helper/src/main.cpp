// grassfield-clipboard-helper (ADR-0034): the clipboard history's capture and store, ONE process per shell, started by
// shell/services/Clipboard.qml while the history is on.
//
//   grassfield-clipboard-helper --display <absolute socket> --state <dir> --runtime <dir> [--retention <ms>] [--history-store 0|1]
//   grassfield-clipboard-helper --clear-pinned --state <dir>          deletes the pinned store (the history being off), then exits
//   grassfield-clipboard-helper --clear-history --state <dir>         deletes the history store (the history being off), then exits
//   grassfield-clipboard-helper --apply-clears --state <dir> [--cleared-at <ms>] [--pinned-cleared-at <ms>]
//                                      carries out the settings' clears not carried out yet (the history being off), then exits
//   grassfield-clipboard-helper --thumbnail <png|jpeg|webp> <max px>  the image worker: one image on stdin, a PNG on stdout
//
// The display is only ever the socket named by --display: WAYLAND_DISPLAY and WAYLAND_SOCKET are removed from the environment
// first and never read (libwayland's own lookup takes WAYLAND_SOCKET first, whatever name it is given).
//
// stdout, one line each, fields separated by US (0x1f), each escaped (backslash, line break, return, US: \\ \n \r \u):
//   S ok | S unsupported | S error <why>     the state (unsupported: exit 3; error: exit 1)
//   L 0|1                                   the compositor's lock state (hyprland_lock_notifier_v1)
//   O <seq> <kind>                          a copy to decide: the shell answers Y or N; nothing is read before Y
//   I <id> <kind> <mimes> <size> <copiedAt> <pinnedAt> <formatted> <files> <title> <excerpt> <thumbnail> <app>
//   X <id>                                  an item is gone (deleted, expired, pushed out, cleared)
//   A <id> | A                              the clipboard now holds that item | the request failed or another client took it
//   R <seq> <id>...                         the items matching a search, pinned first, newest first
//   N pin-full <id>                         the pinned items are full
//   V <id> <png path> <text>                a preview (an image's PNG, or the text, at most 64 KiB); both empty when none
// stdin, one line each, same fields: R | P (resume or pause capture), Y <seq> <app> | N <seq>, T <retention ms>, D 0|1 (the
// history store), E (expire now), CH (clear the history), CP (clear the pinned items), X <id>, PIN <id>, UNPIN <id>,
// C <id> 0|1 (copy; 1: plain text only), Q <seq> <query>, V <id>, VD <id>, QUIT. End of stdin ends the helper.
#include "helper.h"
#include "thumbnail.h"

#include <QCoreApplication>
#include <QFile>
#include <QSocketNotifier>

#include <algorithm>
#include <csignal>
#include <cstdio>
#include <cstring>

#include <fcntl.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>

namespace
{
int g_signalPipe[2] = {-1, -1};

void onSignal(int)
{
    const char c = 1;
    [[maybe_unused]] const ssize_t n = ::write(g_signalPipe[1], &c, 1);
}

class Commands : public QObject
{
public:
    explicit Commands(Helper *helper)
        : m_helper(helper)
    {
        ::fcntl(0, F_SETFL, ::fcntl(0, F_GETFL) | O_NONBLOCK);
        m_notifier = new QSocketNotifier(0, QSocketNotifier::Read, this);
        connect(m_notifier, &QSocketNotifier::activated, this, [this] { readable(); });
    }

private:
    void readable()
    {
        char chunk[65536];
        for (;;) {
            const ssize_t n = ::read(0, chunk, sizeof chunk);
            if (n == 0) {
                m_notifier->setEnabled(false);
                QCoreApplication::exit(0); // the shell closed our stdin
                return;
            }
            if (n < 0)
                return;
            m_buffer.append(chunk, int(n));
            qsizetype at;
            while ((at = m_buffer.indexOf('\n')) >= 0) {
                const QByteArray line = m_buffer.left(at);
                m_buffer.remove(0, at + 1);
                m_helper->command(line);
            }
            if (m_buffer.size() > 1024 * 1024)
                m_buffer.clear(); // no command is that long
        }
    }

    Helper *m_helper;
    QSocketNotifier *m_notifier;
    QByteArray m_buffer;
};

int usage()
{
    std::fprintf(stderr, "usage: grassfield-clipboard-helper --display <absolute socket> --state <dir> --runtime <dir> "
                         "[--retention <ms>] [--history-store 0|1]\n"
                         "       grassfield-clipboard-helper --clear-pinned --state <dir>\n"
                         "       grassfield-clipboard-helper --clear-history --state <dir>\n"
                         "       grassfield-clipboard-helper --apply-clears --state <dir> [--cleared-at <ms>] [--pinned-cleared-at <ms>]\n"
                         "       grassfield-clipboard-helper --thumbnail <png|jpeg|webp> <max px>\n");
    return 2;
}
} // namespace

int main(int argc, char **argv)
{
    // Before anything that could look at them: the display is only the one named on the command line.
    ::unsetenv("WAYLAND_SOCKET");
    ::unsetenv("WAYLAND_DISPLAY");
    ::umask(077);
    ::signal(SIGPIPE, SIG_IGN);

    if (argc == 4 && std::strcmp(argv[1], "--thumbnail") == 0) {
        QCoreApplication app(argc, argv);
        return Thumbnail::runWorker(QByteArray(argv[2]), QByteArray(argv[3]).toInt());
    }

    Helper::Options options;
    bool clearPinned = false;
    bool clearHistory = false;
    bool applyClears = false;
    // A clear time: digits only, 0 or more (the settings' milliseconds).
    const auto clearTime = [](const char *text, qint64 *out) {
        const QByteArray value(text);
        bool ok = !value.isEmpty() && std::all_of(value.cbegin(), value.cend(), [](char c) { return c >= '0' && c <= '9'; });
        *out = ok ? value.toLongLong(&ok) : -1;
        return ok;
    };
    for (int i = 1; i < argc; ++i) {
        const QByteArray arg(argv[i]);
        const bool hasValue = i + 1 < argc;
        if (arg == "--clear-pinned")
            clearPinned = true;
        else if (arg == "--clear-history")
            clearHistory = true;
        else if (arg == "--apply-clears")
            applyClears = true;
        else if (arg == "--cleared-at" && hasValue) {
            if (!clearTime(argv[++i], &options.clearedAtMs))
                return usage();
        } else if (arg == "--pinned-cleared-at" && hasValue) {
            if (!clearTime(argv[++i], &options.pinnedClearedAtMs))
                return usage();
        }
        else if (arg == "--display" && hasValue)
            options.display = QByteArray(argv[++i]);
        else if (arg == "--state" && hasValue)
            options.stateDir = QFile::decodeName(argv[++i]);
        else if (arg == "--runtime" && hasValue)
            options.runtimeDir = QFile::decodeName(argv[++i]);
        else if (arg == "--retention" && hasValue)
            options.retentionMs = QByteArray(argv[++i]).toLongLong();
        else if (arg == "--history-store" && hasValue)
            options.historyStore = QByteArray(argv[++i]) == "1";
        else
            return usage();
    }
    if (!options.stateDir.startsWith(QLatin1Char('/')))
        return usage();
    if (clearPinned)
        return Helper::clearPinned(options.stateDir);
    if (clearHistory)
        return Helper::clearHistoryStore(options.stateDir);
    if (applyClears) {
        Helper::applyClears(options.stateDir, options.clearedAtMs, options.pinnedClearedAtMs);
        return 0;
    }
    if (!options.runtimeDir.startsWith(QLatin1Char('/')))
        return usage();
    if (options.display.isEmpty() || options.display.at(0) != '/') {
        std::fprintf(stderr, "grassfield-clipboard-helper: --display needs an absolute socket path (there is no default)\n");
        return 2;
    }

    // dies with the shell, and runs behind it
    ::prctl(PR_SET_PDEATHSIG, SIGTERM);
    if (::getppid() == 1)
        return 0;
    ::setpriority(PRIO_PROCESS, 0, 10);

    QCoreApplication app(argc, argv);
    options.program = QCoreApplication::applicationFilePath();

    if (::pipe2(g_signalPipe, O_CLOEXEC | O_NONBLOCK) != 0)
        return 1;
    ::signal(SIGTERM, onSignal);
    ::signal(SIGINT, onSignal);
    QSocketNotifier signalNotifier(g_signalPipe[0], QSocketNotifier::Read);
    QObject::connect(&signalNotifier, &QSocketNotifier::activated, &app, [] { QCoreApplication::exit(0); });

    Helper helper{options,
                  [](const QByteArray &line) {
                      if (std::fwrite(line.constData(), 1, size_t(line.size()), stdout) != size_t(line.size()) || std::fflush(stdout) != 0)
                          _exit(0); // the reader is gone
                  },
                  [](int code) { QCoreApplication::exit(code); }};
    if (const int failed = helper.start()) {
        helper.cleanup();
        return failed;
    }
    Commands commands(&helper);
    const int code = app.exec();
    helper.cleanup();
    return code;
}
