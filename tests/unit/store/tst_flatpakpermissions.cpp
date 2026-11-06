// A Flatpak's grants and what an update changes in them (ADR-0049, amending ADR-0037 SD25 and SD33): the metadata's
// [Context], bus policies and conditional grants read as flatpak reads them, malformed and oversized metadata unread, long
// lists cut and counted, and each change classified added, widened, removed or narrowed. The flat list these grants give
// (flatpakAccess) keeps its own cases in tst_flatpak.cpp WhatItCanReach.
#include "flatpak.h"
#include "flatpakpermissions.h"
#include "storetest.h"
#include "storeview.h"

#include <gtest/gtest.h>

using namespace grassfield::store;

namespace {

QByteArray app(const QByteArray &context, const QByteArray &more = {}, const QByteArray &id = "org.example.App")
{
    return "[Application]\nname=" + id + "\nruntime=org.example.Platform/x86_64/1\n\n[Context]\n" + context + "\n" + more;
}

// The grants as "<key>[ <name> <level>]" lines: the level only for a place or a name.
QStringList lines(const std::optional<FlatpakPermissions> &p)
{
    if (!p)
        return {QStringLiteral("(unread)")};
    QStringList out;
    for (const FlatpakGrant &g : p->grants) {
        QString line = g.key;
        if (!g.name.isEmpty())
            line += QLatin1Char(' ') + g.name + QLatin1Char(' ') + QString::number(g.level);
        out.append(line);
    }
    if (p->more > 0)
        out.append(QStringLiteral("more %1").arg(p->more));
    return out;
}

QStringList changes(const QByteArray &before, const QByteArray &after)
{
    // As flatpakPermissionChanges reads them: the installed side narrowest, the newer widest.
    const std::optional<FlatpakPermissions> b = flatpakPermissions(before, FlatpakReading::Narrowest), a = flatpakPermissions(after);
    if (!b || !a)
        return {QStringLiteral("(unread)")};
    QStringList out;
    for (const FlatpakPermissionChange &c : diffFlatpakPermissions(*b, *a)) {
        QString line = changeKindName(c.kind) + QLatin1Char(' ') + c.grant.key;
        if (!c.grant.name.isEmpty())
            line += QLatin1Char(' ') + c.grant.name;
        if (!c.previous.key.isEmpty())
            line += QStringLiteral(" from ") + (c.previous.name.isEmpty() ? c.previous.key : c.previous.name) + QLatin1Char('/')
                + QString::number(c.previous.level);
        out.append(line);
    }
    return out;
}

bool asks(const QByteArray &before, const QByteArray &after)
{
    return asksForMore(diffFlatpakPermissions(*flatpakPermissions(before, FlatpakReading::Narrowest), *flatpakPermissions(after)));
}

} // namespace

// A browser as Flathub's commonly declare themselves: each grant once, places with their mode, names sorted, the harmless
// names left out; the flat list is the same parse's.
TEST(FlatpakPermissions, Browser)
{
    const QByteArray metadata = storetest::readFixture(QStringLiteral("flatpak/browser-metadata.txt"));
    ASSERT_FALSE(metadata.isEmpty());
    const std::optional<FlatpakPermissions> p = flatpakPermissions(metadata);
    ASSERT_TRUE(p);
    EXPECT_EQ(p->appId, QStringLiteral("org.example.Browser"));
    EXPECT_EQ(lines(p), (QStringList{QStringLiteral("network"), QStringLiteral("folders $RUN/pipewire-0 2"),
                                     QStringLiteral("folders /run/.heim_org.h5l.kcm-socket 2"), QStringLiteral("folders xdg-download 2"),
                                     QStringLiteral("devices"), QStringLiteral("audio"), QStringLiteral("x11Fallback"), QStringLiteral("ipc"),
                                     QStringLiteral("printers"), QStringLiteral("smartCards"), QStringLiteral("outside"),
                                     QStringLiteral("sessionService org.gtk.vfs.* 1"), QStringLiteral("systemService org.freedesktop.NetworkManager 1")}));
    EXPECT_EQ(p->access, (QStringList{QStringLiteral("network"), QStringLiteral("folders"), QStringLiteral("devices"), QStringLiteral("audio"),
                                      QStringLiteral("x11"), QStringLiteral("sharedMemory"), QStringLiteral("printers"), QStringLiteral("smartCards"),
                                      QStringLiteral("outside"), QStringLiteral("sessionService:org.gtk.vfs.*"),
                                      QStringLiteral("systemService:org.freedesktop.NetworkManager")}));
    EXPECT_EQ(flatpakAccess(metadata), p->access);
    // x11 beside fallback-x11 is X11 only where Wayland is missing (flatpak 1.17's flatpak_context_compute_allowed_sockets):
    // the grant is the fallback; the flat list keeps SD25's x11.
}

