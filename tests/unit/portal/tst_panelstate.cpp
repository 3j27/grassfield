// docs/specs/system-dialogs.md FC5: what the Open and Save panels remember per application (portal-filechooser.json).
#include <gtest/gtest.h>

#include "panelstate.h"

#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTemporaryDir>

using grassfield::portal::PanelState;

TEST(PanelState, RemembersEachApplicationsFolderViewAndSize)
{
    QTemporaryDir dir;
    const QString file = dir.filePath(QStringLiteral("state/portal-filechooser.json"));
    {
        PanelState state(file);
        EXPECT_TRUE(state.entry(QStringLiteral("org.example.A")).folder.isEmpty()); // nothing yet, nothing created
        EXPECT_FALSE(QFile::exists(file));
        EXPECT_TRUE(state.remember(QStringLiteral("org.example.A"), {QStringLiteral("file:///home/u/Pictures"), QStringLiteral("gallery"), true, 0}, 10));
        EXPECT_TRUE(state.remember(QString(), {QStringLiteral("file:///tmp"), QStringLiteral("list"), false, 0}, 11));
    }
    PanelState again(file);
    const PanelState::Entry a = again.entry(QStringLiteral("org.example.A"));
    EXPECT_EQ(a.folder, QStringLiteral("file:///home/u/Pictures"));
    EXPECT_EQ(a.view, QStringLiteral("gallery"));
    EXPECT_TRUE(a.expanded);
    EXPECT_EQ(a.used, 10);
    EXPECT_EQ(again.entry(QString()).view, QStringLiteral("list"));
}

TEST(PanelState, KeepsOnlyWhatItCanUse)
{
    QTemporaryDir dir;
    const QString file = dir.filePath(QStringLiteral("portal-filechooser.json"));
    PanelState state(file);
    // A remote folder, a relative one and an unknown view are not kept.
    state.remember(QStringLiteral("a"), {QStringLiteral("smb://host/share"), QStringLiteral("cover-flow"), false, 0}, 1);
    EXPECT_TRUE(state.entry(QStringLiteral("a")).folder.isEmpty());
    EXPECT_TRUE(state.entry(QStringLiteral("a")).view.isEmpty());
    state.remember(QStringLiteral("b"), {QStringLiteral("file:relative"), QStringLiteral("icons"), false, 0}, 2);
    EXPECT_TRUE(state.entry(QStringLiteral("b")).folder.isEmpty());

    // Bounded: the least recently used application goes first.
    for (int i = 0; i < PanelState::kMaxApps + 5; ++i)
        state.remember(QStringLiteral("app%1").arg(i), {QStringLiteral("file:///tmp"), QStringLiteral("list"), false, 0}, 100 + i);
    PanelState read(file);
    EXPECT_TRUE(read.entry(QStringLiteral("app0")).folder.isEmpty());
    EXPECT_EQ(read.entry(QStringLiteral("app%1").arg(PanelState::kMaxApps + 4)).folder, QStringLiteral("file:///tmp"));
    QFile f(file);
    ASSERT_TRUE(f.open(QIODevice::ReadOnly));
    EXPECT_EQ(QJsonDocument::fromJson(f.readAll()).object().value(QLatin1String("apps")).toObject().size(), PanelState::kMaxApps);
}

TEST(PanelState, AnUnusableFileIsAnEmptyMemory)
{
    QTemporaryDir dir;
    const QString file = dir.filePath(QStringLiteral("portal-filechooser.json"));
    for (const QByteArray &content : {QByteArray("not json"), QByteArray("[1,2]"), QByteArray(R"({"version": 2, "apps": {}})"),
                                      QByteArray(R"({"version": 1, "apps": {"a": "x"}})")}) {
        QFile f(file);
        ASSERT_TRUE(f.open(QIODevice::WriteOnly | QIODevice::Truncate));
        f.write(content);
        f.close();
        PanelState state(file);
        EXPECT_TRUE(state.entry(QStringLiteral("a")).folder.isEmpty()) << content.constData();
        // And it is replaced whole by the next write.
        EXPECT_TRUE(state.remember(QStringLiteral("a"), {QStringLiteral("file:///tmp"), {}, false, 0}, 1));
        EXPECT_EQ(PanelState(file).entry(QStringLiteral("a")).folder, QStringLiteral("file:///tmp"));
    }
    // Oversized: not read.
    QFile big(file);
    ASSERT_TRUE(big.open(QIODevice::WriteOnly | QIODevice::Truncate));
    big.write(R"({"version": 1, "apps": {"a": {"folder": "file:///tmp"}}})");
    big.write(QByteArray(PanelState::kMaxFileBytes, ' '));
    big.close();
    EXPECT_TRUE(PanelState(file).entry(QStringLiteral("a")).folder.isEmpty());
}
