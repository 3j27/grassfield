#include "removal.h"

#include <QRegularExpression>

namespace grassfield::store {

namespace {

// grassfield-store-helper's denied(): the fixed list, then the prefixes (the name itself or <prefix>-anything).
const QSet<QString> &fixedSystem()
{
    static const QSet<QString> names{
        QStringLiteral("base"),         QStringLiteral("base-devel"), QStringLiteral("filesystem"),
        QStringLiteral("glibc"),        QStringLiteral("bash"),       QStringLiteral("coreutils"),
        QStringLiteral("util-linux"),   QStringLiteral("shadow"),     QStringLiteral("pam"),
        QStringLiteral("sudo"),         QStringLiteral("polkit"),     QStringLiteral("dbus"),
        QStringLiteral("dbus-broker"),  QStringLiteral("dbus-broker-units"),
        QStringLiteral("kmod"),         QStringLiteral("mkinitcpio"), QStringLiteral("dracut"),
        QStringLiteral("grub"),         QStringLiteral("efibootmgr"), QStringLiteral("refind"),
        QStringLiteral("syslinux"),     QStringLiteral("snapper"),    QStringLiteral("btrfs-progs"),
        QStringLiteral("cryptsetup"),   QStringLiteral("lvm2"),       QStringLiteral("plymouth"),
        QStringLiteral("archlinux-keyring"), QStringLiteral("intel-ucode"), QStringLiteral("amd-ucode"),
        // The session's runtime (ADR-0044 D3); its prefixes are in protection().
        QStringLiteral("hyprland"),     QStringLiteral("quickshell"), QStringLiteral("networkmanager"),
        QStringLiteral("mesa"),         QStringLiteral("wireplumber"), QStringLiteral("sddm"),
        QStringLiteral("uwsm"),         QStringLiteral("gnome-keyring")};
    return names;
}

// The apps Omarchy installs on every machine and itself offers to remove (omarchy-remove-preinstalls; ADR-0044 D2): they are
// on its lists but are not the system's. Held to the helper's list by tests/integration/store_helper.sh.
const QSet<QString> &preinstalledApps()
{
    static const QSet<QString> names{
        QStringLiteral("aether"),       QStringLiteral("cliamp"),     QStringLiteral("libreoffice-fresh"), QStringLiteral("xournalpp"),
        QStringLiteral("pinta"),        QStringLiteral("obsidian"),   QStringLiteral("obs-studio"),        QStringLiteral("kdenlive"),
        QStringLiteral("moonlight-qt"), QStringLiteral("lazydocker"), QStringLiteral("omacut"),            QStringLiteral("omacalc"),
        QStringLiteral("omawrite")};
    return names;
}

bool hasPrefix(const QString &name, QLatin1StringView prefix)
{
    return name == prefix || (name.startsWith(prefix) && name.size() > prefix.size() && name.at(prefix.size()) == QLatin1Char('-'));
}

} // namespace

QSet<QString> parsePackageList(const QByteArray &text)
{
    QSet<QString> out;
    for (QByteArray line : text.split('\n')) {
        const int hash = line.indexOf('#');
        if (hash >= 0)
            line.truncate(hash);
        for (const QByteArray &word : line.simplified().split(' ')) {
            if (!word.isEmpty())
                out.insert(QString::fromUtf8(word));
        }
    }
    return out;
}

Protection protection(const QString &name, const DenyList &deny)
{
    if (hasPrefix(name, QLatin1StringView("grassfield")))
        return Protection::Grassfield;
    if (hasPrefix(name, QLatin1StringView("omarchy")) || hasPrefix(name, QLatin1StringView("yay")))
        return Protection::Omarchy;
    if (fixedSystem().contains(name) || hasPrefix(name, QLatin1StringView("linux")) || hasPrefix(name, QLatin1StringView("systemd"))
        || hasPrefix(name, QLatin1StringView("limine")) || hasPrefix(name, QLatin1StringView("pacman"))
        || hasPrefix(name, QLatin1StringView("qt6")) || hasPrefix(name, QLatin1StringView("pipewire"))
        || hasPrefix(name, QLatin1StringView("xdg-desktop-portal")) || name.endsWith(QLatin1String("-firmware")) || name.contains(QLatin1String("-firmware-")) || deny.holdPkg.contains(name))
        return Protection::System;
    if (preinstalledApps().contains(name))
        return Protection::None; // on Omarchy's lists, but the user may remove it (HoldPkg, above, still keeps it)
    if (deny.omarchy.contains(name))
        return Protection::Omarchy;
    return Protection::None;
}

Removal removal(const QString &package, const RemovalFacts &facts, const DenyList &deny)
{
    if (!facts.installed)
        return Removal::NotInstalled;
    switch (protection(package, deny)) {
    case Protection::System:
        return Removal::PartOfSystem;
    case Protection::Omarchy:
        return Removal::PartOfOmarchy;
    case Protection::Grassfield:
        return Removal::PartOfGrassfield;
    case Protection::None:
        break;
    }
    if (!facts.explicitlyInstalled)
        return Removal::Dependency;
    if (!facts.inRepository)
        return Removal::NotFromRepository;
    if (!facts.ownsEntry)
        return Removal::NotAnApp;
    if (!deny.omarchyRead())
        return Removal::ListsMissing;
    return Removal::Removable;
}

QString protectedInPlan(const QStringList &plan, const DenyList &deny)
{
    for (const QString &line : plan) {
        const QString name = line.section(QLatin1Char(' '), 0, 0);
        if (!name.isEmpty() && protection(name, deny) != Protection::None)
            return name;
    }
    return {};
}

QStringList dependentsFromError(const QByteArray &pacmanOutput)
{
    // pacman 7, on stdout: ":: removing glib2 breaks dependency 'glib2' required by accountsservice"
    static const QRegularExpression re(QStringLiteral("breaks dependency '[^']*' required by ([a-z0-9@_+][a-z0-9@._+-]*)"));
    QStringList out;
    auto it = re.globalMatch(QString::fromUtf8(pacmanOutput));
    while (it.hasNext()) {
        const QString name = it.next().captured(1);
        if (!out.contains(name))
            out.append(name);
    }
    out.sort();
    return out;
}

} // namespace grassfield::store
