#include "activityapp.h"

#include "autoappearance.h"
#include "chromecaps.h"
#include "runmode.h"
#include "shortcutstyle.h"
#include "translationloader.h"

#include <QClipboard>
#include <QDBusMessage>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcess>
#include <QTime>
#include <QWindow>

#include <pwd.h>

#include <algorithm>

namespace activity {

namespace {

constexpr qint64 kConfigMax = 1024 * 1024; // grassfield.json (ADR-0020: a real one is a few KiB)

QString configFile()
{
    return grassfield::apps::runmode::configDir() + QStringLiteral("/grassfield.json");
}

const Tab kTabs[] = {Tab::Cpu, Tab::Memory, Tab::Energy, Tab::Disk, Tab::Network};

QString tabTitle(Tab tab)
{
    switch (tab) {
    case Tab::Cpu:
        return QCoreApplication::translate("ActivityApp", "CPU");
    case Tab::Memory:
        return QCoreApplication::translate("ActivityApp", "Memory");
    case Tab::Energy:
        return QCoreApplication::translate("ActivityApp", "Energy");
    case Tab::Disk:
        return QCoreApplication::translate("ActivityApp", "Disk");
    case Tab::Network:
        return QCoreApplication::translate("ActivityApp", "Network");
    }
    return QString();
}

} // namespace

ActivityApp::ActivityApp(Options options, QString statePath, QObject *parent)
    : QObject(parent)
    , m_options(std::move(options))
    , m_statePath(std::move(statePath))
    , m_state(readState(m_statePath))
    , m_actions(m_options.procRoot)
    , m_inspectors(m_options.procRoot, m_options.uid, m_options.clockTicks)
    , m_apps(DesktopApps::fromEnvironment())
{
    qRegisterMetaType<SnapshotPtr>();
    m_worker = new SamplerWorker(m_options);
    m_worker->moveToThread(&m_thread);
    connect(&m_thread, &QThread::finished, m_worker, &QObject::deleteLater);
    connect(this, &ActivityApp::sampleRequested, m_worker, &SamplerWorker::sample, Qt::QueuedConnection);
    connect(m_worker, &SamplerWorker::sampled, this, &ActivityApp::takeSnapshot, Qt::QueuedConnection);
    m_thread.setObjectName(QStringLiteral("activity-sampler"));
    m_thread.start(QThread::LowPriority);

    // AM57: Inspect's reads run on the sampler's thread too (AD35), between its samples.
    m_inspectors.setWorker(m_worker);
    m_inspectors.setInterval(m_state.interval);
    m_inspectors.setNames(
        [this](int pid, quint64 start) {
            const TableRow *row = m_table.processRow(pid, start);
            return row ? row->name : QString();
        },
        [this](uint32_t uid) { return userName(uid); });
    connect(&m_inspectors, &Inspectors::opened, this, &ActivityApp::inspectRequested);
    // Never qGuiApp: a static cast, undefined where the application is a QCoreApplication (the backend's tests; UBSan).
    if (auto *gui = qobject_cast<QGuiApplication *>(QCoreApplication::instance()))
        connect(gui, &QGuiApplication::focusWindowChanged, this, &ActivityApp::focusWindowChanged);

    m_timer.setInterval(m_state.interval * 1000);
    connect(&m_timer, &QTimer::timeout, this, [this] {
        if (m_quick) { // the second sample after a gap came one second after the first: back to the interval
            m_quick = false;
            m_timer.setInterval(m_state.interval * 1000);
        }
        requestSample();
    });
    m_saveTimer.setSingleShot(true);
    m_saveTimer.setInterval(500);
    connect(&m_saveTimer, &QTimer::timeout, this, [this] { writeState(m_statePath, m_state); });
    connect(&m_inhibitors, &InhibitorWatch::changed, this, [this] {
        if (m_state.tab == Tab::Energy)
            requestSample();
    });
    connect(&m_battery, &BatteryWatch::changed, this, [this] { m_summary.setBattery(m_battery.state()); });
    connect(&m_table, &ProcessTable::selectionChanged, this, &ActivityApp::updateActionTargets);
    m_summary.setDiskMode(m_state.diskGraph);
    m_summary.setNetworkMode(m_state.networkGraph);

    // Appearance follows grassfield.json (read only), like every Grassfield surface (as Preview and the Store).
    m_macDevice = grassfield::apps::macDeviceHere();
    const QString file = configFile();
    const QString dir = QFileInfo(file).absolutePath();
    if (QFileInfo(dir).isDir())
        m_watcher.addPath(dir);
    if (QFileInfo::exists(file))
        m_watcher.addPath(file);
    const auto reread = [this] {
        const QString f = configFile();
        if (QFileInfo::exists(f) && !m_watcher.files().contains(f))
            m_watcher.addPath(f);
        readAppearance();
    };
    connect(&m_watcher, &QFileSystemWatcher::fileChanged, this, reread);
    connect(&m_watcher, &QFileSystemWatcher::directoryChanged, this, reread);
    readAppearance();
    m_autoTimer.setInterval(grassfield::apps::kAutoRecheckMs);
    connect(&m_autoTimer, &QTimer::timeout, this, [this] {
        if (m_autoAppearance)
            readAppearance();
    });
    m_autoTimer.start();

    m_table.setView(m_state.view);
    applyTab();
    m_summary.setTab(m_state.tab);
}

ActivityApp::~ActivityApp()
{
    if (m_saveTimer.isActive()) {
        m_saveTimer.stop();
        writeState(m_statePath, m_state);
    }
    m_thread.quit();
    m_thread.wait();
}

bool ActivityApp::devSession() const
{
    return grassfield::apps::runmode::dev();
}

const TabState &ActivityApp::tabState() const
{
    return m_state.tabs.at(m_state.tab);
}

TabState &ActivityApp::tabState()
{
    return m_state.tabs[m_state.tab];
}

void ActivityApp::applyTab()
{
    const TabState &t = tabState();
    m_table.setColumns(t.columns);
    m_table.setSort(t.sort, t.descending);
    emit columnsChanged();
}

void ActivityApp::setTab(const QString &key)
{
    const std::optional<Tab> tab = tabFromKey(key);
    if (!tab || *tab == m_state.tab)
        return;
    m_state.tab = *tab;
    applyTab();
    m_summary.setTab(*tab);
    emit tabChanged();
    scheduleSave();
    // The tab reads other files (ADR-0038 d): the next sample comes now, and the interval starts again from it.
    requestSample();
    if (m_shown && !m_quick)
        m_timer.start();
}

QVariantList ActivityApp::tabs() const
{
    QVariantList list;
    for (Tab t : kTabs)
        list << QVariantMap{{QStringLiteral("key"), tabKey(t)}, {QStringLiteral("title"), tabTitle(t)}};
    return list;
}

void ActivityApp::setView(const QString &key)
{
    const std::optional<View> view = viewFromKey(key);
    if (!view || (*view == m_state.view && *view != View::Selected))
        return;
    const unsigned readsBefore = readsForView(m_state.view);
    m_state.view = *view;
    m_table.setView(*view);
    emit viewChanged();
    scheduleSave();
    if (readsForView(*view) != readsBefore)
        requestSample(); // the GPU views read the GPU clients (AM49): a sample now fills them
}

QVariantList ActivityApp::views() const
{
    QVariantList list;
    for (View v : activity::views())
        list << QVariantMap{{QStringLiteral("key"), viewKey(v)}, {QStringLiteral("title"), activity::viewTitle(v)}};
    return list;
}

void ActivityApp::setSearch(const QString &text)
{
    if (text == m_search)
        return;
    m_search = text;
    m_table.setSearch(text);
    emit searchChanged();
}

void ActivityApp::setInterval(int seconds)
{
    if (seconds != 1 && seconds != 2 && seconds != 5)
        return;
    if (seconds == m_state.interval)
        return;
    m_state.interval = seconds;
    if (!m_quick)
        m_timer.setInterval(seconds * 1000);
    m_inspectors.setInterval(seconds);
    emit intervalChanged();
    scheduleSave();
}

QVariantList ActivityApp::columns() const
{
    const TabState &t = tabState();
    QVariantList list;
    const std::vector<Column> &defaults = tabColumns(m_state.tab).defaults;
    for (Column c : tabColumns(m_state.tab).all) {
        const QString key = columnKey(c);
        const bool shown = std::find(t.columns.begin(), t.columns.end(), c) != t.columns.end();
        const bool optional = std::find(defaults.begin(), defaults.end(), c) == defaults.end();
        list << QVariantMap{{QStringLiteral("key"), key},
                            {QStringLiteral("title"), columnTitle(c, m_swapped)},
                            {QStringLiteral("shown"), shown},
                            {QStringLiteral("optional"), optional},
                            {QStringLiteral("hideable"), c != Column::Name},
                            {QStringLiteral("numeric"), columnIsNumeric(c)},
                            {QStringLiteral("width"), t.widths.value(key, 0)}};
    }
    return list;
}

QVariantList ActivityApp::shownColumns() const
{
    const TabState &t = tabState();
    QVariantList list;
    for (Column c : t.columns) {
        const QString key = columnKey(c);
        list << QVariantMap{{QStringLiteral("key"), key},
                            {QStringLiteral("title"), columnTitle(c, m_swapped)},
                            {QStringLiteral("numeric"), columnIsNumeric(c)},
                            {QStringLiteral("width"), t.widths.value(key, 0)}};
    }
    return list;
}

void ActivityApp::setColumnShown(const QString &key, bool shown)
{
    const std::optional<Column> c = columnFromKey(key);
    const std::vector<Column> &all = tabColumns(m_state.tab).all;
    if (!c || *c == Column::Name || std::find(all.begin(), all.end(), *c) == all.end())
        return;
    TabState &t = tabState();
    auto it = std::find(t.columns.begin(), t.columns.end(), *c);
    if (shown == (it != t.columns.end()))
        return;
    if (shown) {
        // In its default place among the shown columns: after the shown column that precedes it in the tab's order.
        auto pos = t.columns.end();
        for (Column other : all) {
            if (other == *c)
                break;
            auto found = std::find(t.columns.begin(), t.columns.end(), other);
            if (found != t.columns.end())
                pos = found + 1;
        }
        t.columns.insert(pos, *c);
    } else {
        t.columns.erase(it);
        if (t.sort == *c) { // the sort column hidden: the tab's default sort again
            t.sort = tabColumns(m_state.tab).sort;
            t.descending = true;
        }
    }
    applyTab();
    scheduleSave();
    // A column may read more (Wake Ups, Command; AD10): a sample now fills it.
    requestSample();
}

void ActivityApp::setColumnWidth(const QString &key, int width)
{
    const std::optional<Column> c = columnFromKey(key);
    if (!c)
        return;
    TabState &t = tabState();
    const int w = std::clamp(width, 24, 4000);
    if (t.widths.value(key) == w)
        return;
    t.widths.insert(key, w);
    emit columnsChanged();
    scheduleSave();
}

void ActivityApp::sortBy(const QString &key)
{
    const std::optional<Column> c = columnFromKey(key);
    if (!c)
        return;
    TabState &t = tabState();
    if (t.sort == *c) {
        t.descending = !t.descending;
    } else {
        t.sort = *c;
        t.descending = columnIsNumeric(*c); // numbers start with the largest, text with A (AM10)
    }
    m_table.setSort(t.sort, t.descending);
    emit columnsChanged();
    scheduleSave();
}

void ActivityApp::copySelection()
{
    if (m_table.selectedCount() == 0)
        return;
    if (auto *app = qobject_cast<QGuiApplication *>(QCoreApplication::instance()))
        app->clipboard()->setText(m_table.copyText());
}

// AM50: the actions follow the selection, and the rows' owners as the last sample gave them.
void ActivityApp::updateActionTargets()
{
    const std::vector<TableRow> rows = m_table.selectedRows();
    std::vector<ProcessActions::Target> targets;
    for (const TableRow &r : rows)
        targets.push_back({r.process.pid, r.process.start, r.name, r.process.own, r.kernel});
    m_actions.setSelection(std::move(targets));
    const bool inspectable = rows.size() == 1 && !rows.front().kernel; // AM3: the Info button, one row
    if (inspectable != m_inspectable) {
        m_inspectable = inspectable;
        emit inspectChanged();
    }
}

bool ActivityApp::canInspect() const
{
    return m_inspectable;
}

QObject *ActivityApp::focusWindow() const
{
    return QGuiApplication::focusWindow();
}

void ActivityApp::inspectSelection()
{
    const std::vector<TableRow> rows = m_table.selectedRows();
    if (rows.size() == 1 && !rows.front().kernel)
        m_inspectors.open(rows.front().process.pid, rows.front().process.start, rows.front().name);
}

void ActivityApp::inspectRow(int row)
{
    const TableRow *r = m_table.rowAt(row);
    if (r && !r->kernel)
        m_inspectors.open(r->process.pid, r->process.start, r->name);
}

void ActivityApp::closeInspection(QObject *inspection)
{
    m_inspectors.close(qobject_cast<Inspection *>(inspection));
}

void ActivityApp::saveSize(int width, int height)
{
    if (width == m_state.width && height == m_state.height)
        return;
    m_state.width = width;
    m_state.height = height;
    scheduleSave();
}

void ActivityApp::setGraphMode(const QString &graph, const QString &mode)
{
    if (graph == QLatin1String("disk") && (mode == QLatin1String("io") || mode == QLatin1String("data")) && mode != m_state.diskGraph) {
        m_state.diskGraph = mode;
        m_summary.setDiskMode(mode);
        scheduleSave();
    } else if (graph == QLatin1String("network") && (mode == QLatin1String("packets") || mode == QLatin1String("data"))
               && mode != m_state.networkGraph) {
        m_state.networkGraph = mode;
        m_summary.setNetworkMode(mode);
        scheduleSave();
    }
}

void ActivityApp::setWindowShown(bool shown)
{
    if (shown == m_shown)
        return;
    m_shown = shown;
    if (!shown) {
        m_timer.stop(); // AM8, AM-P3: no per-process sample while the window is not on screen
        return;
    }
    // Back on screen: a sample at once, and no rate drawn across the gap (AM8). Its rates show "—", so the next sample
    // comes a second later rather than a whole interval.
    if (m_sampledOnce) {
        m_forget = true;
        m_quick = m_state.interval > 1;
        m_timer.setInterval(m_quick ? 1000 : m_state.interval * 1000);
    }
    requestSample();
    m_timer.start();
}

void ActivityApp::requestSample()
{
    if (!m_shown)
        return;
    if (m_busy) {
        m_again = true; // one at a time: the next starts when this one is back
        return;
    }
    m_busy = true;
    if (m_state.tab == Tab::Energy) {
        m_inhibitors.refresh(); // AM38: asked at each sample while the Energy tab is shown
        m_battery.refresh();    // AM39: the battery's figures and graph, the same way
    }
    emit sampleRequested(readsForColumns(m_state.tab, tabState().columns) | readsForView(m_state.view), m_state.interval, m_forget);
    m_forget = false;
}

void ActivityApp::takeSnapshot(const SnapshotPtr &snapshot, unsigned reads)
{
    m_busy = false;
    m_sampledOnce = true;
    if (reads & ReadProcesses)
        ++m_processSamples;
    if ((reads & ReadSystemMemory) && snapshot->system.memory.ok && m_swapped != !snapshot->system.memory.swapIsZramOnly) {
        m_swapped = !snapshot->system.memory.swapIsZramOnly; // AM34: Compressed or Swapped Memory
        m_table.setSwappedMemory(m_swapped);
        m_inspectors.setSwappedMemory(m_swapped);
        emit columnsChanged();
    }
    m_summary.addSample(*snapshot);
    // AM47: a GPU's name from pci.ids, else its card's place ("GPU 1" for card0), for the headers of Processes, by GPU.
    bool named = false;
    for (const GpuDevice &gpu : snapshot->gpus) {
        const QString pdev = QString::fromStdString(gpu.pdev);
        const QString name = !gpu.model.empty() ? QString::fromStdString(gpu.model)
                             : gpu.card >= 0 ? QCoreApplication::translate("ActivityApp", "GPU %1").arg(gpu.card + 1)
                                             : pdev;
        if (m_gpuNames.value(pdev) != name) {
            m_gpuNames.insert(pdev, name);
            named = true;
        }
    }
    if (named)
        m_table.setGpuNames(m_gpuNames);
    m_table.setRows(tableRows(*snapshot));
    updateActionTargets();
    m_inspectors.namesChanged(); // a parent's or a group leader's name may have come
    m_ready = true;
    emit sampled();
    if (m_again) {
        m_again = false;
        requestSample();
    }
}

std::vector<TableRow> ActivityApp::tableRows(const Snapshot &snapshot)
{
    const double ticks = m_options.clockTicks > 0 ? static_cast<double>(m_options.clockTicks) : 100.0;
    std::vector<TableRow> rows;
    rows.reserve(snapshot.rows.size() + 1);
    TableRow kernel;
    kernel.kernel = true;
    kernel.process.systemAccount = true;
    kernel.process.threads = snapshot.kernel.threads;
    kernel.process.cpuTicks = snapshot.kernel.cpuTicks;
    kernel.process.cpuPercent = snapshot.kernel.cpuPercent;
    kernel.cpuSeconds = static_cast<double>(snapshot.kernel.cpuTicks) / ticks;
    kernel.user = userName(0);
    if (snapshot.kernel.threads > 0) // a pid namespace without kernel threads (a container) has no Kernel row
        rows.push_back(std::move(kernel));
    const QSet<int> &sleepers = m_inhibitors.pids();
    for (const ProcessRow &p : snapshot.rows) {
        TableRow r;
        r.process = p;
        r.cpuSeconds = static_cast<double>(p.cpuTicks) / ticks;
        r.name = QString::fromStdString(p.name);
        r.user = userName(p.uid);
        if (p.own && !p.appId.empty()) {
            const DesktopApp &app = m_apps.app(QString::fromStdString(p.appId));
            r.appName = app.name;
            r.icon = app.icon;
        }
        r.preventingSleep = sleepers.contains(p.pid);
        rows.push_back(std::move(r));
    }
    return rows;
}

QString ActivityApp::userName(uint32_t uid)
{
    auto it = m_users.constFind(uid);
    if (it != m_users.constEnd())
        return *it;
    QString name = QString::number(uid);
    passwd pw{};
    passwd *found = nullptr;
    char buf[4096];
    if (getpwuid_r(uid, &pw, buf, sizeof buf, &found) == 0 && found && found->pw_name)
        name = QString::fromLocal8Bit(found->pw_name);
    return *m_users.insert(uid, name);
}

void ActivityApp::scheduleSave()
{
    m_saveTimer.start();
}

void ActivityApp::readAppearance()
{
    bool dark = true, reduce = false, contrast = false;
    qreal scale = 1;
    QString accent = QStringLiteral("multicolor"), highlight = QStringLiteral("automatic"), doubleClick = QStringLiteral("zoom");
    QString shortcutSetting, formats = QStringLiteral("auto");
    QFile f(configFile());
    if (f.open(QIODevice::ReadOnly) && f.size() <= kConfigMax) {
        const QJsonObject root = QJsonDocument::fromJson(f.read(kConfigMax)).object();
        const QString setting = root.value(QStringLiteral("appearance")).toString();
        m_autoAppearance = setting == QLatin1String("auto");
        dark = grassfield::apps::isDarkAppearance(setting, QTime::currentTime());
        const QJsonObject a11y = root.value(QStringLiteral("accessibility")).toObject();
        reduce = a11y.value(QStringLiteral("reduceMotion")).toBool(false);
        contrast = a11y.value(QStringLiteral("increaseContrast")).toBool(false);
        scale = qBound(1.0, a11y.value(QStringLiteral("textSize")).toDouble(1), 1.3);
        const QString d = root.value(QStringLiteral("windows")).toObject().value(QStringLiteral("titlebarDoubleClick")).toString();
        if (d == QLatin1String("minimize") || d == QLatin1String("none"))
            doubleClick = d;
        static const QStringList names{QStringLiteral("blue"), QStringLiteral("purple"), QStringLiteral("pink"), QStringLiteral("red"),
                                       QStringLiteral("orange"), QStringLiteral("yellow"), QStringLiteral("green"), QStringLiteral("graphite")};
        const QJsonObject accentObject = root.value(QStringLiteral("accent")).toObject();
        if (names.contains(accentObject.value(QStringLiteral("color")).toString()))
            accent = accentObject.value(QStringLiteral("color")).toString();
        if (names.contains(accentObject.value(QStringLiteral("highlight")).toString()))
            highlight = accentObject.value(QStringLiteral("highlight")).toString();
        shortcutSetting = root.value(QStringLiteral("keyboard")).toObject().value(QStringLiteral("shortcutStyle")).toString();
        const QString fm = root.value(QStringLiteral("region")).toObject().value(QStringLiteral("formats")).toString();
        if (!fm.isEmpty())
            formats = fm;
    } else {
        m_autoAppearance = false;
    }
    const QLocale locale = grassfield::i18n::formatsLocale(grassfield::i18n::systemLanguage(), formats);
    if (locale != m_formats) {
        m_formats = locale;
        m_table.setLocale(locale);
        m_summary.setLocale(locale);
        m_inspectors.setLocale(locale);
    }
    const QString shortcuts = grassfield::apps::shortcutStyle(shortcutSetting, m_macDevice);
    const bool canMinimize = grassfield::apps::minimizeAvailableInFile();
    if (dark != m_dark || reduce != m_reduceMotion || contrast != m_increaseContrast || scale != m_textScale || accent != m_accentColor
        || highlight != m_accentHighlight || doubleClick != m_titlebarDoubleClick || canMinimize != m_canMinimize || shortcuts != m_shortcutStyle) {
        m_dark = dark;
        m_reduceMotion = reduce;
        m_increaseContrast = contrast;
        m_textScale = scale;
        m_accentColor = accent;
        m_accentHighlight = highlight;
        m_titlebarDoubleClick = doubleClick;
        m_canMinimize = canMinimize;
        m_shortcutStyle = shortcuts;
        emit appearanceChanged();
    }
}

QStringList reopenCommand()
{
    const QStringList ipc = grassfield::apps::runmode::shellIpcArgs();
    if (ipc.isEmpty())
        return {};
    return QStringList{QStringLiteral("qs")} + ipc
        + QStringList{QStringLiteral("dock"), QStringLiteral("reopen"), QStringLiteral("org.grassfield.Activity")};
}

QProcess *runWithTimeout(const QStringList &command, const QProcessEnvironment &env, int timeoutMs, QObject *parent)
{
    if (command.isEmpty())
        return nullptr;
    auto *process = new QProcess(parent);
    process->setProcessEnvironment(env);
    process->setProgram(command.first());
    process->setArguments(command.mid(1));
    process->setStandardOutputFile(QProcess::nullDevice());
    process->setStandardErrorFile(QProcess::nullDevice());
    QObject::connect(process, &QProcess::finished, process, &QObject::deleteLater);
    QObject::connect(process, &QProcess::errorOccurred, process, [process](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart)
            process->deleteLater();
    });
    QTimer::singleShot(timeoutMs, process, [process] { process->kill(); });
    process->start();
    return process;
}

