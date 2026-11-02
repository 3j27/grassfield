// Unit tests for the Files search (ADR-0027): the pure logic (apps/files/src/searchlogic.{h,cpp}: the location, the criteria,
// saved searches) and the search on its thread (filesearch.{h,cpp}: the walk, the index programs, generations), gtest, run by
// scripts/dev/test.sh. Files and the stand-in index programs are created under GRASSFIELD_TEST_TMP (a directory inside .dev/);
// those tests skip without it.
#include "filesearch.h"
#include "savedsearches.h"
#include "searchlogic.h"

#include <QCoreApplication>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QJsonDocument>
#include <QTemporaryDir>

#include <memory>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <utime.h>

#include <gtest/gtest.h>

using namespace SearchLogic;

namespace
{
QCoreApplication &app()
{
    static int argc = 1;
    static char name[] = "tst_search";
    static char *argv[] = {name, nullptr};
    static QCoreApplication application(argc, argv);
    return application;
}

std::unique_ptr<QTemporaryDir> sandbox(QString *why)
{
    const QString base = qEnvironmentVariable("GRASSFIELD_TEST_TMP");
    if (base.isEmpty() || !QDir::cleanPath(base).contains(QLatin1String("/.dev/"))) {
        *why = QStringLiteral("GRASSFIELD_TEST_TMP (a directory under .dev/) is not set");
        return nullptr;
    }
    QDir().mkpath(base);
    auto dir = std::make_unique<QTemporaryDir>(base + QStringLiteral("/filesearch-XXXXXX"));
    if (!dir->isValid()) {
        *why = QStringLiteral("cannot create a directory in ") + base;
        return nullptr;
    }
    return dir;
}

void write(const QString &path, const QByteArray &bytes = "x")
{
    QDir().mkpath(QFileInfo(path).absolutePath());
    QFile f(path);
    ASSERT_TRUE(f.open(QIODevice::WriteOnly));
    f.write(bytes);
}

// A stand-in for an index program: prints `lines` and exits with `code` (a shell script under the sandbox).
QString program(const QTemporaryDir &dir, const QString &name, const QStringList &lines, int code = 0, const QString &error = QString())
{
    const QString path = dir.filePath(name);
    QFile f(path);
    if (!f.open(QIODevice::WriteOnly))
        return QString();
    f.write("#!/bin/sh\n");
    for (const QString &line : lines)
        f.write(("printf '%s\\n' '" + line + "'\n").toUtf8());
    if (!error.isEmpty())
        f.write(("printf '%s\\n' '" + error + "' >&2\n").toUtf8());
    f.write(("exit " + QString::number(code) + "\n").toUtf8());
    f.close();
    QFile::setPermissions(path, QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner);
    return path;
}

struct Outcome {
    QStringList paths;
    int done = 0;
    int backend = -1;
    bool limited = false;
    bool contentsUnavailable = false;
};

Outcome run(const FileSearch::Settings &settings)
{
    app();
    Outcome out;
    FileSearchRunner runner;
    QObject::connect(&runner, &FileSearchRunner::found, &runner, [&](const QStringList &p) { out.paths += p; });
    QObject::connect(&runner, &FileSearchRunner::done, &runner, [&](int backend, bool limited, bool contents) {
        ++out.done;
        out.backend = backend;
        out.limited = limited;
        out.contentsUnavailable = contents;
    });
    runner.start(settings);
    QElapsedTimer clock;
    clock.start();
    while (out.done == 0 && clock.elapsed() < 10000)
        QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
    out.paths.sort();
    return out;
}

QDateTime at(const char *iso)
{
    return QDateTime::fromString(QString::fromLatin1(iso), Qt::ISODate);
}
} // namespace

