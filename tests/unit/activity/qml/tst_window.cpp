// A-W1 (spec "Acceptance criteria"; ADR-0038 step 2a): the window and its real backend on a fixture tree, offscreen. The
// rows of the tab, the tabs, a header click that sorts, the columns chooser, typing in the search field, the views, Copy as
// text, no sample while the window is hidden, suspended by the compositor or minimized (AM8, AD35), and the size it keeps
// (AM2).
#include "../fixture.h"
#include "activityapp.h"
#include "iconprovider.h"
#include "shownwatch.h"

#include <QClipboard>
#include <QFile>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QJsonObject>
#include <QQmlApplicationEngine>
#include <QQuickItem>
#include <QQuickWindow>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QTest>
#include <QtGui/private/qwindow_p.h>

#include <gtest/gtest.h>

#include <functional>
#include <memory>

#ifndef ACTIVITY_ROOT
#error "ACTIVITY_ROOT: the repository's root (build-direct.sh and CMakeLists.txt define it)"
#endif

using namespace activity;
using activity_test::Fixture;

namespace {

constexpr unsigned kMe = 1000;

std::string nul(std::initializer_list<const char *> words)
{
    std::string s;
    for (const char *w : words) {
        s += w;
        s += '\0';
    }
    return s;
}

// From the window: items declared in a QML Window have the window as their QObject parent, not its content item.
QQuickItem *named(QQuickWindow *win, const char *name)
{
    return win->findChild<QQuickItem *>(QString::fromLatin1(name));
}

// The header delegates (the Repeater's items; the Repeater itself is a child too).
QList<QQuickItem *> headers(QQuickWindow *win)
{
    QList<QQuickItem *> list;
    if (QQuickItem *row = named(win, "columnHeaders")) {
        for (QQuickItem *child : row->childItems()) {
            if (child->property("modelData").isValid())
                list << child;
        }
    }
    return list;
}

QQuickItem *header(QQuickWindow *win, const QString &key)
{
    for (QQuickItem *h : headers(win)) {
        if (h->property("modelData").toMap().value(QStringLiteral("key")).toString() == key)
            return h;
    }
    return nullptr;
}

int rows(QQuickWindow *win)
{
    QQuickItem *list = named(win, "processRows");
    return list ? list->property("count").toInt() : -1;
}

QPoint centre(QQuickItem *item)
{
    return item->mapToScene(QPointF(item->width() / 2, item->height() / 2)).toPoint();
}

// A click once the window has laid out what changed: a Row positions its children, and a ListView its delegates, at the
// next polish, so a click sent at once can land where an item is not yet.
void settledClick(QQuickWindow *win, const std::function<QPoint()> &where)
{
    win->requestUpdate();
    QTest::qWait(100);
    const QPoint p = where();
    QTest::mouseMove(win, p);
    QTest::qWait(20);
    QTest::mouseClick(win, Qt::LeftButton, Qt::NoModifier, p);
}

// Waits until `value()` equals `want`. QtTest's retrying macros report a failure only inside a QtTest run: under gtest they
// return from the case silently, so every wait here goes through a gtest assertion.
template <typename F, typename T>
::testing::AssertionResult becomes(F value, T want, int ms = 3000)
{
    if (QTest::qWaitFor([&] { return value() == want; }, ms))
        return ::testing::AssertionSuccess();
    return ::testing::AssertionFailure() << "still " << value() << " after " << ms << " ms, wanted " << want;
}

// What Qt's Wayland client does when the compositor suspends the window (xdg_toplevel's `suspended` state, which Hyprland
// 0.56 sets on every window whose workspace is not shown: Grassfield's special:minimized, a Desktop not shown): the window
// stays visible, isExposed() turns false and an expose event comes (QWaylandXdgSurface::isExposed, then
// QWaylandWindow::updateExposure and QGuiApplicationPrivate::processExposeEvent). Offscreen windows are always exposed.
void suspend(QQuickWindow *win, bool suspended)
{
    QWindowPrivate::get(win)->exposed = !suspended;
    QExposeEvent e(suspended ? QRegion() : QRegion(QRect(QPoint(), win->size())));
    QCoreApplication::sendEvent(win, &e);
}

// Counts the events of one type a window receives.
struct EventCounter : QObject {
    EventCounter(QObject *target, QEvent::Type type, int &count)
        : m_type(type)
        , m_count(count)
    {
        target->installEventFilter(this);
    }
    bool eventFilter(QObject *, QEvent *event) override
    {
        if (event->type() == m_type)
            ++m_count;
        return false;
    }
    QEvent::Type m_type;
    int &m_count;
};

struct Window {
    Fixture f;
    QTemporaryDir config, state;
    std::unique_ptr<ActivityApp> backend; // outlives the engine (declared first, destroyed last), as in main.cpp
    std::unique_ptr<QQmlApplicationEngine> engine;
    QQuickWindow *win = nullptr;

