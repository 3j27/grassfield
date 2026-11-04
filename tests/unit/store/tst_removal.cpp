// What the Store may uninstall (apps/store/src/removal.h; ADR-0037 b.1, S16; spec SR22): the deny list on the vectors the
// helper's own denied() answers in tests/integration/store_helper.sh, the reasons, the plan check and pacman's message.
#include "removal.h"
#include "storetest.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>

#include <gtest/gtest.h>

using namespace grassfield::store;

namespace {

QString protectionName(Protection p)
{
    switch (p) {
    case Protection::None:
        return QStringLiteral("none");
    case Protection::System:
        return QStringLiteral("system");
    case Protection::Omarchy:
        return QStringLiteral("omarchy");
    case Protection::Grassfield:
        return QStringLiteral("grassfield");
    }
    return {};
}

DenyList vectorDeny(const QJsonObject &v)
{
    DenyList deny;
    for (const QJsonValue &n : v.value(QStringLiteral("omarchyLists")).toArray())
        deny.omarchy.insert(n.toString());
    for (const QJsonValue &n : v.value(QStringLiteral("holdPkg")).toArray())
        deny.holdPkg.insert(n.toString());
    return deny;
}

} // namespace

TEST(Removal, SharedVectors)
{
    const QJsonObject v = QJsonDocument::fromJson(storetest::readFixture(QStringLiteral("removal-vectors.json"))).object();
    const DenyList deny = vectorDeny(v);
    const QJsonArray cases = v.value(QStringLiteral("cases")).toArray();
    ASSERT_GT(cases.size(), 80);
    for (const QJsonValue &c : cases) {
        const QString name = c.toObject().value(QStringLiteral("name")).toString();
        const QString want = c.toObject().value(QStringLiteral("protection")).toString();
        // "linux" is in the vectors' Omarchy list too: the system's reason wins.
        EXPECT_EQ(protectionName(protection(name, deny)), want) << qPrintable(name);
    }
}

// ADR-0045 D2: the apps Omarchy preinstalls and itself offers to remove are on its lists but not the system's; the rest of the
// lists stays. D3: the session's runtime is protected by name, whatever the lists say.
TEST(Removal, OptionalPreinstallsAndTheRuntime)
{
    DenyList deny;
    deny.omarchy = {QStringLiteral("libreoffice-fresh"), QStringLiteral("obs-studio"), QStringLiteral("mpv"), QStringLiteral("chromium")};
    deny.holdPkg = {QStringLiteral("pacman"), QStringLiteral("kdenlive")};
    const RemovalFacts app{true, true, true, true};
    EXPECT_EQ(removal(QStringLiteral("libreoffice-fresh"), app, deny), Removal::Removable);
    EXPECT_EQ(removal(QStringLiteral("obs-studio"), app, deny), Removal::Removable);
    EXPECT_EQ(removal(QStringLiteral("kdenlive"), app, deny), Removal::PartOfSystem) << "HoldPkg still keeps it";
    EXPECT_EQ(removal(QStringLiteral("mpv"), app, deny), Removal::PartOfOmarchy);
    EXPECT_EQ(removal(QStringLiteral("chromium"), app, deny), Removal::PartOfOmarchy);
    for (const char *name : {"hyprland", "quickshell", "networkmanager", "mesa", "qt6-base", "qt6-tools", "pipewire", "pipewire-pulse",
                             "wireplumber", "xdg-desktop-portal-hyprland", "sddm", "uwsm", "gnome-keyring"})
        EXPECT_EQ(removal(QString::fromLatin1(name), app, deny), Removal::PartOfSystem) << name;
    // Not prefixes of them by accident.
    EXPECT_EQ(removal(QStringLiteral("qt5-base"), app, deny), Removal::Removable);
    EXPECT_EQ(removal(QStringLiteral("mesa-utils"), app, deny), Removal::Removable);
}

TEST(Removal, PackageList)
{
    const QSet<QString> names = parsePackageList("# Omarchy core package list\n\naether\nalsa-utils  # sound\n  btop chromium\n#gone\n");
    EXPECT_EQ(names, (QSet<QString>{QStringLiteral("aether"), QStringLiteral("alsa-utils"), QStringLiteral("btop"), QStringLiteral("chromium")}));
    EXPECT_TRUE(parsePackageList("").isEmpty());
}

TEST(Removal, Reasons)
{
    DenyList deny;
    deny.omarchy = {QStringLiteral("chromium")};
    deny.holdPkg = {QStringLiteral("pacman"), QStringLiteral("glibc")};
    const RemovalFacts app{true, true, true, true};
    EXPECT_EQ(removal(QStringLiteral("gimp"), app, deny), Removal::Removable);
    EXPECT_EQ(removal(QStringLiteral("gimp"), RemovalFacts{false, false, true, true}, deny), Removal::NotInstalled);
    EXPECT_EQ(removal(QStringLiteral("chromium"), app, deny), Removal::PartOfOmarchy);
    EXPECT_EQ(removal(QStringLiteral("grassfield-store"), app, deny), Removal::PartOfGrassfield);
    EXPECT_EQ(removal(QStringLiteral("linux-zen"), app, deny), Removal::PartOfSystem);
    EXPECT_EQ(removal(QStringLiteral("glib2"), RemovalFacts{true, false, true, false}, deny), Removal::Dependency);
    EXPECT_EQ(removal(QStringLiteral("localapp"), RemovalFacts{true, true, false, true}, deny), Removal::NotFromRepository);
    EXPECT_EQ(removal(QStringLiteral("tree"), RemovalFacts{true, true, true, false}, deny), Removal::NotAnApp);
    DenyList noLists;
    noLists.holdPkg = deny.holdPkg;
    EXPECT_EQ(removal(QStringLiteral("gimp"), app, noLists), Removal::ListsMissing);
}

TEST(Removal, PlanAndPacmanMessage)
{
    DenyList deny;
    deny.omarchy = {QStringLiteral("btop")};
    EXPECT_EQ(protectedInPlan({QStringLiteral("probe-app 1-1"), QStringLiteral("efibootmgr 18-3")}, deny), QStringLiteral("efibootmgr"));
    EXPECT_EQ(protectedInPlan({QStringLiteral("xterm 411-1"), QStringLiteral("libxaw 1.0.16-1")}, deny), QString());
    EXPECT_EQ(protectedInPlan({QStringLiteral("gs-app 1-1"), QStringLiteral("btop 1.4-1")}, deny), QStringLiteral("btop"));
    const QByteArray err = "checking dependencies...\n"
                           "error: failed to prepare transaction (could not satisfy dependencies)\n"
                           ":: removing glib2 breaks dependency 'glib2' required by accountsservice\n"
                           ":: removing glib2 breaks dependency 'glib2>=2.80' required by gtk3\n"
                           ":: removing glib2 breaks dependency 'glib2' required by accountsservice\n";
    EXPECT_EQ(dependentsFromError(err), (QStringList{QStringLiteral("accountsservice"), QStringLiteral("gtk3")}));
    EXPECT_TRUE(dependentsFromError("error: target not found: nothing\n").isEmpty());
}