TEST(SearchLocation, RoundTripsTextFolderAndRows)
{
    Query q;
    q.text = QStringLiteral("rapport & co 50% #1 ?é");
    q.folder = QUrl::fromLocalFile(QStringLiteral("/home/u/Docs & Notes"));
    q.criteria = {{Attribute::Kind, Op::Is, QStringLiteral("pdf"), QString()},
                  {Attribute::Modified, Op::WithinLast, QStringLiteral("7"), QStringLiteral("days")},
                  {Attribute::Name, Op::Contains, QStringLiteral("a:b&c=d"), QString()}};
    const QUrl url = toUrl(q);
    EXPECT_TRUE(isSearchUrl(url));
    EXPECT_EQ(url.scheme(), QStringLiteral("grassfield-search"));
    const auto back = fromUrl(url);
    ASSERT_TRUE(back.has_value());
    EXPECT_EQ(*back, q);
    // Through a string, as history and tabs keep it.
    const auto again = fromUrl(QUrl(url.toString(QUrl::FullyEncoded)));
    ASSERT_TRUE(again.has_value());
    EXPECT_EQ(*again, q);
}

TEST(SearchLocation, ThisComputerHasNoFolder)
{
    Query q;
    q.text = QStringLiteral("notes");
    const auto back = fromUrl(toUrl(q));
    ASSERT_TRUE(back.has_value());
    EXPECT_TRUE(back->inComputer());
}

TEST(SearchLocation, MalformedLocationsAreRefused)
{
    EXPECT_FALSE(fromUrl(QUrl(QStringLiteral("file:///tmp"))).has_value());
    EXPECT_FALSE(fromUrl(QUrl(QStringLiteral("grassfield-search:/?q=a&in=smb%253A%252F%252Fhost%252Fshare"))).has_value()) << "a remote folder";
    EXPECT_FALSE(fromUrl(QUrl(QStringLiteral("grassfield-search:/?q=a&c=colour%253Ais%253A%253Ared"))).has_value()) << "an unknown attribute";
    EXPECT_FALSE(fromUrl(QUrl(QStringLiteral("grassfield-search:/?q=a&c=size%253Abegins-with%253A%253A3"))).has_value()) << "an operator the attribute does not take";
    EXPECT_FALSE(fromUrl(QUrl(QStringLiteral("grassfield-search:/?q=a&c=kind"))).has_value()) << "a short row";
}

TEST(SearchCriteria, OperatorsAndCompleteness)
{
    EXPECT_EQ(operatorsFor(Attribute::Kind), (QList<Op>{Op::Is, Op::IsNot}));
    EXPECT_TRUE(takesOp(Attribute::Created, Op::ThisWeek));
    EXPECT_FALSE(takesOp(Attribute::Name, Op::Greater));
    EXPECT_TRUE(isComplete({Attribute::Opened, Op::Today, QString(), QString()})) << "today needs no value";
    EXPECT_FALSE(isComplete({Attribute::Opened, Op::WithinLast, QStringLiteral("0"), QStringLiteral("days")}));
    EXPECT_FALSE(isComplete({Attribute::Modified, Op::Before, QStringLiteral("31/12/2026"), QString()})) << "dates are ISO";
    EXPECT_TRUE(isComplete({Attribute::Modified, Op::Before, QStringLiteral("2026-12-31"), QString()}));
    EXPECT_FALSE(isComplete({Attribute::Name, Op::Contains, QStringLiteral("  "), QString()}));
    EXPECT_FALSE(isComplete({Attribute::Kind, Op::Is, QStringLiteral("spaceship"), QString()}));
    EXPECT_TRUE(isComplete({Attribute::Kind, Op::Is, QStringLiteral("any"), QString()}));
}

