// SPDX-License-Identifier: MIT
// menu-demo: the Qt reference app for global menus (master-prompt §5.7 T1, spike S5).
//
// A QMainWindow with a QMenuBar (File, Edit, View) whose actions are real: each one appends a line to the
// action log (`--log <file>`, default ./menu-demo-actions.log) and to the window's text area, so a test can
// prove that a menu item triggered through DBusMenu ran the application's own code.
//
// On start it prints one diagnostic line (stdout):
//   menu-demo: platform=<qpa> theme-env=<QT_QPA_PLATFORMTHEME> bus=<unique name> nativeMenuBar=<0|1>
//   platformMenuBar=<0|1> menuBarVisible=<0|1>
// platformMenuBar=1 means Qt created a platform (DBusMenu) menu bar instead of drawing it in the window.
//
// Build: tests/fixtures/menu-demo/build.sh. Run it only against the NESTED compositor and a PRIVATE D-Bus
// session bus (dbus-run-session), see tests/compositor/appmenu.sh.

#include <QAction>
#include <QActionGroup>
#include <QApplication>
#include <QDBusConnection>
#include <QDateTime>
#include <QFile>
#include <QKeySequence>
#include <QMainWindow>
#include <QMenu>
#include <QMenuBar>
#include <QPlainTextEdit>
#include <QStringList>
#include <QTextStream>
#include <QTimer>

#include <cstdio>

namespace {
    QString g_logPath = QStringLiteral("menu-demo-actions.log");

    void appendLog(QPlainTextEdit* view, const QString& what) {
        const QString line = QDateTime::currentDateTime().toString(Qt::ISODateWithMs) + QLatin1Char(' ') + what;
        QFile         f(g_logPath);
        if (f.open(QIODevice::Append | QIODevice::Text)) {
            QTextStream out(&f);
            out << line << '\n';
        }
        if (view)
            view->appendPlainText(line);
        std::fprintf(stdout, "menu-demo: action %s\n", qPrintable(what));
        std::fflush(stdout);
    }

    QAction* addLogged(QMenu* menu, const QString& text, const QString& id, QPlainTextEdit* view, const QKeySequence& shortcut = {}) {
        QAction* a = menu->addAction(text);
        if (!shortcut.isEmpty())
            a->setShortcut(shortcut);
        QObject::connect(a, &QAction::triggered, view, [view, id, a](bool checked) { appendLog(view, a->isCheckable() ? id + (checked ? "=on" : "=off") : id); });
        return a;
    }
} // namespace

int main(int argc, char** argv) {
    QApplication app(argc, argv);
    QApplication::setApplicationName(QStringLiteral("menu-demo"));
    QApplication::setDesktopFileName(QStringLiteral("org.grassfield.MenuDemo"));

    const QStringList args = QApplication::arguments();
    const qsizetype   logArg = args.indexOf(QStringLiteral("--log"));
    if (logArg >= 0 && logArg + 1 < args.size())
        g_logPath = args.at(logArg + 1);

    QMainWindow win;
    win.setWindowTitle(QStringLiteral("Menu Demo"));
    auto* view = new QPlainTextEdit(&win);
    view->setReadOnly(true);
    view->setPlaceholderText(QStringLiteral("Menu actions appear here."));
    win.setCentralWidget(view);
    win.resize(640, 400);

    QMenuBar* bar = win.menuBar();

    QMenu* file = bar->addMenu(QStringLiteral("&File"));
    addLogged(file, QStringLiteral("&New"), QStringLiteral("file.new"), view, QKeySequence::New);
    addLogged(file, QStringLiteral("&Open…"), QStringLiteral("file.open"), view, QKeySequence::Open);
    QMenu* recent = file->addMenu(QStringLiteral("Open &Recent"));
    addLogged(recent, QStringLiteral("notes.txt"), QStringLiteral("file.recent.notes"), view);
    addLogged(recent, QStringLiteral("todo.md"), QStringLiteral("file.recent.todo"), view);
    file->addSeparator();
    QAction* quit = addLogged(file, QStringLiteral("&Quit"), QStringLiteral("file.quit"), view, QKeySequence::Quit);
    QObject::connect(quit, &QAction::triggered, &app, [] { QTimer::singleShot(0, qApp, &QCoreApplication::quit); });

    QMenu* edit = bar->addMenu(QStringLiteral("&Edit"));
    addLogged(edit, QStringLiteral("&Undo"), QStringLiteral("edit.undo"), view, QKeySequence::Undo);
    addLogged(edit, QStringLiteral("&Copy"), QStringLiteral("edit.copy"), view, QKeySequence::Copy);
    addLogged(edit, QStringLiteral("&Paste"), QStringLiteral("edit.paste"), view, QKeySequence::Paste);
    QAction* disabled = addLogged(edit, QStringLiteral("&Redo (disabled)"), QStringLiteral("edit.redo"), view, QKeySequence::Redo);
    disabled->setEnabled(false);
    edit->addSeparator();
    addLogged(edit, QStringLiteral("&Word Wrap"), QStringLiteral("edit.wrap"), view)->setCheckable(true);

    QMenu* viewMenu = bar->addMenu(QStringLiteral("&View"));
    addLogged(viewMenu, QStringLiteral("Zoom &In"), QStringLiteral("view.zoom-in"), view, QKeySequence::ZoomIn);
    addLogged(viewMenu, QStringLiteral("Zoom &Out"), QStringLiteral("view.zoom-out"), view, QKeySequence::ZoomOut);
    QMenu*        theme = viewMenu->addMenu(QStringLiteral("&Theme"));
    auto*         group = new QActionGroup(theme);
    const QString themes[] = {QStringLiteral("Light"), QStringLiteral("Dark")};
    for (const QString& t : themes) {
        QAction* a = addLogged(theme, t, QStringLiteral("view.theme.") + t.toLower(), view);
        a->setCheckable(true);
        group->addAction(a);
    }

    win.show();

    // Report once the window (and its menu bar) is set up.
    QTimer::singleShot(1500, &win, [bar] {
        const QByteArray themeEnv = qgetenv("QT_QPA_PLATFORMTHEME");
        std::fprintf(stdout, "menu-demo: platform=%s theme-env=%s bus=%s nativeMenuBar=%d platformMenuBar=%d menuBarVisible=%d\n", qPrintable(QGuiApplication::platformName()),
                     themeEnv.isEmpty() ? "(unset)" : themeEnv.constData(), qPrintable(QDBusConnection::sessionBus().baseService()), bar->isNativeMenuBar() ? 1 : 0,
                     bar->platformMenuBar() ? 1 : 0, bar->isVisible() ? 1 : 0);
        std::fflush(stdout);
    });

    return QApplication::exec();
}
