// The listings of grassfield-portal's Open and Save panels (FolderModel.chooser; ADR-0035 D-4, docs/specs/system-dialogs.md
// section 1): over a real KIO listing of a scratch folder, the files a panel cannot take are dimmed and never selected, a
// panel that takes one item keeps one, and a folder panel dims every file. Part of files-kio-tests (a scratch home).
#include "foldermodel.h"

#include <QCoreApplication>
#include <QDeadlineTimer>
#include <QDir>
#include <QFile>
#include <QTemporaryDir>
#include <QThread>

#include <gtest/gtest.h>

namespace {

class FolderChooserTest : public ::testing::Test
{
protected:
    void SetUp() override
    {
        ASSERT_TRUE(m_dir.isValid());
        for (const char *name : {"a.txt", "b.png", "report.PDF"}) {
            QFile f(m_dir.filePath(QString::fromLatin1(name)));
            ASSERT_TRUE(f.open(QIODevice::WriteOnly));
            f.write("x");
        }
        ASSERT_TRUE(QDir(m_dir.path()).mkdir(QStringLiteral("sub")));
        m_model.setUrl(QUrl::fromLocalFile(m_dir.path()));
        QDeadlineTimer deadline(10000);
        while ((m_model.loading() || m_model.count() < 4) && !deadline.hasExpired()) {
            QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
            QThread::msleep(5);
        }
        ASSERT_EQ(m_model.count(), 4);
    }

    int row(const char *name)
    {
        for (int r = 0; r < m_model.count(); ++r)
            if (m_model.nameAt(r) == QLatin1String(name))
                return r;
        return -1;
    }

    bool dimmed(const char *name) { return m_model.data(m_model.index(row(name), 0), FolderModel::DimmedRole).toBool(); }

    QTemporaryDir m_dir;
    FolderModel m_model;
};

} // namespace

TEST_F(FolderChooserTest, FilesOnlyWithoutAPanel)
{
    for (const char *name : {"a.txt", "b.png", "report.PDF", "sub"})
        EXPECT_FALSE(dimmed(name)) << name;
    m_model.select(row("a.txt"), Qt::NoModifier);
    m_model.select(row("b.png"), Qt::ControlModifier);
    EXPECT_EQ(m_model.selectedCount(), 2);
}

TEST_F(FolderChooserTest, ThePanelsFilterDimsAndRefuses)
{
    m_model.setChooser({{QStringLiteral("globs"), QStringList{QStringLiteral("*.txt"), QStringLiteral("*.pdf")}}, {QStringLiteral("single"), true}});
    EXPECT_FALSE(dimmed("a.txt"));
    EXPECT_TRUE(dimmed("b.png"));
    EXPECT_FALSE(dimmed("report.PDF")); // a glob ignores case
    EXPECT_FALSE(dimmed("sub"));        // folders open
    m_model.select(row("b.png"), Qt::NoModifier);
    EXPECT_EQ(m_model.selectedCount(), 0);
    m_model.select(row("a.txt"), Qt::NoModifier);
    EXPECT_EQ(m_model.selectedUrls(), QList<QUrl>{QUrl::fromLocalFile(m_dir.filePath(QStringLiteral("a.txt")))});
    // One item at most: Ctrl and Shift are plain clicks, Select All does nothing.
    m_model.select(row("report.PDF"), Qt::ControlModifier);
    EXPECT_EQ(m_model.selectedCount(), 1);
    m_model.select(row("sub"), Qt::ShiftModifier);
    EXPECT_EQ(m_model.selectedCount(), 1);
    m_model.selectAll();
    EXPECT_EQ(m_model.selectedCount(), 1);
}

TEST_F(FolderChooserTest, MimeTypesAndSeveralItems)
{
    m_model.setChooser({{QStringLiteral("mimeTypes"), QStringList{QStringLiteral("image/*")}}});
    EXPECT_TRUE(dimmed("a.txt"));
    EXPECT_FALSE(dimmed("b.png"));
    m_model.selectAll();
    EXPECT_EQ(m_model.selectedCount(), 2); // the picture and the folder
    // A new filter drops from the selection what the panel can no longer take.
    m_model.setChooser({{QStringLiteral("mimeTypes"), QStringList{QStringLiteral("text/plain")}}});
    EXPECT_EQ(m_model.selectedCount(), 1);
    EXPECT_FALSE(dimmed("a.txt"));
}

TEST_F(FolderChooserTest, AFolderPanelDimsEveryFile)
{
    m_model.select(row("a.txt"), Qt::NoModifier);
    m_model.setChooser({{QStringLiteral("foldersOnly"), true}, {QStringLiteral("single"), true}});
    EXPECT_EQ(m_model.selectedCount(), 0);
    for (const char *name : {"a.txt", "b.png", "report.PDF"})
        EXPECT_TRUE(dimmed(name)) << name;
    EXPECT_FALSE(dimmed("sub"));
    m_model.select(row("sub"), Qt::NoModifier);
    EXPECT_EQ(m_model.selectedCount(), 1);
}
