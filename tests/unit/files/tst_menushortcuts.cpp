// Unit tests for reserveFirstShortcutId (apps/globalmenu.h, gtest): a keyed Qt.labs.platform menu item, as the apps'
// global menus build them, when it is the first key the process registers. Without the reservation that item gets the
// id Qt.labs.platform takes for "no key" (-1): disabled, it still acts on its key; once it is gone, the next press of
// its key crashes the app. Each scenario runs in a child process (this binary again), so a crash fails the test instead
// of ending the run. The child runs offscreen, without the desktop's platform theme and away from any session bus.
#include "globalmenu.h"

#include <QApplication>
#include <QGuiApplication>
#include <QPointer>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QTest>
#include <QUrl>
#include <QWindow>

#include <gtest/gtest.h>

#include <fcntl.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

namespace {

// A window with its global menu as the apps build it: a MenuBar in a Loader (gone while the registrar is, a fresh one
// when it is back), with one keyed item. Nothing else here registers a key.
constexpr char kWindowQml[] = R"(
import QtQuick
import Qt.labs.platform as Platform

Window {
    id: w
    property bool menuShown: true
    property bool keyed: true
    property int triggered: 0
    readonly property var menuBar: menuLoader.item
    width: 100
    height: 100
    visible: true

    Loader {
        id: menuLoader
        active: w.menuShown
        sourceComponent: Platform.MenuBar {
            Platform.Menu {
                title: "File"
                Platform.MenuItem {
                    text: "New Window"
                    shortcut: "Ctrl+N"
                    enabled: w.keyed
                    onTriggered: w.triggered++
                }
            }
        }
    }
}
)";

// What the child saw; it exits with this code (a crash ends it with a signal instead).
enum Outcome : int {
    Ok = 0,
    NoWindow = 10, // the QML did not load or its window never became the key window
    KeyIgnored,    // Ctrl+N did not trigger the live item
    DisabledActed, // Ctrl+N triggered the disabled item
    MenuKept,      // the menu bar was not destroyed: the scenario would prove nothing
    StaleActed,    // Ctrl+N acted while no menu item was there
};

std::string outcomeName(int code)
{
    switch (code) {
    case Ok:
        return "ok";
    case NoWindow:
        return "no key window";
    case KeyIgnored:
        return "Ctrl+N did not trigger the live item";
    case DisabledActed:
        return "Ctrl+N triggered the disabled item";
    case MenuKept:
        return "the menu bar was not destroyed";
    case StaleActed:
        return "Ctrl+N acted with no menu item there";
    }
    return "exit code " + std::to_string(code);
}

enum class Scenario {
    Disable,    // the item is disabled (in Files: a window of the browser's own is the key window)
    DropMenu,   // the menu bar goes (the registrar went away) and comes back (it restarted)
    CloseWindow // the window that registered first closes; the key is pressed in another one
};

bool activate(QWindow *window)
{
    window->requestActivate();
    return QTest::qWaitForWindowActive(window);
}

void pressCtrlN(QWindow *window)
{
    QTest::keyClick(window, Qt::Key_N, Qt::ControlModifier);
}

int triggered(const QObject *window)
{
    return window->property("triggered").toInt();
}

Outcome runScenario(Scenario scenario)
{
    QQmlEngine engine;
    QQmlComponent component(&engine);
    component.setData(kWindowQml, QUrl(QStringLiteral("file:///tst_menushortcuts.qml")));
    std::unique_ptr<QObject> first(component.create());
    auto *window = qobject_cast<QWindow *>(first.get());
    if (!window || !activate(window)) {
        qWarning("%s", qUtf8Printable(component.errorString()));
        return NoWindow;
    }
    pressCtrlN(window);
    if (triggered(window) != 1)
        return KeyIgnored;

    switch (scenario) {
    case Scenario::Disable:
        window->setProperty("keyed", false);
        pressCtrlN(window);
        return triggered(window) == 1 ? Ok : DisabledActed;
    case Scenario::DropMenu: {
        const QPointer<QObject> bar = window->property("menuBar").value<QObject *>();
        window->setProperty("menuShown", false);
        QTest::qWait(20); // the Loader's item goes with deleteLater
        if (bar)
            return MenuKept;
        pressCtrlN(window);
        if (triggered(window) != 1)
            return StaleActed;
        window->setProperty("menuShown", true);
        pressCtrlN(window);
        return triggered(window) == 2 ? Ok : KeyIgnored;
    }
    case Scenario::CloseWindow: {
        std::unique_ptr<QObject> second(component.create());
        auto *other = qobject_cast<QWindow *>(second.get());
        const QPointer<QObject> bar = window->property("menuBar").value<QObject *>();
        first.reset();
        if (bar)
            return MenuKept;
        if (!other || !activate(other))
            return NoWindow;
        pressCtrlN(other);
        return triggered(other) == 1 ? Ok : KeyIgnored;
    }
    }
    return Ok;
}

