// Unit tests for bridges/menu-bridge/src/Ongoing.{h,cpp} (ADR-0052: org.grassfield.Ongoing1's validation, identity, limits,
// lock redaction and menu/1 lines), the two shell -> bridge lines it adds to Protocol, and the apps' shared client
// apps/ongoing.h (its state fits the host's rules). Linked into menu-bridge-unit-tests (main() is in tst_menubridge.cpp).
// The D-Bus path (owning the name, credentials, a sender leaving the bus, ActionInvoked) is NOT covered here: it needs a
// session bus with systemd application scopes.
#include "Ongoing.h"
#include "Protocol.h"
#include "ongoing.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTemporaryDir>

#include <gtest/gtest.h>

#include <cmath>
#include <limits>

using namespace gf::menubridge;
using namespace gf::menubridge::ongoing;

namespace {
    constexpr qint64 kNow = 1'800'000'000'000; // a fixed "now" (Unix ms)
    const QString    kA   = QStringLiteral(":1.10");
    const QString    kB   = QStringLiteral(":1.11");

    Input input(QVariantMap fields) {
        Input in;
        in.entries = static_cast<int>(fields.size());
        in.fields  = std::move(fields);
        return in;
    }

    QVariantMap minimal() {
        return {{QStringLiteral("kind"), QStringLiteral("transfer")}, {QStringLiteral("title"), QStringLiteral("Copying 3 items")}};
    }

    Checked check(QVariantMap fields) {
        return checkState(input(std::move(fields)), kNow);
    }

    Checked withActions(const QList<Action>& actions) {
        Input in      = input(minimal());
        in.hasActions = true;
        in.actions    = actions;
        ++in.entries;
        return checkState(in, kNow);
    }

    State state(const QString& title = QStringLiteral("Copying")) {
        State s;
        s.kind  = Kind::Transfer;
        s.title = title;
        return s;
    }

    // Keys "k000000000000001", "k...2": predictable for the tests (hex digits only).
    std::function<QString()> counterKeys() {
        auto n = std::make_shared<int>(0);
        return [n] { return QStringLiteral("%1").arg(++*n, 16, 16, QLatin1Char('0')); };
    }

    QJsonObject json(const QByteArray& line) {
        EXPECT_TRUE(line.endsWith('\n'));
        return QJsonDocument::fromJson(line.trimmed()).object();
    }

    DesktopIndex index() {
        DesktopIndex i;
        i.add(QStringLiteral("org.grassfield.Store"), QStringLiteral("grassfield-store"));
        i.add(QStringLiteral("org.grassfield.Files"), QStringLiteral("grassfield-files"));
        i.add(QStringLiteral("Alacritty"), QStringLiteral("alacritty"));
        i.add(QStringLiteral("org.example.Two"), QStringLiteral("shared-bin"));
        i.add(QStringLiteral("org.example.Three"), QStringLiteral("shared-bin"));
        i.add(QStringLiteral("org.mozilla.firefox"), QStringLiteral("flatpak"));
        return i;
    }

    QString cgroupOf(const QString& unit) {
        return QStringLiteral("0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-graphical.slice/") + unit + u'\n';
    }
} // namespace

// ---- text and ids -----------------------------------------------------------------------------------------------------

TEST(OngoingText, OnePlainLineWithoutControlOrBidiCharacters) {
    EXPECT_EQ(cleanText(QStringLiteral("  a\tb\nc\u0007d  "), 64), QStringLiteral("a b c d"));
    // The bidirectional controls are built from their code points: never written raw in a source file.
    EXPECT_EQ(cleanText(QStringLiteral("evil") + QChar(0x202E) + QStringLiteral("txt.exe"), 64), QStringLiteral("eviltxt.exe"));
    EXPECT_EQ(cleanText(QStringLiteral("x") + QChar(0x2066) + u'y' + QChar(0x2069) + QChar(0x200F) + u'z' + QChar(0x0085) + u'w', 64), QStringLiteral("xyz w"));
    EXPECT_EQ(cleanText(QStringLiteral("abcdef"), 3), QStringLiteral("abc"));
    // Never half of a surrogate pair.
    const QString emoji = QStringLiteral("ab\U0001F600");
    EXPECT_EQ(cleanText(emoji, 3), QStringLiteral("ab"));
}

TEST(OngoingText, Ids) {
    EXPECT_TRUE(isValidActivityId(QStringLiteral("copy-12_A")));
    EXPECT_FALSE(isValidActivityId(QString()));
    EXPECT_FALSE(isValidActivityId(QStringLiteral("a.b")));
    EXPECT_FALSE(isValidActivityId(QString(65, u'a')));
    EXPECT_TRUE(isValidActionId(QStringLiteral("stop")));
    EXPECT_TRUE(isValidActionId(QStringLiteral("open-2")));
    EXPECT_FALSE(isValidActionId(QStringLiteral("Stop")));
    EXPECT_FALSE(isValidActionId(QStringLiteral("2stop")));
    EXPECT_FALSE(isValidActionId(QString(33, u'a')));
    EXPECT_TRUE(isValidAppId(QStringLiteral("org.grassfield.Store")));
    EXPECT_FALSE(isValidAppId(QStringLiteral(".hidden")));
    EXPECT_FALSE(isValidAppId(QStringLiteral("a/b")));
    EXPECT_TRUE(isValidKey(QStringLiteral("0123456789abcdef")));
    EXPECT_FALSE(isValidKey(QStringLiteral("0123456789ABCDEF")));
}

// ---- state validation ---------------------------------------------------------------------------------------------------

