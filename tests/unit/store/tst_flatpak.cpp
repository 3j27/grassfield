// Flathub in the user's installation (ADR-0037 a, b.3; step 3c part 2, SD25 to SD27): what the Store reads of flatpak
// and how it asks for flatpak's own plan on a pseudo-terminal. The fixtures under tests/fixtures/store/flatpak are what
// flatpak 1.18 printed in store-probes-4.sh (S22, S23), its sizes with the no-break space of a UTF-8 locale. The fake
// flatpak here answers as flatpak does: its questions only on a terminal, and nothing installed unless told to proceed.
#include "appstreamsource.h"
#include "flatpak.h"
#include "operations.h"
#include "storetest.h"

#include <QDir>
#include <QDirIterator>
#include <QElapsedTimer>
#include <QEventLoop>
#include <QFile>
#include <QProcess>
#include <QTemporaryDir>
#include <QThread>
#include <QTimer>

#include <gtest/gtest.h>

#include <functional>
#include <iostream>

using namespace grassfield::store;

namespace {

QStringList fixtureLines(const char *name)
{
    return terminalLines(storetest::readFixture(QStringLiteral("flatpak/") + QLatin1String(name)));
}

// A fake flatpak in `dir`: remote-info answers from the fixtures (exit 1 for an app Flathub lacks), install asks S23's two
// questions on a terminal and writes each answer to `answers`; it "installs" (the file `installed`) only on a yes to proceed.
// `question` replaces the first question (another kind of question).
QString fakeFlatpak(const QTemporaryDir &dir, const QByteArray &question = {})
{
    const QByteArray fixtures = STORE_FIXTURES "/flatpak";
    const QByteArray d = dir.path().toUtf8();
    return storetest::script(dir.filePath(QStringLiteral("flatpak")),
                             "echo \"$*\" >>'" + d + "/calls'\n"
                             "case \"$*\" in\n"
                             "  *no.such.App*) echo 'error: No remote refs found for no.such.App' >&2; exit 1 ;;\n"
                             "  'remote-info --user --show-metadata flathub '*) cat '" + fixtures + "/metadata.txt' ;;\n"
                             "  'install --user flathub '*)\n"
                             "    if [ ! -t 0 ] || [ ! -t 1 ]; then echo 'Do you want to install it? [Y/n]: n'; exit 1; fi\n"
                             + (question.isEmpty() ? "    cat '" + fixtures + "/runtime-question.txt'\n    printf 'Do you want to install it? [Y/n]: '\n"
                                                   : "    printf '" + question + "'\n")
                             + "    read a; echo \"$a\" >>'" + d + "/answers'\n"
                               "    cat '" + fixtures + "/plan-table.txt'\n"
                               "    printf 'Proceed with these changes to the user installation? [Y/n]: '\n"
                               "    read b; echo \"$b\" >>'" + d + "/answers'\n"
                               "    [ \"$b\" = y ] && : >'" + d + "/installed' && exit 0\n"
                               "    exit 1 ;;\n"
                               "  *) exit 2 ;;\n"
                               "esac");
}

QByteArray readAll(const QString &path)
{
    QFile f(path);
    return f.open(QIODevice::ReadOnly) ? f.readAll() : QByteArray();
}

} // namespace

TEST(Flatpak, RefsAndLists)
{
    EXPECT_TRUE(isFlatpakAppRef(QStringLiteral("app/org.gnome.design.Typography/x86_64/stable")));
    EXPECT_EQ(flatpakRefId(QStringLiteral("app/io.github.fragglet.sdl_sopwith/x86_64/stable")), QStringLiteral("io.github.fragglet.sdl_sopwith"));
    for (const char *bad : {"runtime/org.gnome.Platform/x86_64/50", "app/org.gnome.Typography/x86_64", "app/notanid/x86_64/stable",
                            "app/org.gnome.Typography/x86_64/stable/x", "app/org.gnome.Typography/x86 64/stable",
                            "app/org.gnome.Typography/x86_64/sta;ble", "app/org.gnome.Typography/x86_64/", "app/-org.a.b/x86_64/stable"}) {
        EXPECT_FALSE(isFlatpakAppRef(QLatin1String(bad))) << bad;
        EXPECT_TRUE(flatpakRefId(QLatin1String(bad)).isEmpty()) << bad;
    }
    EXPECT_EQ(parseFlatpakList("io.github.fragglet.sdl_sopwith\norg.gnome.design.Typography\n\nnot an id\n../x\n"),
              (QSet<QString>{QStringLiteral("io.github.fragglet.sdl_sopwith"), QStringLiteral("org.gnome.design.Typography")}));
    EXPECT_TRUE(hasFlathubRemote("fedora\nflathub\n"));
    EXPECT_FALSE(hasFlathubRemote("flathub-beta\nmyflathub\n"));
    EXPECT_FALSE(flatpakArch().isEmpty());
}

