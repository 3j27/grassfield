// Backend of the activity monitor's window (ADR-0038 step 2a; spec AM1 to AM19, AM74): the sampler on its thread at the
// update frequency while the window is shown (AM8, AM9), the table of the tab, view and search, the columns and the sort of
// each tab, appearance from grassfield.json (read only, as every Grassfield app), and activity.json for what the window
// remembers.
#pragma once

#include "activitystate.h"
#include "desktopapps.h"
#include "inhibitors.h"
#include "processtable.h"
#include "samplerworker.h"

#include <QElapsedTimer>
#include <QFileSystemWatcher>
#include <QHash>
#include <QLocale>
#include <QObject>
#include <QThread>
#include <QTimer>
#include <QVariantList>

namespace activity {

class ActivityApp : public QObject
{
    Q_OBJECT
    // Appearance (grassfield.json), as the Store reads it.
    Q_PROPERTY(bool dark READ dark NOTIFY appearanceChanged)
    Q_PROPERTY(bool reduceMotion READ reduceMotion NOTIFY appearanceChanged)
    Q_PROPERTY(bool increaseContrast READ increaseContrast NOTIFY appearanceChanged)
    Q_PROPERTY(qreal textScale READ textScale NOTIFY appearanceChanged)
    Q_PROPERTY(QString accentColor READ accentColor NOTIFY appearanceChanged)
    Q_PROPERTY(QString accentHighlight READ accentHighlight NOTIFY appearanceChanged)
    Q_PROPERTY(QString titlebarDoubleClick READ titlebarDoubleClick NOTIFY appearanceChanged)
    Q_PROPERTY(bool canMinimize READ canMinimize NOTIFY appearanceChanged)
    Q_PROPERTY(QString shortcutStyle READ shortcutStyle NOTIFY appearanceChanged)
    // The tab ("cpu", "memory", "energy", "disk", "network") and the five tabs' keys and titles, in order (AM3, AM4).
    Q_PROPERTY(QString tab READ tab WRITE setTab NOTIFY tabChanged)
    Q_PROPERTY(QVariantList tabs READ tabs CONSTANT)
    // The view (AM12) and the views of the View menu, with their titles; the title is the toolbar's subtitle.
    Q_PROPERTY(QString view READ view WRITE setView NOTIFY viewChanged)
    Q_PROPERTY(QString viewTitle READ viewTitle NOTIFY viewChanged)
    Q_PROPERTY(QVariantList views READ views CONSTANT)
    Q_PROPERTY(QString search READ search WRITE setSearch NOTIFY searchChanged)
    // AM9: 1, 2 or 5 seconds.
    Q_PROPERTY(int interval READ interval WRITE setInterval NOTIFY intervalChanged)
    Q_PROPERTY(QObject *table READ table CONSTANT)
    // Every column of the tab, in the table's order ({key, title, shown, optional, numeric, width}): View > Columns and the
    // header's menu (AM15). `shownColumns` is the shown ones alone, in order; a width of 0 is the token width.
    Q_PROPERTY(QVariantList columns READ columns NOTIFY columnsChanged)
    Q_PROPERTY(QVariantList shownColumns READ shownColumns NOTIFY columnsChanged)
    Q_PROPERTY(QString sortKey READ sortKey NOTIFY columnsChanged)
    Q_PROPERTY(bool sortDescending READ sortDescending NOTIFY columnsChanged)
    // The size the window had when it last closed (AM2); 0 for the token size.
    Q_PROPERTY(int savedWidth READ savedWidth CONSTANT)
    Q_PROPERTY(int savedHeight READ savedHeight CONSTANT)
    // The first sample has come (until then the table is empty and says nothing).
    Q_PROPERTY(bool ready READ ready NOTIFY sampled)
    // AM-P3's dev counter: the samples that read the processes since the app started.
    Q_PROPERTY(int processSamples READ processSamples NOTIFY sampled)
    // The Network tab's line under the table (AM43).
    Q_PROPERTY(bool devSession READ devSession CONSTANT)

public:
    // `options`: the sampler's (defaultOptions(), or a fixture's in a dev session, AM79). `statePath`: activity.json.
    ActivityApp(Options options, QString statePath, QObject *parent = nullptr);
    ~ActivityApp() override;