TEST(OngoingState, MinimalStateIsIndeterminateWithoutActions) {
    const Checked c = check(minimal());
    ASSERT_TRUE(c.state) << c.error.toStdString();
    EXPECT_EQ(c.state->kind, Kind::Transfer);
    EXPECT_EQ(c.state->title, QStringLiteral("Copying 3 items"));
    EXPECT_FALSE(c.state->progress);
    EXPECT_TRUE(c.state->actions.isEmpty());
}

TEST(OngoingState, KindAndTitleAreRequiredAndChecked) {
    QVariantMap m = minimal();
    m.remove(QStringLiteral("kind"));
    EXPECT_FALSE(check(m).state);
    m = minimal();
    m.insert(QStringLiteral("kind"), QStringLiteral("island"));
    EXPECT_FALSE(check(m).state);
    m.insert(QStringLiteral("kind"), 3);
    EXPECT_FALSE(check(m).state);
    for (const char* k : {"timer", "transfer", "recording", "install", "call", "progress"})
        EXPECT_EQ(kindName(*kindFromName(QLatin1String(k))), QLatin1String(k));
    m = minimal();
    m.remove(QStringLiteral("title"));
    EXPECT_FALSE(check(m).state);
    m.insert(QStringLiteral("title"), QStringLiteral(" \n\t "));
    EXPECT_FALSE(check(m).state) << "empty once cleaned";
    m.insert(QStringLiteral("title"), QString(65, u'x'));
    EXPECT_FALSE(check(m).state);
    m.insert(QStringLiteral("title"), QString(64, u'x'));
    EXPECT_TRUE(check(m).state);
    m.insert(QStringLiteral("title"), QString(5000, u'x'));
    EXPECT_FALSE(check(m).state);
    m.insert(QStringLiteral("title"), 42);
    EXPECT_FALSE(check(m).state);
}

TEST(OngoingState, UnknownFieldsAndTooManyFieldsAreRefused) {
    QVariantMap m = minimal();
    m.insert(QStringLiteral("markup"), QStringLiteral("<b>x</b>"));
    EXPECT_FALSE(check(m).state);
    m = minimal();
    m.insert(QStringLiteral("icon"), QStringLiteral("/tmp/x.png"));
    EXPECT_FALSE(check(m).state) << "apps supply no image";
    Input in   = input(minimal());
    in.entries = kMaxFields + 1;
    EXPECT_FALSE(checkState(in, kNow).state);
}

TEST(OngoingState, SubtitleIsCleanedAndBounded) {
    QVariantMap m = minimal();
    m.insert(QStringLiteral("subtitle"), QStringLiteral("41.9 MB of 111.6 MB\n– About 10 seconds"));
    ASSERT_TRUE(check(m).state);
    EXPECT_EQ(check(m).state->subtitle, QStringLiteral("41.9 MB of 111.6 MB – About 10 seconds"));
    m.insert(QStringLiteral("subtitle"), QString());
    EXPECT_TRUE(check(m).state) << "an empty subtitle is allowed";
    m.insert(QStringLiteral("subtitle"), QString(129, u'y'));
    EXPECT_FALSE(check(m).state);
}

TEST(OngoingState, Progress) {
    QVariantMap m = minimal();
    m.insert(QStringLiteral("progress"), 0.25);
    EXPECT_DOUBLE_EQ(*check(m).state->progress, 0.25);
    m.insert(QStringLiteral("progress"), 1);
    EXPECT_DOUBLE_EQ(*check(m).state->progress, 1.0);
    m.insert(QStringLiteral("progress"), -1.0);
    ASSERT_TRUE(check(m).state);
    EXPECT_FALSE(check(m).state->progress) << "negative: indeterminate";
    m.insert(QStringLiteral("progress"), 1.01);
    EXPECT_FALSE(check(m).state);
    m.insert(QStringLiteral("progress"), std::nan(""));
    EXPECT_FALSE(check(m).state);
    m.insert(QStringLiteral("progress"), std::numeric_limits<double>::infinity());
    EXPECT_FALSE(check(m).state);
    m.insert(QStringLiteral("progress"), QStringLiteral("50%"));
    EXPECT_FALSE(check(m).state);
}

TEST(OngoingState, TimesAreBounded) {
    QVariantMap m = minimal();
    m.insert(QStringLiteral("kind"), QStringLiteral("timer"));
    EXPECT_FALSE(check(m).state) << "a timer needs started or ends";
    m.insert(QStringLiteral("ends"), kNow + 5 * 60 * 1000);
    EXPECT_TRUE(check(m).state);
    m.insert(QStringLiteral("ends"), kNow + kEndsAheadMs + 1);
    EXPECT_FALSE(check(m).state);
    m.insert(QStringLiteral("ends"), kNow - 2 * 60 * 1000);
    EXPECT_FALSE(check(m).state);
    m.insert(QStringLiteral("ends"), 1.5);
    EXPECT_FALSE(check(m).state) << "integers only";
    m.remove(QStringLiteral("ends"));
    m.insert(QStringLiteral("started"), kNow - 60 * 60 * 1000);
    EXPECT_TRUE(check(m).state);
    m.insert(QStringLiteral("started"), kNow + 2 * 60 * 1000);
    EXPECT_FALSE(check(m).state);
    m.insert(QStringLiteral("started"), kNow - kStartedPastMs - 1);
    EXPECT_FALSE(check(m).state);
    m.insert(QStringLiteral("started"), static_cast<qulonglong>(kNow));
    EXPECT_TRUE(check(m).state) << "t is taken as well as x";
    m.insert(QStringLiteral("ends"), kNow + 1000);
    EXPECT_FALSE(check(m).state) << "started and ends exclude each other";
}