TEST(Flatpak, TerminalLinesAndSizes)
{
    EXPECT_EQ(terminalLines("\x1b[1mBold\x1b[0m line\r\nnext\rover\x1b]0;title\x07 end"),
              (QStringList{QStringLiteral("Bold line"), QStringLiteral("next"), QStringLiteral("over end")}));
    EXPECT_EQ(parseFlatpakSize(QStringLiteral("418.8 MB")), 418800000);
    EXPECT_EQ(parseFlatpakSize(QString::fromUtf8("68.6\xc2\xa0kB")), 68600);
    EXPECT_EQ(parseFlatpakSize(QStringLiteral("147.9?MB")), 147900000) << "the C locale writes the no-break space as ?";
    EXPECT_EQ(parseFlatpakSize(QStringLiteral("1.0 GB")), 1000000000);
    EXPECT_EQ(parseFlatpakSize(QStringLiteral("512 bytes")), 512);
    EXPECT_EQ(parseFlatpakSize(QStringLiteral("2,5 MB")), 2500000);
    for (const char *bad : {"", "MB", "12 parsecs", "-1 MB", "1 MB extra"})
        EXPECT_EQ(parseFlatpakSize(QLatin1String(bad)), -1) << bad;
}

// S23's table: seven refs, the app's own last, each with the most it downloads; "(partial)" read too.
TEST(Flatpak, ItsOwnPlan)
{
    const QList<FlatpakRow> rows = parseFlatpakPlan(fixtureLines("plan-table.txt"));
    ASSERT_EQ(rows.size(), 7);
    EXPECT_EQ(rows.at(0).id, QStringLiteral("org.freedesktop.Platform.GL.default"));
    EXPECT_EQ(rows.at(0).branch, QStringLiteral("25.08"));
    EXPECT_EQ(rows.at(0).op, QStringLiteral("i"));
    EXPECT_EQ(rows.at(0).download, 147900000);
    EXPECT_EQ(rows.at(3).id, QStringLiteral("org.gnome.Platform.Locale"));
    EXPECT_EQ(rows.at(3).download, 386500000) << "(partial) after the size";
    EXPECT_EQ(rows.at(6).id, QStringLiteral("org.gnome.design.Typography"));
    EXPECT_EQ(rows.at(6).download, 68600);
    // A row of another remote, a number out of order, and anything after the question are not the plan's.
    QStringList lines = fixtureLines("plan-table.txt");
    lines.insert(6, QStringLiteral(" 9.     org.example.Other   1   i  flathub < 1 MB"));
    const QList<FlatpakRow> numbered = parseFlatpakPlan(lines);
    EXPECT_EQ(numbered.size(), 7);
    EXPECT_TRUE(std::none_of(numbered.cbegin(), numbered.cend(), [](const FlatpakRow &r) { return r.id == QLatin1String("org.example.Other"); }));
    EXPECT_TRUE(parseFlatpakPlan({QStringLiteral(" 1.     org.example.App   stable   i  elsewhere < 1 MB")}).isEmpty());
    EXPECT_TRUE(parseFlatpakPlan({QStringLiteral("Proceed with these changes to the user installation? [Y/n]: "),
                                  QStringLiteral(" 1.     org.example.App   stable   i  flathub < 1 MB")})
                    .isEmpty());
    EXPECT_TRUE(parseFlatpakPlan({QStringLiteral("Looking for matches…")}).isEmpty());
}

