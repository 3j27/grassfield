// The window's unit tests (ADR-0038 step 2): gtest cases inside a QCoreApplication, for the backend's timers, thread and
// file watcher.
#include <QCoreApplication>
#include <QTemporaryDir>

#include <gtest/gtest.h>

int main(int argc, char **argv)
{
    // Review of 5bfd4419: no test reaches the live session's runtime files (its dock-tile.json, its projection): a private
    // runtime directory, and no display to name a folder by (a test that needs one sets its own).
    QTemporaryDir runtime;
    qputenv("XDG_RUNTIME_DIR", runtime.path().toUtf8());
    qunsetenv("WAYLAND_DISPLAY");
    QCoreApplication app(argc, argv);
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
