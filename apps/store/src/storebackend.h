// The Store window's backend (ADR-0037 steps 2 and 3; spec SR1-SR23, SR24 read-only, SR26-SR29): what the QML reads, and the
// work behind it off the GUI thread. Each load builds one immutable Snapshot in a worker (pacman's lists, Arch's AppStream,
// the cached catalog checked again, the web apps' launchers, the merged model) and the window swaps it in whole; a fetch
// (the catalog when its copy is older than 6 hours or on Ctrl+R, its icons, Arch's AppStream package when none is
// installed) runs only online, and never on a metered connection without Ctrl+R. Get and Uninstall… plan first (the plan
// check, plancheck.h, on a worker), then queue an operation (operations.h) once the sheet's default button is pressed;
// Open starts the app (ADR-0011). A link opens in the browser, https only, never in a dev session.
#pragma once

#include "appstreamsource.h"
#include "aur.h"
#include "catalogstore.h"
#include "channel.h"
#include "operations.h"
#include "pacman.h"
#include "plancheck.h"
#include "removal.h"
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
    QSet<QString> foreign;          // packages no repository has (pacman -Qm)
    QSet<QString> foreignWithEntry; // those of them that own an application entry
    QHash<QString, QStringList> entries; // package -> the desktop ids of its entries in /usr/share/applications
    DenyList deny;                       // what is never removed (removal.h)
    QList<view::WebAppEntry> webApps;
    // The catalog's first pinned Omarchy file that differs in the installed Omarchy ("" when they all match, ADR-0037 g):
    // no setup runs then (b.2).
    QString omarchyDiffers;
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
    // {aur, flathub, flatpak, screenshots}: the optional sources (off until turned on) and the switch of the screenshots
    // (owner ST6: on), read from grassfield.json's "store" keys (the settings window writes aur and screenshots, SD20).
    Q_PROPERTY(QVariantMap sources READ sources NOTIFY sourcesChanged)
    // The key window (QGuiApplication::focusWindow), null while no window of the Store has the keyboard. Qt matches a
    // window's Shortcuts and its global menu's keys while one of its transient children has the keyboard too, so a key
    // belongs to the key window alone (as Files' FilesApp.focusWindow).
    Q_PROPERTY(QObject *focusWindow READ focusWindow NOTIFY focusWindowChanged)
    // The queue (spec SR18): [{id, app, name, kind, state, blocked, done, total}], the running one first.
    Q_PROPERTY(QVariantList operations READ operations NOTIFY operationsChanged)
    // How the last operation of an app ended, while it says something: app id -> {kind, name, outcome, present, total,
    // details}.
    Q_PROPERTY(QVariantMap results READ results NOTIFY operationsChanged)
    // pacman stopped mid-way and left its lock (db.lck there, no pacman running): SR20's explanation, then Arch's recovery.
    Q_PROPERTY(bool staleLock READ staleLock NOTIFY operationsChanged)

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
    QObject *focusWindow() const;
    QVariantList operations() const;
    QVariantMap results() const;
    bool staleLock() const { return m_staleLock; }

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
    // Installed (SR23): [{group, apps}], groups in a fixed order, apps by name; "aur" holds the packages installed explicitly
    // from outside the repositories that the AUR knows (asked once the AUR is on), "foreign" the others that own an entry.
    Q_INVOKABLE QVariantList installed() const;
    // The AUR (step 3b2; spec SR7, SR11), each asked only while the AUR is on and the Store online, answered by a signal:
    // a search by name after Return (aurResults: the results' summaries with votes and outOfDate, the most voted first, a
    // repository's names left out; problem "" | off | offline | short | tooMany | unavailable), the AUR's facts of an AUR
    // page (aurInfo: read app(id) again), and its build script (buildScript: the PKGBUILD as plain text). `id` is an AUR
    // page's ("aur:<name>") or a catalog app whose source is the AUR.
    Q_INVOKABLE void searchAur(const QString &term);
    Q_INVOKABLE void requestAur(const QString &id);
    Q_INVOKABLE void requestBuildScript(const QString &id);
    // Updates (SR24, read only): software-update.json read again.
    Q_INVOKABLE QVariantMap updates() const;
    // Ctrl+R: everything read again and the catalog fetched, metered or not.
    Q_INVOKABLE void refresh();
    // grassfield.json for the settings window's switches (SD20, as the Settings app writes its keys, ADR-0020): {exists, ok,
    // text}, at most 1 MiB of a regular file; and its text written back whole (QSaveFile), "" or why it was not.
    Q_INVOKABLE QVariantMap readConfig() const;
    Q_INVOKABLE QString writeConfig(const QString &text) const;
    // A product page's Homepage or Bug tracker: https only, never in a dev session; false when not opened.
    Q_INVOKABLE bool openLink(const QString &url);
    // The image source of a screenshot ("" while screenshots are off or the Store is offline).
    Q_INVOKABLE QString screenshotSource(const QString &url) const;
    // Get and Uninstall… (SR14, SR22): what the operation would do, answered by planReady(app, kind, plan): {refusal: "" |
    // busy | unfinished | outdated | offline | dependency | protected | failed | unavailable, packages [{name, version, repo,
    // size}], download, installed, unfinished, upgrades, dependents, protected, detail}. kind: install or remove.
    Q_INVOKABLE void plan(const QString &id, const QString &kind);
    // What the app's buttons may do now: {installed, launcher, get: "" or why not, uninstall: "" or why not} (getBlock,
    // uninstallBlock). Read again with `revision` and `operations`.
    Q_INVOKABLE QVariantMap actions(const QString &id) const;
    // The sheet's default button: the operation joins the queue, with the plan made last for this app (false when there is
    // none, or the app cannot be installed or removed).
    Q_INVOKABLE bool install(const QString &id);
    Q_INVOKABLE bool uninstall(const QString &id);
    Q_INVOKABLE bool removeWaiting(const QString &operationId);
    Q_INVOKABLE void dismiss(const QString &id);
    // Open (SR21): the app's entry through uwsm (ADR-0011), a web app by omarchy-launch-webapp; false when it did not start.
    Q_INVOKABLE bool open(const QString &id);
    // Ctrl+Q: quits at once, or once the running operation ended (the window closes meanwhile; waiting ones are dropped).
    Q_INVOKABLE void quitWhenIdle();
    // "Open Software Update" of a refused plan (SR15): Settings at General, where Software Update lives (ADR-0033); false
    // when it did not start (in a dev session only through the fake program).
    Q_INVOKABLE bool openSoftwareUpdate();

    // The first load; the window calls it once its first frame is up.
    void start();

    // Screenshots on and the Store online: screenshotSource's answer, and the provider's gate (kept current for it, since
    // it fetches off the GUI thread and a page may still ask after the Store went offline).
    bool screenshotsAllowed() const { return m_screenshots && m_online; }
    std::shared_ptr<const std::atomic_bool> screenshotGate() const { return m_screenshotGate; }