TEST(OngoingState, AtMostThreeWellFormedActions) {
    const Checked ok = withActions({{QStringLiteral("stop"), QStringLiteral(" Stop ")}, {QStringLiteral("show"), QStringLiteral("Show")}});
    ASSERT_TRUE(ok.state) << ok.error.toStdString();
    EXPECT_EQ(ok.state->actions.size(), 2);
    EXPECT_EQ(ok.state->actions.first().label, QStringLiteral("Stop"));
    EXPECT_FALSE(withActions({{QStringLiteral("a"), QStringLiteral("A")}, {QStringLiteral("b"), QStringLiteral("B")}, {QStringLiteral("c"), QStringLiteral("C")},
                              {QStringLiteral("d"), QStringLiteral("D")}})
                     .state);
    EXPECT_FALSE(withActions({{QStringLiteral("Stop"), QStringLiteral("Stop")}}).state);
    EXPECT_FALSE(withActions({{QStringLiteral("stop"), QStringLiteral("Stop")}, {QStringLiteral("stop"), QStringLiteral("Again")}}).state);
    EXPECT_FALSE(withActions({{QStringLiteral("stop"), QString()}}).state);
    EXPECT_FALSE(withActions({{QStringLiteral("stop"), QString(25, u'x')}}).state);
    Input in         = input(minimal());
    in.hasActions    = true;
    in.actionsTypeOk = false;
    EXPECT_FALSE(checkState(in, kNow).state) << "actions of another type than a(ss)";
}

TEST(OngoingState, ConvertedMapInput) {
    QVariantMap m = minimal();
    m.insert(QStringLiteral("actions"), QVariantList{QVariantList{QStringLiteral("stop"), QStringLiteral("Stop")}});
    const auto in = inputFromDBus(m);
    ASSERT_TRUE(in);
    EXPECT_TRUE(in->hasActions);
    EXPECT_TRUE(in->actionsTypeOk);
    ASSERT_EQ(in->actions.size(), 1);
    EXPECT_TRUE(checkState(*in, kNow).state);
    m.insert(QStringLiteral("actions"), QStringLiteral("stop"));
    EXPECT_FALSE(checkState(*inputFromDBus(m), kNow).state);
    EXPECT_FALSE(inputFromDBus(QVariant(QStringLiteral("not a map"))));
}

// ---- identity -----------------------------------------------------------------------------------------------------------

TEST(OngoingIdentity, AppUnitNames) {
    // uwsm (ADR-0011: the Dock starts `uwsm-app -- <Exec argv>`): the binary's name, '-' escaped by systemd.
    EXPECT_EQ(unitAppId(cgroupOf(QStringLiteral("app-Hyprland-grassfield\\x2dstore-2616d5ca.scope"))), QStringLiteral("grassfield-store"));
    EXPECT_EQ(unitAppId(cgroupOf(QStringLiteral("app-Hyprland-org.grassfield.Files-2616d5ca.scope"))), QStringLiteral("org.grassfield.Files"));
    EXPECT_EQ(unitAppId(cgroupOf(QStringLiteral("app-gnome-org.gnome.Nautilus-4242.scope"))), QStringLiteral("org.gnome.Nautilus"));
    EXPECT_EQ(unitAppId(cgroupOf(QStringLiteral("app-flatpak-org.mozilla.firefox-12345.scope"))), QStringLiteral("org.mozilla.firefox"));
    EXPECT_EQ(unitAppId(cgroupOf(QStringLiteral("app-alacritty-0123456789abcdef0123456789abcdef.scope"))), QStringLiteral("alacritty"));
    EXPECT_EQ(unitAppId(cgroupOf(QStringLiteral("app-Hyprland-foot@0123abcd.service"))), QStringLiteral("foot"));
    // A process in a sub-cgroup of its scope.
    EXPECT_EQ(unitAppId(cgroupOf(QStringLiteral("app-Hyprland-alacritty-2616d5ca.scope/tab1"))), QStringLiteral("alacritty"));
    // Not the contract: no instance, ambiguous, not an app unit, a slice only, nothing.
    EXPECT_EQ(unitAppId(cgroupOf(QStringLiteral("app-Hyprland-foo.scope"))), QString());
    EXPECT_EQ(unitAppId(cgroupOf(QStringLiteral("app-a-b-c-2616d5ca.scope"))), QString());
    EXPECT_EQ(unitAppId(cgroupOf(QStringLiteral("grassfield-shell.service"))), QString());
    EXPECT_EQ(unitAppId(QStringLiteral("0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-graphical.slice\n")), QString());
    EXPECT_EQ(unitAppId(QStringLiteral("0::/\n")), QString());
    EXPECT_EQ(unitAppId(QString()), QString());
    // An escape that decodes to a character no desktop id has.
    EXPECT_EQ(unitAppId(cgroupOf(QStringLiteral("app-Hyprland-a\\x2fb-2616d5ca.scope"))), QString());
    // cgroup v1 only: the last hierarchy line.
    EXPECT_EQ(unitAppId(QStringLiteral("1:name=systemd:/user.slice/user@1000.service/app.slice/app-Hyprland-alacritty-2616d5ca.scope\n")), QStringLiteral("alacritty"));
}

TEST(OngoingIdentity, FlatpakInfo) {
    EXPECT_EQ(flatpakAppId("[Application]\nname=org.mozilla.firefox\nruntime=runtime/org.freedesktop.Platform\n"), QStringLiteral("org.mozilla.firefox"));
    EXPECT_EQ(flatpakAppId("[Instance]\nname=org.mozilla.firefox\n"), QString()) << "another group";
    EXPECT_EQ(flatpakAppId("[Application]\nname=firefox\n"), QString()) << "not a reverse-DNS id";
    EXPECT_EQ(flatpakAppId("[Application]\nname=org.x/../y.z\n"), QString());
    EXPECT_EQ(flatpakAppId(QByteArray()), QString());
}