TEST(SearchCriteria, RowsHoldOnTheFacts)
{
    const QDateTime now = at("2026-11-01T12:00:00");
    Facts f;
    f.name = QStringLiteral("Résumé Final.PDF");
    f.size = 2500000;
    f.modified = at("2026-10-30T09:00:00");
    f.created = at("2026-01-15T09:00:00");
    f.opened = at("2026-11-01T08:00:00");
    f.kind = FileLogic::KindCategory::Pdf;
    f.tags = {QStringLiteral("Red"), QStringLiteral("Projet X")};
    auto holds = [&](const QList<Criterion> &rows) {
        Query q;
        q.criteria = rows;
        return matchesCriteria(q, f, now);
    };
    EXPECT_TRUE(holds({{Attribute::Kind, Op::Is, QStringLiteral("pdf"), {}}}));
    EXPECT_FALSE(holds({{Attribute::Kind, Op::IsNot, QStringLiteral("pdf"), {}}}));
    EXPECT_TRUE(holds({{Attribute::Kind, Op::Is, QStringLiteral("any"), {}}}));
    EXPECT_TRUE(holds({{Attribute::Name, Op::BeginsWith, QStringLiteral("resume"), {}}})) << "accents and case folded";
    EXPECT_TRUE(holds({{Attribute::Name, Op::EndsWith, QStringLiteral(".pdf"), {}}}));
    EXPECT_FALSE(holds({{Attribute::Name, Op::Is, QStringLiteral("resume"), {}}}));
    EXPECT_TRUE(holds({{Attribute::Modified, Op::WithinLast, QStringLiteral("3"), QStringLiteral("days")}}));
    EXPECT_FALSE(holds({{Attribute::Modified, Op::WithinLast, QStringLiteral("1"), QStringLiteral("days")}}));
    EXPECT_TRUE(holds({{Attribute::Created, Op::Before, QStringLiteral("2026-02-01"), {}}}));
    EXPECT_TRUE(holds({{Attribute::Created, Op::ThisYear, {}, {}}}));
    EXPECT_FALSE(holds({{Attribute::Created, Op::ThisMonth, {}, {}}}));
    EXPECT_TRUE(holds({{Attribute::Opened, Op::Today, {}, {}}}));
    EXPECT_TRUE(holds({{Attribute::Modified, Op::Exactly, QStringLiteral("2026-10-30"), {}}}));
    EXPECT_TRUE(holds({{Attribute::Size, Op::Greater, QStringLiteral("2"), QStringLiteral("MB")}}));
    EXPECT_FALSE(holds({{Attribute::Size, Op::Less, QStringLiteral("2500"), QStringLiteral("KB")}})) << "decimal units, strict";
    EXPECT_TRUE(holds({{Attribute::Tags, Op::Is, QStringLiteral("projet x"), {}}}));
    EXPECT_FALSE(holds({{Attribute::Tags, Op::Is, QStringLiteral("Blue"), {}}}));
    EXPECT_TRUE(holds({{Attribute::Name, Op::Contains, QStringLiteral(""), {}}})) << "an empty row is ignored";
    EXPECT_TRUE(holds({{Attribute::Kind, Op::Is, QStringLiteral("pdf"), {}}, {Attribute::Tags, Op::Is, QStringLiteral("red"), {}}}));
    EXPECT_FALSE(holds({{Attribute::Kind, Op::Is, QStringLiteral("pdf"), {}}, {Attribute::Tags, Op::Is, QStringLiteral("blue"), {}}})) << "every row";
    Facts folder;
    folder.name = QStringLiteral("Big");
    folder.isDir = true;
    folder.kind = FileLogic::KindCategory::Folder;
    Query q;
    q.criteria = {{Attribute::Size, Op::Greater, QStringLiteral("0"), QStringLiteral("KB")}};
    EXPECT_FALSE(matchesCriteria(q, folder, now)) << "folders have no size here";
}

TEST(SearchCriteria, HugeNumbersSaturateInsteadOfOverflowing)
{
    const QDateTime now = at("2026-11-01T12:00:00");
    Facts f;
    f.name = QStringLiteral("a.bin");
    f.size = 2500000;
    f.modified = at("2026-10-30T09:00:00");
    auto holds = [&](const Criterion &row) {
        Query q;
        q.criteria = {row};
        return matchesCriteria(q, f, now);
    };
    // 10^10 GB is 10^19 bytes, more than a signed 64-bit size holds: it is "bigger than any file", never a negative size
    // (which made every file "greater than" it).
    for (const char *unit : {"GB", "MB", "KB"}) {
        const QString big = QStringLiteral("9999999999999999");
        EXPECT_FALSE(holds({Attribute::Size, Op::Greater, big, QString::fromLatin1(unit)})) << unit;
        EXPECT_TRUE(holds({Attribute::Size, Op::Less, big, QString::fromLatin1(unit)})) << unit;
    }
    EXPECT_FALSE(holds({Attribute::Size, Op::Greater, QStringLiteral("9223372036854775807"), QStringLiteral("GB")}));
    // The largest number that still fits is exact.
    EXPECT_TRUE(holds({Attribute::Size, Op::Less, QStringLiteral("9223372036"), QStringLiteral("GB")}));
    // A huge span of days, months or years reaches back past every file and does not wrap the date.
    for (const char *unit : {"days", "weeks", "months", "years"})
        EXPECT_TRUE(holds({Attribute::Modified, Op::WithinLast, QStringLiteral("9999999999999999"), QString::fromLatin1(unit)})) << unit;
}

