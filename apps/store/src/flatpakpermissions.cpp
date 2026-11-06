#include "flatpakpermissions.h"

#include "catalog.h"

#include <QHash>
#include <QRegularExpression>
#include <QSet>

#include <algorithm>

namespace grassfield::store {

namespace {

constexpr qsizetype kAccessMax = 30; // flatpakAccess's lines, at most

// A key-file list as GLib reads it for flatpak (g_key_file_get_string_list): ";" ends an entry unless escaped, and \s,
// \n, \t, \r, \\ and \; decode. Any other escape, or one at the end, is a value flatpak refuses to interpret (S29):
// std::nullopt.
std::optional<QStringList> keyFileList(const QString &value)
{
    QStringList out;
    QString entry;
    for (qsizetype i = 0; i < value.size(); ++i) {
        const QChar c = value.at(i);
        if (c == QLatin1Char(';')) {
            out.append(entry);
            entry.clear();
            continue;
        }
        if (c != QLatin1Char('\\')) {
            entry += c;
            continue;
        }
        if (++i == value.size())
            return std::nullopt;
        switch (value.at(i).unicode()) {
        case 's':
            entry += QLatin1Char(' ');
            break;
        case 'n':
            entry += QLatin1Char('\n');
            break;
        case 't':
            entry += QLatin1Char('\t');
            break;
        case 'r':
            entry += QLatin1Char('\r');
            break;
        case '\\':
        case ';':
            entry += value.at(i);
            break;
        default:
            return std::nullopt;
        }
    }
    if (!entry.isEmpty())
        out.append(entry);
    return out;
}

// A filesystems entry as flatpak reads it (S29): "\x" is x, and the first ":" not escaped starts its mode (ro, rw,
// create; only ro keeps it from writing). Its level as flatpak ranks the modes (FlatpakFilesystemMode): 1 ro, 2 rw (or a
// mode the Store does not know), 3 create.
struct FilesystemEntry {
    QString path;
    bool readOnly = false;
    int level = 2;
};

FilesystemEntry filesystemEntry(const QString &entry)
{
    FilesystemEntry out;
    QString mode;
    bool inMode = false;
    for (qsizetype i = 0; i < entry.size(); ++i) {
        const QChar c = entry.at(i);
        if (inMode) {
            mode += c;
        } else if (c == QLatin1Char('\\')) {
            if (++i < entry.size())
                out.path += entry.at(i);
        } else if (c == QLatin1Char(':')) {
            inMode = true;
        } else {
            out.path += c;
        }
    }
    out.readOnly = mode == QLatin1String("ro");
    out.level = out.readOnly ? 1 : mode == QLatin1String("create") ? 3 : 2;
    return out;
}

// A filesystems path as one place, normalised as flatpak does first ("//", "/./" and a trailing "/" or "/." collapse,
// S29): "/" for host (all but /run, /var, /tmp and the system's own folders, as flatpak mounts it), "~" for the home
// folder (home, ~, a home folder by its absolute path), "~/.config", "~/.local/share", "~/.cache" for xdg-config,
// xdg-data and xdg-cache, "$RUN" for the user's runtime folder (xdg-run, /run/user/<uid>; /var/run is /run), and "*" for
// a path with ".." (it could be anywhere; flatpak refuses one, S29). Any other word (host-os, host-etc, host-root,
// xdg-download...) stays as written.
QString canonicalPath(const QString &path)
{
    const bool absolute = path.startsWith(QLatin1Char('/'));
    QStringList parts;
    for (const QString &part : path.split(QLatin1Char('/'), Qt::SkipEmptyParts)) {
        if (part == QLatin1String(".."))
            return QStringLiteral("*");
        if (part != QLatin1String("."))
            parts.append(part);
    }
    if (parts.isEmpty())
        return absolute ? QStringLiteral("/") : QString();
    if (absolute && parts.first() == QLatin1String("var") && parts.value(1) == QLatin1String("run"))
        parts.removeFirst(); // /var/run is /run
    QString base;
    if (!absolute) {
        const QString head = parts.takeFirst();
        if (head == QLatin1String("host") && parts.isEmpty())
            return QStringLiteral("/");
        if (head == QLatin1String("home") || head == QLatin1String("~"))
            base = QStringLiteral("~");
        else if (head == QLatin1String("xdg-config"))
            base = QStringLiteral("~/.config");
        else if (head == QLatin1String("xdg-data"))
            base = QStringLiteral("~/.local/share");
        else if (head == QLatin1String("xdg-cache"))
            base = QStringLiteral("~/.cache");
        else if (head == QLatin1String("xdg-run"))
            base = QStringLiteral("$RUN");
        else
            return (QStringList{head} + parts).join(QLatin1Char('/'));
    } else if (parts.first() == QLatin1String("home") || (parts.first() == QLatin1String("var") && parts.value(1) == QLatin1String("home"))) {
        parts.remove(0, parts.first() == QLatin1String("var") ? 2 : 1); // /home, /var/home: every home folder
        if (!parts.isEmpty())
            parts.removeFirst(); // the user's
        base = QStringLiteral("~");
    } else if (parts.first() == QLatin1String("run") && (parts.size() == 1 || parts.at(1) == QLatin1String("user"))) {
        parts.remove(0, qMin<qsizetype>(parts.size(), 3)); // /run, /run/user, /run/user/<uid>
        base = QStringLiteral("$RUN");
    } else {
        return QLatin1Char('/') + parts.join(QLatin1Char('/'));
    }
    return parts.isEmpty() ? base : base + QLatin1Char('/') + parts.join(QLatin1Char('/'));
}

// Whether a canonical path reaches `target`: holds it, or is inside it ("/" holds the home folder, not the runtime folder;
// "*" holds everything).
bool reaches(const QString &path, const QString &target)
{
    if (path == QLatin1String("*"))
        return true;
    if (path == QLatin1String("/"))
        return target.startsWith(QLatin1Char('~'));
    return path == target || target.startsWith(path + QLatin1Char('/')) || path.startsWith(target + QLatin1Char('/'));
}

// A canonical path it can write where programs start at the next login, outside its sandbox: the session's autostart
// and systemd user units, Hyprland's and uwsm's configuration, Omarchy's hooks (post-boot runs at each login),
// environment.d, the shells' start files, ~/.local/bin (on PATH).
bool startsAtLogin(const QString &path, bool readOnly)
{
    if (readOnly)
        return false;
    static const QStringList targets{QStringLiteral("~/.config/autostart"), QStringLiteral("~/.config/systemd"), QStringLiteral("~/.config/hypr"),
                                     QStringLiteral("~/.config/uwsm"), QStringLiteral("~/.config/omarchy"), QStringLiteral("~/.config/environment.d"),
                                     QStringLiteral("~/.config/fish"), QStringLiteral("~/.local/share/systemd"), QStringLiteral("~/.local/bin"),
                                     QStringLiteral("~/.bashrc"), QStringLiteral("~/.bash_profile"), QStringLiteral("~/.bash_login"),
                                     QStringLiteral("~/.profile"), QStringLiteral("~/.zshrc"), QStringLiteral("~/.zshenv"), QStringLiteral("~/.zprofile"),
                                     QStringLiteral("~/.zlogin")};
    return std::any_of(targets.cbegin(), targets.cend(), [&path](const QString &t) { return reaches(path, t); });
}

// A canonical path that reaches past its sandbox: anything in the user's runtime folder but the sound server's sockets
// and the app's own folder (the session bus's and systemd's sockets bypass the bus filter, Hyprland's can start
// programs, others are services' own; read-only does not stop a connection), anything in the system's /run but removable
// media (the system bus, docker...), a path with "..", or, written, flatpak's own folder (its overrides grant any
// permission), the session's D-Bus services (D-Bus starts one on the host when its name is called) or the launcher's
// entries (run on the host when opened), or a folder above one of them (home, xdg-data, host).
bool reachesOutside(const QString &path, bool readOnly, const QString &appId)
{
    const auto within = [&path](const QString &folder) { return path == folder || path.startsWith(folder + QLatin1Char('/')); };
    if (path == QLatin1String("*"))
        return true;
    if (within(QStringLiteral("$RUN")))
        return !within(QStringLiteral("$RUN/pipewire-0")) && !within(QStringLiteral("$RUN/pulse")) && !within(QStringLiteral("$RUN/app/") + appId);
    if (path.startsWith(QLatin1String("/run/")))
        return !within(QStringLiteral("/run/media"));
    static const QStringList written{QStringLiteral("~/.local/share/flatpak"), QStringLiteral("~/.local/share/dbus-1"),
                                     QStringLiteral("~/.local/share/applications")};
    return !readOnly && std::any_of(written.cbegin(), written.cend(), [&path](const QString &w) { return reaches(path, w); });
}

// The classes in their order (FlatpakGrant's key).
const QStringList &classOrder()
{
    static const QStringList order{QStringLiteral("network"), QStringLiteral("allFiles"), QStringLiteral("home"), QStringLiteral("folders"),
                                   QStringLiteral("devices"), QStringLiteral("input"), QStringLiteral("usb"), QStringLiteral("usbPortal"),
                                   QStringLiteral("usbHidden"), QStringLiteral("kvm"), QStringLiteral("audio"), QStringLiteral("x11"),
                                   QStringLiteral("x11Fallback"), QStringLiteral("ipc"), QStringLiteral("shm"), QStringLiteral("printers"),
                                   QStringLiteral("ssh"), QStringLiteral("gpg"), QStringLiteral("smartCards"), QStringLiteral("bus"),
                                   QStringLiteral("systemBus"), QStringLiteral("bluetooth"), QStringLiteral("canbus"), QStringLiteral("devel"),
                                   QStringLiteral("multiarch"), QStringLiteral("login"), QStringLiteral("outside")};
    return order;
}

// flatpakAccess's classes in their order (SD25, unchanged by ADR-0049).
const QStringList &flatClassOrder()
{
    static const QStringList order{QStringLiteral("network"), QStringLiteral("allFiles"), QStringLiteral("home"), QStringLiteral("folders"),
                                   QStringLiteral("devices"), QStringLiteral("input"), QStringLiteral("usb"), QStringLiteral("kvm"),
                                   QStringLiteral("audio"), QStringLiteral("x11"), QStringLiteral("sharedMemory"), QStringLiteral("printers"),
                                   QStringLiteral("ssh"), QStringLiteral("gpg"), QStringLiteral("smartCards"), QStringLiteral("bus"),
                                   QStringLiteral("systemBus"), QStringLiteral("bluetooth"), QStringLiteral("canbus"), QStringLiteral("devel"),
                                   QStringLiteral("multiarch"), QStringLiteral("login"), QStringLiteral("outside")};
    return order;
}

// The class of a place: host and the host's own folders are all files, the home folder its own, any other path a folder.
QString placeClass(const QString &place)
{
    if (place == QLatin1String("/") || place == QLatin1String("host-os") || place == QLatin1String("host-etc") || place == QLatin1String("host-root"))
        return QStringLiteral("allFiles");
    return place == QLatin1String("~") ? QStringLiteral("home") : QStringLiteral("folders");
}

bool isPlaceKey(const QString &key)
{
    return key == QLatin1String("allFiles") || key == QLatin1String("home") || key == QLatin1String("folders");
}

// A conditional grant (flatpak 1.17, "if:<grant>:<condition>", conditions "!"-negated) as Grassfield's session meets it:
// granted, not granted, or granted only where Wayland is missing (x11's fallback). flatpak 1.17 and later always has the
// input and USB device permissions; Grassfield's session is always Wayland. Whether the USB portal is there, or a
// condition the Store does not know, is not known here: granted when the widest reading is asked (what a version may reach
// is never said to be less), not granted for the narrowest (what the installed version could reach is never said to be
// more).
enum class Condition { Granted, NotGranted, WithoutWayland };
Condition condition(const QString &text, FlatpakReading reading)
{
    const bool negated = text.startsWith(QLatin1Char('!'));
    const QString name = negated ? text.mid(1) : text;
    bool value = true;
    if (name == QLatin1String("false"))
        value = false;
    else if (name == QLatin1String("true") || name == QLatin1String("has-input-device") || name == QLatin1String("has-usb-device"))
        value = true;
    else if (name == QLatin1String("has-wayland"))
        return negated ? Condition::WithoutWayland : Condition::Granted;
    else
        return reading == FlatpakReading::Widest ? Condition::Granted : Condition::NotGranted; // has-usb-portal, or unknown
    return value != negated ? Condition::Granted : Condition::NotGranted;
}

// What one [Context] list grants, entry by entry, as flatpak reads it: "if:x:c" grants x under c, and an x granted before
// "if:x:…" in the list is then only flatpak's own compatibility line for older versions (flatpak 1.17 reverts it): the
// conditions decide. "!x" takes x away: from what the list grants after it in the widest reading (an earlier x stays,
// never less said), from everything before it too in the narrowest, as flatpak reads it.
struct ListGrant {
    QString entry;
    bool withoutWayland = false; // granted only where Wayland is missing
};
QList<ListGrant> contextList(const QString &key, const QStringList &entries, FlatpakReading reading)
{
    const bool conditional = key == QLatin1String("shared") || key == QLatin1String("sockets") || key == QLatin1String("devices")
        || key == QLatin1String("features");
    // Each name's state: plain (granted), or its conditions' answer once one is read.
    struct State {
        bool plain = false, conditional = false, granted = false, withoutWayland = false;
    };
    QList<QString> order;
    QHash<QString, State> states;
    QList<ListGrant> malformed;
    for (QString entry : entries) {
        entry = entry.trimmed();
        if (entry.isEmpty())
            continue;
        if (entry.startsWith(QLatin1Char('!'))) {
            if (reading == FlatpakReading::Narrowest && states.contains(entry.mid(1)))
                states[entry.mid(1)] = State{}; // taken away
            continue;
        }
        if (conditional && entry.startsWith(QLatin1String("if:"))) {
            const qsizetype colon = entry.indexOf(QLatin1Char(':'), 3);
            const QString name = colon > 3 ? entry.mid(3, colon - 3) : QString();
            const QString cond = colon > 3 ? entry.mid(colon + 1) : QString();
            if (name.isEmpty() || cond.isEmpty() || name.startsWith(QLatin1Char('!'))) {
                malformed.append({entry, false}); // named as written
                continue;
            }
            if (!states.contains(name))
                order.append(name);
            State &s = states[name];
            if (s.plain && !s.conditional) {
                s.plain = false; // the compatibility line before its conditions
                s.granted = false;
            }
            s.conditional = true;
            switch (condition(cond, reading)) {
            case Condition::Granted:
                s.granted = true;
                s.withoutWayland = false;
                break;
            case Condition::WithoutWayland:
                if (!s.granted)
                    s.withoutWayland = true;
                break;
            case Condition::NotGranted:
                break;
            }
            continue;
        }
        if (!states.contains(entry))
            order.append(entry);
        State &s = states[entry];
        s.plain = true;
        s.conditional = false;
        s.granted = true;
        s.withoutWayland = false;
    }
    QList<ListGrant> out;
    for (const QString &name : std::as_const(order)) {
        const State &s = states.value(name);
        if (s.granted)
            out.append({name, false});
        else if (s.withoutWayland)
            out.append({name, true});
    }
    return out + malformed;
}

// Everything the metadata grants, before the lists are cut.
struct Parsed {
    QString appId;
    QSet<QString> classes;               // the classes without a name (network, devices… login, outside)
    QHash<QString, int> places;          // place -> level
    QHash<QString, int> session, system; // bus name -> level
    QStringList usbPortal, usbHidden;    // [USB Devices] queries, in order, each once
    QStringList other;
    QSet<QString> otherSeen;
    bool x11 = false, x11Fallback = false, wayland = false; // the sockets as written (the X11 rule is decided at the end)
};

std::optional<Parsed> parse(const QByteArray &metadata, FlatpakReading reading)
{
    if (metadata.size() > kMaxFlatpakMetadata)
        return std::nullopt;
    // Each "group key=value" line of the metadata; the classes are decided once the app's id is known.
    struct Line {
        QString group, key, value;
    };
    QList<Line> lines;
    QString group;
    Parsed p;
    for (const QByteArray &raw : metadata.split('\n')) {
        const QString line = QString::fromUtf8(raw).trimmed();
        if (line.isEmpty() || line.startsWith(QLatin1Char('#')))
            continue;
        if (line.startsWith(QLatin1Char('[')) && line.endsWith(QLatin1Char(']'))) {
            group = line.mid(1, line.size() - 2).trimmed();
            continue;
        }
        const qsizetype eq = line.indexOf(QLatin1Char('='));
        if (eq <= 0)
            continue;
        const Line l{group, line.left(eq).trimmed(), line.mid(eq + 1).trimmed()};
        if (l.group == QLatin1String("Application") && l.key == QLatin1String("name"))
            p.appId = l.value;
        lines.append(l);
    }
    if (!isFlatpakId(p.appId))
        return std::nullopt; // not an app's metadata: what it may reach is unknown, never "nothing"
    if (reading == FlatpakReading::Narrowest) {
        // GLib keeps the last of a key repeated in a group: only that line counts (the widest reading takes them all).
        QSet<QString> seen;
        QList<Line> last;
        for (qsizetype i = lines.size() - 1; i >= 0; --i) {
            const QString id = lines.at(i).group + QChar(0) + lines.at(i).key;
            if (!seen.contains(id)) {
                seen.insert(id);
                last.prepend(lines.at(i));
            }
        }
        lines = last;
    }
    const QString &appId = p.appId;

    const auto unknown = [&p](const QString &text) {
        const QString clean = cleanPlainText(text, 160, false);
        if (!p.otherSeen.contains(clean)) {
            p.otherSeen.insert(clean);
            p.other.append(clean);
        }
    };
    const auto raise = [](QHash<QString, int> &map, const QString &name, int level) {
        auto it = map.find(name);
        if (it == map.end())
            map.insert(name, level);
        else
            *it = qMax(*it, level);
    };
    // A bus name it may talk to or own: none of these harmless ones is named, the desktop's notifications, tray, menus,
    // screen saver inhibition, accessibility, file manager and the portals (which ask the user themselves) to talk to,
    // its own names and media-player names to own too; the session's services that start programs on the host, or grant
    // permissions, are "outside" too, and so is a wildcard that covers one of them.
    static const QStringList harmless{QStringLiteral("org.freedesktop.Notifications"), QStringLiteral("org.kde.StatusNotifierWatcher"),
                                      QStringLiteral("com.canonical.AppMenu.Registrar"), QStringLiteral("org.freedesktop.ScreenSaver"),
                                      QStringLiteral("org.a11y.Bus"), QStringLiteral("org.freedesktop.FileManager1")};
    static const QStringList escapes{QStringLiteral("org.freedesktop.Flatpak"), QStringLiteral("org.freedesktop.systemd1"),
                                     QStringLiteral("org.freedesktop.impl.portal.PermissionStore")};
    static const QRegularExpression busName(QStringLiteral(R"(\A[A-Za-z0-9_.*-]{1,255}\z)"));
    const auto covers = [](const QString &name, const QString &service) {
        // "X.*" is X and every name below it, as xdg-dbus-proxy reads it.
        return name == service
            || (name.endsWith(QLatin1String(".*")) && (service == name.chopped(2) || service.startsWith(name.chopped(1))));
    };
    const auto busPolicy = [&](const Line &l, bool onSession) {
        if (l.value == QLatin1String("none") || l.value == QLatin1String("see"))
            return; // nothing, or only that the name exists
        if (!busName.match(l.key).hasMatch()) {
            unknown(QStringLiteral("[%1] %2=%3").arg(l.group, l.key, l.value));
            return;
        }
        const bool talk = l.value == QLatin1String("talk");
        if (onSession) {
            // The escapes first: an app whose own id is one of them (or covers one) is not harmless for it.
            const bool escaping = std::any_of(escapes.cbegin(), escapes.cend(), [&](const QString &service) { return covers(l.key, service); });
            // The harmless services are harmless to talk to; owning one (standing in for the portals or the
            // notifications) is named. Its own names and a media-player name are its to own.
            if (escaping)
                p.classes.insert(QStringLiteral("outside"));
            else if ((talk && (harmless.contains(l.key) || l.key.startsWith(QLatin1String("org.freedesktop.portal."))))
                     || l.key.startsWith(QLatin1String("org.mpris.MediaPlayer2.")) || l.key == appId
                     || l.key.startsWith(appId + QLatin1Char('.')))
                return;
        }
        raise(onSession ? p.session : p.system, l.key, talk ? 1 : 2); // own, or a policy the Store does not know: the most
    };

    for (const Line &l : lines) {
        if (l.group == QLatin1String("Session Bus Policy") || l.group == QLatin1String("System Bus Policy")) {
            busPolicy(l, l.group == QLatin1String("Session Bus Policy"));
            continue;
        }
        if (l.group == QLatin1String("USB Devices")) {
            // The devices it may list and open through the USB portal, and those hidden from it (flatpak's USB queries:
            // all, vnd:<id>, vnd:<id>+dev:<id>, cls:<class>…).
            const bool enumerable = l.key == QLatin1String("enumerable-devices"), hidden = l.key == QLatin1String("hidden-devices");
            if (!enumerable && !hidden) {
                unknown(QStringLiteral("[%1] %2=%3").arg(l.group, l.key, l.value));
                continue;
            }
            const std::optional<QStringList> queries = keyFileList(l.value);
            if (!queries)
                return std::nullopt;
            QStringList &into = enumerable ? p.usbPortal : p.usbHidden;
            // A restriction is read narrowest whatever the reading (the fewest hidden): GLib keeps the last hidden-devices
            // line, so an earlier one counts for nothing.
            if (hidden)
                into.clear();
            for (const QString &q : *queries) {
                const QString query = cleanPlainText(q.trimmed(), 120, false);
                if (!query.isEmpty() && !into.contains(query))
                    into.append(query);
            }
            continue;
        }
        if (l.group == QLatin1String("Application") || l.group == QLatin1String("Runtime") || l.group == QLatin1String("Environment")
            || l.group == QLatin1String("Extra Data") || l.group == QLatin1String("ExtensionOf") || l.group == QLatin1String("Build")
            || l.group.startsWith(QLatin1String("Extension ")))
            continue; // what it is, its variables inside the sandbox, its extensions: no grant
        if (l.group != QLatin1String("Context")) {
            unknown(QStringLiteral("[%1] %2=%3").arg(l.group, l.key, l.value)); // a [Policy …] or a group of a later flatpak
            continue;
        }
        if (l.key == QLatin1String("persistent") || l.key == QLatin1String("unset-environment"))
            continue; // its own folder in ~/.var/app, its variables
        const std::optional<QStringList> entries = keyFileList(l.value);
        if (!entries)
            return std::nullopt; // a value flatpak cannot interpret: what it may reach is unknown
        if (l.key == QLatin1String("filesystems")) {
            // Each entry as flatpak reads it: its escapes decoded, its path normalised, its mode. A place written twice keeps
            // its widest mode (widest reading) or its last (narrowest, as flatpak's table); "!x" takes x away in the
            // narrowest reading only.
            QHash<QString, int> local;
            QStringList order;
            for (QString entry : *entries) {
                entry = entry.trimmed();
                if (entry.isEmpty())
                    continue;
                if (entry.startsWith(QLatin1Char('!'))) {
                    if (reading == FlatpakReading::Narrowest) {
                        const QString place = canonicalPath(filesystemEntry(entry.mid(1)).path);
                        local.remove(place);
                        if (place == QLatin1String("host-reset"))
                            local.remove(QStringLiteral("/")); // "!host-reset" is "!host" too (flatpak_context_take_filesystem)
                    }
                    continue;
                }
                const FilesystemEntry fs = filesystemEntry(entry);
                const QString place = canonicalPath(fs.path);
                if (place.isEmpty()) {
                    unknown(QStringLiteral("%1=%2").arg(l.key, entry));
                    continue;
                }
                if (!order.contains(place))
                    order.append(place);
                if (reading == FlatpakReading::Narrowest || !local.contains(place))
                    local.insert(place, fs.level);
                else
                    local[place] = qMax(local.value(place), fs.level);
            }
            for (const QString &place : std::as_const(order)) {
                if (!local.contains(place))
                    continue;
                const int level = local.value(place);
                raise(p.places, place, level);
                if (startsAtLogin(place, level == 1))
                    p.classes.insert(QStringLiteral("login"));
                if (reachesOutside(place, level == 1, appId))
                    p.classes.insert(QStringLiteral("outside"));
            }
            continue;
        }
        for (const ListGrant &g : contextList(l.key, *entries, reading)) {
            const QString &entry = g.entry;
            if (l.key == QLatin1String("sockets")) {
                // x11 granted only where Wayland is missing is fallback-x11; the X11 rule is decided at the end.
                if (entry == QLatin1String("x11")) {
                    (g.withoutWayland ? p.x11Fallback : p.x11) = true;
                    continue;
                }
                if (entry == QLatin1String("fallback-x11")) {
                    p.x11Fallback = true; // only where Wayland is missing, whatever its condition
                    continue;
                }
                if (entry == QLatin1String("wayland"))
                    p.wayland = !g.withoutWayland || p.wayland;
                if (g.withoutWayland)
                    continue;
            } else if (g.withoutWayland) {
                continue; // Grassfield's session is Wayland: not granted
            }
            const QString word = l.key == QLatin1String("shared") ? (entry == QLatin1String("network") ? QStringLiteral("network")
                                                                     : entry == QLatin1String("ipc")   ? QStringLiteral("ipc")
                                                                                                       : QString())
                : l.key == QLatin1String("sockets")
                ? (entry == QLatin1String("wayland") || entry == QLatin1String("inherit-wayland-socket")
                       ? QStringLiteral("-") // its own window
                   : entry == QLatin1String("pulseaudio")  ? QStringLiteral("audio")
                   : entry == QLatin1String("session-bus") ? QStringLiteral("bus")
                   : entry == QLatin1String("system-bus")  ? QStringLiteral("systemBus")
                   : entry == QLatin1String("ssh-auth")    ? QStringLiteral("ssh")
                   : entry == QLatin1String("gpg-agent")   ? QStringLiteral("gpg")
                   : entry == QLatin1String("pcsc")        ? QStringLiteral("smartCards")
                   : entry == QLatin1String("cups")        ? QStringLiteral("printers")
                                                           : QString())
                : l.key == QLatin1String("devices")
                ? (entry == QLatin1String("dri")     ? QStringLiteral("-") // the graphics processor that draws its window
                   : entry == QLatin1String("all")   ? QStringLiteral("devices")
                   : entry == QLatin1String("input") ? QStringLiteral("input")
                   : entry == QLatin1String("usb")   ? QStringLiteral("usb")
                   : entry == QLatin1String("kvm")   ? QStringLiteral("kvm")
                   : entry == QLatin1String("shm")   ? QStringLiteral("shm")
                                                     : QString())
                : l.key == QLatin1String("features")
                ? (entry == QLatin1String("per-app-dev-shm") ? QStringLiteral("-") // shared between its own instances only
                   : entry == QLatin1String("bluetooth")     ? QStringLiteral("bluetooth")
                   : entry == QLatin1String("canbus")        ? QStringLiteral("canbus")
                   : entry == QLatin1String("devel")         ? QStringLiteral("devel")
                   : entry == QLatin1String("multiarch")     ? QStringLiteral("multiarch")
                                                             : QString())
                : QString();
            if (word.isEmpty())
                unknown(QStringLiteral("%1=%2").arg(l.key, entry)); // a grant this flatpak may know and the Store does not
            else if (word != QLatin1String("-"))
                p.classes.insert(word);
        }
    }
    // Its own id and every name below it are its to own on the session bus (flatpak's default): an id that is one of the
    // session's escapes, or holds one, is outside its sandbox whatever its policy says.
    if (std::any_of(escapes.cbegin(), escapes.cend(), [&appId](const QString &e) { return e == appId || e.startsWith(appId + QLatin1Char('.')); }))
        p.classes.insert(QStringLiteral("outside"));
    // X11 as flatpak 1.17 computes it (flatpak_context_compute_allowed_sockets): fallback-x11 makes x11 "only where Wayland
    // is missing", even beside x11 itself; in Grassfield's Wayland session that is no X11. x11 alone is the X11 display.
    if (p.x11Fallback)
        p.classes.insert(QStringLiteral("x11Fallback"));
    else if (p.x11)
        p.classes.insert(QStringLiteral("x11"));
    if (p.classes.contains(QStringLiteral("bus")))
        p.classes.insert(QStringLiteral("outside"));
    return p;
}

// Whether place `a` holds place `b`, as flatpak's own check is pessimistic (flatpak_context_adds_permissions): the same
// place, or anything for "*" (a path with "..") and host-root, or for "/" (host) the home folder, its user folders and
// what host mounts (not /run, not the system's own folders). A folder never holds a place inside it: "~/foo" or
// "~/Projects/notes" may be a link out of it, which only an explicit grant lets through.
bool placeHolds(const QString &a, const QString &b)
{
    if (a == b || a == QLatin1String("*"))
        return true;
    if (b == QLatin1String("*"))
        return false;
    if (a == QLatin1String("host-root"))
        return true;
    if (a != QLatin1String("/"))
        return false;
    if (b.startsWith(QLatin1Char('~')) || (b.startsWith(QLatin1String("xdg-")) && !b.startsWith(QLatin1String("xdg-run"))))
        return true;
    static const QStringList system{QStringLiteral("/run"), QStringLiteral("/usr"), QStringLiteral("/etc"), QStringLiteral("/lib"),
                                    QStringLiteral("/lib64"), QStringLiteral("/bin"), QStringLiteral("/sbin"), QStringLiteral("/app"),
                                    QStringLiteral("/proc"), QStringLiteral("/dev"), QStringLiteral("/sys"), QStringLiteral("/tmp")};
    return b.startsWith(QLatin1Char('/'))
        && std::none_of(system.cbegin(), system.cend(), [&b](const QString &s) { return b == s || b.startsWith(s + QLatin1Char('/')); });
}

// Whether bus name rule `a` holds rule `b`: the same, or a wildcard "X.*" holding X, X.Y and X.Y.* (never "Xother").
bool nameHolds(const QString &a, const QString &b)
{
    if (a == b)
        return true;
    if (!a.endsWith(QLatin1String(".*")))
        return false;
    const QString base = a.chopped(2);
    const QString bBase = b.endsWith(QLatin1String(".*")) ? b.chopped(2) : b;
    return bBase == base || bBase.startsWith(base + QLatin1Char('.'));
}

// Whether grant `a` holds what grant `b` grants, whatever their levels: the same grant, a place as placeHolds says, a
// name under a wildcard, a service of a whole bus, a kind of device among all devices, a USB device the portal's "all" or
// raw USB access reaches, the fallback X11 under X11 itself.
bool holds(const FlatpakGrant &a, const FlatpakGrant &b)
{
    if (isPlaceKey(a.key) && isPlaceKey(b.key))
        return placeHolds(a.name, b.name);
    if (a.key == b.key && (a.key == QLatin1String("sessionService") || a.key == QLatin1String("systemService")))
        return nameHolds(a.name, b.name);
    if (a.key == QLatin1String("bus") && b.key == QLatin1String("sessionService"))
        return true;
    if (a.key == QLatin1String("systemBus") && b.key == QLatin1String("systemService"))
        return true;
    if (a.key == QLatin1String("devices")
        && (b.key == QLatin1String("input") || b.key == QLatin1String("usb") || b.key == QLatin1String("kvm") || b.key == QLatin1String("usbPortal")))
        return true;
    if (a.key == QLatin1String("usb") && b.key == QLatin1String("usbPortal"))
        return true;
    if (a.key == QLatin1String("usbPortal") && b.key == QLatin1String("usbPortal"))
        return a.name == b.name || a.name == QLatin1String("all");
    if (a.key == QLatin1String("x11") && b.key == QLatin1String("x11Fallback"))
        return true; // flatpak: "if we used to allow X11, also allow new fallback X11, as that is actually less"
    return a.key == b.key && a.name == b.name;
}

// Whether `a` grants all `b` does: it holds it at its level or above (a whole bus, all devices: every level).
bool coversGrant(const FlatpakGrant &a, const FlatpakGrant &b)
{
    if (!holds(a, b))
        return false;
    return a.key != b.key && !(isPlaceKey(a.key) && isPlaceKey(b.key)) ? true : a.level >= b.level;
}

} // namespace

std::optional<FlatpakPermissions> flatpakPermissions(const QByteArray &metadata, FlatpakReading reading)
{
    const std::optional<Parsed> parsed = parse(metadata, reading);
    if (!parsed)
        return std::nullopt;
    const Parsed &p = *parsed;
    FlatpakPermissions out;
    out.appId = p.appId;

    QStringList placeNames = p.places.keys();
    std::sort(placeNames.begin(), placeNames.end());
    QStringList session = p.session.keys(), system = p.system.keys();
    std::sort(session.begin(), session.end());
    std::sort(system.begin(), system.end());
    QStringList portal = p.usbPortal, hidden = p.usbHidden;
    std::sort(portal.begin(), portal.end());
    std::sort(hidden.begin(), hidden.end());

    QList<FlatpakGrant> grants;
    QSet<QString> classes = p.classes;
    for (const QString &place : std::as_const(placeNames))
        classes.insert(placeClass(place));
    if (!portal.isEmpty())
        classes.insert(QStringLiteral("usbPortal"));
    if (!hidden.isEmpty())
        classes.insert(QStringLiteral("usbHidden"));
    for (const QString &key : classOrder()) {
        if (!classes.contains(key))
            continue;
        if (isPlaceKey(key)) {
            for (const QString &place : std::as_const(placeNames)) {
                if (placeClass(place) == key)
                    grants.append({key, place, p.places.value(place)});
            }
        } else if (key == QLatin1String("usbPortal") || key == QLatin1String("usbHidden")) {
            for (const QString &query : key == QLatin1String("usbPortal") ? std::as_const(portal) : std::as_const(hidden))
                grants.append({key, query, 1});
        } else {
            grants.append({key, {}, 1});
        }
    }
    for (const QString &name : std::as_const(session))
        grants.append({QStringLiteral("sessionService"), name, p.session.value(name)});
    for (const QString &name : std::as_const(system))
        grants.append({QStringLiteral("systemService"), name, p.system.value(name)});
    for (const QString &text : p.other)
        grants.append({QStringLiteral("other"), text, 1});

    // flatpakAccess's flat list (SD25's classes, as before ADR-0049): each class once, then the names and the grants the
    // Store does not know, 30 lines at most: the rest counted, never dropped unsaid (the named classes come first, so they
    // stay). Its x11 is x11 written, or fallback-x11 without a Wayland socket; ipc and shm are sharedMemory; the USB portal's
    // devices are usb.
    QSet<QString> flat = classes;
    flat.remove(QStringLiteral("x11Fallback"));
    flat.remove(QStringLiteral("x11"));
    if (p.x11 || (p.x11Fallback && !p.wayland))
        flat.insert(QStringLiteral("x11"));
    if (flat.remove(QStringLiteral("ipc")) | flat.remove(QStringLiteral("shm")))
        flat.insert(QStringLiteral("sharedMemory"));
    flat.remove(QStringLiteral("usbHidden"));
    if (flat.remove(QStringLiteral("usbPortal")))
        flat.insert(QStringLiteral("usb"));
    for (const QString &key : flatClassOrder()) {
        if (flat.contains(key))
            out.access.append(key);
    }
    for (const QString &name : std::as_const(session))
        out.access.append(QStringLiteral("sessionService:") + name);
    for (const QString &name : std::as_const(system))
        out.access.append(QStringLiteral("systemService:") + name);
    for (const QString &text : p.other)
        out.access.append(QStringLiteral("other:") + text);
    if (out.access.size() > kAccessMax) {
        const qsizetype more = out.access.size() - (kAccessMax - 1);
        out.access = out.access.mid(0, kAccessMax - 1);
        out.access.append(QStringLiteral("more:%1").arg(more));
    }

    if (grants.size() > kMaxFlatpakGrants) {
        out.more = int(grants.size() - kMaxFlatpakGrants);
        grants = grants.mid(0, kMaxFlatpakGrants);
    }
    out.grants = grants;
    return out;
}

QList<FlatpakPermissionChange> diffFlatpakPermissions(const FlatpakPermissions &before, const FlatpakPermissions &after)
{
    QList<FlatpakPermissionChange> added, widened, removed, narrowed;
    const auto hiddenEntry = [](const FlatpakGrant &g) { return g.key == QLatin1String("usbHidden"); };
    const auto coveredBy = [&hiddenEntry](const FlatpakGrant &g, const QList<FlatpakGrant> &side) {
        return std::any_of(side.cbegin(), side.cend(), [&](const FlatpakGrant &o) { return !hiddenEntry(o) && coversGrant(o, g); });
    };
    // What the other side had of a grant it does not cover: the same grant at another level, or a grant one holds of the
    // other (a wider or a narrower place, name or class). The same grant first, for its level.
    const auto related = [&hiddenEntry](const FlatpakGrant &g, const QList<FlatpakGrant> &side) -> const FlatpakGrant * {
        for (const FlatpakGrant &o : side) {
            if (o.key == g.key && o.name == g.name)
                return &o;
        }
        for (const FlatpakGrant &o : side) {
            if (!hiddenEntry(o) && (holds(o, g) || holds(g, o)))
                return &o;
        }
        return nullptr;
    };
    const auto contains = [](const QList<FlatpakGrant> &side, const FlatpakGrant &g) {
        return std::any_of(side.cbegin(), side.cend(), [&g](const FlatpakGrant &o) { return o.key == g.key && o.name == g.name; });
    };
    for (const FlatpakGrant &g : after.grants) {
        if (hiddenEntry(g)) {
            if (!contains(before.grants, g))
                narrowed.append({FlatpakChangeKind::Narrowed, g, {}}); // a device newly hidden from it
            continue;
        }
        if (coveredBy(g, before.grants))
            continue;
        if (const FlatpakGrant *o = related(g, before.grants))
            widened.append({FlatpakChangeKind::Widened, g, *o});
        else
            added.append({FlatpakChangeKind::Added, g, {}});
    }
    for (const FlatpakGrant &g : before.grants) {
        if (hiddenEntry(g)) {
            if (!contains(after.grants, g))
                widened.append({FlatpakChangeKind::Widened, g, {}}); // no longer hidden (flatpak's adds_usb_device)
            continue;
        }
        if (coveredBy(g, after.grants))
            continue;
        if (const FlatpakGrant *o = related(g, after.grants))
            narrowed.append({FlatpakChangeKind::Narrowed, *o, g});
        else
            removed.append({FlatpakChangeKind::Removed, g, {}});
    }
    // A narrowed grant may be named twice (two places it held, one left): once.
    QList<FlatpakPermissionChange> uniqueNarrowed;
    for (const FlatpakPermissionChange &c : std::as_const(narrowed)) {
        if (std::none_of(uniqueNarrowed.cbegin(), uniqueNarrowed.cend(), [&c](const FlatpakPermissionChange &u) { return u.grant == c.grant; })
            && std::none_of(widened.cbegin(), widened.cend(), [&c](const FlatpakPermissionChange &w) { return w.grant == c.grant; }))
            uniqueNarrowed.append(c);
    }
    // A cut list cannot be compared: what it does not name may be new.
    if (after.more > 0)
        added.append({FlatpakChangeKind::Added, {QStringLiteral("more"), QString::number(after.more), 1}, {}});
    return added + widened + removed + uniqueNarrowed;
}

bool asksForMore(const QList<FlatpakPermissionChange> &changes)
{
    return std::any_of(changes.cbegin(), changes.cend(), [](const FlatpakPermissionChange &c) {
        return c.kind == FlatpakChangeKind::Added || c.kind == FlatpakChangeKind::Widened;
    });
}

QString changeKindName(FlatpakChangeKind kind)
{
    switch (kind) {
    case FlatpakChangeKind::Added:
        return QStringLiteral("added");
    case FlatpakChangeKind::Widened:
        return QStringLiteral("widened");
    case FlatpakChangeKind::Removed:
        return QStringLiteral("removed");
    case FlatpakChangeKind::Narrowed:
        return QStringLiteral("narrowed");
    }
    return {};
}

} // namespace grassfield::store
