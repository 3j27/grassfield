// The Store window's backend (ADR-0037 step 2; spec SR1-SR12, SR23, SR24 read-only, SR26-SR29): what the QML reads, and the
// work behind it off the GUI thread. Each load builds one immutable Snapshot in a worker (pacman's lists, Arch's AppStream,
// the cached catalog checked again, the web apps' launchers, the merged model) and the window swaps it in whole; a fetch
// (the catalog when its copy is older than 6 hours or on Ctrl+R, its icons, Arch's AppStream package when none is
// installed) runs only online, and never on a metered connection without Ctrl+R. Nothing here installs, removes or opens
// an app (step 3); a link opens in the browser, https only, never in a dev session.
#pragma once

#include "appstreamsource.h"
#include "catalogstore.h"
#include "channel.h"
#include "pacman.h"
#include "storemodel.h"
#include "storeview.h"

#include <QFileSystemWatcher>
#include <QLocale>
#include <QObject>
#include <QSet>
#include <QThreadPool>
#include <QTimer>
#include <QVariantList>
#include <QVariantMap>

#include <atomic>
#include <memory>
#include <optional>

namespace grassfield::store {

// Everything one load read and made; never changed once built (StoreApp::entry points into `catalog`).
struct Snapshot {
    std::optional<Catalog> catalog;
    Catalog fallback; // the built-in categories, while there is no catalog
    QString channel;               // stable or beta
    bool catalogConfigured = false; // false while this build has no hosting (a .invalid base) and no dev plumbing
    CatalogStore::Outcome catalogOutcome = CatalogStore::Outcome::Missing;
    QString catalogReason;
    QDateTime catalogFetchedAt;
    QString fetchProblem; // "" or why the last fetch of the catalog was not used: untrusted, refused, unavailable
    AppStreamData appstream;
    QString appstreamProblem; // "" or unverified, unavailable
    QList<SyncPackage> sync;
    QSet<QString> explicitPackages;
    QSet<QString> foreignWithEntry; // packages no repository has that own an application entry
    QList<view::WebAppEntry> webApps;
    QList<StoreApp> apps;
    QHash<QString, int> index; // app id -> apps
    QHash<QString, QString> tints; // app id -> hero tint (#rrggbb)
    bool pacmanRead = false;
    const QList<CatalogCategory> &categories() const { return catalog ? catalog->categories : fallback.categories; }
};

class StoreBackend : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString language READ language CONSTANT)
    Q_PROPERTY(bool devSession READ devSession CONSTANT)
    // Appearance, from grassfield.json (read only), as the other apps.
    Q_PROPERTY(bool dark READ dark NOTIFY appearanceChanged)
    Q_PROPERTY(bool reduceMotion READ reduceMotion NOTIFY appearanceChanged)
    Q_PROPERTY(bool increaseContrast READ increaseContrast NOTIFY appearanceChanged)
    Q_PROPERTY(qreal textScale READ textScale NOTIFY appearanceChanged)
    Q_PROPERTY(QString accentColor READ accentColor NOTIFY appearanceChanged)
    Q_PROPERTY(QString accentHighlight READ accentHighlight NOTIFY appearanceChanged)
    Q_PROPERTY(QString shortcutStyle READ shortcutStyle NOTIFY appearanceChanged)
    Q_PROPERTY(QString titlebarDoubleClick READ titlebarDoubleClick NOTIFY appearanceChanged)
    Q_PROPERTY(bool canMinimize READ canMinimize NOTIFY appearanceChanged)
    // Bumped each time a new snapshot is in place: the pages read their data again.
    Q_PROPERTY(int revision READ revision NOTIFY dataChanged)
    Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)
    Q_PROPERTY(bool refreshing READ refreshing NOTIFY loadingChanged)
    Q_PROPERTY(bool online READ online NOTIFY networkChanged)
    Q_PROPERTY(bool metered READ metered NOTIFY networkChanged)
    // {inUse, channel, date, old, problem}: problem is "", "unconfigured" (no hosting yet), "untrusted" (no trusted key),
    // "refused" (a bad signature, a rule, a replay) or "unavailable" (not fetched).
    Q_PROPERTY(QVariantMap catalog READ catalogStatus NOTIFY dataChanged)
    // {origin: installed | fetched | none, problem: "" | unverified | unavailable}
    Q_PROPERTY(QVariantMap appData READ appDataStatus NOTIFY dataChanged)
    // {name, initials, picture}: the local user (passwd, AccountsService's picture).
    Q_PROPERTY(QVariantMap user READ user CONSTANT)
    // {aur, flathub, flatpak, screenshots}: the optional sources (off until turned on, step 3 writes them) and the switch of
    // the screenshots (owner ST6: on).
    Q_PROPERTY(QVariantMap sources READ sources CONSTANT)