TEST(OngoingIdentity, DesktopEntryExecBinary) {
    EXPECT_EQ(DesktopIndex::execBinaryOf("[Desktop Entry]\nName=Files\nExec=grassfield-files %U\n"), QStringLiteral("grassfield-files"));
    EXPECT_EQ(DesktopIndex::execBinaryOf("[Desktop Entry]\nExec=/usr/bin/alacritty\n"), QStringLiteral("alacritty"));
    EXPECT_EQ(DesktopIndex::execBinaryOf("[Desktop Entry]\nExec=env GDK_BACKEND=wayland LANG=C /opt/app/bin/app --x\n"), QStringLiteral("app"));
    EXPECT_EQ(DesktopIndex::execBinaryOf("[Desktop Entry]\nExec=\"/opt/My App/run\" %f\n"), QStringLiteral("run"));
    EXPECT_EQ(DesktopIndex::execBinaryOf("[Desktop Entry]\nExec=env -u X foo\n"), QString()) << "env options: unknown";
    EXPECT_EQ(DesktopIndex::execBinaryOf("[Desktop Action new]\nExec=other\n[Desktop Entry]\nExec=main\n"), QStringLiteral("main"));
    bool hidden = false;
    EXPECT_EQ(DesktopIndex::execBinaryOf("[Desktop Entry]\nHidden=true\nExec=x\n", &hidden), QStringLiteral("x"));
    EXPECT_TRUE(hidden);
}

TEST(OngoingIdentity, DesktopIndexScanFollowsXdgPrecedence) {
    QTemporaryDir home;
    QTemporaryDir system;
    ASSERT_TRUE(home.isValid() && system.isValid());
    auto write = [](const QString& path, const QByteArray& text) {
        QDir().mkpath(QFileInfo(path).path());
        QFile f(path);
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
        f.write(text);
    };
    write(system.path() + QStringLiteral("/org.example.A.desktop"), "[Desktop Entry]\nExec=a-bin\n");
    write(system.path() + QStringLiteral("/org.example.B.desktop"), "[Desktop Entry]\nExec=b-bin\n");
    write(system.path() + QStringLiteral("/kde/konsole.desktop"), "[Desktop Entry]\nExec=konsole\n");
    write(home.path() + QStringLiteral("/org.example.A.desktop"), "[Desktop Entry]\nExec=a-user\n");
    write(home.path() + QStringLiteral("/org.example.B.desktop"), "[Desktop Entry]\nHidden=true\n");
    DesktopIndex i;
    i.scan({home.path(), system.path()});
    EXPECT_TRUE(i.has(QStringLiteral("org.example.A")));
    EXPECT_EQ(i.withExec(QStringLiteral("a-user")), QStringList{QStringLiteral("org.example.A")}) << "the user's entry wins";
    EXPECT_TRUE(i.withExec(QStringLiteral("a-bin")).isEmpty());
    EXPECT_FALSE(i.has(QStringLiteral("org.example.B"))) << "hidden by the user's entry";
    EXPECT_TRUE(i.has(QStringLiteral("kde-konsole")));
}

TEST(OngoingIdentity, ResolveFromTheKernelsFacts) {
    const DesktopIndex idx = index();
    ProcFacts          f;
    f.uid    = 1000;
    f.cgroup = cgroupOf(QStringLiteral("app-Hyprland-grassfield\\x2dstore-2616d5ca.scope"));
    EXPECT_EQ(resolveApp(f, 1000, idx).appId, QStringLiteral("org.grassfield.Store")) << "by the entry's Exec binary";
    EXPECT_FALSE(resolveApp(f, 1001, idx).error.isEmpty()) << "another user";
    f.cgroup = cgroupOf(QStringLiteral("app-Hyprland-org.grassfield.Files-2616d5ca.scope"));
    EXPECT_EQ(resolveApp(f, 1000, idx).appId, QStringLiteral("org.grassfield.Files")) << "by the desktop id";
    f.cgroup = cgroupOf(QStringLiteral("app-Hyprland-shared\\x2dbin-2616d5ca.scope"));
    EXPECT_TRUE(resolveApp(f, 1000, idx).appId.isEmpty()) << "two entries start the binary";
    f.cgroup = cgroupOf(QStringLiteral("app-Hyprland-unknown-2616d5ca.scope"));
    EXPECT_TRUE(resolveApp(f, 1000, idx).appId.isEmpty()) << "no entry";
    f.cgroup = QStringLiteral("0::/user.slice/user-1000.slice/session-2.scope\n");
    EXPECT_TRUE(resolveApp(f, 1000, idx).appId.isEmpty()) << "outside an application scope";
    // Flatpak: /.flatpak-info decides, never the cgroup; a malformed file is not a fallback to the scope.
    f.cgroup      = cgroupOf(QStringLiteral("app-Hyprland-org.grassfield.Files-2616d5ca.scope"));
    f.flatpak     = true;
    f.flatpakInfo = "[Application]\nname=org.mozilla.firefox\n";
    EXPECT_EQ(resolveApp(f, 1000, idx).appId, QStringLiteral("org.mozilla.firefox"));
    f.flatpakInfo = "garbage";
    EXPECT_TRUE(resolveApp(f, 1000, idx).appId.isEmpty());
    f.flatpakInfo = "[Application]\nname=org.not.Installed\n";
    EXPECT_TRUE(resolveApp(f, 1000, idx).appId.isEmpty());
}

// ---- the book -----------------------------------------------------------------------------------------------------------

