// ADR-0035 D-4, docs/specs/system-dialogs.md section 1 (A-FC1): every FileChooser option of xdg-desktop-portal 1.22.1's
// backend interface in, what the panel gets, and the exact results out.
#include <gtest/gtest.h>

#include "chooserlogic.h"

#include <QDBusMetaType>
#include <QUrl>

using namespace grassfield::portal::chooser;

namespace {

// A value of the options vardict as a test hands it (the D-Bus form, QDBusArgument, is covered by tst_filechooser over a
// private bus).
template<class T>
QVariant wire(const T &value)
{
    return QVariant::fromValue(value);
}

Filter filter(const QString &name, QList<FilterRule> rules)
{
    return Filter{name, rules};
}

const Filter kImages = filter(QStringLiteral("Images"), {{0, QStringLiteral("*.png")}, {1, QStringLiteral("image/jpeg")}});
const Filter kText = filter(QStringLiteral("Text"), {{1, QStringLiteral("text/plain")}});

class ChooserLogic : public ::testing::Test
{
protected:
    void SetUp() override { registerTypes(); }
};

} // namespace

TEST_F(ChooserLogic, OpenOptionsMapToThePanel)
{
    const QVariantMap options{
        {QStringLiteral("accept_label"), QStringLiteral("_Import")},
        {QStringLiteral("modal"), false},
        {QStringLiteral("multiple"), true},
        {QStringLiteral("directory"), false},
        {QStringLiteral("filters"), wire(QList<Filter>{kImages, kText})},
        {QStringLiteral("current_filter"), wire(kText)},
        {QStringLiteral("choices"), wire(QList<Choice>{
                                        {QStringLiteral("encoding"), QStringLiteral("_Encoding"),
                                         {{QStringLiteral("utf8"), QStringLiteral("Unicode (UTF-8)")}, {QStringLiteral("latin1"), QStringLiteral("Western")}},
                                         QStringLiteral("latin1")},
                                        {QStringLiteral("reencode"), QStringLiteral("Re-encode"), {}, QStringLiteral("true")}})},
        {QStringLiteral("current_folder"), QByteArray("/home/u/Pictures\0", 17)},
    };
    const Request r = parse(Kind::Open, QStringLiteral("org.example.App"), QStringLiteral("wayland:abc"), QStringLiteral("Open Image"), options);
    EXPECT_TRUE(r.error.isEmpty());
    EXPECT_EQ(r.acceptLabel, QStringLiteral("Import")); // GTK's mnemonic marker goes
    EXPECT_FALSE(r.modal);
    EXPECT_TRUE(r.multiple);
    ASSERT_EQ(r.filters.size(), 2);
    EXPECT_EQ(r.currentFilter, 1);
    ASSERT_EQ(r.choices.size(), 2);
    EXPECT_EQ(r.choices[0].label, QStringLiteral("Encoding"));
    EXPECT_EQ(r.choices[0].initial, QStringLiteral("latin1"));
    EXPECT_EQ(r.choices[1].initial, QStringLiteral("true"));
    EXPECT_EQ(r.currentFolder, QStringLiteral("/home/u/Pictures"));

    const QVariantMap q = toQml(r);
    EXPECT_EQ(q.value("kind").toString(), QStringLiteral("open"));
    EXPECT_EQ(q.value("title").toString(), QStringLiteral("Open Image"));
    EXPECT_EQ(q.value("currentFolder").toString(), QStringLiteral("file:///home/u/Pictures"));
    const QVariantMap images = q.value("filters").toList().at(0).toMap();
    EXPECT_EQ(images.value("globs").toStringList(), QStringList{QStringLiteral("*.png")});
    EXPECT_EQ(images.value("mimeTypes").toStringList(), QStringList{QStringLiteral("image/jpeg")});
    EXPECT_EQ(q.value("currentFilter").toInt(), 1);
    EXPECT_FALSE(q.value("modal").toBool());
}