TEST(SearchCriteria, TextAndTerms)
{
    EXPECT_TRUE(textMatchesName(QStringLiteral("final resume"), QStringLiteral("Résumé Final.pdf"))) << "every word, any order";
    EXPECT_FALSE(textMatchesName(QStringLiteral("final draft"), QStringLiteral("Résumé Final.pdf")));
    EXPECT_TRUE(textMatchesName(QString(), QStringLiteral("anything")));
    Query q;
    q.criteria = {{Attribute::Name, Op::BeginsWith, QStringLiteral("Report"), {}}, {Attribute::Contents, Op::Contains, QStringLiteral("budget"), {}}};
    EXPECT_EQ(nameTerm(q), QStringLiteral("Report"));
    EXPECT_EQ(contentsText(q), QStringLiteral("budget"));
    EXPECT_FALSE(needsFacts(q)) << "names and contents need no lstat";
    q.text = QStringLiteral(" notes ");
    EXPECT_EQ(nameTerm(q), QStringLiteral("notes"));
    q.criteria.append({Attribute::Size, Op::Greater, QStringLiteral("1"), QStringLiteral("MB")});
    EXPECT_TRUE(needsFacts(q));

    // A new smart folder (no text, no complete row) asks for nothing.
    Query empty;
    EXPECT_FALSE(hasTerms(empty));
    empty.text = QStringLiteral("  ");
    empty.criteria = {{Attribute::Name, Op::Contains, QString(), {}}};
    EXPECT_FALSE(hasTerms(empty)) << "blank text and an unfinished row";
    empty.criteria.append({Attribute::Kind, Op::Is, QStringLiteral("pdf"), {}});
    EXPECT_TRUE(hasTerms(empty));
    EXPECT_TRUE(hasTerms(q));
}

TEST(SavedSearch, JsonRoundTripAndRefusals)
{
    Saved saved;
    saved.name = QStringLiteral("Big PDFs");
    saved.query.text = QStringLiteral("invoice");
    saved.query.folder = QUrl::fromLocalFile(QStringLiteral("/home/u/Documents"));
    saved.query.criteria = {{Attribute::Size, Op::Greater, QStringLiteral("10"), QStringLiteral("MB")}};
    saved.sidebar = true;
    const QJsonObject json = toJson(saved);
    EXPECT_EQ(json.value(QStringLiteral("version")).toInt(), 1);
    EXPECT_EQ(json.value(QStringLiteral("scope")).toString(), QStringLiteral("file:///home/u/Documents"));
    const auto back = fromJson(json);
    ASSERT_TRUE(back.has_value());
    EXPECT_EQ(back->name, saved.name);
    EXPECT_EQ(back->query, saved.query);
    EXPECT_TRUE(back->sidebar);
    QJsonObject newer = json;
    newer.insert(QStringLiteral("version"), 2);
    EXPECT_FALSE(fromJson(newer).has_value()) << "a newer version is left alone";
    QJsonObject nameless = json;
    nameless.insert(QStringLiteral("name"), QStringLiteral("  "));
    EXPECT_FALSE(fromJson(nameless).has_value());
    QJsonObject remote = json;
    remote.insert(QStringLiteral("scope"), QStringLiteral("sftp://host/home"));
    EXPECT_FALSE(fromJson(remote).has_value());
    QJsonObject computer = json;
    computer.insert(QStringLiteral("scope"), QStringLiteral("computer"));
    ASSERT_TRUE(fromJson(computer).has_value());
    EXPECT_TRUE(fromJson(computer)->query.inComputer());
}