// Set in the child's environment: which application and scenario it runs ("gui:1", "widgets:2").
constexpr char kChildVariable[] = "GF_MENU_SHORTCUTS_CHILD";

// The child: an application as the app has (Files: QApplication; Settings and Preview: QGuiApplication), the reservation
// right after it, then the scenario.
[[noreturn]] void runChild(bool widgets, Scenario scenario)
{
    qputenv("QT_QPA_PLATFORM", "offscreen");
    qunsetenv("QT_QPA_PLATFORMTHEME");
    qputenv("DBUS_SESSION_BUS_ADDRESS", "unix:path=/dev/null/no-bus");
    int argc = 1;
    char name[] = "tst_menushortcuts";
    char *argv[] = {name, nullptr};
    Outcome outcome = Ok;
    {
        std::unique_ptr<QGuiApplication> app(widgets ? new QApplication(argc, argv) : new QGuiApplication(argc, argv));
        grassfield::apps::reserveFirstShortcutId(*app);
        outcome = runScenario(scenario);
    }
    std::exit(outcome);
}

// Starts this binary again, running only the current test, as the child for `widgets` and `scenario`; returns how the
// child ended: an outcome, or the signal that killed it. (Not a gtest death test: gtest 1.18 keeps a death test's
// stderr in a file under /tmp, which the Claude Code sandbox does not let it write.)
std::string runInChild(bool widgets, Scenario scenario)
{
    const ::testing::TestInfo *test = ::testing::UnitTest::GetInstance()->current_test_info();
    std::string self = "/proc/self/exe";
    std::string filter = std::string("--gtest_filter=") + test->test_suite_name() + "." + test->name();
    char *argv[] = {self.data(), filter.data(), nullptr};
    std::vector<std::string> environment{std::string(kChildVariable) + "=" + (widgets ? "widgets:" : "gui:")
                                         + std::to_string(static_cast<int>(scenario))};
    for (char **entry = environ; *entry; ++entry) {
        if (std::strncmp(*entry, kChildVariable, std::strlen(kChildVariable)) != 0)
            environment.emplace_back(*entry);
    }
    std::vector<char *> envp;
    for (std::string &entry : environment)
        envp.push_back(entry.data());
    envp.push_back(nullptr);
    // The child's gtest banner goes to /dev/null; its stderr (Qt's messages) stays.
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    pid_t pid = 0;
    const int spawned = posix_spawn(&pid, self.c_str(), &actions, nullptr, argv, envp.data());
    posix_spawn_file_actions_destroy(&actions);
    if (spawned != 0)
        return std::string("not started: ") + std::strerror(spawned);
    int status = 0;
    if (waitpid(pid, &status, 0) != pid)
        return "not waited for";
    if (WIFSIGNALED(status))
        return std::string("killed by ") + strsignal(WTERMSIG(status));
    return WIFEXITED(status) ? outcomeName(WEXITSTATUS(status)) : "stopped";
}

// The scenario once with a QGuiApplication and once with a QApplication, each in its own process; in the child, runs
// the one it was started for instead.
void expectOk(Scenario scenario)
{
    if (const char *role = std::getenv(kChildVariable)) {
        const std::string value(role);
        const std::size_t colon = value.find(':');
        runChild(value.substr(0, colon) == "widgets", static_cast<Scenario>(std::atoi(value.c_str() + colon + 1)));
    }
    EXPECT_EQ(runInChild(false, scenario), "ok") << "QGuiApplication (Settings, Preview)";
    EXPECT_EQ(runInChild(true, scenario), "ok") << "QApplication (Files)";
}

} // namespace

TEST(MenuShortcuts, ADisabledItemDoesNotAct)
{
    expectOk(Scenario::Disable);
}

TEST(MenuShortcuts, TheKeyAfterTheMenuBarWentAndCameBack)
{
    expectOk(Scenario::DropMenu);
}

TEST(MenuShortcuts, TheKeyInAnotherWindowAfterTheFirstClosed)
{
    expectOk(Scenario::CloseWindow);
}
