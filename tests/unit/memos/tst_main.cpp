// The Memos unit tests' main (ADR-0051): a QGuiApplication around the cases (QTextDocument and the clipboard need one),
// always offscreen.
#include <QGuiApplication>

#include <gtest/gtest.h>

int main(int argc, char **argv)
{
    qputenv("QT_QPA_PLATFORM", "offscreen");
    QGuiApplication app(argc, argv);
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