void askShellToReopen(QObject *parent)
{
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    for (const QString &key : env.keys()) {
        if (key.startsWith(QLatin1String("QS_")))
            env.remove(key);
    }
    env.remove(QStringLiteral("XDG_ACTIVATION_TOKEN"));
    runWithTimeout(reopenCommand(), env, grassfield::apps::runmode::kShellIpcMs, parent);
}

Launch claimOrHandOver(QDBusConnection &bus, ActivityService *service, const QString &token, int answerMs)
{
    const QString name = ActivityService::serviceName();
    const QString path = QStringLiteral("/org/grassfield/Activity");
    bus.registerObject(path, service, QDBusConnection::ExportScriptableSlots);
    for (int attempt = 0; attempt < 2; ++attempt) {
        if (bus.registerService(name))
            return Launch::Run;
        QDBusMessage call = QDBusMessage::createMethodCall(name, path, QStringLiteral("org.grassfield.Activity"), QStringLiteral("Activate"));
        call << token;
        const QDBusMessage reply = bus.call(call, QDBus::Block, answerMs);
        if (reply.type() == QDBusMessage::ReplyMessage)
            return Launch::Leave;
        // Only a name left meanwhile is taken; a running app that answers late (still starting) or not at all keeps its
        // one window, as a busy app on macOS opens nothing more.
        const QString error = reply.errorName();
        if (error != QLatin1String("org.freedesktop.DBus.Error.ServiceUnknown")
            && error != QLatin1String("org.freedesktop.DBus.Error.NameHasNoOwner"))
            return Launch::Leave;
    }
    return Launch::Leave;
}

QString ActivityService::serviceName()
{
    return grassfield::apps::runmode::dev() ? QStringLiteral("org.grassfield.Activity.Dev") : QStringLiteral("org.grassfield.Activity");
}

void ActivityService::Activate(const QString &token)
{
    // An xdg-activation token is a short printable string; anything else is dropped (the window still comes forward).
    bool printable = token.size() <= 256;
    for (const QChar ch : token)
        printable = printable && ch.unicode() > 0x20 && ch.unicode() < 0x7f;
    emit activateRequested(printable ? token : QString());
}

} // namespace activity
