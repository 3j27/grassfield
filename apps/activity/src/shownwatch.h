#pragma once

#include "activityapp.h"

#include <QEvent>
#include <QObject>
#include <QWindow>

#include <functional>

namespace activity {

// AM8, AD35: the window is on screen when it is visible, exposed and not minimized; the backend samples only then. Hidden
// comes from what the compositor sends: Hyprland suspends every window whose workspace is not shown (xdg_toplevel's
// `suspended` state; Grassfield's minimize moves the window to special:minimized), and Qt's Wayland client then reports
// the window not exposed. Qt's Minimized state is for the platforms that keep it: on Wayland Qt reverts it at once.
class ShownWatch : public QObject
{
public:
    ShownWatch(QWindow *window, ActivityApp *backend)
        : QObject(window)
        , m_window(window)
        , m_backend(backend)
    {
        window->installEventFilter(this);
        connect(window, &QWindow::visibilityChanged, this, [this] { update(); });
        update();
    }

    bool eventFilter(QObject *watched, QEvent *event) override
    {
        if (watched == m_window && (event->type() == QEvent::Expose || event->type() == QEvent::Show || event->type() == QEvent::Hide))
            QMetaObject::invokeMethod(this, [this] { update(); }, Qt::QueuedConnection);
        return false;
    }

private:
    void update()
    {
        m_backend->setWindowShown(m_window->isVisible() && m_window->isExposed() && m_window->visibility() != QWindow::Minimized);
    }

    QWindow *m_window;
    ActivityApp *m_backend;
};

// AM1, AD34: a second launch's activation. Qt's next activation request takes the token (xdg-activation-v1); the window is
// shown and raised. Off screen (minimized, or on another Desktop: the compositor suspends it, AD35), `reopen` asks the
// shell's Dock to bring it back, which xdg-activation alone does not do for a window on special:minimized.
inline void activateWindow(QWindow *window, const QString &token, const std::function<void()> &reopen)
{
    const bool offScreen = !window->isExposed() || window->visibility() == QWindow::Minimized;
    if (!token.isEmpty())
        qputenv("XDG_ACTIVATION_TOKEN", token.toUtf8());
    window->setWindowStates(window->windowStates() & ~Qt::WindowMinimized);
    window->show();
    window->raise();
    window->requestActivate();
    if (offScreen && reopen)
        reopen();
}

} // namespace activity
