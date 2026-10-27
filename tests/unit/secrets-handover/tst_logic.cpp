// The handover's decisions without a bus (apps/secrets-handover/src/logic.h, peer.h): which items move, when KWallet is not
// even asked, the marker, the user's own choice of KWallet, which bus a dev run may use, and which executables are trusted.
#include "logic.h"
#include "peer.h"

#include <QDir>
#include <QFile>
#include <QTemporaryDir>

#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <gtest/gtest.h>

using namespace grassfield::handover;

TEST(SecretsHandover, OnlyItemsALibsecretClientSavedMove)
{
    EXPECT_TRUE(isLibsecretItem({{QStringLiteral("xdg:schema"), QStringLiteral("chrome_libsecret_os_crypt_password_v2")},
                                 {QStringLiteral("application"), QStringLiteral("chromium")}}));
    // An entry written through KWallet's own API: server, user and type only.
    EXPECT_FALSE(isLibsecretItem({{QStringLiteral("server"), QStringLiteral("Passwords")}, {QStringLiteral("user"), QStringLiteral("smb-share")},
                                  {QStringLiteral("type"), QStringLiteral("plaintext")}}));
    EXPECT_FALSE(isLibsecretItem({{QStringLiteral("xdg:schema"), QString()}}));
    EXPECT_FALSE(isLibsecretItem({}));
}

TEST(SecretsHandover, NoWalletFileMeansNothingToAsk)
{
    QTemporaryDir data;
    ASSERT_TRUE(data.isValid());
    EXPECT_FALSE(hasWallet(data.path()));
    ASSERT_TRUE(QDir().mkpath(data.path() + QStringLiteral("/kwalletd")));
    QFile attributes(data.path() + QStringLiteral("/kwalletd/kdewallet_attributes.json"));
    ASSERT_TRUE(attributes.open(QIODevice::WriteOnly));
    attributes.close();
    EXPECT_FALSE(hasWallet(data.path())); // attributes alone: no wallet
    QFile wallet(data.path() + QStringLiteral("/kwalletd/kdewallet.kwl"));
    ASSERT_TRUE(wallet.open(QIODevice::WriteOnly));
    wallet.close();
    EXPECT_TRUE(hasWallet(data.path()));
}

TEST(SecretsHandover, MarkerSaysOnlyCounts)
{
    EXPECT_EQ(markerPath(QStringLiteral("/home/u/.local/state/grassfield")), QStringLiteral("/home/u/.local/state/grassfield/secrets-handover"));
    EXPECT_EQ(markerLine(QStringLiteral("moved"), 2, 1), QStringLiteral("moved moved=2 kept=1\n"));
}

TEST(SecretsHandover, MarkerGoesToTheUnitsStateDirectory)
{
    const QString home = QStringLiteral("/home/u/.local/state");
    EXPECT_EQ(stateDirectory(QStringLiteral("/home/u/.local/state/grassfield"), home), QStringLiteral("/home/u/.local/state/grassfield"));
    EXPECT_EQ(stateDirectory(QStringLiteral("/run/a:/run/b"), home), QStringLiteral("/run/a")); // several: the first
    EXPECT_EQ(stateDirectory(QString(), home), QStringLiteral("/home/u/.local/state/grassfield"));
    EXPECT_EQ(stateDirectory(QStringLiteral("relative"), home), QStringLiteral("/home/u/.local/state/grassfield"));
}

TEST(SecretsHandover, TheUsersOwnKWalletChoiceWins)
{
    QTemporaryDir config;
    ASSERT_TRUE(config.isValid());
    const auto keeps = [&](const QByteArray &text) {
        QFile file(config.path() + QStringLiteral("/kwalletrc"));
        EXPECT_TRUE(file.open(QIODevice::WriteOnly | QIODevice::Truncate));
        file.write(text);
        file.close();
        return userKeepsKWalletService(config.path());
    };
    EXPECT_FALSE(userKeepsKWalletService(config.path())); // no file
    EXPECT_TRUE(keeps("[org.freedesktop.secrets]\napiEnabled=true\n"));
    EXPECT_TRUE(keeps("[Wallet]\nEnabled=true\n\n[org.freedesktop.secrets]\napiEnabled[$i]=1\n"));
    EXPECT_TRUE(keeps("[org.freedesktop.secrets]\napiEnabled = Yes\n"));
    EXPECT_FALSE(keeps("[org.freedesktop.secrets]\napiEnabled=false\n"));
    EXPECT_FALSE(keeps("[org.freedesktop.secrets]\napiEnabled=true\napiEnabled=false\n")); // the last entry wins
    EXPECT_FALSE(keeps("[Wallet]\napiEnabled=true\n"));                                      // another group
    EXPECT_FALSE(keeps("[org.freedesktop.secrets]\napiEnabledX=true\n"));
}