// Which question flatpak asks: only S23's runtime question is answered yes; "Proceed" no; anything else no.
TEST(Flatpak, ItsQuestions)
{
    QStringList lines = fixtureLines("runtime-question.txt");
    lines.removeLast();
    EXPECT_EQ(flatpakPrompt(lines), FlatpakPrompt::None) << "no question yet";
    lines.append(QStringLiteral("Do you want to install it? [Y/n"));
    EXPECT_EQ(flatpakPrompt(lines), FlatpakPrompt::None) << "a question still on its way";
    lines.last() = QStringLiteral("Do you want to install it? [Y/n]: ");
    EXPECT_EQ(flatpakPrompt(lines), FlatpakPrompt::RequiredRuntime);
    EXPECT_EQ(flatpakPrompt({QStringLiteral("Do you want to install it? [Y/n]: ")}), FlatpakPrompt::Other)
        << "the same words without the runtime's line are another question";
    EXPECT_EQ(flatpakPrompt({QStringLiteral("Required runtime for a (runtime/b) found in remote elsewhere"),
                             QStringLiteral("Do you want to install it? [Y/n]: ")}),
              FlatpakPrompt::Other)
        << "a runtime of another remote";
    lines = fixtureLines("plan-table.txt");
    lines.append(QStringLiteral("Proceed with these changes to the user installation? [Y/n]: "));
    EXPECT_EQ(flatpakPrompt(lines), FlatpakPrompt::Proceed);
    EXPECT_EQ(flatpakPrompt({QStringLiteral("Similar refs found for ‘x’ in remote ‘flathub’:"), QStringLiteral(""),
                             QStringLiteral("Which do you want to use (0 to abort)? [0-2]: ")}),
              FlatpakPrompt::Other);
    EXPECT_EQ(flatpakPrompt({QStringLiteral("Proceed with these changes to the system installation? [Y/n]: ")}), FlatpakPrompt::Other);
}

TEST(Flatpak, WhatItCanReach)
{
    // S22's app: the network, its sound and the X11 display (dri, ipc, wayland and fallback-x11 are not said).
    EXPECT_EQ(flatpakAccess(storetest::readFixture(QStringLiteral("flatpak/metadata.txt"))),
              (QStringList{QStringLiteral("network"), QStringLiteral("audio"), QStringLiteral("x11")}));
    const QByteArray wide = "[Application]\nname=org.example.Wide\n\n[Context]\nfilesystems=host;xdg-download;~/Games:create;!home;\n"
                            "devices=all;\nsockets=wayland;session-bus;\nfeatures=bluetooth;devel;\nshared=ipc;\n\n"
                            "[Session Bus Policy]\norg.freedesktop.Flatpak=talk\n";
    EXPECT_EQ(flatpakAccess(wide), (QStringList{QStringLiteral("allFiles"), QStringLiteral("folders"), QStringLiteral("devices"),
                                                QStringLiteral("bus"), QStringLiteral("bluetooth"), QStringLiteral("outside")}));
    EXPECT_EQ(flatpakAccess("[Context]\nfilesystems=home:ro;\nshared=!network;\nsockets=fallback-x11;\n"), QStringList{QStringLiteral("home")});
    EXPECT_TRUE(flatpakAccess("[Context]\nshared=ipc;\nsockets=wayland;\ndevices=dri;\n[Extension x]\nfilesystems=host;\n").isEmpty())
        << "another group's keys are not the app's";
    EXPECT_TRUE(flatpakAccess("[Session Bus Policy]\norg.freedesktop.Flatpak=none\n").isEmpty());
    EXPECT_TRUE(flatpakAccess("[Context]\nfilesystems=!host;!home;!xdg-download;\ndevices=!all;\n").isEmpty()) << "taken away, not granted";
    EXPECT_TRUE(flatpakAccess({}).isEmpty());
}