    Window()
    {
        f.process(100, "alpha", kMe, 300, 1, nul({"alpha"}), "/");
        f.process(101, "beta", kMe, 200, 1, nul({"beta"}), "/");
        f.process(102, "gamma", kMe, 100, 1, nul({"gamma"}), "/");
        // The system files of the summary (AM29, AM32).
        f.write("proc/stat", "cpu  100 0 50 1000 0 0 0 0 0 0\ncpu0 100 0 50 1000 0 0 0 0 0 0\nintr 1\n");
        f.write("proc/loadavg", "0.10 0.20 0.30 1/57 999\n");
        f.write("proc/meminfo", "MemTotal: 16000000 kB\nMemAvailable: 8000000 kB\nActive(file): 1000000 kB\nInactive(file): 500000 kB\n");
        qputenv("GRASSFIELD_CONFIG_HOME", config.path().toUtf8());
        Options o;
        o.procRoot = f.proc();
        o.sysRoot = f.sys();
        o.uid = kMe;
        o.clockTicks = 100;
        o.maxKeptFiles = 4096;
        backend = std::make_unique<ActivityApp>(o, statePath());
        engine = std::make_unique<QQmlApplicationEngine>();
        engine->addImportPath(QStringLiteral(ACTIVITY_ROOT "/ui"));
        engine->addImageProvider(QStringLiteral("icon"), new IconProvider);
        engine->setInitialProperties({{QStringLiteral("backend"), QVariant::fromValue(backend.get())}, {QStringLiteral("globalMenu"), false}});
        engine->load(QUrl::fromLocalFile(QStringLiteral(ACTIVITY_ROOT "/apps/activity/qml/Main.qml")));
        if (!engine->rootObjects().isEmpty())
            win = qobject_cast<QQuickWindow *>(engine->rootObjects().constFirst());
        if (win) {
            new ShownWatch(win, backend.get());
            win->requestActivate();
        }
    }

    QString statePath() const { return state.path() + QStringLiteral("/activity.json"); }

    bool sampled()
    {
        QSignalSpy spy(backend.get(), &ActivityApp::sampled);
        return spy.wait(5000);
    }
};

} // namespace