TEST_F(ChooserLogic, OpenResultsAreExact)
{
    const QVariantMap options{{QStringLiteral("multiple"), true}, {QStringLiteral("filters"), wire(QList<Filter>{kImages, kText})},
                              {QStringLiteral("choices"), wire(QList<Choice>{{QStringLiteral("enc"), QStringLiteral("Enc"),
                                                                               {{QStringLiteral("a"), QStringLiteral("A")}, {QStringLiteral("b"), QStringLiteral("B")}},
                                                                               QStringLiteral("a")},
                                                                              {QStringLiteral("ro"), QStringLiteral("Read only"), {}, QStringLiteral("false")}})}};
    const Request r = parse(Kind::Open, {}, {}, {}, options);
    const Results res = results(r, {{QStringLiteral("uris"), QVariantList{QStringLiteral("file:///tmp/a%20b.png"), QStringLiteral("file:///tmp/c.png")}},
                                    {QStringLiteral("choices"), QVariantList{QVariantMap{{"id", "enc"}, {"value", "b"}}, QVariantMap{{"id", "ro"}, {"value", "true"}}}},
                                    {QStringLiteral("filter"), 0}});
    ASSERT_TRUE(res.ok);
    EXPECT_EQ(res.map.value("uris").toStringList(), (QStringList{QStringLiteral("file:///tmp/a%20b.png"), QStringLiteral("file:///tmp/c.png")}));
    const auto choices = res.map.value("choices").value<QList<Pair>>();
    EXPECT_EQ(choices, (QList<Pair>{{QStringLiteral("enc"), QStringLiteral("b")}, {QStringLiteral("ro"), QStringLiteral("true")}}));
    EXPECT_EQ(res.map.value("current_filter").value<Filter>(), kImages);
    // What the user picked, the application may write (4b-17): said, whatever the frontend's default.
    EXPECT_EQ(res.map.value("writable"), QVariant(true));

    // The D-Bus signatures the frontend reads.
    EXPECT_STREQ(QDBusMetaType::typeToSignature(QMetaType::fromType<QList<Pair>>()), "a(ss)");
    EXPECT_STREQ(QDBusMetaType::typeToSignature(QMetaType::fromType<Filter>()), "(sa(us))");
    EXPECT_STREQ(QDBusMetaType::typeToSignature(QMetaType::fromType<QList<Choice>>()), "a(ssa(ss)s)");
}

TEST_F(ChooserLogic, AnswersThatBreakTheInterfaceAreRefused)
{
    const Request one = parse(Kind::Open, {}, {}, {}, {});
    EXPECT_FALSE(results(one, {{QStringLiteral("uris"), QVariantList{}}}).ok);
    EXPECT_FALSE(results(one, {{QStringLiteral("uris"), QVariantList{"file:///a", "file:///b"}}}).ok); // not multiple
    EXPECT_FALSE(results(one, {{QStringLiteral("uris"), QVariantList{"smb://host/share/a"}}}).ok);   // only file://
    EXPECT_FALSE(results(one, {{QStringLiteral("uris"), QVariantList{"file://host/a"}}}).ok);
    EXPECT_FALSE(results(one, {{QStringLiteral("uris"), QVariantList{"file:///tmp/../etc/passwd"}}}).ok);
    EXPECT_FALSE(results(one, {{QStringLiteral("uris"), QVariantList{"relative/path"}}}).ok);
    EXPECT_TRUE(results(one, {{QStringLiteral("uris"), QVariantList{"file:///tmp/a"}}}).ok);
    // A folder with a trailing "/" is that folder.
    EXPECT_EQ(results(parse(Kind::Open, {}, {}, {}, {{QStringLiteral("directory"), true}}), {{QStringLiteral("uris"), QVariantList{"file:///tmp/dir/"}}})
                  .map.value("uris").toStringList(),
              QStringList{QStringLiteral("file:///tmp/dir")});
    EXPECT_FALSE(results(one, {{QStringLiteral("uris"), QVariantList{"file:///tmp//a"}}}).ok);

    // A choice value the choice does not allow is its initial value; a filter index out of range is the current filter.
    const Request c = parse(Kind::Open, {}, {}, {},
                            {{QStringLiteral("filters"), wire(QList<Filter>{kImages, kText})},
                             {QStringLiteral("choices"), wire(QList<Choice>{{QStringLiteral("ro"), QStringLiteral("RO"), {}, QStringLiteral("true")}})}});
    const Results res = results(c, {{QStringLiteral("uris"), QVariantList{"file:///tmp/a"}},
                                    {QStringLiteral("choices"), QVariantList{QVariantMap{{"id", "ro"}, {"value", "maybe"}}}},
                                    {QStringLiteral("filter"), 7}});
    ASSERT_TRUE(res.ok);
    EXPECT_EQ(res.map.value("choices").value<QList<Pair>>(), (QList<Pair>{{QStringLiteral("ro"), QStringLiteral("true")}}));
    EXPECT_EQ(res.map.value("current_filter").value<Filter>(), kImages);
    // No filters, no current_filter in the results; no choices, no choices.
    EXPECT_FALSE(results(one, {{QStringLiteral("uris"), QVariantList{"file:///tmp/a"}}}).map.contains("current_filter"));
    EXPECT_FALSE(results(one, {{QStringLiteral("uris"), QVariantList{"file:///tmp/a"}}}).map.contains("choices"));
}

