// Flathub in the user's installation (ADR-0037 a, b.3; step 3c part 2, SD25 to SD27): what the Store reads of flatpak
// and how it asks for flatpak's own plan on a pseudo-terminal. The fixtures under tests/fixtures/store/flatpak are what
// flatpak 1.18 printed in store-probes-4.sh (S22, S23), its sizes with the no-break space of a UTF-8 locale. The fake
// flatpak here answers as flatpak does: its questions only on a terminal, and nothing installed unless told to proceed.
#include "appstreamsource.h"
#include "childprocess.h"
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
    EXPECT_TRUE(isFlatpakAppRef(QStringLiteral("app/org.x.Y/aarch64/24.08")));
    EXPECT_TRUE(isFlatpakAppRef(QStringLiteral("app/org.x.Y/x86_64/_beta-1")));
    EXPECT_EQ(flatpakRefId(QStringLiteral("app/io.github.fragglet.sdl_sopwith/x86_64/stable")), QStringLiteral("io.github.fragglet.sdl_sopwith"));
    for (const char *bad : {"runtime/org.gnome.Platform/x86_64/50", "app/org.gnome.Typography/x86_64", "app/notanid/x86_64/stable",
                            "app/org.gnome.Typography/x86_64/stable/x", "app/org.gnome.Typography/x86 64/stable",
                            "app/org.gnome.Typography/x86_64/sta;ble", "app/org.gnome.Typography/x86_64/", "app/-org.a.b/x86_64/stable",
                            "app/org.x.Y/../stable", "app/org.x.Y/x86_64/..", "app/org.x.Y/x86_64/a..b", "app/org.x.Y/-x86_64/stable",
                            "app/org.x.Y/x86_64/-stable", "app/org.x.Y/x86_64/.stable", "app/org.x.Y/.x/stable"}) {
        EXPECT_FALSE(isFlatpakAppRef(QLatin1String(bad))) << bad;
        EXPECT_TRUE(flatpakRefId(QLatin1String(bad)).isEmpty()) << bad;
    }
    EXPECT_EQ(parseFlatpakList("io.github.fragglet.sdl_sopwith\norg.gnome.design.Typography\n\nnot an id\n../x\n"),
              (QSet<QString>{QStringLiteral("io.github.fragglet.sdl_sopwith"), QStringLiteral("org.gnome.design.Typography")}));
    EXPECT_TRUE(hasFlathubRemote("fedora\nflathub\n"));
    EXPECT_FALSE(hasFlathubRemote("flathub-beta\nmyflathub\n"));
    EXPECT_FALSE(flatpakArch().isEmpty());
}