TEST(OngoingBook, CreateUpdateAndOwnership) {
    Book               book(counterKeys());
    const Book::Result r = book.publish(kA, QStringLiteral("org.grassfield.Files"), QStringLiteral("copy-1"), state());
    ASSERT_TRUE(r.ok);
    EXPECT_TRUE(r.changed);
    EXPECT_TRUE(isValidKey(r.key));
    const Book::Result same = book.publish(kA, QStringLiteral("org.grassfield.Files"), QStringLiteral("copy-1"), state());
    EXPECT_TRUE(same.ok);
    EXPECT_FALSE(same.changed) << "nothing new for the shell";
    EXPECT_EQ(same.key, r.key);
    const Book::Result moved = book.publish(kA, QStringLiteral("org.grassfield.Files"), QStringLiteral("copy-1"), state(QStringLiteral("Moving")));
    EXPECT_TRUE(moved.changed);
    EXPECT_EQ(book.byKey(r.key)->state.title, QStringLiteral("Moving"));
    // A second connection of the same app cannot take or end it; another app's same id is another activity.
    EXPECT_EQ(book.publish(kB, QStringLiteral("org.grassfield.Files"), QStringLiteral("copy-1"), state()).error, QStringLiteral("org.freedesktop.DBus.Error.AccessDenied"));
    EXPECT_FALSE(book.end(kB, QStringLiteral("org.grassfield.Files"), QStringLiteral("copy-1")));
    EXPECT_TRUE(book.publish(kB, QStringLiteral("org.grassfield.Store"), QStringLiteral("copy-1"), state()).ok);
    EXPECT_EQ(book.count(), 2);
    EXPECT_EQ(book.end(kA, QStringLiteral("org.grassfield.Files"), QStringLiteral("copy-1")), r.key);
    EXPECT_EQ(book.count(), 1);
}

TEST(OngoingBook, LimitsPerAppAndInAll) {
    Book book(counterKeys());
    for (int i = 0; i < kMaxPerApp; ++i)
        EXPECT_TRUE(book.publish(kA, QStringLiteral("app.one.A"), QStringLiteral("a%1").arg(i), state()).ok);
    // The cap is per application, whatever the connection.
    EXPECT_EQ(book.publish(kB, QStringLiteral("app.one.A"), QStringLiteral("more"), state()).error, QStringLiteral("org.freedesktop.DBus.Error.LimitsExceeded"));
    int app = 0;
    while (book.count() < kMaxTotal) {
        const QString appId = QStringLiteral("app.n.A%1").arg(app++);
        for (int i = 0; i < kMaxPerApp && book.count() < kMaxTotal; ++i)
            ASSERT_TRUE(book.publish(kB, appId, QStringLiteral("x%1").arg(i), state()).ok);
    }
    EXPECT_EQ(book.publish(kB, QStringLiteral("app.last.Z"), QStringLiteral("x"), state()).error, QStringLiteral("org.freedesktop.DBus.Error.LimitsExceeded"));
}

TEST(OngoingBook, SenderGoneAndExpiry) {
    Book  book(counterKeys());
    State t = state();
    t.kind  = Kind::Timer;
    t.ends  = kNow + 1000;
    const QString timer = book.publish(kA, QStringLiteral("app.one.A"), QStringLiteral("t"), t).key;
    const QString copy  = book.publish(kA, QStringLiteral("app.one.A"), QStringLiteral("c"), state()).key;
    const QString other = book.publish(kB, QStringLiteral("app.two.B"), QStringLiteral("c"), state()).key;
    EXPECT_TRUE(book.hasEnds());
    EXPECT_TRUE(book.expire(kNow + 1000 + kExpireAfterEndsMs).isEmpty()) << "not yet";
    EXPECT_EQ(book.expire(kNow + 1001 + kExpireAfterEndsMs), QStringList{timer});
    EXPECT_FALSE(book.hasEnds());
    EXPECT_EQ(book.senderGone(kA), QStringList{copy});
    EXPECT_EQ(book.all().size(), 1);
    EXPECT_EQ(book.all().first().key, other);
}

TEST(OngoingBook, RateLimitPerConnection) {
    RateLimiter rate;
    for (int i = 0; i < kRateCalls; ++i)
        EXPECT_TRUE(rate.allow(kA, 1000 + i));
    EXPECT_FALSE(rate.allow(kA, 1000 + kRateCalls));
    EXPECT_TRUE(rate.allow(kB, 1000 + kRateCalls)) << "another connection";
    EXPECT_TRUE(rate.allow(kA, 1000 + kRateWindowMs)) << "the window slid";
    rate.forget(kA);
    for (int i = 0; i < kRateCalls - 1; ++i)
        EXPECT_TRUE(rate.allow(kA, 5000));
}

// ---- menu/1 -------------------------------------------------------------------------------------------------------------

TEST(OngoingLines, FullAndRedacted) {
    Activity a;
    a.key            = QStringLiteral("00000000000000aa");
    a.appId          = QStringLiteral("org.grassfield.Files");
    a.localId        = QStringLiteral("copy-1");
    a.state          = state(QStringLiteral("Copying “a.txt” to “Docs”"));
    a.state.subtitle = QStringLiteral("1 MB of 2 MB");
    a.state.progress = 0.5;
    a.state.actions  = {{QStringLiteral("stop"), QStringLiteral("Stop")}};
    const QJsonObject full = json(ongoingMessage(a, false));
    EXPECT_EQ(full.value(QStringLiteral("type")).toString(), QStringLiteral("ongoing"));
    EXPECT_EQ(full.value(QStringLiteral("id")).toString(), a.key);
    EXPECT_EQ(full.value(QStringLiteral("app")).toString(), a.appId);
    EXPECT_EQ(full.value(QStringLiteral("kind")).toString(), QStringLiteral("transfer"));
    EXPECT_EQ(full.value(QStringLiteral("title")).toString(), a.state.title);
    EXPECT_DOUBLE_EQ(full.value(QStringLiteral("progress")).toDouble(), 0.5);
    EXPECT_TRUE(full.value(QStringLiteral("started")).isNull());
    EXPECT_EQ(full.value(QStringLiteral("actions")).toArray().size(), 1);
    EXPECT_FALSE(full.value(QStringLiteral("redacted")).toBool());
    EXPECT_FALSE(full.contains(QStringLiteral("localId"))) << "the app's own id never reaches the shell";

    const QJsonObject red = json(ongoingMessage(a, true));
    EXPECT_TRUE(red.value(QStringLiteral("redacted")).toBool());
    EXPECT_EQ(red.value(QStringLiteral("app")).toString(), QString());
    EXPECT_EQ(red.value(QStringLiteral("title")).toString(), QString());
    EXPECT_EQ(red.value(QStringLiteral("subtitle")).toString(), QString());
    EXPECT_TRUE(red.value(QStringLiteral("actions")).toArray().isEmpty());
    EXPECT_EQ(red.value(QStringLiteral("kind")).toString(), QStringLiteral("transfer"));
    EXPECT_DOUBLE_EQ(red.value(QStringLiteral("progress")).toDouble(), 0.5);

    const QJsonObject end = json(ongoingEndMessage(a.key));
    EXPECT_EQ(end.value(QStringLiteral("type")).toString(), QStringLiteral("ongoing-end"));
    EXPECT_EQ(end.value(QStringLiteral("id")).toString(), a.key);
}