TEST(SavedSearch, FileNames)
{
    EXPECT_EQ(savedFileName(QStringLiteral("Big PDFs")), QStringLiteral("Big PDFs.json"));
    EXPECT_EQ(savedFileName(QStringLiteral("a/b\x01" "c")), QStringLiteral("abc.json"));
    EXPECT_EQ(savedFileName(QStringLiteral(".hidden")), QStringLiteral("hidden.json")) << "never a hidden file";
    EXPECT_EQ(savedFileName(QStringLiteral("  ")), QStringLiteral("Search.json"));
    EXPECT_LE(savedFileName(QString(300, QChar(0x00e9))).toUtf8().size(), 205);
}

TEST(FileSearchWalk, FolderScopeMatchesNamesAndRows)
{
    QString why;
    auto dir = sandbox(&why);
    if (!dir)
        GTEST_SKIP() << why.toStdString();
    write(dir->filePath(QStringLiteral("docs/Report 2026.pdf")), QByteArray(3000, 'x'));
    write(dir->filePath(QStringLiteral("docs/report-notes.txt")));
    write(dir->filePath(QStringLiteral("docs/deep/a/b/Report old.pdf")));
    write(dir->filePath(QStringLiteral("docs/.hidden/Report secret.pdf")));
    write(dir->filePath(QStringLiteral("docs/Other.pdf")));
    ASSERT_EQ(::symlink("Report 2026.pdf", QFile::encodeName(dir->filePath(QStringLiteral("docs/Report link.pdf"))).constData()), 0);
    FileSearch::Settings s;
    s.query.text = QStringLiteral("report");
    s.query.folder = QUrl::fromLocalFile(dir->filePath(QStringLiteral("docs")));
    Outcome out = run(s);
    EXPECT_EQ(out.done, 1);
    EXPECT_EQ(out.backend, FileSearch::Walk);
    EXPECT_EQ(out.paths, (QStringList{dir->filePath(QStringLiteral("docs/Report 2026.pdf")), dir->filePath(QStringLiteral("docs/deep/a/b/Report old.pdf")),
                                      dir->filePath(QStringLiteral("docs/report-notes.txt"))}))
        << "no hidden entry, no link";
    s.query.criteria = {{Attribute::Kind, Op::Is, QStringLiteral("pdf"), {}}, {Attribute::Size, Op::Greater, QStringLiteral("2"), QStringLiteral("KB")}};
    out = run(s);
    EXPECT_EQ(out.paths, QStringList{dir->filePath(QStringLiteral("docs/Report 2026.pdf"))});
    s.showHidden = true;
    s.query.criteria.clear();
    out = run(s);
    EXPECT_TRUE(out.paths.contains(dir->filePath(QStringLiteral("docs/.hidden/Report secret.pdf"))));
}

TEST(FileSearchWalk, TagRowsReadTheAttribute)
{
    QString why;
    auto dir = sandbox(&why);
    if (!dir)
        GTEST_SKIP() << why.toStdString();
    const QString red = dir->filePath(QStringLiteral("a.txt"));
    write(red);
    write(dir->filePath(QStringLiteral("b.txt")));
    if (::lsetxattr(QFile::encodeName(red).constData(), "user.xdg.tags", "Red", 3, 0) != 0)
        GTEST_SKIP() << "no user extended attributes here";
    FileSearch::Settings s;
    s.query.folder = QUrl::fromLocalFile(dir->path());
    s.query.criteria = {{Attribute::Tags, Op::Is, QStringLiteral("red"), {}}};
    EXPECT_EQ(run(s).paths, QStringList{red});
}