TEST(ActivityWindow, TheTableTabsSortSearchViewsAndCopy)
{
    Window w;
    ASSERT_NE(w.win, nullptr);
    ASSERT_TRUE(QTest::qWaitForWindowExposed(w.win));
    ASSERT_TRUE(w.backend->ready() || w.sampled());
    ASSERT_TRUE(becomes([&] { return rows(w.win); }, 3, 3000));
    EXPECT_EQ(headers(w.win).size(), 8); // the CPU tab's defaults

    // A tab: its own columns (AM4).
    QQuickItem *tabs = named(w.win, "tabs");
    ASSERT_NE(tabs, nullptr);
    QMetaObject::invokeMethod(tabs, "picked", Q_ARG(QString, QStringLiteral("memory")));
    EXPECT_EQ(w.backend->tab(), "memory");
    ASSERT_TRUE(becomes([&] { return static_cast<int>(headers(w.win).size()); }, 5, 2000));
    QMetaObject::invokeMethod(tabs, "picked", Q_ARG(QString, QStringLiteral("cpu")));
    ASSERT_TRUE(becomes([&] { return static_cast<int>(headers(w.win).size()); }, 8, 2000));

    // A header clicked sorts by its column, numbers from the largest (AM10).
    ASSERT_NE(header(w.win, QStringLiteral("pid")), nullptr);
    settledClick(w.win, [&] { return centre(header(w.win, QStringLiteral("pid"))); });
    EXPECT_EQ(w.backend->sortKey(), "pid");
    EXPECT_TRUE(w.backend->sortDescending());
    EXPECT_EQ(w.backend->processTable().data(w.backend->processTable().index(0), ProcessTable::NameRole).toString(), "gamma");

    // The columns chooser (AM15).
    w.backend->setColumnShown(QStringLiteral("wakeUps"), true);
    ASSERT_TRUE(becomes([&] { return static_cast<int>(headers(w.win).size()); }, 9, 2000));
    ASSERT_NE(header(w.win, QStringLiteral("wakeUps")), nullptr);

    // Typing in the search field filters at once (AM14); Esc clears it.
    QTest::keyClick(w.win, Qt::Key_F, Qt::ControlModifier);
    for (char c : {'b', 'e', 't'})
        QTest::keyClick(w.win, c);
    EXPECT_EQ(w.backend->search(), "bet");
    ASSERT_TRUE(becomes([&] { return rows(w.win); }, 1, 2000));
    QTest::keyClick(w.win, Qt::Key_Escape);
    ASSERT_TRUE(becomes([&] { return rows(w.win); }, 3, 2000));

    // A view (AM12): no system process in the fixture.
    w.backend->setView(QStringLiteral("system"));
    ASSERT_TRUE(becomes([&] { return rows(w.win); }, 0, 2000));
    w.backend->setView(QStringLiteral("all"));
    ASSERT_TRUE(becomes([&] { return rows(w.win); }, 3, 2000));

    // A click on a row selects it; Ctrl+C copies it as text, the headers first (AM19).
    QQuickItem *list = named(w.win, "processRows");
    settledClick(w.win, [&] { return list->mapToScene(QPointF(40, 5)).toPoint(); });
    EXPECT_EQ(w.backend->processTable().selectedCount(), 1);
    QTest::keyClick(w.win, Qt::Key_C, Qt::ControlModifier);
    const QStringList copied = QGuiApplication::clipboard()->text().split(QLatin1Char('\n'), Qt::SkipEmptyParts);
    ASSERT_EQ(copied.size(), 2);
    EXPECT_TRUE(copied[0].startsWith(QStringLiteral("Process Name\t% CPU")));
    EXPECT_TRUE(copied[1].startsWith(QStringLiteral("gamma\t")));
}

// Every visible text under `item`.
QStringList textsUnder(QQuickItem *item)
{
    QStringList out;
    if (!item || !item->isVisible())
        return out;
    const QVariant text = item->property("text");
    if (text.typeId() == QMetaType::QString && !text.toString().isEmpty())
        out << text.toString();
    for (QQuickItem *child : item->childItems())
        out << textsUnder(child);
    return out;
}

// AM5: the summary under the table holds the real backend's figures, from the fixture's system files, and its graphs keep
// the historySamples token's count.
TEST(ActivityWindow, TheSummaryShowsTheSystemFigures)
{
    Window w;
    ASSERT_NE(w.win, nullptr);
    ASSERT_TRUE(QTest::qWaitForWindowExposed(w.win));
    QQuickItem *summary = named(w.win, "summary");
    ASSERT_NE(summary, nullptr);
    ASSERT_TRUE(w.backend->ready() || w.sampled());
    EXPECT_GT(w.backend->summaryModel().capacity(), 1);
    ASSERT_TRUE(becomes([&] { return textsUnder(summary).contains(QStringLiteral("57")); }, true)); // Threads, from loadavg
    const QStringList cpu = textsUnder(summary);
    EXPECT_TRUE(cpu.contains(QStringLiteral("Processes:")));
    EXPECT_TRUE(cpu.contains(QStringLiteral("3")));
    EXPECT_TRUE(cpu.contains(QStringLiteral("CPU Load")));
    QMetaObject::invokeMethod(named(w.win, "tabs"), "picked", Q_ARG(QString, QStringLiteral("memory")));
    ASSERT_TRUE(becomes([&] { return textsUnder(summary).contains(QStringLiteral("16.4 GB")); }, true)); // 16 000 000 KiB
    EXPECT_TRUE(textsUnder(summary).contains(QStringLiteral("Memory Pressure")));
}