// Places: read only (ro) 1, read and write (rw, none said) 2, create 3 (flatpak's ranking), the most of one place kept; host, the home folder and
// the user folders by their words; nothing granted for a place taken away.
TEST(FlatpakPermissions, Places)
{
    EXPECT_EQ(lines(flatpakPermissions(app("filesystems=xdg-download:ro;xdg-music;~/Games:create;xdg-pictures:rw;"))),
              (QStringList{QStringLiteral("folders xdg-download 1"), QStringLiteral("folders xdg-music 2"), QStringLiteral("folders xdg-pictures 2"),
                           QStringLiteral("folders ~/Games 3")}));
    EXPECT_EQ(lines(flatpakPermissions(app("filesystems=xdg-download:ro;xdg-download;xdg-download:ro;"))), QStringList{QStringLiteral("folders xdg-download 2")})
        << "the most of one place";
    EXPECT_EQ(lines(flatpakPermissions(app("filesystems=xdg-download:ro;xdg-download;xdg-download:ro;"), FlatpakReading::Narrowest)),
              QStringList{QStringLiteral("folders xdg-download 1")})
        << "narrowest: the last, as flatpak's table keeps it";
    EXPECT_EQ(lines(flatpakPermissions(app("filesystems=host:ro;home:ro;host-os:ro;host-etc;"))),
              (QStringList{QStringLiteral("allFiles / 1"), QStringLiteral("allFiles host-etc 2"), QStringLiteral("allFiles host-os 1"),
                           QStringLiteral("home ~ 1")}));
    EXPECT_EQ(lines(flatpakPermissions(app("filesystems=home;"))), (QStringList{QStringLiteral("home ~ 2"), QStringLiteral("login"), QStringLiteral("outside")}));
    EXPECT_EQ(lines(flatpakPermissions(app("filesystems=!home;!host;\ndevices=!all;"))), QStringList());
    EXPECT_EQ(lines(flatpakPermissions(app("filesystems=~/Documents/../x:ro;"))), (QStringList{QStringLiteral("folders * 1"), QStringLiteral("outside")}));
}

// Bus names: talk 1, own 2 (a policy the Store does not know counts as own), the most of one name kept; its own names,
// media-player names and the harmless ones to talk to left out; the whole session bus is "outside".
TEST(FlatpakPermissions, BusNames)
{
    EXPECT_EQ(lines(flatpakPermissions(app({}, "[Session Bus Policy]\norg.example.B=talk\norg.example.A=own\norg.example.B=own\norg.example.C=frobnicate\n"
                                               "org.example.App.Tray=own\norg.freedesktop.Notifications=talk\norg.example.D=see\n"
                                               "[System Bus Policy]\norg.freedesktop.login1=talk\n"))),
              (QStringList{QStringLiteral("sessionService org.example.A 2"), QStringLiteral("sessionService org.example.B 2"),
                           QStringLiteral("sessionService org.example.C 2"), QStringLiteral("systemService org.freedesktop.login1 1")}));
    EXPECT_EQ(lines(flatpakPermissions(app("sockets=session-bus;system-bus;"))),
              (QStringList{QStringLiteral("bus"), QStringLiteral("systemBus"), QStringLiteral("outside")}));
}

