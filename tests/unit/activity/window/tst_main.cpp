// The window's unit tests (ADR-0038 step 2): gtest cases inside a QCoreApplication, for the backend's timers, thread and
// file watcher.
#include <QCoreApplication>

#include <gtest/gtest.h>

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