TEST(ActivityWindow, HiddenItSamplesNothingAndItKeepsItsSize)
{
    Window w;
    ASSERT_NE(w.win, nullptr);
    ASSERT_TRUE(QTest::qWaitForWindowExposed(w.win));
    ASSERT_TRUE(w.backend->ready() || w.sampled());
    w.backend->setInterval(1);

    // AM8, AM-P3: hidden, no sample; shown again, one at once.
    w.win->hide();
    const int before = w.backend->processSamples();
    QTest::qWait(2500); // two intervals of Very Often
    EXPECT_EQ(w.backend->processSamples(), before);
    w.win->show();
    ASSERT_TRUE(QTest::qWaitForWindowExposed(w.win));
    ASSERT_TRUE(QTest::qWaitFor([&] { return w.backend->processSamples() > before; }, 3000));

    // AD35: suspended by the compositor (minimized, on a Desktop not shown), visible but not exposed: no sample.
    suspend(w.win, true);
    QTest::qWait(100);
    const int suspended = w.backend->processSamples();
    QTest::qWait(2500);
    EXPECT_EQ(w.backend->processSamples(), suspended);
    suspend(w.win, false);
    ASSERT_TRUE(QTest::qWaitFor([&] { return w.backend->processSamples() > suspended; }, 3000));

    // Minimized as Qt says it (a platform that keeps the state; offscreen does): no sample.
    w.win->showMinimized();
    QTest::qWait(100);
    const int minimized = w.backend->processSamples();
    QTest::qWait(2500);
    EXPECT_EQ(w.backend->processSamples(), minimized);
    w.win->showNormal();
    ASSERT_TRUE(QTest::qWaitFor([&] { return w.backend->processSamples() > minimized; }, 3000));

    // AD34: launched again while suspended (minimized, on another Desktop), the app asks the Dock to bring it back, and
    // Qt's next activation request takes the token; on screen, the token alone.
    int reopens = 0;
    suspend(w.win, true);
    activateWindow(w.win, QStringLiteral("token-1"), [&] { ++reopens; });
    EXPECT_EQ(reopens, 1);
    EXPECT_EQ(qgetenv("XDG_ACTIVATION_TOKEN"), "token-1");
    suspend(w.win, false);
    activateWindow(w.win, QString(), [&] { ++reopens; });
    EXPECT_EQ(reopens, 1);
    qunsetenv("XDG_ACTIVATION_TOKEN");

    // A second launch keeps the window's size and its maximized state: no state is asked of the platform (on Wayland a
    // maximize request toggles Hyprland's maximize; the integrator's check of f2ff9a0). The platform reports each request
    // with a WindowStateChange event, even an unchanged one.
    int stateRequests = 0;
    EventCounter counter(w.win, QEvent::WindowStateChange, stateRequests);
    for (const bool maximized : {false, true}) {
        if (maximized) {
            w.win->showMaximized();
            ASSERT_TRUE(becomes([&] { return w.win->visibility(); }, QWindow::Maximized, 2000));
        }
        QTest::qWait(50);
        stateRequests = 0;
        const QSize size = w.win->size();
        activateWindow(w.win, QString(), [&] { ++reopens; });
        QTest::qWait(50);
        EXPECT_EQ(stateRequests, 0) << (maximized ? "maximized" : "normal");
        EXPECT_EQ(w.win->size(), size);
        EXPECT_EQ(w.win->visibility(), maximized ? QWindow::Maximized : QWindow::Windowed);
    }
    EXPECT_EQ(reopens, 1); // on screen both times
    // Minimized as Qt says it (offscreen keeps the state): off screen, so the Dock is asked, and the state goes.
    w.win->showMinimized();
    ASSERT_TRUE(becomes([&] { return w.win->visibility(); }, QWindow::Minimized, 2000));
    activateWindow(w.win, QString(), [&] { ++reopens; });
    EXPECT_EQ(reopens, 2);
    ASSERT_TRUE(becomes([&] { return w.win->visibility() != QWindow::Minimized; }, true, 2000));
    w.win->showNormal();

    // AM2: the size it closes at is the one it opens at.
    w.win->resize(700, 400);
    w.win->close();
    w.engine.reset();
    w.backend.reset(); // writes what is pending
    QFile f(w.statePath());
    ASSERT_TRUE(f.open(QIODevice::ReadOnly));
    const QJsonObject root = QJsonDocument::fromJson(f.readAll()).object();
    EXPECT_EQ(root.value(QStringLiteral("interval")).toInt(), 1);
    EXPECT_EQ(root.value(QStringLiteral("window")).toObject().value(QStringLiteral("width")).toInt(), 700);
    EXPECT_EQ(root.value(QStringLiteral("window")).toObject().value(QStringLiteral("height")).toInt(), 400);
}

int main(int argc, char **argv)
{
    // Always offscreen, whatever the session says: a test never opens a window on the owner's compositor.
    qputenv("QT_QPA_PLATFORM", "offscreen");
    qputenv("QT_QUICK_CONTROLS_STYLE", "Basic");
    QGuiApplication app(argc, argv);
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
