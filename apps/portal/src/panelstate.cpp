#include "panelstate.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSaveFile>
#include <QUrl>

#include <algorithm>

namespace grassfield::portal {

namespace {

bool knownView(const QString &view)
{
    return view == QLatin1String("icons") || view == QLatin1String("list") || view == QLatin1String("columns")
        || view == QLatin1String("gallery");
}

// A local absolute folder URL as kept, "" for anything else.
QString folderUrl(const QString &text)
{
    // Tolerant: the panel gives its folder as QML prints a URL (a space left as it is).
    const QUrl url(text);
    if (!url.isValid() || !url.isLocalFile() || !url.host().isEmpty() || url.hasQuery() || url.hasFragment()
        || !url.toLocalFile().startsWith(u'/'))
        return {};
    return url.toString(QUrl::FullyEncoded);
}

} // namespace

PanelState::PanelState(const QString &file)
    : m_file(file)
{
}

void PanelState::load()
{
    if (m_loaded)
        return;
    m_loaded = true;
    QFile f(m_file);
    if (!f.exists())
        return;
    if (f.size() > kMaxFileBytes || !f.open(QIODevice::ReadOnly)) {
        qWarning("grassfield-portal: the panels' memory is not readable or too large; the defaults apply");
        return;
    }
    QJsonParseError error{};
    const QJsonDocument doc = QJsonDocument::fromJson(f.read(kMaxFileBytes), &error);
    if (error.error != QJsonParseError::NoError || !doc.isObject() || doc.object().value(QLatin1String("version")).toInt() != 1) {
        qWarning("grassfield-portal: the panels' memory is malformed; the defaults apply");
        return;
    }
    const QJsonObject apps = doc.object().value(QLatin1String("apps")).toObject();
    for (auto it = apps.constBegin(); it != apps.constEnd() && m_apps.size() < kMaxApps; ++it) {
        if (it.key().size() > 255 || !it.value().isObject())
            continue;
        const QJsonObject o = it.value().toObject();
        Entry e;
        e.folder = folderUrl(o.value(QLatin1String("folder")).toString());
        const QString view = o.value(QLatin1String("view")).toString();
        e.view = knownView(view) ? view : QString();
        e.expanded = o.value(QLatin1String("expanded")).toBool();
        e.used = qint64(o.value(QLatin1String("used")).toDouble());
        m_apps.insert(it.key(), e);
    }
}

PanelState::Entry PanelState::entry(const QString &appId)
{
    load();
    return m_apps.value(appId);
}

bool PanelState::remember(const QString &appId, Entry entry, qint64 now)
{
    load();
    if (appId.size() > 255)
        return false;
    entry.folder = folderUrl(entry.folder);
    if (!knownView(entry.view))
        entry.view.clear();
    entry.used = now;
    m_apps.insert(appId, entry);
    // Bounded: the least recently used applications go first.
    while (m_apps.size() > kMaxApps) {
        auto oldest = std::min_element(m_apps.begin(), m_apps.end(), [](const Entry &a, const Entry &b) { return a.used < b.used; });
        m_apps.erase(oldest);
    }

    QJsonObject apps;
    for (auto it = m_apps.constBegin(); it != m_apps.constEnd(); ++it) {
        QJsonObject o;
        if (!it->folder.isEmpty())
            o.insert(QLatin1String("folder"), it->folder);
        if (!it->view.isEmpty())
            o.insert(QLatin1String("view"), it->view);
        o.insert(QLatin1String("expanded"), it->expanded);
        o.insert(QLatin1String("used"), double(it->used));
        apps.insert(it.key(), o);
    }
    const QJsonObject root{{QLatin1String("version"), 1}, {QLatin1String("apps"), apps}};
    if (!QDir().mkpath(QFileInfo(m_file).absolutePath())) {
        qWarning("grassfield-portal: cannot create the state directory; the panels' memory is not kept");
        return false;
    }
    QSaveFile out(m_file);
    if (!out.open(QIODevice::WriteOnly) || out.write(QJsonDocument(root).toJson(QJsonDocument::Compact)) < 0 || !out.commit()) {
        qWarning("grassfield-portal: cannot write the panels' memory");
        return false;
    }
    return true;
}

} // namespace grassfield::portal