// A path as the panel gives it: QML prints a URL with its spaces and letters as they are, KIO's own URLs encode them; both are
// the same file, returned fully encoded (review of step 4b, BLOCKER 1).
TEST_F(ChooserLogic, PathsWithSpacesAndAnyLetterAreFiles)
{
    const Request one = parse(Kind::Open, {}, {}, {}, {});
    const auto uris = [&](const Request &r, const QVariantList &given) {
        const Results res = results(r, {{QStringLiteral("uris"), given}});
        return res.ok ? res.map.value("uris").toStringList() : QStringList{QStringLiteral("refused")};
    };
    EXPECT_EQ(uris(one, {QStringLiteral("file:///tmp/My Documents/new file.txt")}),
              QStringList{QStringLiteral("file:///tmp/My%20Documents/new%20file.txt")});
    EXPECT_EQ(uris(one, {QStringLiteral("file:///tmp/My%20Documents/new%20file.txt")}),
              QStringList{QStringLiteral("file:///tmp/My%20Documents/new%20file.txt")});
    EXPECT_EQ(uris(one, {QString::fromUtf8("file:///tmp/R\u00e9sum\u00e9 2026.pdf")}),
              QStringList{QStringLiteral("file:///tmp/R%C3%A9sum%C3%A9%202026.pdf")});
    // '%', '#' and '?' in a name, as QUrl::fromLocalFile encodes them.
    EXPECT_EQ(uris(one, {QUrl::fromLocalFile(QStringLiteral("/tmp/100% #1?.txt")).toString()}),
              QStringList{QUrl::fromLocalFile(QStringLiteral("/tmp/100% #1?.txt")).toString(QUrl::FullyEncoded)});
    // A raw '#' or '?' starts a fragment or a query: not a local file.
    EXPECT_EQ(uris(one, {QStringLiteral("file:///tmp/a#b")}), QStringList{QStringLiteral("refused")});
    EXPECT_EQ(uris(one, {QStringLiteral("file:///tmp/a?b")}), QStringList{QStringLiteral("refused")});
    EXPECT_EQ(uris(one, {QStringLiteral("file:///tmp/a%00b")}), QStringList{QStringLiteral("refused")});

    // Save and SaveFiles: a folder with a space.
    EXPECT_TRUE(results(parse(Kind::Save, {}, {}, {}, {}), {{QStringLiteral("uris"), QVariantList{"file:///tmp/My Documents/a b.txt"}}}).ok);
    const Request several = parse(Kind::SaveFiles, {}, {}, {}, {{QStringLiteral("files"), wire(QByteArrayList{QByteArray("a b.txt"), QByteArray("c.txt")})}});
    EXPECT_TRUE(results(several, {{QStringLiteral("uris"), QVariantList{"file:///tmp/My Documents/a b.txt", "file:///tmp/My%20Documents/c.txt"}}}).ok);
}

