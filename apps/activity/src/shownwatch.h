#pragma once

#include "activityapp.h"

#include <QEvent>
#include <QObject>
#include <QWindow>

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

} // namespace activity
