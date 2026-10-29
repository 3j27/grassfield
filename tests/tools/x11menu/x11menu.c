// SPDX-License-Identifier: MIT
// x11menu: an X11 override-redirect window, what an XWayland app's menu is, for the NESTED dev compositor only
// (tests/compositor/tiling.sh: the shared edge's handle under an X11 menu). Never run it against the owner's X display: use
// tests/tools/x11menu/x11menu.sh, which refuses the caller's own DISPLAY.
//
// Usage: x11menu X Y W H   (root coordinates)
// Maps an override-redirect window of type _NET_WM_WINDOW_TYPE_POPUP_MENU (it wants no focus: Hyprland's windowAt returns the
// focused window for it) at X Y, W x H, prints "mapped" once it is mapped and "pressed" for each button press on it. Ends on
// SIGTERM/SIGINT or when the X connection closes.
#define _GNU_SOURCE
#include <X11/Xatom.h>
#include <X11/Xlib.h>

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/select.h>

static volatile sig_atomic_t want_exit;

static void on_signal(int sig) {
    (void)sig;
    want_exit = 1;
}

int main(int argc, char** argv) {
    if (argc != 5) {
        fprintf(stderr, "usage: x11menu X Y W H\n");
        return 2;
    }
    const int x = atoi(argv[1]), y = atoi(argv[2]), w = atoi(argv[3]), h = atoi(argv[4]);
    if (w <= 0 || h <= 0) {
        fprintf(stderr, "x11menu: a positive size is needed\n");
        return 2;
    }
    Display* dpy = XOpenDisplay(NULL);
    if (!dpy) {
        fprintf(stderr, "x11menu: no X display\n");
        return 1;
    }
    struct sigaction sa = {.sa_handler = on_signal};
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);

    const int            screen = DefaultScreen(dpy);
    XSetWindowAttributes attrs  = {0};
    attrs.override_redirect     = True;
    attrs.background_pixel      = 0x6e3aa5;
    attrs.event_mask            = ButtonPressMask | StructureNotifyMask;
    Window win = XCreateWindow(dpy, RootWindow(dpy, screen), x, y, (unsigned)w, (unsigned)h, 0, CopyFromParent, InputOutput, CopyFromParent,
                               CWOverrideRedirect | CWBackPixel | CWEventMask, &attrs);
    Atom type  = XInternAtom(dpy, "_NET_WM_WINDOW_TYPE", False);
    Atom menu  = XInternAtom(dpy, "_NET_WM_WINDOW_TYPE_POPUP_MENU", False);
    XChangeProperty(dpy, win, type, XA_ATOM, 32, PropModeReplace, (const unsigned char*)&menu, 1);
    XMapRaised(dpy, win);
    XFlush(dpy);

    const int fd = ConnectionNumber(dpy);
    while (!want_exit) {
        while (XPending(dpy)) {
            XEvent ev;
            XNextEvent(dpy, &ev);
            if (ev.type == MapNotify && ev.xmap.window == win) {
                printf("mapped\n");
                fflush(stdout);
            } else if (ev.type == ButtonPress && ev.xbutton.window == win) {
                printf("pressed\n");
                fflush(stdout);
            }
        }
        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(fd, &fds);
        struct timeval tv = {.tv_sec = 0, .tv_usec = 50000};
        const int      n  = select(fd + 1, &fds, NULL, NULL, &tv);
        if (n < 0 && errno != EINTR)
            break;
    }
    XDestroyWindow(dpy, win);
    XCloseDisplay(dpy);
    return 0;
}