TEST(Flatpak, InfoAndProgress)
{
    const FlatpakFacts remote = parseFlatpakInfo("            ID: io.github.fragglet.sdl_sopwith\n           Ref: app/io.github.fragglet.sdl_sopwith/x86_64/stable\n"
                                                 "       Version: 2.9.0\n       License: GPL-2.0-or-later\n Download Size: 145.9?kB\n"
                                                 "Installed Size: 448.0?kB\n       Runtime: org.freedesktop.Platform/x86_64/25.08\n");
    EXPECT_EQ(remote.version, QStringLiteral("2.9.0"));
    EXPECT_EQ(remote.license, QStringLiteral("GPL-2.0-or-later"));
    EXPECT_EQ(remote.download, 145900);
    EXPECT_EQ(remote.installed, 448000);
    const FlatpakFacts local = parseFlatpakInfo("Version: 2.9.0\nInstalled: 448.0 kB\n");
    EXPECT_EQ(local.installed, 448000);
    EXPECT_EQ(local.download, -1);
    // S24's lines: each ref once, whatever else flatpak prints.
    const QByteArray out = "Looking for matches…\nInstalling runtime/org.freedesktop.Platform.GL.default/x86_64/25.08\n"
                           "Installing runtime/org.freedesktop.Platform/x86_64/25.08\nInstalling runtime/org.freedesktop.Platform/x86_64/25.08\n"
                           "Updating runtime/org.freedesktop.Platform.Locale/x86_64/25.08\nInstalling app/io.github.fragglet.sdl_sopwith/x86_64/stable\n"
                           "Installation complete.\n";
    EXPECT_EQ(flatpakSteps(out, true), 4);
    EXPECT_EQ(flatpakSteps(out, false), 0);
    EXPECT_EQ(flatpakSteps("Uninstalling app/org.gnome.design.Typography/x86_64/stable\r\nUninstalling runtime/org.gnome.design.Typography.Locale/x86_64/stable\n", false), 2);
}

// flatpak's own plan, asked on the Store's pseudo-terminal (SD25): yes for the runtime, no to proceed, nothing installed.
TEST(Flatpak, PlanOnATerminal)
{
    QTemporaryDir dir;
    FlatpakTools tools;
    tools.flatpak = fakeFlatpak(dir);
    const QString ref = QStringLiteral("app/org.gnome.design.Typography/x86_64/stable");
    const InstallPlan plan = checkFlatpakInstall(ref, tools, true);
    ASSERT_EQ(plan.refusal, Refusal::None) << plan.detail.toStdString();
    ASSERT_EQ(plan.packages.size(), 7);
    EXPECT_EQ(plan.packages.at(4).name, QStringLiteral("org.gnome.Platform"));
    EXPECT_EQ(plan.packages.at(4).version, QStringLiteral("50"));
    EXPECT_EQ(plan.packages.at(4).repo, QStringLiteral("flathub"));
    EXPECT_EQ(plan.downloadSize, 147900000LL + 148000000 + 14600000 + 386500000 + 418800000 + 19700 + 68600);
    EXPECT_EQ(plan.installedSize, -1);
    EXPECT_EQ(plan.access, (QStringList{QStringLiteral("network"), QStringLiteral("audio"), QStringLiteral("x11")}));
    EXPECT_EQ(readAll(dir.filePath(QStringLiteral("answers"))), QByteArray("y\nn\n"));
    EXPECT_FALSE(QFile::exists(dir.filePath(QStringLiteral("installed"))));
    EXPECT_EQ(readAll(dir.filePath(QStringLiteral("calls"))),
              "remote-info --user --show-metadata flathub " + ref.toUtf8() + "\ninstall --user flathub " + ref.toUtf8() + "\n");

    // Another question: answered no, and no plan.
    QTemporaryDir other;
    tools.flatpak = fakeFlatpak(other, "Which do you want to use (0 to abort)? [0-2]: ");
    InstallPlan refused = checkFlatpakInstall(ref, tools, true);
    EXPECT_EQ(refused.refusal, Refusal::Failed);
    EXPECT_EQ(readAll(other.filePath(QStringLiteral("answers"))), QByteArray("0\nn\n")) << "0 to a choice, then no";
    EXPECT_FALSE(QFile::exists(other.filePath(QStringLiteral("installed"))));

    // An app Flathub lacks: flatpak's words; offline: not asked; not a ref: not asked.
    tools.flatpak = fakeFlatpak(dir);
    refused = checkFlatpakInstall(QStringLiteral("app/no.such.App/x86_64/stable"), tools, true);
    EXPECT_EQ(refused.refusal, Refusal::Failed);
    EXPECT_EQ(refused.detail, QStringLiteral("error: No remote refs found for no.such.App"));
    QFile::remove(dir.filePath(QStringLiteral("calls")));
    EXPECT_EQ(checkFlatpakInstall(ref, tools, false).refusal, Refusal::Offline);
    EXPECT_EQ(checkFlatpakInstall(QStringLiteral("app/org.x.Y/x86_64/a b"), tools, true).refusal, Refusal::Failed);
    EXPECT_FALSE(QFile::exists(dir.filePath(QStringLiteral("calls"))));
}