// flatpak 1.17's conditional grants: the plain line before them is only for older flatpaks; Grassfield's session is
// Wayland, flatpak 1.17 always has the input and USB permissions, the USB portal (or an unknown condition) is granted.
TEST(FlatpakPermissions, ConditionalGrants)
{
    EXPECT_EQ(lines(flatpakPermissions(storetest::readFixture(QStringLiteral("flatpak/conditional-metadata.txt")))),
              (QStringList{QStringLiteral("network"), QStringLiteral("input"), QStringLiteral("audio"), QStringLiteral("x11Fallback"),
                           QStringLiteral("bluetooth")}));
    EXPECT_EQ(lines(flatpakPermissions(app("sockets=x11;if:x11:!has-wayland;"))), QStringList{QStringLiteral("x11Fallback")})
        << "only where Wayland is missing";
    EXPECT_EQ(lines(flatpakPermissions(app("sockets=fallback-x11;"))), QStringList{QStringLiteral("x11Fallback")});
    EXPECT_EQ(lines(flatpakPermissions(app("sockets=x11;fallback-x11;"))), QStringList{QStringLiteral("x11Fallback")})
        << "fallback-x11 makes x11 itself conditional (flatpak_context_compute_allowed_sockets)";
    EXPECT_EQ(lines(flatpakPermissions(app("sockets=wayland;x11;"))), QStringList{QStringLiteral("x11")});
    EXPECT_EQ(lines(flatpakPermissions(app("sockets=if:x11:true;"))), QStringList{QStringLiteral("x11")});
    EXPECT_EQ(lines(flatpakPermissions(app("sockets=x11;if:x11:false;"))), QStringList());
    EXPECT_EQ(lines(flatpakPermissions(app("sockets=if:x11:false;x11;"))), QStringList{QStringLiteral("x11")}) << "a plain grant after its conditions";
    EXPECT_EQ(lines(flatpakPermissions(app("sockets=x11;if:x11:false;if:x11:has-wayland;"))), QStringList{QStringLiteral("x11")}) << "any condition met";
    EXPECT_EQ(lines(flatpakPermissions(app("devices=usb;if:usb:!has-usb-device;all;if:all:has-usb-portal;"))),
              (QStringList{QStringLiteral("devices")}))
        << "usb's compatibility line reverted, all granted where the USB portal may be";
    EXPECT_EQ(lines(flatpakPermissions(app("shared=if:network:!has-wayland;\nfeatures=if:devel:something-new;"))), QStringList{QStringLiteral("devel")})
        << "only where Wayland is missing: never in Grassfield's session; an unknown condition: granted";
    EXPECT_EQ(lines(flatpakPermissions(app("shared=if:network:!has-wayland;\nfeatures=if:devel:something-new;\ndevices=if:usb:has-usb-portal;"),
                                       FlatpakReading::Narrowest)),
              QStringList())
        << "narrowest: a condition the Store cannot check grants nothing";
    EXPECT_EQ(lines(flatpakPermissions(app("sockets=if:x11;if::true;if:!x11:true;"))),
              (QStringList{QStringLiteral("other sockets=if:x11 1"), QStringLiteral("other sockets=if::true 1"), QStringLiteral("other sockets=if:!x11:true 1")}))
        << "malformed: named as written";
}

