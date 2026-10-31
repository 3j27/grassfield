#include "activitystate.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSaveFile>

#include <algorithm>

namespace activity {

namespace {

constexpr int kVersion = 1;
constexpr qint64 kMaxSize = 256 * 1024;

const Tab kTabs[] = {Tab::Cpu, Tab::Memory, Tab::Energy, Tab::Disk, Tab::Network};

TabState defaultTab(Tab tab)
{
    TabState t;
    t.columns = tabColumns(tab).defaults;
    t.sort = tabColumns(tab).sort;
    t.descending = columnIsNumeric(t.sort);
    return t;
}

bool inTab(Tab tab, Column c)
{
    const std::vector<Column> &all = tabColumns(tab).all;
    return std::find(all.begin(), all.end(), c) != all.end();
}

TabState readTab(Tab tab, const QJsonObject &o)
{
    TabState t = defaultTab(tab);
    const QJsonArray columns = o.value(QStringLiteral("columns")).toArray();
    if (!columns.isEmpty()) {
        std::vector<Column> shown{Column::Name}; // the name cannot be hidden and comes first (AM15)
        for (const QJsonValue &v : columns) {
            const std::optional<Column> c = columnFromKey(v.toString());
            if (c && *c != Column::Name && inTab(tab, *c) && std::find(shown.begin(), shown.end(), *c) == shown.end())
                shown.push_back(*c);
        }
        t.columns = shown;
    }
    const QJsonObject widths = o.value(QStringLiteral("widths")).toObject();
    for (auto it = widths.constBegin(); it != widths.constEnd(); ++it) {
        const std::optional<Column> c = columnFromKey(it.key());
        const int w = it.value().toInt(-1);
        if (c && inTab(tab, *c) && w >= 24 && w <= 4000)
            t.widths.insert(it.key(), w);
    }
    const std::optional<Column> sort = columnFromKey(o.value(QStringLiteral("sort")).toString());
    if (sort && inTab(tab, *sort)) {
        t.sort = *sort;
        t.descending = o.value(QStringLiteral("descending")).toBool(columnIsNumeric(*sort));
    }
    return t;
}

void setAside(const QString &path)
{
    QFile::remove(path + QStringLiteral(".bad"));
    QFile::rename(path, path + QStringLiteral(".bad"));
}

} // namespace

ActivityState defaultState()
{
    ActivityState s;
    for (Tab tab : kTabs)
        s.tabs[tab] = defaultTab(tab);
    return s;
}

ActivityState readState(const QString &path)
{
    ActivityState s = defaultState();
    QFile f(path);
    if (!f.exists())
        return s;
    if (!f.open(QIODevice::ReadOnly) || f.size() > kMaxSize) {
        f.close();
        setAside(path);
        return s;
    }
    QJsonParseError error{};
    const QJsonDocument doc = QJsonDocument::fromJson(f.readAll(), &error);
    f.close();
    if (error.error != QJsonParseError::NoError || !doc.isObject() || doc.object().value(QStringLiteral("version")).toInt() != kVersion) {
        setAside(path);
        return s;
    }
    const QJsonObject root = doc.object();
    const QJsonObject window = root.value(QStringLiteral("window")).toObject();
    const int w = window.value(QStringLiteral("width")).toInt(0), h = window.value(QStringLiteral("height")).toInt(0);
    if (w >= 200 && w <= 16384 && h >= 150 && h <= 16384) {
        s.width = w;
        s.height = h;
    }
    if (const std::optional<Tab> tab = tabFromKey(root.value(QStringLiteral("tab")).toString()))
        s.tab = *tab;
    if (const std::optional<View> view = viewFromKey(root.value(QStringLiteral("view")).toString()); view && *view != View::Selected)
        s.view = *view; // Selected Processes holds rows of one run only
    const int interval = root.value(QStringLiteral("interval")).toInt(5);
    if (interval == 1 || interval == 2 || interval == 5)
        s.interval = interval;
    const QString disk = root.value(QStringLiteral("diskGraph")).toString();
    if (disk == QLatin1String("io") || disk == QLatin1String("data"))
        s.diskGraph = disk;
    const QString network = root.value(QStringLiteral("networkGraph")).toString();
    if (network == QLatin1String("packets") || network == QLatin1String("data"))
        s.networkGraph = network;
    const QString dock = root.value(QStringLiteral("dockIcon")).toString();
    if (dockIconKinds().contains(dock))
        s.dockIcon = dock;
    const QJsonValue ask = root.value(QStringLiteral("askEfficiency"));
    if (ask.isBool())
        s.askEfficiency = ask.toBool();
    const QString period = root.value(QStringLiteral("appHistoryPeriod")).toString();
    if (period == QLatin1String("12h") || period == QLatin1String("7d") || period == QLatin1String("30d"))
        s.appHistoryPeriod = period;
    const QJsonObject tabs = root.value(QStringLiteral("tabs")).toObject();
    for (Tab tab : kTabs) {
        const QJsonValue v = tabs.value(tabKey(tab));
        if (v.isObject())
            s.tabs[tab] = readTab(tab, v.toObject());
    }
    return s;
}

const QStringList &dockIconKinds()
{
    static const QStringList kinds{QStringLiteral("icon"), QStringLiteral("network"), QStringLiteral("disk"),
                                   QStringLiteral("cpu-usage"), QStringLiteral("cpu-history")};
    return kinds;
}

bool writeState(const QString &path, const ActivityState &state)
{
    QJsonObject root;
    root.insert(QStringLiteral("version"), kVersion);
    if (state.width > 0 && state.height > 0)
        root.insert(QStringLiteral("window"), QJsonObject{{QStringLiteral("width"), state.width}, {QStringLiteral("height"), state.height}});
    root.insert(QStringLiteral("tab"), tabKey(state.tab));
    root.insert(QStringLiteral("view"), viewKey(state.view == View::Selected ? View::All : state.view));
    root.insert(QStringLiteral("interval"), state.interval);
    root.insert(QStringLiteral("diskGraph"), state.diskGraph);
    root.insert(QStringLiteral("networkGraph"), state.networkGraph);
    root.insert(QStringLiteral("dockIcon"), state.dockIcon);
    root.insert(QStringLiteral("askEfficiency"), state.askEfficiency);
    root.insert(QStringLiteral("appHistoryPeriod"), state.appHistoryPeriod);
    QJsonObject tabs;
    for (const auto &[tab, t] : state.tabs) {
        QJsonArray columns;
        for (Column c : t.columns)
            columns.append(columnKey(c));
        QJsonObject widths;
        for (auto it = t.widths.constBegin(); it != t.widths.constEnd(); ++it)
            widths.insert(it.key(), it.value());
        tabs.insert(tabKey(tab), QJsonObject{{QStringLiteral("columns"), columns},
                                             {QStringLiteral("widths"), widths},
                                             {QStringLiteral("sort"), columnKey(t.sort)},
                                             {QStringLiteral("descending"), t.descending}});
    }
    root.insert(QStringLiteral("tabs"), tabs);
    if (!QDir().mkpath(QFileInfo(path).absolutePath()))
        return false;
    QSaveFile f(path);
    if (!f.open(QIODevice::WriteOnly))
        return false;
    f.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    f.write(QJsonDocument(root).toJson(QJsonDocument::Indented));
    return f.commit();
}

} // namespace activity