TEST(SecretsHandover, ADevRunUsesOnlyAPrivateTestBus)
{
    const QString dir = QStringLiteral("/tmp/secrets-handover.x/move");
    EXPECT_TRUE(isPrivateTestBus(QStringLiteral("unix:path=/tmp/secrets-handover.x/move/bus.sock,guid=0123"), dir));
    EXPECT_TRUE(isPrivateTestBus(QStringLiteral("tcp:host=127.0.0.1,port=40001,family=ipv4"), dir));
    EXPECT_FALSE(isPrivateTestBus(QStringLiteral("unix:path=/run/user/1000/bus"), dir));
    EXPECT_FALSE(isPrivateTestBus(QStringLiteral("unix:path=/tmp/secrets-handover.x/move/../../../run/user/1000/bus"), dir));
    EXPECT_FALSE(isPrivateTestBus(QStringLiteral("unix:path=%2Frun%2Fuser%2F1000%2Fbus"), dir));
    EXPECT_FALSE(isPrivateTestBus(QStringLiteral("unix:abstract=/tmp/dbus-x"), dir));
    EXPECT_FALSE(isPrivateTestBus(QStringLiteral("unix:path=/tmp/secrets-handover.x/move/bus.sock;unix:path=/run/user/1000/bus"), dir));
    EXPECT_FALSE(isPrivateTestBus(QStringLiteral("tcp:host=192.168.1.2,port=1"), dir));
    EXPECT_FALSE(isPrivateTestBus(QString(), dir));
    EXPECT_FALSE(isPrivateTestBus(QStringLiteral("unix:path=/tmp/secrets-handover.x/move/bus.sock"), QString()));
}

TEST(SecretsHandover, TrustedExecutables)
{
    // A system executable: root-owned file and directories, not writable by group or others.
    EXPECT_TRUE(trustedExecutable(QStringLiteral("/usr/bin/env")));
    EXPECT_FALSE(trustedExecutable(QStringLiteral("usr/bin/env")));
    EXPECT_FALSE(trustedExecutable(QStringLiteral("/usr/bin/../bin/env")));
    EXPECT_FALSE(trustedExecutable(QStringLiteral("/usr/bin"))); // a directory
    EXPECT_FALSE(trustedExecutable(QStringLiteral("/usr/bin/no-such-program")));
    // The user's own file (as root in a build container, its directory is still /tmp: writable by others).
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    QFile own(dir.path() + QStringLiteral("/ksecretd"));
    ASSERT_TRUE(own.open(QIODevice::WriteOnly));
    own.close();
    EXPECT_FALSE(trustedExecutable(own.fileName()));
}

// A peer as identify() fills it, for this very process (alive) running `exe`.
static Peer peerRunning(const char *exe, const struct stat &file)
{
    Peer peer;
    peer.owner = QStringLiteral(":1.7");
    peer.exe = QString::fromLatin1(exe);
    peer.uid = ::getuid();
    peer.pid = ::getpid();
    peer.pidfd = int(::syscall(SYS_pidfd_open, ::getpid(), 0));
    peer.hasFile = true;
    peer.fileDev = file.st_dev;
    peer.fileIno = file.st_ino;
    peer.fileUid = file.st_uid;
    peer.fileMode = file.st_mode;
    peer.fileLinks = file.st_nlink;
    return peer;
}

TEST(SecretsHandover, PeersAreTheExpectedFileByInode)
{
    struct stat env {};
    ASSERT_EQ(::stat("/usr/bin/env", &env), 0);
    Peer peer = peerRunning("/usr/bin/env", env);
    ASSERT_GE(peer.pidfd, 0) << "pidfd_open";
    EXPECT_TRUE(is(peer, QStringLiteral("/usr/bin/env")));
    EXPECT_FALSE(is(peer, QStringLiteral("/usr/bin/true"))); // another file, whatever the name says
    peer.uid = ::getuid() + 1;
    EXPECT_FALSE(is(peer, QStringLiteral("/usr/bin/env"))); // another user
    close(peer);
}

TEST(SecretsHandover, ALeftoverFromAReplacedBinaryMayOnlyBeAskedToQuit)
{
    // ksecretd started before a KWallet upgrade: /proc/<pid>/exe says "<path> (deleted)", the old file has no link left.
    struct stat old {};
    ASSERT_EQ(::stat("/usr/bin/env", &old), 0);
    old.st_ino += 1;
    old.st_nlink = 0;
    Peer peer = peerRunning("/usr/bin/env (deleted)", old);
    ASSERT_GE(peer.pidfd, 0) << "pidfd_open";
    EXPECT_FALSE(is(peer, QStringLiteral("/usr/bin/env"))); // never a peer for secrets
    EXPECT_TRUE(ranFrom(peer, QStringLiteral("/usr/bin/env")));
    Peer linked = peer;
    linked.fileLinks = 1; // still named somewhere: not a replaced package file
    EXPECT_FALSE(ranFrom(linked, QStringLiteral("/usr/bin/env")));
    Peer users = peer;
    users.fileUid = ::getuid() == 0 ? 1000 : ::getuid(); // the user's own file
    EXPECT_FALSE(ranFrom(users, QStringLiteral("/usr/bin/env")));
    Peer other = peer;
    other.exe = QStringLiteral("/home/u/ksecretd (deleted)");
    EXPECT_FALSE(ranFrom(other, QStringLiteral("/usr/bin/env")));
    close(peer);
}

TEST(SecretsHandover, NoPidfdIsNotAlive)
{
    EXPECT_FALSE(alive(-1));
}