TEST_F(ChooserLogic, SaveTakesTheNameAndTheFolder)
{
    const Request r = parse(Kind::Save, {}, {}, {},
                            {{QStringLiteral("current_name"), QStringLiteral("Untitled.txt")},
                             {QStringLiteral("current_folder"), QByteArray("/home/u/Documents", 17)},
                             {QStringLiteral("multiple"), true},
                             {QStringLiteral("directory"), true}});
    EXPECT_EQ(r.currentName, QStringLiteral("Untitled.txt"));
    EXPECT_EQ(r.currentFolder, QStringLiteral("/home/u/Documents"));
    EXPECT_FALSE(r.multiple); // Open's options only
    EXPECT_FALSE(r.directory);

    // current_file wins: its folder and its name.
    const Request f = parse(Kind::Save, {}, {}, {},
                            {{QStringLiteral("current_name"), QStringLiteral("Other.txt")},
                             {QStringLiteral("current_folder"), QByteArray("/tmp")},
                             {QStringLiteral("current_file"), QByteArray("/home/u/Notes/today.md\0", 23)}});
    EXPECT_EQ(f.currentName, QStringLiteral("today.md"));
    EXPECT_EQ(f.currentFolder, QStringLiteral("/home/u/Notes"));
    EXPECT_EQ(toQml(f).value("currentFile").toString(), QStringLiteral("file:///home/u/Notes/today.md"));

    // A suggested name is never a path; a relative folder is no folder.
    EXPECT_EQ(parse(Kind::Save, {}, {}, {}, {{QStringLiteral("current_name"), QStringLiteral("../../evil.sh")}}).currentName, QStringLiteral("evil.sh"));
    EXPECT_EQ(parse(Kind::Save, {}, {}, {}, {{QStringLiteral("current_name"), QStringLiteral("..")}}).currentName, QString());
    EXPECT_EQ(parse(Kind::Save, {}, {}, {}, {{QStringLiteral("current_folder"), QByteArray("relative")}}).currentFolder, QString());

    // Exactly one URI with a valid name.
    EXPECT_TRUE(results(r, {{QStringLiteral("uris"), QVariantList{"file:///home/u/Documents/Untitled.txt"}}}).ok);
    EXPECT_FALSE(results(r, {{QStringLiteral("uris"), QVariantList{"file:///home/u/Documents/a", "file:///home/u/Documents/b"}}}).ok);
    EXPECT_FALSE(results(r, {{QStringLiteral("uris"), QVariantList{"file:///"}}}).ok);
}

TEST_F(ChooserLogic, SaveFilesGivesOneUriPerName)
{
    QByteArrayList names{QByteArray("a.txt\0", 6), QByteArray("b.txt\0", 6)};
    const Request r = parse(Kind::SaveFiles, {}, {}, {}, {{QStringLiteral("files"), wire(names)}, {QStringLiteral("current_folder"), QByteArray("/tmp/out")}});
    EXPECT_TRUE(r.error.isEmpty());
    EXPECT_EQ(r.files, (QStringList{QStringLiteral("a.txt"), QStringLiteral("b.txt")}));
    EXPECT_TRUE(r.filters.isEmpty()); // SaveFiles has no filters
    EXPECT_TRUE(results(r, {{QStringLiteral("uris"), QVariantList{"file:///tmp/out/a.txt", "file:///tmp/out/b%202.txt"}}}).ok);
    EXPECT_FALSE(results(r, {{QStringLiteral("uris"), QVariantList{"file:///tmp/out/a.txt"}}}).ok);                          // one per name
    EXPECT_FALSE(results(r, {{QStringLiteral("uris"), QVariantList{"file:///tmp/out/a.txt", "file:///tmp/other/b.txt"}}}).ok); // one folder

    // A name that is not one (a path, "..") ends the request at once; so does no name at all.
    EXPECT_FALSE(parse(Kind::SaveFiles, {}, {}, {}, {{QStringLiteral("files"), wire(QByteArrayList{QByteArray("../x")})}}).error.isEmpty());
    EXPECT_FALSE(parse(Kind::SaveFiles, {}, {}, {}, {}).error.isEmpty());
    // More names than a panel takes: the request ends at once, never with a part of them (review of step 4b, NIT 10).
    QByteArrayList many;
    for (int i = 0; i <= kMaxFiles; ++i)
        many.append(QByteArray::number(i) + ".txt");
    EXPECT_FALSE(parse(Kind::SaveFiles, {}, {}, {}, {{QStringLiteral("files"), wire(many)}}).error.isEmpty());
    many.removeLast();
    EXPECT_TRUE(parse(Kind::SaveFiles, {}, {}, {}, {{QStringLiteral("files"), wire(many)}}).error.isEmpty());
}