// A plan that never comes ends at its deadline, its process group stopped.
TEST(Flatpak, PlanInTime)
{
    QTemporaryDir dir;
    FlatpakTools tools;
    tools.flatpak = storetest::script(dir.filePath(QStringLiteral("flatpak")),
                                      "case \"$1\" in remote-info) echo '[Context]' ;; install) sleep 30 & echo $! >'"
                                          + dir.path().toUtf8() + "/child'; wait ;; esac");
    tools.planMs = 1500;
    QElapsedTimer clock;
    clock.start();
    const InstallPlan plan = checkFlatpakInstall(QStringLiteral("app/org.example.Slow/x86_64/stable"), tools, true);
    EXPECT_EQ(plan.refusal, Refusal::Failed);
    EXPECT_EQ(plan.detail, QStringLiteral("flatpak install: no plan in time"));
    EXPECT_LT(clock.elapsed(), 9000);
    const QString child = QString::fromUtf8(readAll(dir.filePath(QStringLiteral("child")))).trimmed();
    ASSERT_FALSE(child.isEmpty());
    // Gone, or a zombie no one reaped yet (a container's first process may not).
    const auto alive = [&child] {
        const QByteArray stat = readAll(QStringLiteral("/proc/") + child + QStringLiteral("/stat"));
        return !stat.isEmpty() && stat.mid(stat.lastIndexOf(')') + 2, 1) != "Z";
    };
    for (int i = 0; i < 50 && alive(); ++i)
        QThread::msleep(100);
    EXPECT_FALSE(alive()) << "what it started is stopped with it";
}