TEST(FileSearchIndex, AnswersAreCheckedAndKeptUnderTheRoot)
{
    QString why;
    auto dir = sandbox(&why);
    if (!dir)
        GTEST_SKIP() << why.toStdString();
    const QString home = dir->filePath(QStringLiteral("home"));
    write(home + QStringLiteral("/notes.txt"));
    write(home + QStringLiteral("/Work/notes-old.txt"));
    write(home + QStringLiteral("/.cache/notes.txt"));
    write(dir->filePath(QStringLiteral("elsewhere/notes.txt")));
    FileSearch::Settings s;
    s.query.text = QStringLiteral("notes");
    s.root = home;
    s.localsearch = program(*dir, QStringLiteral("localsearch"),
                            {QStringLiteral("Results:"), QStringLiteral("  \x1b[32mfile://") + home + QStringLiteral("/notes.txt\x1b[0m"),
                             QStringLiteral("  file://") + home + QStringLiteral("/Work/notes-old.txt"), QStringLiteral("  file://") + home + QStringLiteral("/.cache/notes.txt"),
                             QStringLiteral("  file://") + dir->filePath(QStringLiteral("elsewhere/notes.txt")), QStringLiteral("  file://") + home + QStringLiteral("/gone.txt")});
    Outcome out = run(s);
    EXPECT_EQ(out.backend, FileSearch::Index);
    EXPECT_EQ(out.paths, (QStringList{home + QStringLiteral("/Work/notes-old.txt"), home + QStringLiteral("/notes.txt")}))
        << "outside the root, under a hidden folder or gone: left out";
}

TEST(FileSearchIndex, PlocateWhenTheIndexHasNothing)
{
    QString why;
    auto dir = sandbox(&why);
    if (!dir)
        GTEST_SKIP() << why.toStdString();
    const QString home = dir->filePath(QStringLiteral("home"));
    write(home + QStringLiteral("/Annual report.odt"));
    write(home + QStringLiteral("/report card.png"));
    FileSearch::Settings s;
    s.query.text = QStringLiteral("annual report");
    s.root = home;
    s.localsearch = program(*dir, QStringLiteral("localsearch"), {});
    s.plocate = program(*dir, QStringLiteral("plocate"), {home + QStringLiteral("/Annual report.odt"), home + QStringLiteral("/report card.png")});
    Outcome out = run(s);
    EXPECT_EQ(out.backend, FileSearch::Names);
    EXPECT_EQ(out.paths, QStringList{home + QStringLiteral("/Annual report.odt")}) << "plocate matched one word: every word must be in the name";
}

TEST(FileSearchIndex, NoMatchIsNotAnError)
{
    QString why;
    auto dir = sandbox(&why);
    if (!dir)
        GTEST_SKIP() << why.toStdString();
    const QString home = dir->filePath(QStringLiteral("home"));
    write(home + QStringLiteral("/zebra.txt"));
    FileSearch::Settings s;
    s.query.text = QStringLiteral("zebra");
    s.root = home;
    // plocate's "nothing matched" (exit 1, no message): no results, no walk.
    s.plocate = program(*dir, QStringLiteral("plocate"), {}, 1);
    Outcome out = run(s);
    EXPECT_EQ(out.backend, FileSearch::Names);
    EXPECT_TRUE(out.paths.isEmpty());
    // An error (no database): the home folder is walked instead.
    s.plocate = program(*dir, QStringLiteral("plocate2"), {}, 1, QStringLiteral("plocate: /var/lib/plocate/plocate.db: No such file or directory"));
    out = run(s);
    EXPECT_EQ(out.backend, FileSearch::Walk);
    EXPECT_EQ(out.paths, QStringList{home + QStringLiteral("/zebra.txt")});
}

TEST(FileSearchIndex, ContentsNeedTheIndex)
{
    QString why;
    auto dir = sandbox(&why);
    if (!dir)
        GTEST_SKIP() << why.toStdString();
    const QString home = dir->filePath(QStringLiteral("home"));
    write(home + QStringLiteral("/budget.ods"));
    write(home + QStringLiteral("/plan.txt"));
    FileSearch::Settings s;
    s.root = home;
    s.query.criteria = {{Attribute::Contents, Op::Contains, QStringLiteral("budget"), {}}};
    Outcome out = run(s);
    EXPECT_TRUE(out.contentsUnavailable);
    EXPECT_TRUE(out.paths.isEmpty());
    s.localsearch = program(*dir, QStringLiteral("localsearch"), {QStringLiteral("file://") + home + QStringLiteral("/plan.txt")});
    out = run(s);
    EXPECT_FALSE(out.contentsUnavailable);
    EXPECT_EQ(out.paths, QStringList{home + QStringLiteral("/plan.txt")}) << "what the index matched in the contents";
}