// Malformed metadata: unread (never "nothing"), or the lines it cannot read left out, never a crash.
TEST(FlatpakPermissions, Malformed)
{
    EXPECT_FALSE(flatpakPermissions({}));
    EXPECT_FALSE(flatpakPermissions("[Context]\nshared=network;\n")) << "no app";
    EXPECT_FALSE(flatpakPermissions("[Application]\nname=../../etc\n")) << "not a Flatpak id";
    EXPECT_FALSE(flatpakPermissions(app("filesystems=home\\"))) << "an escape at the end";
    EXPECT_FALSE(flatpakPermissions(app("sockets=x\\q;"))) << "an escape GLib does not know";
    QByteArray binary(4096, '\0');
    for (int i = 0; i < binary.size(); ++i)
        binary[i] = char((i * 37 + 11) & 0xff);
    EXPECT_FALSE(flatpakPermissions(binary));
    EXPECT_EQ(lines(flatpakPermissions(app("shared=network;", "no equals sign here\n=nokey\n[\n[Context\nsockets=x11;\n"))),
              (QStringList{QStringLiteral("network"), QStringLiteral("x11")}))
        << "lines without a key and a broken group header are skipped; the lines after it stay in their group";
    EXPECT_EQ(lines(flatpakPermissions(app("shared=network;", "[]\nsockets=x11;\n"))),
              (QStringList{QStringLiteral("network"), QStringLiteral("other [] sockets=x11; 1")}))
        << "a group without a name is a group the Store does not know: named as written";
    EXPECT_EQ(lines(flatpakPermissions(app("filesystems=:ro;\nsockets=;;;"))), QStringList{QStringLiteral("other filesystems=:ro 1")});
    // Larger than kMaxFlatpakMetadata: unread.
    QByteArray huge = app("shared=network;");
    huge += "[Session Bus Policy]\n";
    while (huge.size() <= kMaxFlatpakMetadata)
        huge += "org.example.Padding" + QByteArray::number(huge.size()) + "=talk\n";
    EXPECT_FALSE(flatpakPermissions(huge));
    // UTF-8 in a path is kept; a bus name with characters D-Bus forbids is named as written.
    EXPECT_EQ(lines(flatpakPermissions(app("filesystems=~/Musique/Été;", "[Session Bus Policy]\norg.exämple=talk\n"))),
              (QStringList{QStringLiteral("folders ~/Musique/Été 2"), QStringLiteral("other [Session Bus Policy] org.exämple=talk 1")}));
}

// Very long lists: at most kMaxFlatpakGrants grants, the rest counted; the flat list at most 30 lines; one parse of
// near the largest metadata in reasonable time.
TEST(FlatpakPermissions, LongLists)
{
    QByteArray many = "[Session Bus Policy]\n";
    for (int i = 0; i < 5000; ++i)
        many += "org.example.Service" + QByteArray::number(10000 + i) + "=talk\n";
    QByteArray folders = "filesystems=";
    for (int i = 0; i < 3000; ++i)
        folders += "~/Folder" + QByteArray::number(10000 + i) + ";";
    const std::optional<FlatpakPermissions> p = flatpakPermissions(app("shared=network;\n" + folders, many));
    ASSERT_TRUE(p);
    EXPECT_EQ(p->grants.size(), kMaxFlatpakGrants);
    EXPECT_EQ(p->more, 1 + 3000 + 5000 - kMaxFlatpakGrants);
    EXPECT_EQ(p->grants.first().key, QStringLiteral("network")) << "the classes first";
    ASSERT_EQ(p->access.size(), 30);
    EXPECT_EQ(p->access.mid(0, 2), (QStringList{QStringLiteral("network"), QStringLiteral("folders")}));
    EXPECT_EQ(p->access.last(), QStringLiteral("more:%1").arg(2 + 5000 - 29));
    // The view: the grants, then the count.
    const QVariantList v = view::permissions(p->grants, p->more);
    ASSERT_EQ(v.size(), kMaxFlatpakGrants + 1);
    EXPECT_EQ(v.last().toMap().value(QStringLiteral("key")).toString(), QStringLiteral("more"));
    EXPECT_EQ(v.last().toMap().value(QStringLiteral("name")).toString(), QString::number(p->more));
    // A diff of two such lists is bounded too (and asks: the cut cannot be compared).
    const QList<FlatpakPermissionChange> d = diffFlatpakPermissions(*p, *p);
    ASSERT_EQ(d.size(), 1);
    EXPECT_EQ(d.first().grant.key, QStringLiteral("more"));
    EXPECT_TRUE(asksForMore(d));
    const QVariantList cv = view::permissionChanges(QList<FlatpakPermissionChange>(100, d.first()), 64);
    ASSERT_EQ(cv.size(), 65);
    EXPECT_EQ(cv.last().toMap().value(QStringLiteral("change")).toString(), QStringLiteral("more"));
    EXPECT_EQ(cv.last().toMap().value(QStringLiteral("name")).toString(), QStringLiteral("36"));
}

