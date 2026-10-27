// The handover's decisions without a bus (apps/secrets-handover/src/logic.h, peer.h trustedExecutable): which items move,
// when KWallet is not even asked, the marker, and which executables are trusted.
#include "logic.h"
#include "peer.h"

#include <QDir>
#include <QFile>
#include <QTemporaryDir>

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
    EXPECT_EQ(markerPath(QStringLiteral("/home/u/.local/state")), QStringLiteral("/home/u/.local/state/grassfield/secrets-handover"));
    EXPECT_EQ(markerLine(QStringLiteral("moved"), 2, 1), QStringLiteral("moved moved=2 kept=1\n"));
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

TEST(SecretsHandover, NoPidfdIsNotAlive)
{
    EXPECT_FALSE(alive(-1));
}
