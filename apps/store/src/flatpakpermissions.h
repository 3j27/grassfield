// What a Flatpak's metadata lets it reach, as a list of grants, and what an update changes in it (ADR-0049, amending
// ADR-0037 SD25 and SD33). The metadata is the key file `flatpak remote-info --show-metadata` prints before an install and
// `flatpak info --show-metadata` after: its [Context] (shared, sockets, devices, features, filesystems, persistent),
// [Session Bus Policy], [System Bus Policy], [USB Devices] and [Environment] groups, each list read as flatpak reads it
// (S29: GLib's escapes, then a filesystems entry's own; flatpak 1.17's conditional grants "if:<grant>:<condition>").
// flatpak.h flatpakAccess is this parse's flat list. Pure: no file, no process.
#pragma once

#include <QByteArray>
#include <QList>
#include <QString>
#include <QStringList>

#include <optional>

namespace grassfield::store {

// One grant of the metadata.
//   key: a class, in this order: network, allFiles (host, host-os, host-etc, host-root), home, folders (any other path),
//        devices (all), input, usb (every USB device, directly), usbPortal (a USB query the portal lets it list and open:
//        all, vnd:…), usbHidden (a USB query hidden from it: a restriction), kvm, audio, x11 (the X11 display),
//        x11Fallback (X11 only where Wayland is missing: fallback-x11, if:x11:!has-wayland, or x11 beside fallback-x11, as
//        flatpak 1.17 computes it; none in Grassfield's Wayland session), ipc (shared=ipc), shm (devices=shm), printers,
//        ssh, gpg, smartCards, bus (the whole session bus), systemBus, bluetooth, canbus, devel, multiarch, login (it can
//        write where programs start at the next login), outside (it may start programs outside its sandbox); then
//        sessionService and systemService (a bus name it may talk to or own, the harmless ones left out: flatpakAccess's
//        rules), then other (a grant the Store does not know).
//   name: for allFiles, home and folders the place, normalised (flatpak's word or "/" for host, "~" for the home folder,
//        "~/…", "/…", "$RUN/…" for the user's runtime folder, xdg-download and the other user folders as flatpak writes
//        them, "*" for a path with ".."); for a service its bus name ("X.*" for X and every name below it); for usbPortal
//        and usbHidden the query; for other, the grant as flatpak writes it; "" otherwise.
//   level: for a place 1 read only, 2 read and write, 3 create (flatpak's own ranking of the modes); for a service 1
//        talk, 2 own (or a policy the Store does not know); 1 otherwise.
struct FlatpakGrant {
    QString key, name;
    int level = 1;
    bool operator==(const FlatpakGrant &o) const { return key == o.key && name == o.name && level == o.level; }
};

// The most grants a parse lists (the rest counted in `more`, never dropped unsaid), and the largest metadata it reads.
inline constexpr int kMaxFlatpakGrants = 200;
inline constexpr qsizetype kMaxFlatpakMetadata = 1024 * 1024;

struct FlatpakPermissions {
    QString appId;
    QList<FlatpakGrant> grants; // in FlatpakGrant's order: the classes, places and names sorted, then the others as written
    int more = 0;               // grants past kMaxFlatpakGrants
    QStringList access;         // flatpak.h flatpakAccess's flat list (30 lines at most, "more:<n>" last when cut)
};

// How a metadata is read where flatpak's own reading is not known here (ADR-0049):
//   Widest: what a version may reach is never said to be less: "!x" takes away only what the list grants after it, a key
//           written twice counts every time, a condition the Store cannot check (the USB portal, an unknown one) grants.
//           The product page, the install sheet and the newer side of an update.
//   Narrowest: what the installed version could reach is never said to be more: "!x" takes x away as flatpak does, a key
//           written twice counts once (its last line, as GLib keeps it), a condition the Store cannot check grants
//           nothing. The installed side of an update, so that a new grant is never hidden by an old one read generously.
enum class FlatpakReading { Widest, Narrowest };

// The metadata's grants; nullopt when it is not an app's (no [Application] name that is a Flatpak id), larger than
// kMaxFlatpakMetadata, or holds a value flatpak cannot interpret: unknown, never "nothing".
std::optional<FlatpakPermissions> flatpakPermissions(const QByteArray &metadata, FlatpakReading reading = FlatpakReading::Widest);

// What an update changes, grant by grant (the idea of Project Luma's depot_permissions, reimplemented; ADR-0049), as
// pessimistic as flatpak's own flatpak_context_adds_permissions:
//   Added: a grant the installed version has nothing of (a new class, place, USB query or bus name; a folder inside one
//          it had, as ~/foo under ~, which may be a link out of it);
//   Widened: one it had less of: the same place or name at a higher level (read only to read and write to create, talk
//            to own), a wider one that holds an older one (a place under host to host, org.example.A to org.example.*,
//            input to all devices, a USB query to raw USB, x11's fallback to x11), a USB query no longer hidden;
//   Removed, Narrowed: the same, the other way (a USB query newly hidden is Narrowed).
// A grant that one of the other side holds at its level or above is no change (host read and write holds ~/Downloads;
// x11 holds its fallback). A cut list ("more") is always Added: its grants cannot be compared. `before` should be read
// Narrowest and `after` Widest (flatpakPermissionChanges does).
enum class FlatpakChangeKind { Added, Widened, Removed, Narrowed };
struct FlatpakPermissionChange {
    FlatpakChangeKind kind = FlatpakChangeKind::Added;
    FlatpakGrant grant;    // the newer version's (Added, Widened, Narrowed) or the installed one's (Removed); key "more"
                           // with its count in name for a cut list
    FlatpakGrant previous; // Widened, Narrowed: what the installed version had of it (the same grant at its level, or the
                           // place, name or class it held); empty key for Added and Removed
};
// The changes: Added, then Widened, Removed, Narrowed, each in FlatpakGrant's order.
QList<FlatpakPermissionChange> diffFlatpakPermissions(const FlatpakPermissions &before, const FlatpakPermissions &after);
// Whether an update asks for more: a grant added or widened. The document portal (the files the user picks in an Open
// or Save dialog) is never a grant, so it never asks.
bool asksForMore(const QList<FlatpakPermissionChange> &changes);
// "added", "widened", "removed" or "narrowed".
QString changeKindName(FlatpakChangeKind kind);

} // namespace grassfield::store