public:
    explicit StoreBackend(QObject *parent = nullptr);
    ~StoreBackend() override;

    QString language() const { return m_language; }
    bool devSession() const;
    bool dark() const { return m_dark; }
    bool reduceMotion() const { return m_reduceMotion; }
    bool increaseContrast() const { return m_increaseContrast; }
    qreal textScale() const { return m_textScale; }
    QString accentColor() const { return m_accentColor; }
    QString accentHighlight() const { return m_accentHighlight; }
    QString shortcutStyle() const { return m_shortcutStyle; }
    QString titlebarDoubleClick() const { return m_titlebarDoubleClick; }
    bool canMinimize() const { return m_canMinimize; }
    int revision() const { return m_revision; }
    bool loading() const { return m_loading; }
    bool refreshing() const { return m_refreshing; }
    bool online() const { return m_online; }
    bool metered() const { return m_metered; }
    QVariantMap catalogStatus() const;
    QVariantMap appDataStatus() const;
    QVariantMap user() const { return m_user; }
    QVariantMap sources() const;

    // Discover (the catalog's, else the built-in one) and the catalog's other sections, in order.
    Q_INVOKABLE QVariantList sections() const;
    // {id, title, symbol, count}, the catalog's (else the built-in ones), those without apps left out.
    Q_INVOKABLE QVariantList categories() const;
    // A category's apps, by name; kind "" for all, else only that source.
    Q_INVOKABLE QVariantList categoryApps(const QString &id, const QString &kind = QString()) const;
    Q_INVOKABLE QVariantList search(const QString &query) const;
    // The product page, {} when the app is not offered.
    Q_INVOKABLE QVariantMap app(const QString &id) const;
    // pacman -Si for the Information list, answered by packageInfo().
    Q_INVOKABLE void requestPackageInfo(const QString &package);
    // Installed (SR23, read only): [{group, apps}], groups in a fixed order, apps by name.
    Q_INVOKABLE QVariantList installed() const;
    // Updates (SR24, read only): software-update.json read again.
    Q_INVOKABLE QVariantMap updates() const;
    // Ctrl+R: everything read again and the catalog fetched, metered or not.
    Q_INVOKABLE void refresh();
    // A product page's Homepage or Bug tracker: https only, never in a dev session; false when not opened.
    Q_INVOKABLE bool openLink(const QString &url);
    // The image source of a screenshot ("" while screenshots are off or the Store is offline).
    Q_INVOKABLE QString screenshotSource(const QString &url) const;

    // The first load; the window calls it once its first frame is up.
    void start();

    // Screenshots on and the Store online: screenshotSource's answer, and the provider's gate (kept current for it, since
    // it fetches off the GUI thread and a page may still ask after the Store went offline).
    bool screenshotsAllowed() const { return m_screenshots && m_online; }
    std::shared_ptr<const std::atomic_bool> screenshotGate() const { return m_screenshotGate; }

signals:
    void appearanceChanged();
    void dataChanged();
    void loadingChanged();
    void networkChanged();
    void packageInfo(const QString &name, const QVariantMap &facts); // "package" is a reserved word in QML

private:
    struct Job {
        bool fetchCatalog = false;
        bool forced = false; // Ctrl+R
        bool fetchAppData = false;
    };
    void run(Job job);
    void apply(std::shared_ptr<const Snapshot> snapshot);
    void readAppearance();
    void readNetwork();
    bool catalogStale() const;
    QLocale formats() const { return m_formats; }

    QString m_language = QStringLiteral("en");
    QLocale m_formats;
    bool m_dark = false;
    bool m_reduceMotion = false;
    bool m_increaseContrast = false;
    qreal m_textScale = 1;
    QString m_accentColor = QStringLiteral("multicolor");
    QString m_accentHighlight = QStringLiteral("automatic");
    QString m_shortcutStyle = QStringLiteral("pc");
    QString m_titlebarDoubleClick = QStringLiteral("zoom");
    bool m_canMinimize = true;
    bool m_autoAppearance = false;
    bool m_macDevice = false;
    QFileSystemWatcher m_watcher;
    QTimer m_autoTimer;

    int m_revision = 0;
    bool m_loading = true;
    bool m_refreshing = false;
    bool m_online = true;
    bool m_metered = false;
    bool m_screenshots = true;
    QVariantMap m_user;
    std::shared_ptr<const Snapshot> m_snapshot;
    bool m_jobRunning = false;
    std::optional<Job> m_pendingJob;
    std::shared_ptr<std::atomic_bool> m_cancel;
    std::shared_ptr<std::atomic_bool> m_screenshotGate = std::make_shared<std::atomic_bool>(true);
    QThreadPool m_pool; // last member: waits for the jobs while the rest is still there
};

} // namespace grassfield::store