TEST_F(ChooserLogic, FiltersAreCheckedAndTheCurrentOneShownFirst)
{
    // Invalid filters (no name, no rule, an unknown rule type, an empty pattern) are dropped.
    const QList<Filter> given{filter({}, {{0, "*.a"}}), filter("None", {}), filter("Odd", {{2, "*.b"}}), filter("Empty", {{0, ""}}), kText};
    const Request r = parse(Kind::Open, {}, {}, {}, {{QStringLiteral("filters"), wire(given)}});
    ASSERT_EQ(r.filters.size(), 1);
    EXPECT_EQ(r.filters[0], kText);
    EXPECT_EQ(r.currentFilter, 0);
    // No list: the current filter is the list (the interface allows any current filter then).
    const Request alone = parse(Kind::Save, {}, {}, {}, {{QStringLiteral("current_filter"), wire(kImages)}});
    ASSERT_EQ(alone.filters.size(), 1);
    EXPECT_EQ(alone.currentFilter, 0);
    // A current filter that is not in the list: the first one.
    const Request other = parse(Kind::Open, {}, {}, {}, {{QStringLiteral("filters"), wire(QList<Filter>{kText})}, {QStringLiteral("current_filter"), wire(kImages)}});
    EXPECT_EQ(other.currentFilter, 0);
    EXPECT_EQ(other.filters.size(), 1);
}

// The filter returned is the application's own, byte for byte (GTK finds it by its name); only the panel's copy is made one
// plain line (review of step 4b, MINOR 7).
TEST_F(ChooserLogic, TheFilterReturnedIsTheOneGiven)
{
    const Filter odd = filter(QStringLiteral("  Images\u2066 (*.png)  "), {{0, QStringLiteral("*.png")}});
    const Request r = parse(Kind::Open, {}, {}, {}, {{QStringLiteral("filters"), wire(QList<Filter>{kText, odd})}, {QStringLiteral("current_filter"), wire(odd)}});
    ASSERT_EQ(r.filters.size(), 2);
    EXPECT_EQ(r.filters[1], odd);
    EXPECT_EQ(r.currentFilter, 1);
    EXPECT_EQ(toQml(r).value("filters").toList().at(1).toMap().value("name").toString(), QStringLiteral("Images (*.png)"));
    const Results res = results(r, {{QStringLiteral("uris"), QVariantList{"file:///tmp/a.png"}}, {QStringLiteral("filter"), 1}});
    ASSERT_TRUE(res.ok);
    EXPECT_EQ(res.map.value("current_filter").value<Filter>(), odd);
}

