// grassfield-secrets-handover (ADR-0035 D-12, step 2c): run once per Grassfield session by
// grassfield-secrets-handover.service, which config/hypr/grassfield/autostart.lua starts before the shell. The unit is
// Type=notify: it reports ready after phase 1, so the shell, and any app the user opens from it, starts after a leftover
// ksecretd has let go of the Secret Service; phase 2 goes on while the session starts.
#include "handover.h"
#include "logic.h"
#include "translationloader.h"

#include <QCoreApplication>
#include <QDir>

#include <cstdio>
#include <cstring>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

namespace {

// systemd's readiness message, without libsystemd: one datagram to $NOTIFY_SOCKET ('@' marks an abstract address).
void notifyReady()
{
    const QByteArray socketPath = qgetenv("NOTIFY_SOCKET");
    if (socketPath.isEmpty() || socketPath.size() >= int(sizeof(sockaddr_un::sun_path)))
        return;
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    std::memcpy(address.sun_path, socketPath.constData(), size_t(socketPath.size()));
    if (address.sun_path[0] == '@')
        address.sun_path[0] = '\0';
    const int fd = ::socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0)
        return;
    static const char message[] = "READY=1";
    ::sendto(fd, message, sizeof message - 1, MSG_NOSIGNAL, reinterpret_cast<const sockaddr *>(&address),
             socklen_t(offsetof(sockaddr_un, sun_path) + size_t(socketPath.size())));
    ::close(fd);
}

QString home(const char *variable, const QString &fallback)
{
    const QString value = qEnvironmentVariable(variable);
    return value.startsWith(QLatin1Char('/')) ? value : QDir::homePath() + fallback;
}

} // namespace

int main(int argc, char **argv)
{
    // Secret values pass through this process: no core file and no ptrace by the user's other processes (the unit also sets
    // LimitCORE=0 and MemorySwapMax=0). Its own /proc/self stays readable (its pidfds' fdinfo).
    ::prctl(PR_SET_DUMPABLE, 0, 0, 0, 0);
    // QDBUS_DEBUG makes Qt print every D-Bus message with its arguments, secrets included, to the journal: never here (the
    // unit unsets it too).
    qunsetenv("QDBUS_DEBUG");
    QCoreApplication app(argc, argv);
    QCoreApplication::setApplicationName(QStringLiteral("grassfield-secrets-handover"));
    const bool dev = grassfield::i18n::devSession();
    if (qgetenv("GRASSFIELD_SESSION") != "1" && !dev) {
        std::fputs("grassfield-secrets-handover: refused: not a Grassfield session\n", stderr);
        notifyReady();
        return 2;
    }
    // A dev session runs it only against the tests' fakes: never on the owner's bus, whose ksecretd and secrets are real.
    if (dev && (qgetenv("GF_TEST_BUS") != "1"
                || !grassfield::handover::isPrivateTestBus(qEnvironmentVariable("DBUS_SESSION_BUS_ADDRESS"), qEnvironmentVariable("GF_TEST_BUS_DIR")))) {
        std::fputs("grassfield-secrets-handover: refused: a dev session runs it only on a private test bus (GF_TEST_BUS=1, GF_TEST_BUS_DIR)\n", stderr);
        notifyReady();
        return 2;
    }
    // The user's own kwalletrc keeps KWallet as the Secret Service: that choice wins (ADR-0035 Q17-b), nothing is done.
    if (grassfield::handover::userKeepsKWalletService(home("XDG_CONFIG_HOME", QStringLiteral("/.config")))) {
        std::puts("grassfield-secrets-handover: left alone: the user's kwalletrc keeps KWallet as the Secret Service");
        notifyReady();
        return 0;
    }
    grassfield::i18n::install(grassfield::i18n::systemLanguage());

    grassfield::handover::Config config;
    config.dataHome = home("XDG_DATA_HOME", QStringLiteral("/.local/share"));
    config.stateDir = grassfield::handover::stateDirectory(qEnvironmentVariable("STATE_DIRECTORY"),
                                                           home("XDG_STATE_HOME", QStringLiteral("/.local/state")));
    if (dev) {
        // Dev plumbing (ADR-0019), honoured only in a dev session: the tests' fake services run another executable.
        if (const QString path = qEnvironmentVariable("GRASSFIELD_HANDOVER_KSECRETD"); !path.isEmpty())
            config.ksecretd = path;
        if (const QString path = qEnvironmentVariable("GRASSFIELD_HANDOVER_KEYRING"); !path.isEmpty())
            config.keyring = path;
        if (const int ms = qEnvironmentVariableIntValue("GRASSFIELD_HANDOVER_PROMPT_MS"); ms > 0)
            config.promptTimeoutMs = ms;
        if (const int ms = qEnvironmentVariableIntValue("GRASSFIELD_HANDOVER_NOTIFY_MS"); ms > 0)
            config.notifyWaitMs = ms;
    }

    QDBusConnection bus = QDBusConnection::sessionBus();
    if (!bus.isConnected()) {
        std::fputs("grassfield-secrets-handover: no session bus\n", stderr);
        notifyReady();
        return 1;
    }
    grassfield::handover::Handover handover(bus, config);
    handover.releaseLeftover();
    notifyReady();
    const QString outcome = handover.move();
    std::printf("grassfield-secrets-handover: %s moved=%d kept=%d skipped=%d\n", qPrintable(outcome), handover.moved(), handover.kept(),
                handover.skipped());
    return 0;
}