    bool dark() const { return m_dark; }
    bool reduceMotion() const { return m_reduceMotion; }
    bool increaseContrast() const { return m_increaseContrast; }
    qreal textScale() const { return m_textScale; }
    QString accentColor() const { return m_accentColor; }
    QString accentHighlight() const { return m_accentHighlight; }
    QString titlebarDoubleClick() const { return m_titlebarDoubleClick; }
    bool canMinimize() const { return m_canMinimize; }
    QString shortcutStyle() const { return m_shortcutStyle; }

    QString tab() const { return tabKey(m_state.tab); }
    void setTab(const QString &key);
    QVariantList tabs() const;
    QString view() const { return viewKey(m_state.view); }
    void setView(const QString &key);
    QString viewTitle() const { return activity::viewTitle(m_state.view); }
    QVariantList views() const;
    QString search() const { return m_search; }
    void setSearch(const QString &text);
    int interval() const { return m_state.interval; }
    void setInterval(int seconds);
    QObject *table() { return &m_table; }
    ProcessTable &processTable() { return m_table; }
    QVariantList columns() const;
    QVariantList shownColumns() const;
    QString sortKey() const { return columnKey(tabState().sort); }
    bool sortDescending() const { return tabState().descending; }
    int savedWidth() const { return m_state.width; }
    int savedHeight() const { return m_state.height; }
    bool ready() const { return m_ready; }
    int processSamples() const { return m_processSamples; }
    bool devSession() const;

    // AM8: the window is on screen (visible, not minimized, exposed). While it is not, no sample is taken.
    Q_INVOKABLE void setWindowShown(bool shown);
    // AM15: a column of the tab shown or hidden (never the name), its width.
    Q_INVOKABLE void setColumnShown(const QString &key, bool shown);
    Q_INVOKABLE void setColumnWidth(const QString &key, int width);
    // AM10: a header clicked sorts by its column; the same header again reverses.
    Q_INVOKABLE void sortBy(const QString &key);
    // AM19: the selected rows to the clipboard.
    Q_INVOKABLE void copySelection();
    // AM2: the window's size as it closes.
    Q_INVOKABLE void saveSize(int width, int height);

    // The rows of a snapshot as the table shows them (the tests feed snapshots through it).
    std::vector<TableRow> tableRows(const Snapshot &snapshot);
    void takeSnapshot(const SnapshotPtr &snapshot, unsigned reads);

signals:
    void appearanceChanged();
    void tabChanged();
    void viewChanged();
    void searchChanged();
    void intervalChanged();
    void columnsChanged();
    void sampled();
    // Asked by the worker's thread; queued.
    void sampleRequested(unsigned reads, double interval, bool forget);

private:
    const TabState &tabState() const;
    TabState &tabState();
    void applyTab();
    void requestSample();
    void scheduleSave();
    void readAppearance();
    QString userName(uint32_t uid);

    Options m_options;
    QString m_statePath;
    ActivityState m_state;
    ProcessTable m_table;
    QThread m_thread;
    SamplerWorker *m_worker = nullptr; // lives on m_thread
    QTimer m_timer, m_saveTimer, m_autoTimer;
    bool m_shown = false, m_busy = false, m_again = false, m_forget = false, m_quick = false, m_sampledOnce = false;
    bool m_ready = false;
    int m_processSamples = 0;
    QString m_search;
    bool m_swapped = false;
    DesktopApps m_apps;
    InhibitorWatch m_inhibitors;
    QHash<uint32_t, QString> m_users;
    QFileSystemWatcher m_watcher;
    bool m_autoAppearance = false, m_macDevice = false;
    bool m_dark = true, m_reduceMotion = false, m_increaseContrast = false, m_canMinimize = true;
    qreal m_textScale = 1;
    QString m_accentColor = QStringLiteral("multicolor"), m_accentHighlight = QStringLiteral("automatic");
    QString m_titlebarDoubleClick = QStringLiteral("zoom"), m_shortcutStyle;
    QLocale m_formats;
};

// AM1: one instance. The running app owns org.grassfield.Activity on the session bus (".Dev" in a dev session, which
// shares the owner's bus); a second launch calls Activate with its activation token and leaves.
class ActivityService : public QObject
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.grassfield.Activity")

public:
    using QObject::QObject;
    static QString serviceName();

public slots:
    Q_SCRIPTABLE void Activate(const QString &token);

signals:
    void activateRequested(const QString &token);
};

} // namespace activity