TEST(OngoingLines, ShellLockAndActionLines) {
    QString    error;
    const auto lock = parseShellMessage(R"({"type":"lock","locked":false})", &error);
    ASSERT_TRUE(lock);
    EXPECT_EQ(lock->type, ShellMessage::Type::Lock);
    EXPECT_FALSE(lock->locked);
    EXPECT_FALSE(parseShellMessage(R"({"type":"lock","locked":"no"})", &error));
    EXPECT_EQ(error, QStringLiteral("field:locked"));
    const auto act = parseShellMessage(R"({"type":"ongoing-action","id":"0123456789abcdef","action":"stop"})", &error);
    ASSERT_TRUE(act);
    EXPECT_EQ(act->type, ShellMessage::Type::OngoingAction);
    EXPECT_EQ(act->ongoing, QStringLiteral("0123456789abcdef"));
    EXPECT_EQ(act->action, QStringLiteral("stop"));
    EXPECT_FALSE(parseShellMessage(R"({"type":"ongoing-action","id":"0123","action":"stop"})", &error));
    EXPECT_FALSE(parseShellMessage(R"({"type":"ongoing-action","id":"0123456789abcdef","action":"Stop!"})", &error));
    EXPECT_FALSE(parseShellMessage(R"({"type":"ongoing-action","id":"0123456789abcdef"})", &error));
}

TEST(OngoingLines, CodeMatchesTheVersionedXml) {
    QFile file(QStringLiteral(GRASSFIELD_ONGOING_DBUS_XML));
    ASSERT_TRUE(file.open(QIODevice::ReadOnly));
    const QString xml = QString::fromUtf8(file.readAll());
    EXPECT_TRUE(xml.contains(interfaceXml())) << "update Ongoing.cpp and dbus/org.grassfield.Ongoing1.xml together";
}

// ---- the host without the bus (OngoingObject's decisions) ---------------------------------------------------------------

namespace {
    struct Sink {
        QList<QJsonObject> lines;
        Host::Send         send() {
            return [this](const QByteArray& l) { lines.append(json(l)); };
        }
    };

    Input withStop() {
        Input in      = input(minimal());
        in.hasActions = true;
        in.actions    = {{QStringLiteral("stop"), QStringLiteral("Stop")}};
        ++in.entries;
        return in;
    }

    ProcReads goodReads() {
        ProcReads r;
        r.uid    = 1000;
        r.pid    = 4242;
        r.cgroup = cgroupOf(QStringLiteral("app-Hyprland-org.grassfield.Files-2616d5ca.scope"));
        return r;
    }
} // namespace

TEST(OngoingHost, RedactedUntilTheShellReportsUnlocked) {
    Sink s;
    Host host(s.send(), counterKeys());
    EXPECT_TRUE(host.locked()) << "fail closed: no lock report yet";
    ASSERT_TRUE(host.publish(kA, QStringLiteral("org.grassfield.Files"), QStringLiteral("copy-1"), withStop(), kNow).ok);
    ASSERT_EQ(s.lines.size(), 1);
    EXPECT_TRUE(s.lines.last().value(QStringLiteral("redacted")).toBool());
    EXPECT_EQ(s.lines.last().value(QStringLiteral("title")).toString(), QString());
    EXPECT_TRUE(s.lines.last().value(QStringLiteral("actions")).toArray().isEmpty());

    host.setLocked(false); // every activity again, in full
    ASSERT_EQ(s.lines.size(), 2);
    EXPECT_FALSE(s.lines.last().value(QStringLiteral("redacted")).toBool());
    EXPECT_EQ(s.lines.last().value(QStringLiteral("title")).toString(), QStringLiteral("Copying 3 items"));

    // A new shell connects: locked again until it reports, for new lines and for the replay.
    host.resetLock();
    EXPECT_TRUE(host.locked());
    EXPECT_TRUE(json(host.snapshot().first()).value(QStringLiteral("redacted")).toBool());
    Input changed = withStop();
    changed.fields.insert(QStringLiteral("title"), QStringLiteral("Moving"));
    ASSERT_TRUE(host.publish(kA, QStringLiteral("org.grassfield.Files"), QStringLiteral("copy-1"), changed, kNow).ok);
    EXPECT_TRUE(s.lines.last().value(QStringLiteral("redacted")).toBool());
    EXPECT_EQ(s.lines.last().value(QStringLiteral("title")).toString(), QString());

    host.setLocked(false);
    host.setLocked(true); // locking redacts what was sent in full
    EXPECT_TRUE(s.lines.last().value(QStringLiteral("redacted")).toBool());
}

