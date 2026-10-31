// $XDG_STATE_HOME/grassfield/activity.json (spec AM74, ADR-0020): version 1, written by the app only. What the window
// remembers: its size, the tab, the view, the update frequency, per tab the columns shown (in order), their widths and
// the sort, and what the Disk and Network graphs show (step 2b). A broken file or another version is set aside (renamed
// .bad) and the defaults are used.
#pragma once

#include "columns.h"
#include "processtable.h"

#include <QHash>
#include <QString>
#include <QStringList>

#include <map>
#include <vector>

namespace activity {

struct TabState {
    std::vector<Column> columns; // shown, in order; the name first
    QHash<QString, int> widths;  // by column key
    Column sort = Column::CpuPercent;
    bool descending = true;
};

struct ActivityState {
    int width = 0, height = 0; // 0: the token size (AM2)
    Tab tab = Tab::Cpu;
    View view = View::All;
    int interval = 5; // AM9: 1, 2 or 5 seconds (AD3: Normally)
    std::map<Tab, TabState> tabs;
    QString diskGraph = QStringLiteral("io");          // AM42: "io" or "data"
    QString networkGraph = QStringLiteral("packets");  // AM44: "packets" or "data"
    QString dockIcon = QStringLiteral("icon");          // AM62: "icon", "network", "disk", "cpu-usage" or "cpu-history"
    bool askEfficiency = true;                          // AM68: false once "Don't ask again" was checked
};

// AM62: View > Dock Icon's choices, in the menu's order.
const QStringList &dockIconKinds();

// The defaults: every tab with its default columns and sort.
ActivityState defaultState();
// Reads the state; anything missing or out of range takes its default. A file that is not version 1 JSON is renamed
// <path>.bad (replacing an older one) and the defaults come back.
ActivityState readState(const QString &path);
bool writeState(const QString &path, const ActivityState &state);

} // namespace activity
