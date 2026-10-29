// What the Open and Save panels remember per application (docs/specs/system-dialogs.md FC5, ADR-0020's persisted files):
// the last folder, the view and whether the Save panel was expanded, as the macOS panels do. One JSON file,
// $XDG_STATE_HOME/grassfield/portal-filechooser.json (runmode::stateDir()):
//   {"version": 1, "apps": {"<app id>": {"folder": "file:///home/u/Documents", "view": "list", "expanded": true,
//                                        "used": 1761650000000}}}
// At most kMaxApps applications, the least recently used dropped first. A missing, unreadable, oversized or malformed file
// is an empty memory (nothing is asked, the defaults apply); each write replaces the file whole (QSaveFile).
#pragma once

#include <QDateTime>
#include <QHash>
#include <QString>

namespace grassfield::portal {

class PanelState
{
public:
    static constexpr int kMaxApps = 64;
    static constexpr qint64 kMaxFileBytes = 256 * 1024;

    struct Entry {
        // A local folder URL ("" when none is kept), a view of Files ("icons", "list", "columns", "gallery"; "" none).
        QString folder;
        QString view;
        bool expanded = false;
        qint64 used = 0;
    };

    explicit PanelState(const QString &file);

    // The entry of `appId` ("" is the entry of applications the frontend could not name).
    Entry entry(const QString &appId);
    // Keeps `entry` for `appId` (its `used` set to `now`, ms since the epoch) and writes the file. False when it could not be
    // written (logged; the panel works on).
    bool remember(const QString &appId, Entry entry, qint64 now = QDateTime::currentMSecsSinceEpoch());

    QString file() const { return m_file; }

private:
    void load();

    QString m_file;
    bool m_loaded = false;
    QHash<QString, Entry> m_apps;
};

} // namespace grassfield::portal