TEST(OngoingHost, ButtonsOnlyWhenUnlockedAndDeclared) {
    Sink s;
    Host host(s.send(), counterKeys());
    ASSERT_TRUE(host.publish(kA, QStringLiteral("org.grassfield.Files"), QStringLiteral("copy-1"), withStop(), kNow).ok);
    const QString key = host.book().all().first().key;
    EXPECT_EQ(host.invoke(key, QStringLiteral("stop")).error, QStringLiteral("locked")) << "before any lock report";
    host.setLocked(false);
    EXPECT_EQ(host.invoke(QStringLiteral("ffffffffffffffff"), QStringLiteral("stop")).error, QStringLiteral("unknown-activity"));
    EXPECT_EQ(host.invoke(key, QStringLiteral("delete-everything")).error, QStringLiteral("unknown-action")) << "only what the app declared";
    const Host::Invocation ok = host.invoke(key, QStringLiteral("stop"));
    EXPECT_EQ(ok.error, QString());
    EXPECT_EQ(ok.owner, kA) << "ActionInvoked goes to the owner only";
    EXPECT_EQ(ok.localId, QStringLiteral("copy-1"));
    host.setLocked(true);
    EXPECT_EQ(host.invoke(key, QStringLiteral("stop")).error, QStringLiteral("locked"));
}

TEST(OngoingHost, EndsAndInvalidCalls) {
    Sink s;
    Host host(s.send(), counterKeys());
    EXPECT_EQ(host.publish(kA, QStringLiteral("app.one.A"), QStringLiteral("bad id"), withStop(), kNow).error, QStringLiteral("org.freedesktop.DBus.Error.InvalidArgs"));
    EXPECT_TRUE(s.lines.isEmpty());
    ASSERT_TRUE(host.publish(kA, QStringLiteral("app.one.A"), QStringLiteral("x"), withStop(), kNow).ok);
    EXPECT_TRUE(host.holds(kA));
    EXPECT_FALSE(host.holds(kB));
    host.end(kB, QStringLiteral("app.one.A"), QStringLiteral("x")); // not its owner: nothing
    EXPECT_EQ(s.lines.size(), 1);
    host.senderGone(kA);
    EXPECT_EQ(s.lines.last().value(QStringLiteral("type")).toString(), QStringLiteral("ongoing-end"));
    EXPECT_FALSE(host.holds(kA));
}

TEST(OngoingIdentity, CallerReadsFailClosed) {
    const DesktopIndex idx = index();
    EXPECT_EQ(judgeCaller(goodReads(), 1000, idx).appId, QStringLiteral("org.grassfield.Files"));
    ProcReads r = goodReads();
    r.rootUnreadable = true;
    EXPECT_TRUE(judgeCaller(r, 1000, idx).appId.isEmpty()) << "an unreadable root could hide a Flatpak";
    r = goodReads();
    r.pidfdPid = 4242;
    EXPECT_EQ(judgeCaller(r, 1000, idx).appId, QStringLiteral("org.grassfield.Files")) << "the pidfd still pins the process";
    r.pidfdPid = -1;
    EXPECT_TRUE(judgeCaller(r, 1000, idx).appId.isEmpty()) << "the process exited while it was read";
    r.pidfdPid = 4343;
    EXPECT_TRUE(judgeCaller(r, 1000, idx).appId.isEmpty());
    r.pidfdPid = 0;
    EXPECT_TRUE(judgeCaller(r, 1000, idx).appId.isEmpty()) << "an unreadable fdinfo";
    r = goodReads();
    r.cgroup.clear();
    EXPECT_TRUE(judgeCaller(r, 1000, idx).appId.isEmpty());
    EXPECT_TRUE(judgeCaller(goodReads(), 1001, idx).appId.isEmpty());
}

namespace {
    const QString kPublish = QStringLiteral("Publish");
    const QString kEnd     = QStringLiteral("End");
} // namespace

TEST(OngoingAdmission, RefusalsAreRememberedThenForgotten) {
    Admission a;
    EXPECT_EQ(a.admit(kA, kPublish, 0, {}, {}).outcome, Admission::Outcome::Admit);
    a.refused(kA, QStringLiteral("not in an application scope"), 100);
    const Admission::Result r = a.admit(kA, kPublish, 200, {}, {});
    EXPECT_EQ(r.outcome, Admission::Outcome::Refused) << "no new credential look-up";
    EXPECT_EQ(r.message, QStringLiteral("not in an application scope"));
    EXPECT_EQ(a.admit(kA, kEnd, 200, {}, {}).outcome, Admission::Outcome::Refused);
    EXPECT_EQ(a.admit(kA, kPublish, 100 + kRefusalCacheMs, {}, {}).outcome, Admission::Outcome::Admit) << "asked again later";
    EXPECT_EQ(a.refusals(), 0);
    for (int i = 0; i < kMaxRefusals + 10; ++i)
        a.refused(QStringLiteral(":9.%1").arg(i), QStringLiteral("x"), 0);
    EXPECT_EQ(a.refusals(), kMaxRefusals) << "bounded";
}

TEST(OngoingAdmission, RateLimitSparesEndAndIsForgottenOnRefusal) {
    Admission a;
    const QHash<QString, bool> self{{kA, true}};
    for (int i = 0; i < kRateCalls; ++i)
        EXPECT_EQ(a.admit(kA, kPublish, 1000, self, {}).outcome, Admission::Outcome::Admit);
    EXPECT_EQ(a.admit(kA, kPublish, 1000, self, {}).outcome, Admission::Outcome::RateLimited) << "Publish stays rate-limited";
    EXPECT_EQ(a.admit(kA, kEnd, 1000, self, {}).outcome, Admission::Outcome::Admit) << "an End is never lost to the rate limit";
    EXPECT_EQ(a.admit(kA, kPublish, 1000, self, {}).outcome, Admission::Outcome::RateLimited) << "an End does not open the door to a Publish";
    EXPECT_EQ(a.rateEntries(), 1);
    a.refused(kA, QStringLiteral("x"), 1000);
    EXPECT_EQ(a.rateEntries(), 0) << "a refused connection's calls are forgotten";
    EXPECT_EQ(a.admit(kA, kPublish, 1000 + kRefusalCacheMs, {}, {}).outcome, Admission::Outcome::Admit);
    a.forget(kA);
    EXPECT_EQ(a.rateEntries(), 0);
}