// Step 4's updates (S31): `remote-ls --user --updates --columns=application,branch,origin,ref`, each line checked; an app's
// and a runtime's refs.
TEST(Flatpak, UpdatesListed)
{
    EXPECT_TRUE(isFlatpakRef(QStringLiteral("runtime/org.gnome.Platform/x86_64/50")));
    EXPECT_TRUE(isFlatpakRef(QStringLiteral("app/org.x.Y/x86_64/stable")));
    for (const char *bad : {"extension/org.x.Y/x86_64/1", "runtime/org.x.Y/x86_64", "runtime/notanid/x86_64/1", "runtime/org.x.Y/../1",
                            "app/org.x.Y/x86_64/-stable", "--system"})
        EXPECT_FALSE(isFlatpakRef(QLatin1String(bad))) << bad;
    // S31a's lines (tab-separated), and lines that are not one of them.
    const QList<FlatpakUpdate> updates = parseFlatpakUpdates(
        "org.example.Hello\tstable\tflathub\tapp/org.example.Hello/x86_64/stable\n"
        "org.example.Platform\t1\tflathub\truntime/org.example.Platform/x86_64/1\n"
        "\n"
        "org.example.Other\tstable\tflathub\tapp/org.example.Hello/x86_64/stable\n"   // a ref of another id
        "org.example.Hello\tbeta\tflathub\tapp/org.example.Hello/x86_64/stable\n"     // of another branch
        "org.example.Bad\tstable\t\tapp/org.example.Bad/x86_64/stable\n"              // no origin
        "org.example.Bad\tstable\tflathub\tapp/org.example.Bad/x86_64/stable --system\n"
        "org.example.Two\tstable\tflathub\n"                                           // three columns
        "org.example.Mine\tstable\tmine\tapp/org.example.Mine/x86_64/stable\n");
    ASSERT_EQ(updates.size(), 3);
    EXPECT_EQ(updates.at(0).id, QStringLiteral("org.example.Hello"));
    EXPECT_TRUE(updates.at(0).app);
    EXPECT_EQ(updates.at(1).ref, QStringLiteral("runtime/org.example.Platform/x86_64/1"));
    EXPECT_FALSE(updates.at(1).app);
    EXPECT_EQ(updates.at(2).origin, QStringLiteral("mine")) << "the origin is kept: the backend keeps Flathub's";
    QByteArray many;
    for (int i = 0; i < 600; ++i)
        many += QStringLiteral("org.example.A%1\tstable\tflathub\tapp/org.example.A%1/x86_64/stable\n").arg(i).toUtf8();
    EXPECT_EQ(parseFlatpakUpdates(many).size(), 512);

    // flatpak answering, and not (offline: exit 1, S31d).
    QTemporaryDir dir;
    FlatpakTools tools;
    tools.flatpak = storetest::script(dir.filePath(QStringLiteral("flatpak")),
                                      "echo \"$*\" >>'" + dir.path().toUtf8() + "/calls'\n"
                                      "[ -e '" + dir.path().toUtf8() + "/offline' ] && { echo 'error: Unable to load summary' >&2; exit 1; }\n"
                                      "printf 'org.example.Hello\\tstable\\tflathub\\tapp/org.example.Hello/x86_64/stable\\n'\n");
    const std::optional<QList<FlatpakUpdate>> listed = listFlatpakUpdates(tools);
    ASSERT_TRUE(listed);
    EXPECT_EQ(listed->size(), 1);
    EXPECT_EQ(readAll(dir.filePath(QStringLiteral("calls"))), "remote-ls --user --updates --columns=application,branch,origin,ref\n");
    storetest::writeFile(dir.filePath(QStringLiteral("offline")), "");
    EXPECT_FALSE(listFlatpakUpdates(tools));
}