TEST(FileSearchRunner, ASupersededSearchReportsNothing)
{
    QString why;
    auto dir = sandbox(&why);
    if (!dir)
        GTEST_SKIP() << why.toStdString();
    for (int i = 0; i < 300; ++i)
        write(dir->filePath(QStringLiteral("old/old-%1.txt").arg(i)));
    write(dir->filePath(QStringLiteral("new/new.txt")));
    app();
    FileSearchRunner runner;
    QStringList seen;
    int done = 0;
    QObject::connect(&runner, &FileSearchRunner::found, &runner, [&](const QStringList &p) { seen += p; });
    QObject::connect(&runner, &FileSearchRunner::done, &runner, [&](int, bool, bool) { ++done; });
    FileSearch::Settings first;
    first.query.folder = QUrl::fromLocalFile(dir->filePath(QStringLiteral("old")));
    runner.start(first);
    FileSearch::Settings second;
    second.query.folder = QUrl::fromLocalFile(dir->filePath(QStringLiteral("new")));
    runner.start(second);
    QElapsedTimer clock;
    clock.start();
    while (done == 0 && clock.elapsed() < 10000)
        QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
    // Let any late batch of the first search arrive: none may pass.
    for (int i = 0; i < 10; ++i)
        QCoreApplication::processEvents(QEventLoop::AllEvents, 20);
    EXPECT_EQ(done, 1);
    EXPECT_EQ(seen, QStringList{dir->filePath(QStringLiteral("new/new.txt"))});
}

TEST(SavedSearchStore, SavesReplacesListsAndRemoves)
{
    QString why;
    auto dir = sandbox(&why);
    if (!dir)
        GTEST_SKIP() << why.toStdString();
    app();
    const QString folder = dir->filePath(QStringLiteral("saved-searches"));
    SavedSearches store(folder);
    EXPECT_TRUE(store.entries().isEmpty()) << "no folder yet";
    Saved a;
    a.name = QStringLiteral("Invoices");
    a.query.text = QStringLiteral("invoice");
    EXPECT_EQ(store.save(a), QString());
    ASSERT_EQ(store.entries().size(), 1);
    EXPECT_EQ(store.entries().first().file, QStringLiteral("Invoices.json"));
    const QFileDevice::Permissions perms = QFile::permissions(folder + QStringLiteral("/Invoices.json"));
    EXPECT_EQ(perms & (QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner), QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    EXPECT_EQ(perms & 0x0077, 0) << "0600: nothing for the group or others";
    // The same name again replaces it.
    a.query.text = QStringLiteral("facture");
    a.sidebar = true;
    EXPECT_EQ(store.save(a), QString());
    ASSERT_EQ(store.entries().size(), 1);
    EXPECT_EQ(store.entries().first().saved.query.text, QStringLiteral("facture"));
    EXPECT_TRUE(store.entries().first().saved.sidebar);
    // Another search whose file name would be taken by a file that is not a search of that name.
    write(folder + QStringLiteral("/Big.json"), "not json");
    Saved b;
    b.name = QStringLiteral("Big");
    EXPECT_EQ(store.save(b), QString());
    QStringList files;
    for (const auto &e : store.entries())
        files << e.file;
    EXPECT_EQ(files, (QStringList{QStringLiteral("Big 2.json"), QStringLiteral("Invoices.json")})) << "the unreadable file stays and is not listed";
    EXPECT_TRUE(QFile::exists(folder + QStringLiteral("/Big.json")));
    EXPECT_TRUE(store.setSidebar(QStringLiteral("Big 2.json"), true));
    EXPECT_FALSE(store.remove(QStringLiteral("Big.json"))) << "only a listed search is removed";
    EXPECT_FALSE(store.remove(QStringLiteral("../Invoices.json")));
    EXPECT_TRUE(store.remove(QStringLiteral("Invoices.json")));
    ASSERT_EQ(store.entries().size(), 1);
    EXPECT_EQ(store.entries().first().saved.name, QStringLiteral("Big"));
    EXPECT_NE(store.save(Saved{}), QString()) << "a nameless search";
}