TEST(OngoingAdmission, IdleConnectionsGiveTheirPlace) {
    const QString newcomer = QStringLiteral(":3.1");
    const QString idleOne  = QStringLiteral(":2.7");
    const QString idleTwo  = QStringLiteral(":2.9");
    const QString looking  = QStringLiteral(":2.11"); // its identity is still being looked up
    // Every tracked connection verified; all but two hold an activity; `looking` holds none but is not verified yet.
    QHash<QString, bool> tracked;
    for (int i = 0; i < kMaxSenders; ++i)
        tracked.insert(QStringLiteral(":2.%1").arg(i), true);
    tracked.insert(looking, false);
    auto holdsAllBut = [](QStringList without) { return [without](const QString& s) { return !without.contains(s); }; };

    {
        Admission a;
        // Every connection holds an activity, or is not verified yet: none is idle, the newcomer waits, nothing is kept.
        const Admission::Result r = a.admit(newcomer, kPublish, 0, tracked, holdsAllBut({looking}));
        EXPECT_EQ(r.outcome, Admission::Outcome::TooManyConnections) << "a connection being looked up is never evicted";
        EXPECT_TRUE(r.evicted.isEmpty());
        EXPECT_EQ(a.rateEntries(), 0) << "the cap is checked before the rate limit: nothing grows per refused connection";
        // A connection already tracked is never refused by the cap.
        EXPECT_EQ(a.admit(QStringLiteral(":2.0"), kPublish, 0, tracked, holdsAllBut({looking})).outcome, Admission::Outcome::Admit);
    }
    {
        Admission a;
        // Every connection holds an activity: none is idle, whatever its stage.
        const Admission::Result r = a.admit(newcomer, kPublish, 0, tracked, [](const QString&) { return true; });
        EXPECT_EQ(r.outcome, Admission::Outcome::TooManyConnections) << "a connection holding an activity is never evicted";
    }
    {
        Admission a;
        // Verified and holding nothing: idle, evicted for the newcomer; the one being looked up stays.
        const Admission::Result r = a.admit(newcomer, kPublish, 0, tracked, holdsAllBut({idleOne, idleTwo, looking}));
        EXPECT_EQ(r.outcome, Admission::Outcome::Admit);
        EXPECT_EQ(r.evicted, (QStringList{idleOne, idleTwo}));
    }
}

// ---- the apps' client (apps/ongoing.h) ----------------------------------------------------------------------------------

TEST(OngoingClient, FitsTheHostsLimits) {
    namespace client = grassfield::apps::ongoing;
    EXPECT_EQ(client::fit(QStringLiteral("  a \n b "), 10), QStringLiteral("a b"));
    const QString fitted = client::fit(QString(100, u'x'), 64);
    EXPECT_EQ(fitted.size(), 64);
    EXPECT_TRUE(fitted.endsWith(QChar(0x2026)));

    grassfield::apps::OngoingActivity a;
    a.kind     = QStringLiteral("transfer");
    a.title    = QStringLiteral("Copying “") + QString(80, u'n') + QStringLiteral("” to “Docs”");
    a.subtitle = QString(200, u's');
    a.progress = 0.4;
    a.actions  = {{QStringLiteral("stop"), QStringLiteral("Stop this transfer right now please")}};
    const QVariantMap m = client::state(a);
    // The host accepts what the client sends (the actions as the bus would deliver them).
    Input in;
    for (auto it = m.cbegin(); it != m.cend(); ++it) {
        ++in.entries;
        if (it.key() == QLatin1String("actions")) {
            in.hasActions = true;
            for (const auto& b : it.value().value<QList<grassfield::apps::OngoingButton>>())
                in.actions.append({b.id, b.label});
        } else {
            in.fields.insert(it.key(), it.value());
        }
    }
    const Checked c = checkState(in, QDateTime::currentMSecsSinceEpoch());
    ASSERT_TRUE(c.state) << c.error.toStdString();
    EXPECT_EQ(c.state->title.size(), kMaxTitle);
    EXPECT_EQ(c.state->actions.first().label.size(), kMaxLabel);
    // At most the host's per-app limit is published, the first ones asked for; the others wait for a free place.
    const QStringList order = {QStringLiteral("copy-1"), QStringLiteral("copy-2"), QStringLiteral("copy-3"), QStringLiteral("copy-4"), QStringLiteral("copy-5")};
    QSet<QString> wanted(order.cbegin(), order.cend());
    EXPECT_EQ(client::kMaxShown, kMaxPerApp);
    EXPECT_EQ(client::shown(order, wanted), order.mid(0, 3));
    wanted.remove(QStringLiteral("copy-2"));
    EXPECT_EQ(client::shown(order, wanted), (QStringList{QStringLiteral("copy-1"), QStringLiteral("copy-3"), QStringLiteral("copy-4")}));
    EXPECT_TRUE(client::shown(order, {}).isEmpty());
    // Indeterminate, no time: those keys are left out.
    a.progress = -1;
    EXPECT_FALSE(client::state(a).contains(QStringLiteral("progress")));
    EXPECT_FALSE(client::state(a).contains(QStringLiteral("started")));
    EXPECT_FALSE(client::state(a).contains(QStringLiteral("ends")));
}