// What an update lets an app reach that it could not (SD25 for an update): the installed metadata against Flathub's newer
// one; nothing new, something new, and either unread.
TEST(Flatpak, UpdateAccessAdded)
{
    QTemporaryDir dir;
    const QByteArray d = dir.path().toUtf8();
    storetest::writeFile(dir.filePath(QStringLiteral("installed")), "[Application]\nname=org.example.Hello\n[Context]\nshared=network;\n");
    storetest::writeFile(dir.filePath(QStringLiteral("newer")), "[Application]\nname=org.example.Hello\n[Context]\nshared=network;\n");
    FlatpakTools tools;
    tools.flatpak = storetest::script(dir.filePath(QStringLiteral("flatpak")),
                                      "echo \"$*\" >>'" + d + "/calls'\n"
                                      "case \"$1\" in\n"
                                      "  info) cat '" + d + "/installed'; if [ -e '" + d + "/unreadable' ]; then exit 1; fi ;;\n"
                                      "  remote-info) cat '" + d + "/newer' ;;\n"
                                      "esac\n");
    const QString ref = QStringLiteral("app/org.example.Hello/x86_64/stable");
    std::optional<QStringList> added = flatpakAccessAdded(tools, ref);
    ASSERT_TRUE(added);
    EXPECT_TRUE(added->isEmpty());
    EXPECT_EQ(readAll(dir.filePath(QStringLiteral("calls"))), "info --user --show-metadata -- " + ref.toUtf8() + "\n"
                                                                "remote-info --user --show-metadata flathub " + ref.toUtf8() + "\n");
    storetest::writeFile(dir.filePath(QStringLiteral("newer")),
                         "[Application]\nname=org.example.Hello\n[Context]\nshared=network;\nfilesystems=home;\nsockets=x11;\n");
    added = flatpakAccessAdded(tools, ref);
    ASSERT_TRUE(added);
    EXPECT_EQ(*added, (QStringList{QStringLiteral("home"), QStringLiteral("x11"), QStringLiteral("login"), QStringLiteral("outside")}));
    // What it could reach and no longer can is not "added".
    storetest::writeFile(dir.filePath(QStringLiteral("newer")), "[Application]\nname=org.example.Hello\n");
    added = flatpakAccessAdded(tools, ref);
    ASSERT_TRUE(added);
    EXPECT_TRUE(added->isEmpty());
    // Unread: metadata naming no app, or a value flatpak cannot interpret.
    storetest::writeFile(dir.filePath(QStringLiteral("newer")), "[Context]\nshared=network;\n");
    EXPECT_FALSE(flatpakAccessAdded(tools, ref));
    storetest::writeFile(dir.filePath(QStringLiteral("newer")), "[Application]\nname=org.example.Hello\n[Context]\nfilesystems=b\\qc;\n");
    EXPECT_FALSE(flatpakAccessAdded(tools, ref));
    // The installed side unread (flatpak info fails, whatever it printed) is unread too, whatever the newer commit reaches.
    storetest::writeFile(dir.filePath(QStringLiteral("newer")), "[Application]\nname=org.example.Hello\n[Context]\nshared=network;\n");
    ASSERT_TRUE(flatpakAccessAdded(tools, ref));
    storetest::writeFile(dir.filePath(QStringLiteral("unreadable")), "");
    EXPECT_FALSE(flatpakAccessAdded(tools, ref));
    QFile::remove(dir.filePath(QStringLiteral("unreadable")));
    EXPECT_FALSE(flatpakAccessAdded(tools, QStringLiteral("runtime/org.example.Platform/x86_64/1"))) << "an app's ref only";
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

// What an app's metadata grants it, every grant named (SR11, SD25): "only its own window and files" ([]) only when
// nothing is granted beyond them.
namespace {
QStringList reach(const QByteArray &context, const QByteArray &more = {})
{
    const std::optional<QStringList> access = flatpakAccess("[Application]\nname=org.example.App\nruntime=org.example.Platform/x86_64/1\n\n[Context]\n"
                                                            + context + "\n" + more);
    return access ? *access : QStringList{QStringLiteral("(unread)")};
}
} // namespace

TEST(Flatpak, WhatItCanReach)
{
    // S22's app: the network, its sound, the X11 display and the shared memory X11 uses (dri, wayland and fallback-x11
    // beside wayland draw its own window; notifications are harmless).
    EXPECT_EQ(flatpakAccess(storetest::readFixture(QStringLiteral("flatpak/metadata.txt"))),
              (QStringList{QStringLiteral("network"), QStringLiteral("audio"), QStringLiteral("x11"), QStringLiteral("sharedMemory")}));
    const QByteArray wide = "[Application]\nname=org.example.Wide\n\n[Context]\nfilesystems=host;xdg-download;~/Games:create;!home;\n"
                            "devices=all;\nsockets=wayland;session-bus;\nfeatures=bluetooth;devel;\nshared=ipc;\n\n"
                            "[Session Bus Policy]\norg.freedesktop.Flatpak=talk\n";
    EXPECT_EQ(flatpakAccess(wide),
              (QStringList{QStringLiteral("allFiles"), QStringLiteral("folders"), QStringLiteral("devices"), QStringLiteral("sharedMemory"),
                           QStringLiteral("bus"), QStringLiteral("bluetooth"), QStringLiteral("devel"), QStringLiteral("login"),
                           QStringLiteral("outside"), QStringLiteral("sessionService:org.freedesktop.Flatpak")}));
    EXPECT_EQ(reach("filesystems=home:ro;\nshared=!network;\nsockets=fallback-x11;"), (QStringList{QStringLiteral("home"), QStringLiteral("x11")}))
        << "fallback-x11 without a Wayland socket is the X11 display";

    // Nothing beyond its window and files: its window, the graphics processor, its own folder and variables, names it
    // only sees, harmless names, its own names, another group's keys.
    EXPECT_EQ(reach("sockets=wayland;fallback-x11;inherit-wayland-socket;\ndevices=dri;\nfeatures=per-app-dev-shm;\npersistent=.app;\n"
                    "unset-environment=FOO;",
                    "[Session Bus Policy]\norg.freedesktop.Flatpak=see\norg.freedesktop.systemd1=none\norg.freedesktop.Notifications=talk\n"
                    "org.freedesktop.portal.Desktop=talk\norg.mpris.MediaPlayer2.App=own\norg.example.App=own\norg.example.App.Tray=own\n"
                    "org.kde.StatusNotifierWatcher=talk\ncom.canonical.AppMenu.Registrar=talk\norg.freedesktop.ScreenSaver=talk\norg.a11y.Bus=talk\n"
                    "org.freedesktop.FileManager1=talk\n[System Bus Policy]\norg.freedesktop.UPower=none\n[Environment]\nLD_PRELOAD=x\n"
                    "[Extension org.example.App.Locale]\ndirectory=share/runtime/locale\n[Extra Data]\nuri=https://example.org\n"),
              QStringList());
    EXPECT_EQ(reach("filesystems=!host;!home;!xdg-download;\ndevices=!all;"), QStringList()) << "taken away, not granted";

    // The review's cases (PR #58): each named.
    const auto service = [](const char *name) { return QStringLiteral("sessionService:") + QLatin1String(name); };
    for (const char *escape : {"org.freedesktop.systemd1", "org.freedesktop.impl.portal.PermissionStore", "org.freedesktop.Flatpak"}) {
        EXPECT_EQ(reach({}, "[Session Bus Policy]\n" + QByteArray(escape) + "=talk\n"), (QStringList{QStringLiteral("outside"), service(escape)}))
            << escape;
        EXPECT_EQ(reach({}, "[Session Bus Policy]\n" + QByteArray(escape) + "=own\n"), (QStringList{QStringLiteral("outside"), service(escape)}))
            << escape;
    }
    EXPECT_EQ(reach({}, "[Session Bus Policy]\norg.freedesktop.*=talk\n"), (QStringList{QStringLiteral("outside"), service("org.freedesktop.*")}))
        << "a wildcard covering org.freedesktop.Flatpak";
    // The escapes before its own names (PR #58's merge note): an app named like one is not harmless for it.
    EXPECT_EQ(flatpakAccess("[Application]\nname=org.freedesktop.systemd1\n[Session Bus Policy]\norg.freedesktop.systemd1=talk\n"),
              (QStringList{QStringLiteral("outside"), service("org.freedesktop.systemd1")}));
    EXPECT_EQ(flatpakAccess("[Application]\nname=org.freedesktop.impl\n[Session Bus Policy]\norg.freedesktop.impl.*=own\n"),
              (QStringList{QStringLiteral("outside"), service("org.freedesktop.impl.*")}));
    // "X.*" is X and every name below it (xdg-dbus-proxy); an id that is an escape, or holds one, owns it (PR #65).
    for (const char *escape : {"org.freedesktop.Flatpak", "org.freedesktop.systemd1", "org.freedesktop.impl.portal.PermissionStore"}) {
        const QByteArray rule = QByteArray(escape) + ".*";
        EXPECT_EQ(reach({}, "[Session Bus Policy]\n" + rule + "=talk\n"), (QStringList{QStringLiteral("outside"), service(rule.constData())})) << rule.constData();
        EXPECT_EQ(flatpakAccess("[Application]\nname=" + QByteArray(escape) + "\n"), QStringList{QStringLiteral("outside")}) << escape;
        EXPECT_EQ(flatpakAccess("[Application]\nname=" + QByteArray(escape) + "\n[Session Bus Policy]\n" + rule + "=own\n"),
                  (QStringList{QStringLiteral("outside"), service(rule.constData())}))
            << escape;
    }
    EXPECT_EQ(flatpakAccess("[Application]\nname=org.freedesktop.impl.portal\n"), QStringList{QStringLiteral("outside")}) << "above the permission store";
    EXPECT_EQ(flatpakAccess("[Application]\nname=org.freedesktop.FlatpakTools\n"), QStringList()) << "only starts like one";
    EXPECT_EQ(flatpakAccess("[Application]\nname=org.freedesktop.Flat\n"), QStringList()) << "only the start of one";
    EXPECT_EQ(reach({}, "[Session Bus Policy]\norg.freedesktop.Flat.*=talk\n"), QStringList{service("org.freedesktop.Flat.*")});

    // Where programs start at the next login, writable: a line of its own (autostart, systemd user units, Hyprland's,
    // uwsm's and Omarchy's configuration, environment.d, the shells' start files, ~/.local/bin; PR #65: paths read as
    // flatpak reads them, S29). A folder above flatpak's own, the D-Bus services or the launcher's entries (xdg-data, home,
    // host) reaches outside its sandbox too.
    const auto with = [](const char *first, std::initializer_list<const char *> more) {
        QStringList out{QLatin1String(first)};
        for (const char *m : more)
            out.append(QLatin1String(m));
        return out;
    };
    for (const char *grant : {"xdg-config/autostart", "xdg-config/autostart:create", "xdg-config", "xdg-config/", "~/.config", "~/.config/systemd/user:rw",
                              "~/.config/autostart/app.desktop", "/home/alice/.config", "~/.config//autostart", "~/./.config/autostart",
                              "xdg-config/./autostart", "~/.config/autostart/.", "~/.config/hypr", "xdg-config/hypr/hyprland.conf", "xdg-config/uwsm",
                              "xdg-config/environment.d", "~/.config/fish", "xdg-data/systemd/user", "~/.local/share/systemd", "~/.local/bin", "~/.bashrc",
                              "~/.bash_profile", "~/.bash_login", "~/.profile", "~/.zshrc", "~/.zshenv", "/var/home/alice/.zprofile", "~/.zlogin",
                              "~/.config/omarchy", "xdg-config/omarchy/hooks/post-boot", "xdg-config/autostar\\\\t", "xdg-config/autos\\\\tart:rw",
                              "xdg-config/autostart/app\\\\:ro"})
        EXPECT_EQ(reach("filesystems=" + QByteArray(grant) + ";"), with("folders", {"login"})) << grant;
    for (const char *grant : {"xdg-config/autostart:ro", "xdg-config:ro", "xdg-config/gtk-3.0", "~/.config/other", "/homework", "/home/alice/Music",
                              "xdg-data/applications:ro", "~/.local/share/fonts", "~/.bashrc.d.old", "/run/media", "/run/media/alice/Disk", "/var/run/media",
                              "~/.config/hyprland-themes", "~/.config/omarchy:ro", "xdg-config/autostar\\\\t:ro", "~/a\\\\:b:ro", "xdg-download\\;host"})
        EXPECT_EQ(reach("filesystems=" + QByteArray(grant) + ";"), with("folders", {})) << grant;
    for (const char *grant : {"xdg-data", "xdg-data/", "~/.local", "/home/alice/.local/share", "~/Documents/../.bashrc"})
        EXPECT_EQ(reach("filesystems=" + QByteArray(grant) + ";"), with("folders", {"login", "outside"})) << grant;
    for (const char *grant : {"home", "home/", "home/.", "home//", "~/", "~/.", "~//", "/home/alice", "/var/home", "/home", "ho\\\\me"})
        EXPECT_EQ(reach("filesystems=" + QByteArray(grant) + ";"), with("home", {"login", "outside"})) << grant;
    EXPECT_EQ(reach("filesystems=home:ro;"), with("home", {}));
    for (const char *grant : {"host", "host/", "host/.", "host//", "ho\\\\st", "\\\\host"})
        EXPECT_EQ(reach("filesystems=" + QByteArray(grant) + ";"), with("allFiles", {"login", "outside"})) << "host mounts the home folders, not /run: " << grant;
    for (const char *grant : {"host-os", "host-os/", "host-os/.", "host-os//", "host-etc", "host-etc/", "host-etc/.", "host-etc//:ro"})
        EXPECT_EQ(reach("filesystems=" + QByteArray(grant) + ";"), QStringList{QStringLiteral("allFiles")}) << grant;
    // Past its sandbox: anything in the runtime folder but the sound server's sockets and its own folder (the session
    // bus, systemd, Hyprland's IPC, docker; read-only too), the system's /run but removable media, /var/run as /run;
    // flatpak's own folder, the session's D-Bus services or the launcher's entries written.
    for (const char *grant : {"xdg-run/bus", "xdg-run/bus:ro", "xdg-run/systemd", "xdg-run/systemd/private", "xdg-run", "xdg-run/", "/run/user/1000/bus",
                              "/run/user", "/var/run/user/1000/bus", "/var/run", "/run", "xdg-run/hypr", "xdg-run/hypr:ro", "xdg-run/docker.sock",
                              "xdg-run/pipewire-0-manager", "xdg-run/app", "xdg-run/app/org.example.Other", "xdg-run/bu\\\\s", "/run/dbus",
                              "/run/dbus/system_bus_socket", "/var/run/dbus", "/run/docker.sock", "xdg-data/flatpak", "xdg-data/flatpak/overrides:create",
                              "~/.local/share/flatpak/overrides", "xdg-data/dbus-1/services", "~/.local/share/dbus-1", "xdg-data/applications",
                              "~/.local/share/applications/org.example.Browser.desktop:create"})
        EXPECT_EQ(reach("filesystems=" + QByteArray(grant) + ";"), with("folders", {"outside"})) << grant;
    for (const char *grant : {"xdg-data/flatpak:ro", "xdg-data/dbus-1:ro", "~/.local/share/applications:ro", "xdg-run/pipewire-0", "xdg-run/pulse",
                              "xdg-run/pulse/native", "xdg-run/app/org.example.App", "xdg-run/app/org.example.App/tmp"})
        EXPECT_EQ(reach("filesystems=" + QByteArray(grant) + ";"), with("folders", {})) << grant;
    EXPECT_EQ(reach("filesystems=~/Documents/../x:ro;"), with("folders", {"outside"})) << "it could be the runtime folder's sockets";
    EXPECT_EQ(reach("filesystems=~/My\\sGames;~/Tab\\tbed;~/Line\\nbreak;~/Car\\rriage;"), with("folders", {})) << "GLib's own escapes";
    // A value flatpak cannot interpret (an escape GLib does not know, or one at the end): what it may reach is unknown.
    for (const QByteArray &value : {QByteArray("filesystems=host;b\\qc;"), QByteArray("filesystems=xdg-run/bus;home\\"), QByteArray("sockets=x11;b\\qc;")})
        EXPECT_EQ(reach(value), QStringList{QStringLiteral("(unread)")}) << value.constData();
    EXPECT_EQ(reach({}, "[Session Bus Policy]\norg.freedesktop.secrets=talk\norg.gtk.vfs.*=talk\nca.desrt.dconf=talk\norg.example.AppX=own\n"
                        "org.example.Other=frobnicate\n"),
              (QStringList{service("ca.desrt.dconf"), service("org.example.AppX"), service("org.example.Other"), service("org.freedesktop.secrets"),
                           service("org.gtk.vfs.*")}))
        << "every name outside the harmless ones, sorted; a name that only starts like its id is not its own";
    EXPECT_EQ(reach({}, "[Session Bus Policy]\norg.freedesktop.portal.Desktop=own\norg.freedesktop.Notifications=own\norg.mpris.MediaPlayer2.App=own\n"),
              (QStringList{service("org.freedesktop.Notifications"), service("org.freedesktop.portal.Desktop")}))
        << "the portals and the notifications are harmless to talk to, not to own (PR #65)";
    EXPECT_EQ(reach({}, "[System Bus Policy]\norg.freedesktop.login1=talk\norg.freedesktop.systemd1=talk\norg.freedesktop.Notifications=talk\n"),
              (QStringList{QStringLiteral("systemService:org.freedesktop.Notifications"), QStringLiteral("systemService:org.freedesktop.login1"),
                           QStringLiteral("systemService:org.freedesktop.systemd1")}))
        << "the system bus has no harmless names";
    EXPECT_EQ(reach("sockets=ssh-auth;gpg-agent;pcsc;cups;system-bus;"),
              (QStringList{QStringLiteral("printers"), QStringLiteral("ssh"), QStringLiteral("gpg"), QStringLiteral("smartCards"), QStringLiteral("systemBus")}));
    EXPECT_EQ(reach("sockets=session-bus;"), (QStringList{QStringLiteral("bus"), QStringLiteral("outside")}))
        << "the whole session bus reaches org.freedesktop.Flatpak";
    EXPECT_EQ(reach("devices=kvm;shm;input;usb;"),
              (QStringList{QStringLiteral("input"), QStringLiteral("usb"), QStringLiteral("kvm"), QStringLiteral("sharedMemory")}));
    EXPECT_EQ(reach("features=devel;multiarch;canbus;"), (QStringList{QStringLiteral("canbus"), QStringLiteral("devel"), QStringLiteral("multiarch")}));
    EXPECT_EQ(reach({}, "[USB Devices]\nenumerable-devices=vnd:1234+dev:5678;\nhidden-devices=all;\n"), QStringList{QStringLiteral("usb")});
    EXPECT_EQ(reach({}, "[USB Devices]\nhidden-devices=all;\n"), QStringList());

    // A grant the Store does not know: a line of its own, as flatpak writes it.
    EXPECT_EQ(reach("sockets=wayland;tpm;\ndevices=tpm;\nfeatures=newfeature;\nshared=newns;\nnewkey=a;b;a;",
                    "[Policy portal]\nkey=v1;v2\n[Some Later Group]\nx=y\n[USB Devices]\nhid=1\n[Session Bus Policy]\nnot a name!=talk\n"),
              (QStringList{QStringLiteral("other:sockets=tpm"), QStringLiteral("other:devices=tpm"), QStringLiteral("other:features=newfeature"),
                           QStringLiteral("other:shared=newns"), QStringLiteral("other:newkey=a"), QStringLiteral("other:newkey=b"),
                           QStringLiteral("other:[Policy portal] key=v1;v2"), QStringLiteral("other:[Some Later Group] x=y"),
                           QStringLiteral("other:[USB Devices] hid=1"), QStringLiteral("other:[Session Bus Policy] not a name!=talk")}));
    // A bus name before [Application]: its own names are still its own.
    EXPECT_EQ(flatpakAccess("[Session Bus Policy]\norg.example.App.Tray=own\n[Application]\nname=org.example.App\n"), QStringList());

    // At most 30 lines: the named classes first, the rest counted.
    QByteArray many = "[Session Bus Policy]\n";
    for (int i = 10; i < 50; ++i)
        many += "org.example.Service" + QByteArray::number(i) + "=talk\n";
    const QStringList capped = reach("sockets=session-bus;ssh-auth;", many);
    ASSERT_EQ(capped.size(), 30);
    EXPECT_EQ(capped.mid(0, 3), (QStringList{QStringLiteral("ssh"), QStringLiteral("bus"), QStringLiteral("outside")}));
    EXPECT_EQ(capped.at(3), service("org.example.Service10"));
    EXPECT_EQ(capped.last(), QStringLiteral("more:14"));

    // Not an app's metadata: unknown, never "nothing".
    EXPECT_EQ(flatpakAccess({}), std::nullopt);
    EXPECT_EQ(flatpakAccess("[Context]\nshared=network;\n"), std::nullopt);
    EXPECT_EQ(flatpakAccess("[Application]\nname=notanid\n"), std::nullopt);
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
    EXPECT_EQ(plan.access, (QStringList{QStringLiteral("network"), QStringLiteral("audio"), QStringLiteral("x11"), QStringLiteral("sharedMemory")}));
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
                                      "case \"$1\" in remote-info) printf '[Application]\\nname=org.example.Slow\\n' ;; install) sleep 30 & echo $! >'"
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

// Metadata that could not be read, or that names no app: no access said on the page, and no plan (PR #58).
TEST(Flatpak, MetadataUnread)
{
    const QString ref = QStringLiteral("app/org.example.App/x86_64/stable");
    for (const char *metadata : {"exit 1", "printf '[Context]\\nshared=network;\\n'", "printf '[Application]\\nname=org.example.App\\n'"}) {
        QTemporaryDir dir;
        FlatpakTools tools;
        // flatpak's plan itself is complete: only the metadata can refuse it.
        tools.flatpak = storetest::script(dir.filePath(QStringLiteral("flatpak")),
                                          "case \"$1 $3\" in\n"
                                          "  'remote-info --show-metadata') " + QByteArray(metadata) + " ;;\n"
                                          "  'remote-info flathub') printf 'Ref: app/org.example.App/x86_64/stable\\nVersion: 1\\n' ;;\n"
                                          "  'install flathub') cat '" STORE_FIXTURES "/flatpak/plan-table.txt'\n"
                                          "    printf 'Proceed with these changes to the user installation? [Y/n]: '; read b; exit 1 ;;\n"
                                          "esac");
        const std::optional<FlatpakFacts> facts = flatpakFacts(tools, ref, false);
        ASSERT_TRUE(facts) << metadata;
        EXPECT_EQ(facts->version, QStringLiteral("1"));
        const InstallPlan plan = checkFlatpakInstall(ref, tools, true);
        if (QByteArray(metadata).contains("name=")) {
            EXPECT_EQ(facts->access, QStringList()) << "read, and nothing granted";
            EXPECT_EQ(plan.refusal, Refusal::None) << plan.detail.toStdString();
            EXPECT_EQ(plan.access, QStringList());
        } else {
            EXPECT_EQ(facts->access, std::nullopt) << metadata;
            EXPECT_EQ(plan.refusal, Refusal::Failed) << metadata;
            EXPECT_TRUE(plan.packages.isEmpty());
        }
    }
}

// A runtime flatpak asks for is said yes to eight times at most: a ninth question is another kind (refused, no to all).
TEST(Flatpak, RuntimesAtMostEight)
{
    const QByteArray fixtures = STORE_FIXTURES "/flatpak";
    for (const int asked : {8, 9}) {
        QTemporaryDir dir;
        const QByteArray d = dir.path().toUtf8();
        FlatpakTools tools;
        tools.flatpak = storetest::script(dir.filePath(QStringLiteral("flatpak")),
                                          "case \"$1\" in\n"
                                          "  remote-info) cat '" + fixtures + "/metadata.txt' ;;\n"
                                          "  install)\n"
                                          "    i=0; while [ $i -lt " + QByteArray::number(asked) + " ]; do i=$((i + 1))\n"
                                          "      echo \"Required runtime for org.example.Many/x86_64/stable (runtime/org.example.R$i/x86_64/1) found in remote flathub\"\n"
                                          "      printf 'Do you want to install it? [Y/n]: '; read a; echo \"$a\" >>'" + d + "/answers'\n"
                                          "    done\n"
                                          "    cat '" + fixtures + "/plan-table.txt'\n"
                                          "    printf 'Proceed with these changes to the user installation? [Y/n]: '; read b; echo \"$b\" >>'" + d + "/answers'\n"
                                          "    exit 1 ;;\n"
                                          "esac");
        const InstallPlan plan = checkFlatpakInstall(QStringLiteral("app/org.example.Many/x86_64/stable"), tools, true);
        if (asked == 8) {
            EXPECT_EQ(plan.refusal, Refusal::None) << plan.detail.toStdString();
            EXPECT_EQ(readAll(dir.filePath(QStringLiteral("answers"))), QByteArray("y\n").repeated(8) + "n\n");
        } else {
            EXPECT_EQ(plan.refusal, Refusal::Failed);
            EXPECT_EQ(readAll(dir.filePath(QStringLiteral("answers"))), QByteArray("y\n").repeated(8) + "n\nn\n");
        }
    }
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
    EXPECT_EQ(plan.access, (QStringList{QStringLiteral("network"), QStringLiteral("home"), QStringLiteral("audio"), QStringLiteral("login"),
                                        QStringLiteral("outside")}));
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
    EXPECT_EQ(after->access, (QStringList{QStringLiteral("network"), QStringLiteral("home"), QStringLiteral("audio"), QStringLiteral("login"),
                                          QStringLiteral("outside")}))
        << "its home folder, writable, holds where programs start at login, and flatpak's own folder";

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

// Step 4 with the real flatpak (tests/integration/store_flatpak.sh, after RealFlatpak: Hello 1.2 installed by flatpak itself,
// then 1.3 published, with the same metadata): the Store's check names its ref, the update adds nothing it can reach, the
// Store's own command updates it (operations.cpp: update --user --noninteractive -- <ref>), and the check no longer names it.
TEST(Flatpak, RealUpdate)
{
    if (qEnvironmentVariable("STORE_TEST_FLATPAK_UPDATE") != QLatin1String("1"))
        GTEST_SKIP() << "tests/integration/store_flatpak.sh runs it in a throwaway container";
    storetest::ensureApp();
    FlatpakTools tools;
    tools.env = flatpakEnvironment();
    const QString ref = QStringLiteral("app/org.example.Hello/x86_64/stable");
    const std::optional<QList<FlatpakUpdate>> before = listFlatpakUpdates(tools);
    ASSERT_TRUE(before);
    ASSERT_TRUE(std::any_of(before->cbegin(), before->cend(), [&ref](const FlatpakUpdate &u) { return u.ref == ref && u.app && u.origin == kFlathubRemote; }))
        << "Hello 1.3 on the repository";
    const std::optional<QStringList> added = flatpakAccessAdded(tools, ref);
    ASSERT_TRUE(added);
    EXPECT_TRUE(added->isEmpty()) << added->join(QLatin1Char(',')).toStdString();
    ChildOptions options;
    options.timeoutMs = 120000;
    options.extraEnv = tools.env;
    const ChildResult r = runChild(tools.flatpak, {QStringLiteral("update"), QStringLiteral("--user"), QStringLiteral("--noninteractive"),
                                                   QStringLiteral("--"), ref},
                                   options);
    EXPECT_EQ(r.exitCode, 0) << r.out.toStdString() << r.err.toStdString();
    EXPECT_GE(flatpakSteps(r.out, true), 1) << r.out.toStdString();
    const std::optional<QList<FlatpakUpdate>> after = listFlatpakUpdates(tools);
    ASSERT_TRUE(after);
    EXPECT_TRUE(std::none_of(after->cbegin(), after->cend(), [&ref](const FlatpakUpdate &u) { return u.ref == ref; }));
}