// The real flatpak (tests/integration/store_flatpak.sh: a throwaway container, root's own installation, and a local
// repository named flathub, served slowly over http, with a 20 MB runtime and an app that reaches the network, the home
// folder and the sound server): Flathub's AppStream as flatpak copies it, flatpak's own plan on the Store's terminal, the
// app's facts, an install stopped half-way (SD26), an install, a removal with the unused runtime (SD27).
TEST(Flatpak, RealFlatpak)
{
    if (qEnvironmentVariable("STORE_TEST_FLATPAK") != QLatin1String("1"))
        GTEST_SKIP() << "tests/integration/store_flatpak.sh runs it in a throwaway container";
    storetest::ensureApp();
    FlatpakTools tools;
    tools.env = flatpakEnvironment();
    const QString ref = QStringLiteral("app/org.example.Hello/x86_64/stable");
    ASSERT_TRUE(flathubAdded(tools));
    ASSERT_EQ(refreshFlathubAppStream(tools), QString());
    const QString active = QDir::homePath() + QStringLiteral("/.local/share/flatpak/appstream/flathub/") + flatpakArch() + QStringLiteral("/active");
    const AppStreamData data = readFlathubAppStream(active);
    ASSERT_EQ(data.components.size(), 1);
    EXPECT_EQ(data.components.at(0).flatpakRef, ref);
    EXPECT_EQ(data.components.at(0).runtime, QStringLiteral("org.example.Platform/x86_64/1"));
    EXPECT_EQ(listFlatpakApps(tools), QSet<QString>());

    const InstallPlan plan = checkFlatpakInstall(ref, tools, true);
    ASSERT_EQ(plan.refusal, Refusal::None) << plan.detail.toStdString();
    ASSERT_EQ(plan.packages.size(), 2);
    EXPECT_EQ(plan.packages.at(0).name, QStringLiteral("org.example.Platform"));
    EXPECT_EQ(plan.packages.at(1).name, QStringLiteral("org.example.Hello"));
    EXPECT_GT(plan.downloadSize, 20000000);
    EXPECT_EQ(plan.access, (QStringList{QStringLiteral("network"), QStringLiteral("home"), QStringLiteral("audio")}));
    EXPECT_EQ(listFlatpakApps(tools), QSet<QString>()) << "the plan installs nothing";
    const std::optional<FlatpakFacts> before = flatpakFacts(tools, ref, false);
    ASSERT_TRUE(before);
    EXPECT_EQ(before->version, QStringLiteral("1.2"));
    EXPECT_EQ(before->license, QStringLiteral("MIT"));
    EXPECT_GT(before->download, 0);

    QTemporaryDir state;
    OperationsConfig config;
    config.flatpak = tools.flatpak;
    config.flatpakEnv = tools.env;
    config.stateFile = state.filePath(QStringLiteral("store.json"));
    Operations ops(config);
    int ended = 0;
    QObject::connect(&ops, &Operations::finished, &ops, [&ended] { ++ended; });
    const auto wait = [](const std::function<bool()> &done, int ms) {
        QEventLoop loop;
        QElapsedTimer clock;
        clock.start();
        while (!done() && clock.elapsed() < ms) {
            QTimer::singleShot(20, &loop, &QEventLoop::quit);
            loop.exec();
        }
        return done();
    };
    OperationRecord install;
    install.id = newOperationId();
    install.kind = QStringLiteral("install");
    install.path = QStringLiteral("flatpak");
    install.app = QStringLiteral("org.example.Hello");
    install.name = QStringLiteral("Hello");
    install.flatpak = ref;
    install.plan = plan.packages;
    // Stopped while the runtime downloads (the server sends it slowly): nothing of it left half-installed.
    ops.enqueue(install);
    ASSERT_TRUE(wait([&] { return !ops.items().isEmpty() && ops.items().constFirst().done >= 1; }, 60000));
    ASSERT_TRUE(ops.stop(install.id));
    ASSERT_TRUE(wait([&] { return ended == 1; }, 60000));
    EXPECT_EQ(ops.results().value(QStringLiteral("org.example.Hello")).outcome, QStringLiteral("stopped"))
        << ops.results().value(QStringLiteral("org.example.Hello")).details.toStdString();
    EXPECT_FALSE(flatpakInstalled(tools, QStringLiteral("org.example.Hello")));
    // What it was downloading waits in flatpak's own folder (a staging folder), for the next install to take up.
    const auto staging = [] {
        int n = 0;
        for (QDirIterator it(QDir::homePath() + QStringLiteral("/.local/share/flatpak/repo/tmp"), QDir::Dirs | QDir::NoDotAndDotDot); it.hasNext();)
            n += it.next().section(QLatin1Char('/'), -1).startsWith(QLatin1String("staging-")) ? 1 : 0;
        return n;
    };
    std::cout << "[ INFO     ] staging folders after the stop: " << staging() << std::endl;

    // Installed: its two refs counted, the app listed, its facts from the user's installation.
    install.id = newOperationId();
    ops.enqueue(install);
    int done = 0;
    QObject::connect(&ops, &Operations::changed, &ops, [&] {
        for (const Operations::Item &i : ops.items())
            done = qMax(done, i.done);
    });
    ASSERT_TRUE(wait([&] { return ended == 2; }, 180000));
    EXPECT_TRUE(ops.results().isEmpty()) << ops.results().value(QStringLiteral("org.example.Hello")).details.toStdString();
    EXPECT_EQ(done, 2);
    EXPECT_TRUE(flatpakInstalled(tools, QStringLiteral("org.example.Hello")));
    EXPECT_EQ(staging(), 0) << "the next install took up what the stopped one left";
    const std::optional<FlatpakFacts> after = flatpakFacts(tools, QStringLiteral("org.example.Hello"), true);
    ASSERT_TRUE(after);
    EXPECT_EQ(after->version, QStringLiteral("1.2"));
    EXPECT_GT(after->installed, 0);
    EXPECT_EQ(after->access, (QStringList{QStringLiteral("network"), QStringLiteral("home"), QStringLiteral("audio")}));

    // Removed, and the runtime no other app needs with it.
    OperationRecord removal = install;
    removal.id = newOperationId();
    removal.kind = QStringLiteral("remove");
    removal.flatpak = QStringLiteral("org.example.Hello");
    removal.plan = {plan.packages.at(1)};
    ops.enqueue(removal);
    ASSERT_TRUE(wait([&] { return ended == 3; }, 60000));
    EXPECT_TRUE(ops.results().isEmpty()) << ops.results().value(QStringLiteral("org.example.Hello")).details.toStdString();
    EXPECT_FALSE(flatpakInstalled(tools, QStringLiteral("org.example.Hello")));
    QProcess runtimes;
    runtimes.start(tools.flatpak, {QStringLiteral("list"), QStringLiteral("--user"), QStringLiteral("--runtime"), QStringLiteral("--columns=application")});
    ASSERT_TRUE(runtimes.waitForFinished(20000));
    EXPECT_EQ(runtimes.readAllStandardOutput().trimmed(), QByteArray()) << "the unused runtime went with it";
}