// What an update changes, the five kinds of each: a place, a mode, a name, a policy, a kind of device; as pessimistic as
// flatpak's own flatpak_context_adds_permissions (a folder inside one it had is new).
TEST(FlatpakPermissions, UpdateChanges)
{
    EXPECT_EQ(changes(storetest::readFixture(QStringLiteral("flatpak/update-before.txt")), storetest::readFixture(QStringLiteral("flatpak/update-after.txt"))),
              (QStringList{QStringLiteral("added folders ~/Projects/notes"), QStringLiteral("widened folders xdg-documents from xdg-documents/1"),
                           QStringLiteral("widened devices from input/1"), QStringLiteral("widened sessionService org.example.* from org.example.Helper/1"),
                           QStringLiteral("widened sessionService org.freedesktop.secrets from org.freedesktop.secrets/1"), QStringLiteral("removed network"),
                           QStringLiteral("removed folders xdg-download"), QStringLiteral("removed folders ~/Projects")}));
    EXPECT_TRUE(asks(storetest::readFixture(QStringLiteral("flatpak/update-before.txt")), storetest::readFixture(QStringLiteral("flatpak/update-after.txt"))));
    // The other way.
    EXPECT_EQ(changes(storetest::readFixture(QStringLiteral("flatpak/update-after.txt")), storetest::readFixture(QStringLiteral("flatpak/update-before.txt"))),
              (QStringList{QStringLiteral("added network"), QStringLiteral("added folders xdg-download"), QStringLiteral("added folders ~/Projects"),
                           QStringLiteral("removed folders ~/Projects/notes"), QStringLiteral("narrowed folders xdg-documents from xdg-documents/2"),
                           QStringLiteral("narrowed input from devices/1"), QStringLiteral("narrowed sessionService org.example.Helper from org.example.*/1"),
                           QStringLiteral("narrowed sessionService org.freedesktop.secrets from org.freedesktop.secrets/2")}));

    // Nothing changes: the same metadata, a grant moved, places host holds, x11's fallback where it had x11.
    const QByteArray base = app("shared=network;\nfilesystems=home;xdg-download:ro;");
    EXPECT_EQ(changes(base, base), QStringList());
    EXPECT_EQ(changes(base, app("filesystems=xdg-download:ro;home;\nshared=network;")), QStringList());
    EXPECT_EQ(changes(app("filesystems=host;"), app("filesystems=host;~/Documents;xdg-download;/opt/data;")), QStringList()) << "host holds them";
    EXPECT_EQ(changes(app("sockets=x11;"), app("sockets=fallback-x11;")), QStringList{QStringLiteral("narrowed x11Fallback from x11/1")})
        << "x11 to its fallback is less (flatpak: \"also allow new fallback X11\")";
    EXPECT_FALSE(asks(app("sockets=x11;"), app("sockets=fallback-x11;")));
    EXPECT_FALSE(asks(base, base));

    // The review's MAJOR 1a: X11 itself where it had only the fallback (none in a Wayland session) asks.
    EXPECT_EQ(changes(app("sockets=fallback-x11;"), app("sockets=x11;")), QStringList{QStringLiteral("widened x11 from x11Fallback/1")});
    EXPECT_EQ(changes(app("sockets=wayland;x11;fallback-x11;"), app("sockets=wayland;x11;")), QStringList{QStringLiteral("widened x11 from x11Fallback/1")});
    EXPECT_EQ(changes(app("sockets=wayland;if:x11:!has-wayland;"), app("sockets=wayland;x11;")), QStringList{QStringLiteral("widened x11 from x11Fallback/1")});
    EXPECT_TRUE(asks(app("sockets=fallback-x11;"), app("sockets=x11;")));
    // MAJOR 1b: USB, raw and through the portal, and what is hidden.
    const QByteArray oneDevice = app({}, "[USB Devices]\nenumerable-devices=vnd:1234+dev:5678;\n");
    EXPECT_EQ(lines(flatpakPermissions(oneDevice)), QStringList{QStringLiteral("usbPortal vnd:1234+dev:5678 1")});
    EXPECT_EQ(changes(oneDevice, app("devices=usb;")),
              QStringList{QStringLiteral("widened usb from vnd:1234+dev:5678/1")})
        << "one device through the portal to every device directly";
    EXPECT_EQ(changes(oneDevice, app({}, "[USB Devices]\nenumerable-devices=all;\n")),
              QStringList{QStringLiteral("widened usbPortal all from vnd:1234+dev:5678/1")});
    EXPECT_EQ(changes(oneDevice, app({}, "[USB Devices]\nenumerable-devices=vnd:9999;\n")),
              (QStringList{QStringLiteral("added usbPortal vnd:9999"), QStringLiteral("removed usbPortal vnd:1234+dev:5678")}));
    EXPECT_EQ(changes(app("devices=usb;"), oneDevice), QStringList{QStringLiteral("narrowed usbPortal vnd:1234+dev:5678 from usb/1")});
    EXPECT_EQ(changes(app({}, "[USB Devices]\nenumerable-devices=all;\n"), oneDevice), QStringList{QStringLiteral("narrowed usbPortal vnd:1234+dev:5678 from all/1")});
    const QByteArray hiding = app({}, "[USB Devices]\nenumerable-devices=all;\nhidden-devices=vnd:1111;vnd:2222;\n");
    EXPECT_EQ(changes(hiding, app({}, "[USB Devices]\nenumerable-devices=all;\nhidden-devices=vnd:1111;\n")),
              QStringList{QStringLiteral("widened usbHidden vnd:2222")})
        << "a device no longer hidden (flatpak's adds_usb_device)";
    EXPECT_TRUE(asks(hiding, app({}, "[USB Devices]\nenumerable-devices=all;\nhidden-devices=vnd:1111;\n")));
    EXPECT_EQ(changes(app({}, "[USB Devices]\nenumerable-devices=all;\n"), hiding),
              (QStringList{QStringLiteral("narrowed usbHidden vnd:1111"), QStringLiteral("narrowed usbHidden vnd:2222")}));
    EXPECT_FALSE(asks(app({}, "[USB Devices]\nenumerable-devices=all;\n"), hiding));
    EXPECT_EQ(changes(app("devices=all;"), app("devices=usb;input;kvm;")),
              QStringList{QStringLiteral("narrowed input from devices/1")})
        << "all devices to some: one line, what it has now covered";
    // MAJOR 1c: shared=ipc and devices=shm are two grants.
    EXPECT_EQ(changes(app("shared=ipc;"), app("devices=shm;")), (QStringList{QStringLiteral("added shm"), QStringLiteral("removed ipc")}));
    EXPECT_TRUE(asks(app("shared=ipc;"), app("devices=shm;")));

    // MINOR 2: the installed side read narrowest, so an old grant read generously never hides a new one.
    EXPECT_EQ(changes(app("sockets=x11;!x11;"), app("sockets=x11;")), QStringList{QStringLiteral("added x11")}) << "taken away, as flatpak reads it";
    EXPECT_EQ(changes(app("sockets=x11;\nsockets=wayland;"), app("sockets=x11;")), QStringList{QStringLiteral("added x11")}) << "GLib keeps the last line";
    EXPECT_EQ(changes(app("devices=if:usb:has-usb-portal;"), app("devices=usb;")), QStringList{QStringLiteral("added usb")}) << "unknown: not granted before";
    EXPECT_EQ(changes(app("filesystems=home;!home;"), app("filesystems=home;")),
              (QStringList{QStringLiteral("added home ~"), QStringLiteral("added login"), QStringLiteral("added outside")}));
    EXPECT_EQ(changes(app({}, "[Session Bus Policy]\norg.example.Svc=own\norg.example.Svc=talk\n"), app({}, "[Session Bus Policy]\norg.example.Svc=own\n")),
              QStringList{QStringLiteral("widened sessionService org.example.Svc from org.example.Svc/1")});
    // MINOR 3: create is more than read and write; a folder inside the home folder is new (it may be a link out of it).
    EXPECT_EQ(changes(app("filesystems=~/Games;"), app("filesystems=~/Games:create;")), QStringList{QStringLiteral("widened folders ~/Games from ~/Games/2")});
    EXPECT_EQ(changes(app("filesystems=~/Games:create;"), app("filesystems=~/Games;")), QStringList{QStringLiteral("narrowed folders ~/Games from ~/Games/3")});
    EXPECT_EQ(changes(app("filesystems=home;"), app("filesystems=home;~/foo;")), QStringList{QStringLiteral("added folders ~/foo")});
    EXPECT_EQ(changes(app("filesystems=home;"), app("filesystems=home;xdg-download;")), QStringList{QStringLiteral("added folders xdg-download")});
    EXPECT_TRUE(asks(app("filesystems=home;"), app("filesystems=home;~/foo;")));
    // Counter-review: "!host-reset" takes host away too (flatpak_context_take_filesystem), on the installed side.
    EXPECT_EQ(lines(flatpakPermissions(app("filesystems=host;!host-reset;"), FlatpakReading::Narrowest)), QStringList());
    EXPECT_EQ(changes(app("filesystems=host;!host-reset;"), app("filesystems=host;")),
              (QStringList{QStringLiteral("added allFiles /"), QStringLiteral("added login"), QStringLiteral("added outside")}));
    EXPECT_TRUE(asks(app("filesystems=host;!host-reset;"), app("filesystems=host;")));
    // Counter-review: a repeated hidden-devices key keeps its last line in both readings (GLib; for a restriction the
    // widest reading is the fewest hidden): vnd:1 is no longer hidden.
    const QByteArray twice = app({}, "[USB Devices]\nenumerable-devices=all;\nhidden-devices=vnd:1;\nhidden-devices=vnd:2;\n");
    EXPECT_EQ(lines(flatpakPermissions(twice)), (QStringList{QStringLiteral("usbPortal all 1"), QStringLiteral("usbHidden vnd:2 1")}));
    EXPECT_EQ(changes(app({}, "[USB Devices]\nenumerable-devices=all;\nhidden-devices=vnd:1;\n"), twice),
              (QStringList{QStringLiteral("widened usbHidden vnd:1"), QStringLiteral("narrowed usbHidden vnd:2")}));
    EXPECT_TRUE(asks(app({}, "[USB Devices]\nenumerable-devices=all;\nhidden-devices=vnd:1;\n"), twice));
    // NIT 4: a wildcard never holds a name that only starts like it; host never holds /run (the bus, Hyprland's IPC...).
    EXPECT_EQ(changes(app({}, "[Session Bus Policy]\norg.example.*=talk\n"), app({}, "[Session Bus Policy]\norg.example.*=talk\norg.exampleevil=talk\n")),
              QStringList{QStringLiteral("added sessionService org.exampleevil")});
    EXPECT_EQ(changes(app({}, "[Session Bus Policy]\norg.example.*=talk\n"), app({}, "[Session Bus Policy]\norg.example.*=talk\norg.example.Sub.Name=talk\n")),
              QStringList());
    EXPECT_EQ(changes(app("filesystems=host;"), app("filesystems=host;/run/foo;")), QStringList{QStringLiteral("added folders /run/foo")});
    EXPECT_EQ(changes(app("filesystems=host;"), app("filesystems=host;/usr/lib;")), QStringList{QStringLiteral("added folders /usr/lib")});

    // Added and removed.
    EXPECT_EQ(changes(app({}), app("shared=network;\nsockets=pulseaudio;")), (QStringList{QStringLiteral("added network"), QStringLiteral("added audio")}));
    EXPECT_EQ(changes(app("shared=network;\nsockets=pulseaudio;"), app({})), (QStringList{QStringLiteral("removed network"), QStringLiteral("removed audio")}));
    EXPECT_FALSE(asks(app("shared=network;\nsockets=pulseaudio;"), app({}))) << "less applies as any update";
    // A mode: read only to read and write is widened, the other way narrowed.
    EXPECT_EQ(changes(app("filesystems=xdg-download:ro;"), app("filesystems=xdg-download;")),
              QStringList{QStringLiteral("widened folders xdg-download from xdg-download/1")});
    EXPECT_EQ(changes(app("filesystems=xdg-download;"), app("filesystems=xdg-download:ro;")),
              QStringList{QStringLiteral("narrowed folders xdg-download from xdg-download/2")});
    // A folder to the home folder, and back: each a place of its own; the home folder to host.
    EXPECT_EQ(changes(app("filesystems=xdg-download;"), app("filesystems=home;")),
              (QStringList{QStringLiteral("added home ~"), QStringLiteral("added login"), QStringLiteral("added outside"),
                           QStringLiteral("removed folders xdg-download")}));
    EXPECT_EQ(changes(app("filesystems=home;"), app("filesystems=xdg-download;")),
              (QStringList{QStringLiteral("added folders xdg-download"), QStringLiteral("removed home ~"), QStringLiteral("removed login"),
                           QStringLiteral("removed outside")}));
    EXPECT_EQ(changes(app("filesystems=home;"), app("filesystems=host;")),
              QStringList{QStringLiteral("widened allFiles / from ~/2")});
    EXPECT_EQ(changes(app("filesystems=host:ro;"), app("filesystems=xdg-documents;")),
              QStringList{QStringLiteral("widened folders xdg-documents from //1")})
        << "read only everywhere to writing in Documents: it asks (one line for the place)";
    // Names: one to its wildcard, talk to own; a whole bus.
    EXPECT_EQ(changes(app({}, "[Session Bus Policy]\norg.example.Svc=talk\n"), app({}, "[Session Bus Policy]\norg.example.Svc=own\n")),
              QStringList{QStringLiteral("widened sessionService org.example.Svc from org.example.Svc/1")});
    EXPECT_EQ(changes(app({}, "[Session Bus Policy]\norg.example.Svc=talk\n"), app("sockets=session-bus;")),
              (QStringList{QStringLiteral("added outside"), QStringLiteral("widened bus from org.example.Svc/1")}));
    EXPECT_EQ(changes(app("sockets=session-bus;"), app({}, "[Session Bus Policy]\norg.example.Svc=talk\n")),
              (QStringList{QStringLiteral("removed outside"), QStringLiteral("narrowed sessionService org.example.Svc from bus/1")}));
    EXPECT_EQ(changes(app({}, "[System Bus Policy]\norg.example.A=talk\n"), app({}, "[System Bus Policy]\norg.example.B=talk\n")),
              (QStringList{QStringLiteral("added systemService org.example.B"), QStringLiteral("removed systemService org.example.A")}));
    // A grant the Store does not know is added when new: it asks.
    EXPECT_EQ(changes(app({}), app("sockets=tpm;")), QStringList{QStringLiteral("added other sockets=tpm")});
    EXPECT_TRUE(asks(app({}), app("sockets=tpm;")));
    // Only an added or widened grant asks; the file chooser's portal is never a grant (portal names are harmless).
    EXPECT_FALSE(asks(app({}), app({}, "[Session Bus Policy]\norg.freedesktop.portal.Documents=talk\norg.freedesktop.portal.FileChooser=talk\n")));
}