// A filter's patterns together are bounded (FileLogic::passesFilter costs at most a name's length times their length): a
// filter beyond the bound is dropped, never matched (review of step 4b, MINOR 8).
TEST_F(ChooserLogic, AFilterIsBounded)
{
    // At the bound: 4096 characters in 4 patterns of 1024; beyond: one more character, few rules, each pattern short enough.
    QList<FilterRule> rules(kMaxFilterPatternLength / kMaxTextLength, {0, QString(kMaxTextLength - 1, u'*') + QLatin1Char('a')});
    const Filter atBound = filter(QStringLiteral("At the bound"), rules);
    rules.append({0, QStringLiteral("b")});
    const Filter beyond = filter(QStringLiteral("Beyond"), rules);
    ASSERT_LE(beyond.rules.size(), kMaxRules);
    const Request r = parse(Kind::Open, {}, {}, {}, {{QStringLiteral("filters"), wire(QList<Filter>{atBound, beyond})}});
    ASSERT_EQ(r.filters.size(), 1);
    EXPECT_EQ(r.filters[0].name, QStringLiteral("At the bound"));
    // A pattern longer than any text, and more rules than allowed.
    EXPECT_TRUE(parse(Kind::Open, {}, {}, {}, {{QStringLiteral("filters"), wire(QList<Filter>{filter("Long", {{0, QString(kMaxTextLength + 1, u'x')}})})}})
                    .filters.isEmpty());
    EXPECT_TRUE(parse(Kind::Open, {}, {}, {}, {{QStringLiteral("filters"), wire(QList<Filter>{filter("Many", QList<FilterRule>(kMaxRules + 1, {0, "a"}))})}})
                    .filters.isEmpty());
}

TEST_F(ChooserLogic, ChoicesAreChecked)
{
    const QList<Choice> given{
        {QString(), QStringLiteral("No id"), {}, QStringLiteral("true")},
        {QStringLiteral("a"), QStringLiteral("A"), {{QStringLiteral("x"), QStringLiteral("X")}, {QStringLiteral("x"), QStringLiteral("Twice")}}, QStringLiteral("nope")},
        {QStringLiteral("a"), QStringLiteral("Same id"), {}, {}},
        {QStringLiteral("b"), QStringLiteral("B"), {}, QStringLiteral("yes")},
    };
    const Request r = parse(Kind::Open, {}, {}, {}, {{QStringLiteral("choices"), wire(given)}});
    ASSERT_EQ(r.choices.size(), 2);
    EXPECT_EQ(r.choices[0].options.size(), 1);                  // the second "x" goes
    EXPECT_EQ(r.choices[0].initial, QStringLiteral("x"));       // not an option: the first
    EXPECT_EQ(r.choices[1].initial, QStringLiteral("false"));   // a check box is "true" or "false"

    // An id is returned as given: one too long to return is dropped, never cut (review of step 4b, MINOR 7).
    const QString longId(kMaxTextLength + 1, u'i');
    const Request ids = parse(Kind::Open, {}, {}, {},
                              {{QStringLiteral("choices"), wire(QList<Choice>{{longId, QStringLiteral("Long"), {}, QStringLiteral("true")},
                                                                             {QStringLiteral("c"), QStringLiteral("C"),
                                                                              {{longId, QStringLiteral("Long")}, {QStringLiteral("y"), QStringLiteral("Y")}},
                                                                              QStringLiteral("y")}})}});
    ASSERT_EQ(ids.choices.size(), 1);
    EXPECT_EQ(ids.choices[0].id, QStringLiteral("c"));
    ASSERT_EQ(ids.choices[0].options.size(), 1);
    EXPECT_EQ(ids.choices[0].options[0].first, QStringLiteral("y"));
}

TEST_F(ChooserLogic, AnApplicationsTextIsOneLineOfPlainText)
{
    const Request r = parse(Kind::Open, {}, {}, QStringLiteral("Open\nthe") + QChar(0x202E) + QStringLiteral("fdp.exe <b>file</b>"),
                            {{QStringLiteral("accept_label"), QStringLiteral("__Odd_ label")}});
    EXPECT_EQ(r.title, QStringLiteral("Open thefdp.exe <b>file</b>")); // the override goes, the markup stays text
    EXPECT_EQ(r.acceptLabel, QStringLiteral("_Odd label"));
    EXPECT_EQ(parse(Kind::Open, {}, {}, QString(5000, u'x'), {}).title.size(), kMaxTextLength);
}