signals:
    void appearanceChanged();
    void sourcesChanged();
    void dataChanged();
    void loadingChanged();
    void networkChanged();
    void focusWindowChanged();
    void packageInfo(const QString &name, const QVariantMap &facts); // "package" is a reserved word in QML
    void planReady(const QString &app, const QString &kind, const QVariantMap &plan);
    void operationsChanged();
    void aurResults(const QString &term, const QVariantList &apps, const QString &problem);
    void aurInfo(const QString &id);
    void buildScript(const QString &id, const QString &text, bool ok);

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
    const StoreApp *storeApp(const QString &id) const;
    // A web app of Installed that our catalog does not list ("webapp:<its launcher's file name>"): opened and removed too.
    std::optional<view::WebAppEntry> otherWebApp(const QString &id) const;
    // Why `a` cannot be installed now, or "": dev (no fake program in a dev session), missing (Omarchy's commands or the
    // helper are not there), offline, icon (a web app's icon not cached yet), omarchyChanged (a setup: the installed
    // Omarchy differs from the catalog's pins), source (its source cannot install yet).
    QString getBlock(const StoreApp &a) const;
    // "" when "Uninstall…" is offered for `a`, else why not (SR22): system, omarchy, grassfield, dependency, notApp,
    // notFromRepository, listsMissing, notInstalled, source, dev, missing, omarchyChanged.
    QString uninstallBlock(const StoreApp &a) const;
    // A setup's path (b.2): "" when Omarchy's terminal and grassfield-store-run can run it now, else dev, missing or
    // omarchyChanged.
    QString terminalBlock() const;
    SetupCheck setupCheck(const StoreApp &a, bool install) const;
    // The AUR's command (kAurAdd, kAurDrop) with the catalog's pins, checked as a setup's recipe.
    SetupCheck aurCheck(const QString &command) const;
    // An AUR operation's path (b.2): terminalBlock(), then aurUnchecked when the catalog's pins do not name the command.
    QString aurBlock(const QString &command) const;
    // The AUR package an id names: an AUR page's, or a catalog app's whose source is the AUR ("" otherwise).
    QString aurName(const QString &id) const;
    AurConfig aurConfig() const;
    // What the AUR answered, kept for this run (full: an info answer, with its dependencies; a search's has none).
    void rememberAur(const QList<AurPackage> &packages, bool full);
    // The AUR pages' apps again, from what the AUR answered and what pacman says is installed.
    void rebuildAurApps();
    // The packages installed from outside the repositories, asked of the AUR once (Installed's "AUR" group).
    void askAurForForeign();
    QVariantMap withActions(QVariantMap map, const StoreApp &a) const;
    PlanTools planTools() const;
    void checkStaleLock();

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
    bool m_aur = false;
    bool m_flathub = false;
    QVariantMap m_user;
    std::shared_ptr<const Snapshot> m_snapshot;
    bool m_jobRunning = false;
    std::optional<Job> m_pendingJob;
    std::shared_ptr<std::atomic_bool> m_cancel;
    std::shared_ptr<std::atomic_bool> m_screenshotGate = std::make_shared<std::atomic_bool>(true);
    std::unique_ptr<Operations> m_operations;
    QHash<QString, InstallPlan> m_installPlans; // app id -> the plan its sheet showed
    QHash<QString, RemovePlan> m_removePlans;
    QHash<QString, AurPackage> m_aurPackages; // name -> what the AUR answered this run
    QSet<QString> m_aurFull;                  // the names an info answer gave (with their dependencies)
    QSet<QString> m_aurUnknown;               // the names an info answer did not know
    QSet<QString> m_aurAsked;                 // the installed foreign names asked of the AUR already
    QHash<QString, StoreApp> m_aurApps;       // "aur:<name>" -> its app
    bool m_staleLock = false;
    bool m_quitWhenIdle = false;
    QThreadPool m_pool; // last member: waits for the jobs while the rest is still there
};

} // namespace grassfield::store