// The changes for QML: each with its kind, grant and what it was.
TEST(FlatpakPermissions, ChangesForQml)
{
    const QList<FlatpakPermissionChange> d = diffFlatpakPermissions(*flatpakPermissions(app("filesystems=xdg-download:ro;")),
                                                                    *flatpakPermissions(app("filesystems=xdg-download;\nshared=network;")));
    const QVariantList v = view::permissionChanges(d);
    ASSERT_EQ(v.size(), 2);
    const QVariantMap added = v.at(0).toMap(), widened = v.at(1).toMap();
    EXPECT_EQ(added.value(QStringLiteral("change")).toString(), QStringLiteral("added"));
    EXPECT_EQ(added.value(QStringLiteral("key")).toString(), QStringLiteral("network"));
    EXPECT_FALSE(added.value(QStringLiteral("previous")).isValid());
    EXPECT_EQ(widened.value(QStringLiteral("change")).toString(), QStringLiteral("widened"));
    EXPECT_EQ(widened.value(QStringLiteral("name")).toString(), QStringLiteral("xdg-download"));
    EXPECT_EQ(widened.value(QStringLiteral("level")).toInt(), 2);
    EXPECT_EQ(widened.value(QStringLiteral("previous")).toMap().value(QStringLiteral("level")).toInt(), 1);
}
