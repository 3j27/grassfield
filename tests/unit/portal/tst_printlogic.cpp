// ADR-0035 D-7, steps 6a and 6b; docs/specs/system-dialogs.md section 7 (A-PR1): GTK's print settings and page setup in, the
// sheet's first state, GTK's keys out (both directions, with the names and D-Bus types GTK reads), and the CUPS options of the job;
// step 6b: a printer's own options, a document's page ranges, Open in Preview and the Presets.
#include <gtest/gtest.h>

#include "printlogic.h"

#include <QJsonDocument>
#include <QUrl>

using namespace grassfield::portal::print;

namespace {

Media media(const QString &name, double w, double h, double margin = 4.2)
{
    Media m;
    m.name = name;
    m.displayName = mediaDisplayName(name);
    m.widthMm = w;
    m.heightMm = h;
    m.topMm = m.bottomMm = m.leftMm = m.rightMm = margin;
    return m;
}

const Media kA4 = media(QStringLiteral("iso_a4_210x297mm"), 210, 297);
const Media kLetter = media(QStringLiteral("na_letter_8.5x11in"), 215.9, 279.4);
const Media kA5 = media(QStringLiteral("iso_a5_148x210mm"), 148, 210);

Capabilities office()
{
    Capabilities c;
    c.known = true;
    c.media = {kA4, kLetter, kA5};
    c.defaultMedia = kLetter.name;
    c.twoSided = true;
    c.color = true;
    c.maxCopies = 99;
    return c;
}

Capabilities monoSimplex()
{
    Capabilities c;
    c.known = true;
    c.media = {kA4};
    c.defaultMedia = kA4.name;
    return c;
}

// A printer with options of its own: two in Media & Quality, one in Printer Options.
Capabilities withOptions()
{
    Capabilities c = office();
    c.options = {{QStringLiteral("media-source"), {{QStringLiteral("auto"), QStringLiteral("Automatic")}, {QStringLiteral("tray-1"), QStringLiteral("Tray 1")}},
                  QStringLiteral("auto")},
                 {QStringLiteral("print-quality"),
                  {{QStringLiteral("3"), QStringLiteral("Draft")}, {QStringLiteral("4"), QStringLiteral("Normal")}, {QStringLiteral("5"), QStringLiteral("High")}},
                  QStringLiteral("4")},
                 {QStringLiteral("finishings"), {{QStringLiteral("3"), QStringLiteral("None")}, {QStringLiteral("20"), QStringLiteral("Staple Top Left")}},
                  QStringLiteral("3")}};
    return c;
}

QList<PageRange> ranges(const QString &text)
{
    QList<PageRange> out;
    EXPECT_TRUE(parseRanges(text, &out)) << text.toStdString();
    return out;
}

} // namespace

TEST(PrintLogic, PageRangesAreReadOneBasedAndGivenZeroBased)
{
    EXPECT_EQ(ranges(QStringLiteral("1-3, 5")), (QList<PageRange>{{0, 2}, {4, 4}}));
    EXPECT_EQ(gtkRanges(ranges(QStringLiteral("1-3, 5"))), QStringLiteral("0-2,4"));
    EXPECT_EQ(shownRanges(ranges(QStringLiteral("1-3, 5"))), QStringLiteral("1-3, 5"));
    // Sorted and merged where they meet or overlap; an en dash is a hyphen.
    EXPECT_EQ(gtkRanges(ranges(QStringLiteral("7, 2–4, 5, 3"))), QStringLiteral("1-4,6"));
    EXPECT_EQ(gtkRanges(ranges(QStringLiteral(" 4 "))), QStringLiteral("3"));
    QList<PageRange> untouched{{9, 9}};
    for (const QString &bad : {QString(), QStringLiteral(" "), QStringLiteral("0"), QStringLiteral("3-1"), QStringLiteral("1,,2"),
                               QStringLiteral("a"), QStringLiteral("1-"), QStringLiteral("-2"), QStringLiteral("1-2-3"),
                               QStringLiteral("100001"), QStringLiteral("1.5"), QStringLiteral("١")}) {
        EXPECT_FALSE(parseRanges(bad, &untouched)) << bad.toStdString();
    }
    QStringList many;
    for (int i = 1; i <= 65; ++i)
        many << QString::number(i * 2);
    EXPECT_FALSE(parseRanges(many.join(QLatin1Char(',')), &untouched)) << "more than 64 ranges";
    EXPECT_EQ(untouched, (QList<PageRange>{{9, 9}})) << "a refused text leaves the ranges as they were";
}

TEST(PrintLogic, PaperNamesAndSizes)
{
    double w = 0, h = 0;
    ASSERT_TRUE(pwgSize(QStringLiteral("iso_a4_210x297mm"), &w, &h));
    EXPECT_DOUBLE_EQ(w, 210);
    EXPECT_DOUBLE_EQ(h, 297);
    ASSERT_TRUE(pwgSize(QStringLiteral("na_letter_8.5x11in"), &w, &h));
    EXPECT_NEAR(w, 215.9, 0.001);
    EXPECT_NEAR(h, 279.4, 0.001);
    EXPECT_FALSE(pwgSize(QStringLiteral("iso_a4"), &w, &h));
    EXPECT_FALSE(pwgSize(QStringLiteral("x_0x10mm"), &w, &h));
    EXPECT_EQ(mediaDisplayName(QStringLiteral("iso_a4_210x297mm")), QStringLiteral("A4"));
    EXPECT_EQ(mediaDisplayName(QStringLiteral("na_letter_8.5x11in")), QStringLiteral("US Letter"));
    EXPECT_EQ(mediaDisplayName(QStringLiteral("om_photo_100x150mm")), QStringLiteral("100 × 150 mm"));
    EXPECT_EQ(mediaDisplayName(QStringLiteral("om_odd_100.25x150mm")), QStringLiteral("100.3 × 150 mm"));
    // Not "iso_a40": the name before the size must match whole.
    EXPECT_EQ(mediaDisplayName(QStringLiteral("iso_a40_10x20mm")), QStringLiteral("10 × 20 mm"));
    EXPECT_EQ(findMedia(office().media, QStringLiteral("iso_a5_148x210mm")), kA5);
    EXPECT_EQ(findMedia(office().media, QStringLiteral("iso_a4"), 210.4, 296.6), kA4) << "the same size within a millimetre";
    EXPECT_TRUE(findMedia(office().media, QStringLiteral("iso_a3_297x420mm"), 297, 420).name.isEmpty());
}

TEST(PrintLogic, TheFirstStateIsThePrintersDefaultsThenWhatTheApplicationAsks)
{
    // Nothing asked: the printer's default paper, one copy, every page, portrait, 100 %, one side, in colour.
    Choices c = initialChoices(QStringLiteral("Office"), office(), {}, {}, false, false);
    EXPECT_EQ(c.printer, QStringLiteral("Office"));
    EXPECT_EQ(c.media, kLetter);
    EXPECT_EQ(c.copies, 1);
    EXPECT_TRUE(c.collate);
    EXPECT_EQ(c.pages, QStringLiteral("all"));
    EXPECT_EQ(c.orientation, QStringLiteral("portrait"));
    EXPECT_EQ(c.scale, 100);
    EXPECT_EQ(c.duplex, QStringLiteral("simplex"));
    EXPECT_TRUE(c.color);

    // GTK's own serialization (gtk_print_settings_to_gvariant: strings) and page setup (doubles).
    const QVariantMap settings{
        {QStringLiteral("n-copies"), QStringLiteral("3")},          {QStringLiteral("collate"), QStringLiteral("false")},
        {QStringLiteral("print-pages"), QStringLiteral("ranges")},  {QStringLiteral("page-ranges"), QStringLiteral("0-2,4")},
        {QStringLiteral("orientation"), QStringLiteral("reverse_landscape")}, {QStringLiteral("scale"), QStringLiteral("80.000000")},
        {QStringLiteral("duplex"), QStringLiteral("vertical")},     {QStringLiteral("use-color"), QStringLiteral("false")},
    };
    const QVariantMap pageSetup{{QStringLiteral("Name"), QStringLiteral("iso_a5_148x210mm")}, {QStringLiteral("Width"), 148.0},
                                {QStringLiteral("Height"), 210.0}};
    c = initialChoices(QStringLiteral("Office"), office(), settings, pageSetup, false, false);
    EXPECT_EQ(c.media, kA5);
    EXPECT_EQ(c.copies, 3);
    EXPECT_FALSE(c.collate);
    EXPECT_EQ(c.pages, QStringLiteral("ranges"));
    EXPECT_EQ(c.ranges, QStringLiteral("1-3, 5"));
    EXPECT_EQ(c.orientation, QStringLiteral("landscape"));
    EXPECT_EQ(c.scale, 80);
    EXPECT_EQ(c.duplex, QStringLiteral("vertical"));
    EXPECT_FALSE(c.color);

    // What the printer cannot do is not asked: one side, black and white, its own paper, at most its copies.
    QVariantMap more = settings;
    more.insert(QStringLiteral("use-color"), QStringLiteral("true"));
    more.insert(QStringLiteral("n-copies"), QStringLiteral("5000"));
    c = initialChoices(QStringLiteral("Mono"), monoSimplex(), more, pageSetup, false, false);
    EXPECT_EQ(c.duplex, QStringLiteral("simplex"));
    EXPECT_FALSE(c.color);
    EXPECT_EQ(c.media, kA4) << "A5 is not offered: the printer's default";
    EXPECT_EQ(c.copies, 999);

    // Numbers an application could send to overflow a conversion: bounded first.
    c = initialChoices(QStringLiteral("Office"), office(),
                       {{QStringLiteral("n-copies"), QStringLiteral("1e300")}, {QStringLiteral("scale"), QStringLiteral("1e300")},
                        {QStringLiteral("print-pages"), QStringLiteral("ranges")}, {QStringLiteral("page-ranges"), QStringLiteral("0-2147483647")}},
                       {}, false, false);
    EXPECT_EQ(c.copies, 99);
    EXPECT_EQ(c.scale, 1000);
    EXPECT_EQ(c.pages, QStringLiteral("all")) << "a page past the last one the sheet takes";

    // "current" and "selection" only when the application has them; bad ranges are all pages.
    EXPECT_EQ(initialChoices({}, office(), {{QStringLiteral("print-pages"), QStringLiteral("current")}}, {}, false, false).pages,
              QStringLiteral("all"));
    EXPECT_EQ(initialChoices({}, office(), {{QStringLiteral("print-pages"), QStringLiteral("current")}}, {}, true, false).pages,
              QStringLiteral("current"));
    EXPECT_EQ(initialChoices({}, office(), {{QStringLiteral("print-pages"), QStringLiteral("selection")}}, {}, false, true).pages,
              QStringLiteral("selection"));
    EXPECT_EQ(initialChoices({}, office(),
                             {{QStringLiteral("print-pages"), QStringLiteral("ranges")}, {QStringLiteral("page-ranges"), QStringLiteral("4-2")}},
                             {}, false, false)
                  .pages,
              QStringLiteral("all"));

    // Not known yet: the application's paper; nothing at all: A4.
    Capabilities unknown;
    c = initialChoices({}, unknown, {{QStringLiteral("paper-format"), QStringLiteral("na_letter_8.5x11in")}}, {}, false, false);
    EXPECT_EQ(c.media.name, QStringLiteral("na_letter_8.5x11in"));
    EXPECT_NEAR(c.media.widthMm, 215.9, 0.001);
    EXPECT_EQ(c.duplex, QStringLiteral("simplex"));
    EXPECT_TRUE(c.color);
    c = initialChoices({}, unknown, {}, {}, false, false);
    EXPECT_EQ(c.media.name, QStringLiteral("iso_a4_210x297mm"));
}

TEST(PrintLogic, TheAnswerHasGtksKeysAndTypes)
{
    Choices c = initialChoices(QStringLiteral("Office"), office(), {}, {}, false, false);
    c.copies = 2;
    c.collate = false;
    c.pages = QStringLiteral("ranges");
    c.ranges = QStringLiteral("2-3, 7");
    c.media = kA4;
    c.orientation = QStringLiteral("landscape");
    c.scale = 90;
    c.duplex = QStringLiteral("horizontal");
    c.color = false;
    QVariantMap settings, pageSetup;
    ASSERT_TRUE(toGtk(c, &settings, &pageSetup));
    const QVariantMap wantSettings{
        {QStringLiteral("printer"), QStringLiteral("Office")},       {QStringLiteral("n-copies"), QStringLiteral("1")},
        {QStringLiteral("collate"), QStringLiteral("false")},        {QStringLiteral("print-pages"), QStringLiteral("ranges")},
        {QStringLiteral("page-ranges"), QStringLiteral("1-2,6")},    {QStringLiteral("orientation"), QStringLiteral("landscape")},
        {QStringLiteral("paper-format"), QStringLiteral("iso_a4_210x297mm")},
        {QStringLiteral("paper-width"), QStringLiteral("210.00")},   {QStringLiteral("paper-height"), QStringLiteral("297.00")},
        {QStringLiteral("scale"), QStringLiteral("90")},             {QStringLiteral("duplex"), QStringLiteral("horizontal")},
        {QStringLiteral("use-color"), QStringLiteral("false")},
    };
    EXPECT_EQ(settings, wantSettings);
    for (auto it = settings.cbegin(); it != settings.cend(); ++it)
        EXPECT_EQ(it.value().metaType(), QMetaType::fromType<QString>()) << it.key().toStdString() << ": GTK reads strings";
    const QVariantMap wantPage{
        {QStringLiteral("Name"), QStringLiteral("iso_a4_210x297mm")},
        {QStringLiteral("DisplayName"), QStringLiteral("A4")}, {QStringLiteral("Width"), 210.0},
        {QStringLiteral("Height"), 297.0},            {QStringLiteral("MarginTop"), 4.2},
        {QStringLiteral("MarginBottom"), 4.2},        {QStringLiteral("MarginLeft"), 4.2},
        {QStringLiteral("MarginRight"), 4.2},         {QStringLiteral("Orientation"), QStringLiteral("landscape")},
    };
    EXPECT_EQ(pageSetup, wantPage);
    EXPECT_EQ(pageSetup.value(QStringLiteral("Width")).metaType(), QMetaType::fromType<double>()) << "GTK reads doubles";
    EXPECT_FALSE(pageSetup.contains(QStringLiteral("PPDName"))) << "GTK takes any PPDName over Name (a paper named \"ppd_\")";
    // GTK gets one copy whatever is chosen: GTK 3 renders n-copies into the document (and GTK 4 for a file); the job asks the
    // printer for the copies (review of step 6a, MAJOR: n² copies).
    EXPECT_EQ(c.copies, 2);

    // Round trip: what the answer gives is the state the sheet opens in next time.
    const Choices back = initialChoices(QStringLiteral("Office"), office(), settings, pageSetup, false, false);
    EXPECT_EQ(back.copies, 1) << "the application keeps one copy";
    EXPECT_FALSE(back.collate);
    EXPECT_EQ(back.ranges, QStringLiteral("2-3, 7"));
    EXPECT_EQ(back.media, kA4);
    EXPECT_EQ(back.orientation, QStringLiteral("landscape"));
    EXPECT_EQ(back.scale, 90);
    EXPECT_EQ(back.duplex, QStringLiteral("horizontal"));
    EXPECT_FALSE(back.color);

    // Save as PDF: a file and its format, no printer; never the user's path (GTK only reads that the key is there).
    c.outputUri = QStringLiteral("file:///home/u/Documents/Report.pdf");
    ASSERT_TRUE(toGtk(c, &settings, &pageSetup));
    EXPECT_EQ(settings.value(QStringLiteral("output-uri")), QStringLiteral("file:///dev/null"));
    EXPECT_EQ(settings.value(QStringLiteral("output-file-format")), QStringLiteral("pdf"));
    EXPECT_FALSE(settings.contains(QStringLiteral("printer")));

    // What cannot be printed is no answer.
    c.ranges = QStringLiteral("3-1");
    EXPECT_FALSE(toGtk(c, &settings, &pageSetup));
    c.ranges = QStringLiteral("1");
    c.media = Media{};
    EXPECT_FALSE(toGtk(c, &settings, &pageSetup));
}

TEST(PrintLogic, TheJobGetsCopiesPaperSidesAndColourNeverPagesScaleOrOrientation)
{
    Choices c = initialChoices(QStringLiteral("Office"), office(), {}, {}, false, false);
    c.copies = 3;
    c.collate = true;
    c.pages = QStringLiteral("ranges");
    c.ranges = QStringLiteral("2");
    c.scale = 50;
    c.orientation = QStringLiteral("landscape");
    c.duplex = QStringLiteral("horizontal");
    c.color = false;
    c.media = kA4;
    using Options = QList<QPair<QString, QString>>;
    EXPECT_EQ(cupsOptions(c, office()), (Options{{QStringLiteral("copies"), QStringLiteral("3")},
                                                 {QStringLiteral("multiple-document-handling"), QStringLiteral("separate-documents-collated-copies")},
                                                 {QStringLiteral("media"), QStringLiteral("iso_a4_210x297mm")},
                                                 {QStringLiteral("sides"), QStringLiteral("two-sided-long-edge")},
                                                 {QStringLiteral("print-color-mode"), QStringLiteral("monochrome")}}));
    c.collate = false;
    c.duplex = QStringLiteral("vertical");
    c.color = true;
    c.copies = 1;
    EXPECT_EQ(cupsOptions(c, office()), (Options{{QStringLiteral("media"), QStringLiteral("iso_a4_210x297mm")},
                                                 {QStringLiteral("sides"), QStringLiteral("two-sided-short-edge")},
                                                 {QStringLiteral("print-color-mode"), QStringLiteral("color")}}));
    // A printer without two sides or colour is not asked for them; copies stop at its limit.
    c.copies = 500;
    c.collate = false;
    Capabilities mono = monoSimplex();
    mono.maxCopies = 10;
    EXPECT_EQ(cupsOptions(c, mono), (Options{{QStringLiteral("copies"), QStringLiteral("10")},
                                             {QStringLiteral("multiple-document-handling"), QStringLiteral("separate-documents-uncollated-copies")},
                                             {QStringLiteral("media"), QStringLiteral("iso_a4_210x297mm")}}));
    // The paper goes only as one the printer lists; a printer that listed none (it did not answer) gets it only as a PWG name,
    // never the application's text as it came (a comma would give CUPS several values).
    c.copies = 1;
    c.media = Media{QStringLiteral("iso_a3_297x420mm"), QStringLiteral("A3"), 297, 420};
    EXPECT_EQ(cupsOptions(c, mono), Options{}) << "not one of the printer's";
    Capabilities unknown;
    EXPECT_EQ(cupsOptions(c, unknown), (Options{{QStringLiteral("media"), QStringLiteral("iso_a3_297x420mm")}}));
    c.media.name = QStringLiteral("iso_a4_210x297mm,na_letter_8.5x11in");
    EXPECT_EQ(cupsOptions(c, unknown), Options{});
    c.media.name = QStringLiteral("A4 sides=two-sided-long-edge");
    EXPECT_EQ(cupsOptions(c, unknown), Options{});
    // Save as PDF prints nothing.
    c.media = kA4;
    c.outputUri = QStringLiteral("file:///tmp/a.pdf");
    EXPECT_TRUE(cupsOptions(c, office()).isEmpty());
}

// What reaches CUPS besides the options: a PWG paper name, the document's type off its first bytes (only a PDF),
// the job's name within IPP's 255 bytes, on a character's boundary.
TEST(PrintLogic, WhatReachesCups)
{
    for (const char *good : {"iso_a4_210x297mm", "na_letter_8.5x11in", "om_small-photo_100x150mm", "custom_1x2mm"})
        EXPECT_TRUE(validMediaName(QString::fromLatin1(good))) << good;
    for (const char *bad : {"", "A4", "iso_a4,na_letter", "iso a4", "_a4", "iso_a4\n", "iso_a4;x", "\u00e9"})
        EXPECT_FALSE(validMediaName(QString::fromUtf8(bad))) << bad;
    EXPECT_FALSE(validMediaName(QString(65, QLatin1Char('a'))));
    EXPECT_TRUE(validMediaName(QString(64, QLatin1Char('a'))));

    EXPECT_EQ(documentFormat("%PDF-1.7 body"), QStringLiteral("application/pdf"));
    EXPECT_EQ(documentFormat("%PDF-"), QStringLiteral("application/pdf"));
    EXPECT_EQ(documentFormat("%!PS-Adobe-3.0"), QString()) << "PostScript can program a PostScript printer";
    EXPECT_EQ(documentFormat("%PDF"), QString()) << "not five bytes of a PDF";
    EXPECT_EQ(documentFormat("\x1b%-12345X@PJL ENTER LANGUAGE=PCL"), QString()) << "a printer language";
    EXPECT_EQ(documentFormat(""), QString());
    EXPECT_EQ(documentFormat("GIF89a"), QString());

    EXPECT_EQ(jobName(QStringLiteral("Quarterly Report")), QByteArray("Quarterly Report"));
    EXPECT_EQ(jobName(QString(255, QLatin1Char('a'))).size(), 255);
    EXPECT_EQ(jobName(QString(300, QLatin1Char('a'))).size(), 255);
    // "é" is two bytes in UTF-8: 127 of them are 254 bytes, the 128th would end at byte 256.
    const QByteArray accents = jobName(QString(200, QChar(0x00e9)));
    EXPECT_EQ(accents.size(), 254);
    EXPECT_EQ(QString::fromUtf8(accents), QString(127, QChar(0x00e9))) << "no half character";
    const QByteArray emoji = jobName(QStringLiteral("a") + QString::fromUtf8("\xf0\x9f\x93\x84").repeated(100));
    EXPECT_EQ(emoji.size(), 253) << "a + 63 four-byte characters";
    EXPECT_TRUE(QString::fromUtf8(emoji).toUtf8() == emoji);
}

TEST(PrintLogic, TheSheetsChoicesAreCheckedOnTheWayBack)
{
    const Choices base = initialChoices(QStringLiteral("Office"), office(), {}, {}, false, false);
    EXPECT_EQ(toQml(fromQml(toQml(base), base)), toQml(base)) << "a round trip keeps everything";
    Choices c = fromQml({{QStringLiteral("copies"), -4}, {QStringLiteral("scale"), 5000}, {QStringLiteral("pages"), QStringLiteral("odd")},
                         {QStringLiteral("duplex"), QStringLiteral("sideways")}, {QStringLiteral("orientation"), QStringLiteral("reverse-landscape")},
                         {QStringLiteral("media"), QVariantMap{{QStringLiteral("name"), QString()}, {QStringLiteral("widthMm"), 10}}},
                         {QStringLiteral("outputUri"), QStringLiteral("https://example.org/a.pdf")},
                         {QStringLiteral("printer"), QStringLiteral("Office\nX")}},
                        base);
    EXPECT_EQ(c.copies, 1);
    EXPECT_EQ(c.scale, 1000);
    EXPECT_EQ(c.pages, QStringLiteral("all")) << "an unknown value keeps the one before";
    EXPECT_EQ(c.duplex, QStringLiteral("simplex"));
    EXPECT_EQ(c.orientation, QStringLiteral("landscape"));
    EXPECT_EQ(c.media, base.media) << "a paper without a name or size is not taken";
    EXPECT_TRUE(c.outputUri.isEmpty()) << "Save as PDF writes only a local file";
    EXPECT_EQ(c.printer, QStringLiteral("Office X"));
}

TEST(PrintLogic, OnlyALocalFileIsWritten)
{
    EXPECT_EQ(localPdfPath(QStringLiteral("file:///home/u/Report.pdf")), QStringLiteral("/home/u/Report.pdf"));
    EXPECT_EQ(localPdfPath(QStringLiteral("file:///home/u/My%20Report.pdf")), QStringLiteral("/home/u/My Report.pdf"));
    EXPECT_EQ(localPdfPath(QStringLiteral("file:///home/u/My Report.pdf")), QStringLiteral("/home/u/My Report.pdf"));
    // The sheet's choice reaches GTK encoded.
    EXPECT_EQ(fromQml({{QStringLiteral("outputUri"), QStringLiteral("file:///home/u/My Report.pdf")}}, Choices{}).outputUri,
              QStringLiteral("file:///home/u/My%20Report.pdf"));
    for (const QString &bad : {QStringLiteral("https://example.org/a.pdf"), QStringLiteral("file://host/a.pdf"), QStringLiteral("/home/u/a.pdf"),
                               QStringLiteral("file:///home/u/"), QStringLiteral("file:///home/u/../etc/a.pdf"), QStringLiteral("file:///home/./a.pdf"),
                               QStringLiteral("file:a.pdf"), QString(), QStringLiteral("file:///home/u/%00a.pdf")}) {
        EXPECT_TRUE(localPdfPath(bad).isEmpty()) << bad.toStdString();
    }
}

TEST(PrintLogic, TheFrontendsOptions)
{
    QVariantMap o = prepareOptions({});
    EXPECT_TRUE(o.value(QStringLiteral("modal")).toBool());
    EXPECT_EQ(o.value(QStringLiteral("acceptLabel")).toString(), QString());
    EXPECT_FALSE(o.value(QStringLiteral("hasCurrentPage")).toBool());
    EXPECT_EQ(o.value(QStringLiteral("formats")).toStringList(), (QStringList{QStringLiteral("pdf"), QStringLiteral("ps"), QStringLiteral("svg")}));
    o = prepareOptions({{QStringLiteral("modal"), false}, {QStringLiteral("accept_label"), QStringLiteral("_Print\nnow __x")},
                        {QStringLiteral("has_current_page"), true}, {QStringLiteral("has_selected_pages"), true},
                        {QStringLiteral("supported_output_file_formats"), QStringList{QStringLiteral("PS"), QStringLiteral("exe"), QStringLiteral("ps")}}});
    EXPECT_FALSE(o.value(QStringLiteral("modal")).toBool());
    EXPECT_EQ(o.value(QStringLiteral("acceptLabel")).toString(), QStringLiteral("Print now _x"));
    EXPECT_TRUE(o.value(QStringLiteral("hasCurrentPage")).toBool());
    EXPECT_TRUE(o.value(QStringLiteral("hasSelection")).toBool());
    EXPECT_EQ(o.value(QStringLiteral("formats")).toStringList(), QStringList{QStringLiteral("ps")});
    // Values a conversion would read as false: only a boolean says it.
    for (const QVariant &notBool : {QVariant(QStringLiteral("false")), QVariant(0), QVariant(0u)})
        EXPECT_TRUE(prepareOptions({{QStringLiteral("modal"), notBool}}).value(QStringLiteral("modal")).toBool())
            << "a modal that is not a boolean is the default: " << notBool.typeName();
}

// Step 6b: a printer's own options start at its defaults, go to CUPS as it listed them and only with a value it listed (an
// option of another printer, a value it does not list or one CUPS would read as several values never goes); none for a file.
TEST(PrintLogic, APrintersOwnOptionsGoOnlyAsItListsThem)
{
    const Capabilities caps = withOptions();
    Choices c = initialChoices(QStringLiteral("Office"), caps, {}, {}, false, false);
    EXPECT_EQ(c.options, (QMap<QString, QString>{{QStringLiteral("media-source"), QStringLiteral("auto")},
                                                 {QStringLiteral("print-quality"), QStringLiteral("4")},
                                                 {QStringLiteral("finishings"), QStringLiteral("3")}}));
    EXPECT_TRUE(initialChoices(QStringLiteral("Office"), office(), {}, {}, false, false).options.isEmpty()) << "none reported, none chosen";
    c.options.insert(QStringLiteral("print-quality"), QStringLiteral("5"));
    c.options.insert(QStringLiteral("media-source"), QStringLiteral("tray-9"));
    c.options.insert(QStringLiteral("output-bin"), QStringLiteral("lower"));
    const auto options = cupsOptions(c, caps);
    EXPECT_TRUE(options.contains({QStringLiteral("print-quality"), QStringLiteral("5")}));
    EXPECT_TRUE(options.contains({QStringLiteral("finishings"), QStringLiteral("3")}));
    for (const auto &o : options) {
        EXPECT_NE(o.first, QStringLiteral("media-source")) << "a value the printer does not list";
        EXPECT_NE(o.first, QStringLiteral("output-bin")) << "an option the printer does not report";
    }
    // A value listed that CUPS would read as more than one, or as a collection: never sent.
    Capabilities odd = caps;
    odd.options[1].values.append({QStringLiteral("5,6"), QStringLiteral("x")});
    c.options.insert(QStringLiteral("print-quality"), QStringLiteral("5,6"));
    for (const auto &o : cupsOptions(c, odd))
        EXPECT_NE(o.first, QStringLiteral("print-quality"));
    for (const char *good : {"auto", "tray-1", "5", "na_letter.x"})
        EXPECT_TRUE(validOptionValue(QString::fromLatin1(good))) << good;
    for (const char *bad : {"", "Tray1", "a,b", "a b", "{x}", "\"a\"", "-x", "a=b", "tray\n"})
        EXPECT_FALSE(validOptionValue(QString::fromLatin1(bad))) << bad;
    EXPECT_FALSE(validOptionValue(QString(64, QLatin1Char('a'))));
    // Wanted where listed, else the default; an option the printer does not report is not kept.
    EXPECT_EQ(optionChoices(caps, {{QStringLiteral("print-quality"), QStringLiteral("3")}, {QStringLiteral("media-source"), QStringLiteral("nope")},
                                   {QStringLiteral("output-bin"), QStringLiteral("lower")}}),
              (QMap<QString, QString>{{QStringLiteral("media-source"), QStringLiteral("auto")}, {QStringLiteral("print-quality"), QStringLiteral("3")},
                                      {QStringLiteral("finishings"), QStringLiteral("3")}}));
    EXPECT_EQ(optionSection(QStringLiteral("media-type")), QStringLiteral("quality"));
    EXPECT_EQ(optionSection(QStringLiteral("output-bin")), QStringLiteral("printer"));
    EXPECT_EQ(optionSection(QStringLiteral("job-hold-until")), QString()) << "not one the sheet shows";
    EXPECT_EQ(keywordLabel(QStringLiteral("staple-top-left")), QStringLiteral("Staple Top Left"));
    EXPECT_EQ(keywordLabel(QStringLiteral("face_down")), QStringLiteral("Face Down"));
    // Save as PDF and Open in Preview: nothing for a printer.
    Choices file = c;
    file.preview = true;
    EXPECT_TRUE(cupsOptions(file, caps).isEmpty());
    // The sheet's map: unknown options and values that do not read are dropped on the way back.
    const Choices back = fromQml({{QStringLiteral("options"), QVariantMap{{QStringLiteral("print-quality"), QStringLiteral("5")},
                                                                         {QStringLiteral("job-hold-until"), QStringLiteral("indefinite")},
                                                                         {QStringLiteral("media-type"), QStringLiteral("a,b")},
                                                                         {QStringLiteral("finishings"), 4}}}},
                                 Choices{});
    EXPECT_EQ(back.options, (QMap<QString, QString>{{QStringLiteral("print-quality"), QStringLiteral("5")}}));
    const QVariantList shown = toQml(caps).value(QStringLiteral("options")).toList();
    ASSERT_EQ(shown.size(), 3);
    EXPECT_EQ(shown.at(1).toMap().value(QStringLiteral("section")).toString(), QStringLiteral("quality"));
    EXPECT_EQ(shown.at(2).toMap().value(QStringLiteral("section")).toString(), QStringLiteral("printer"));
    EXPECT_EQ(shown.at(1).toMap().value(QStringLiteral("values")).toList().at(2).toMap().value(QStringLiteral("value")).toString(), QStringLiteral("5"));
}

// Step 6b: a document the application sent first is made already: the printer applies its page ranges (1-based, each a range),
// never for a file; the rest as for GTK's.
TEST(PrintLogic, ADocumentSentFirstHasItsPagesPrintedByThePrinter)
{
    Choices c = initialChoices(QStringLiteral("Office"), office(), {}, {}, false, false);
    c.pages = QStringLiteral("ranges");
    c.ranges = QStringLiteral("5, 1-3");
    const auto options = documentOptions(c, office());
    EXPECT_TRUE(options.contains({QStringLiteral("page-ranges"), QStringLiteral("1-3,5-5")}));
    EXPECT_FALSE(cupsOptions(c, office()).contains({QStringLiteral("page-ranges"), QStringLiteral("1-3,5-5")})) << "GTK applies them itself";
    c.pages = QStringLiteral("all");
    for (const auto &o : documentOptions(c, office()))
        EXPECT_NE(o.first, QStringLiteral("page-ranges"));
    c.pages = QStringLiteral("ranges");
    c.ranges = QStringLiteral("3-1");
    for (const auto &o : documentOptions(c, office()))
        EXPECT_NE(o.first, QStringLiteral("page-ranges")) << "ranges that do not read";
    c.ranges = QStringLiteral("2");
    c.outputUri = QStringLiteral("file:///tmp/a.pdf");
    EXPECT_TRUE(documentOptions(c, office()).isEmpty());
}

// Open in Preview asks GTK for a PDF file as Save as PDF does (never a path of the user's), and sends nothing to a printer.
TEST(PrintLogic, OpenInPreviewAsksForAPdf)
{
    Choices c = initialChoices(QStringLiteral("Office"), office(), {}, {}, false, false);
    c.printer.clear();
    c.preview = true;
    QVariantMap settings, pageSetup;
    ASSERT_TRUE(toGtk(c, &settings, &pageSetup));
    EXPECT_EQ(settings.value(QStringLiteral("output-uri")).toString(), QString::fromLatin1(kPdfOutputUri));
    EXPECT_EQ(settings.value(QStringLiteral("output-file-format")).toString(), QStringLiteral("pdf"));
    EXPECT_FALSE(settings.contains(QStringLiteral("printer")));
    EXPECT_TRUE(fromQml({{QStringLiteral("preview"), true}}, Choices{}).preview);
    EXPECT_EQ(toQml(c).value(QStringLiteral("preview")).toBool(), true);
}

// Last Used Settings keep how a print was printed (two sides, colour, collation, the printer's options), never the document's
// (copies, pages, paper, orientation, scale); applied where the printer takes them; kept as JSON and read back, anything malformed
// refused.
TEST(PrintLogic, LastUsedSettingsKeepHowNotWhat)
{
    Choices printed = initialChoices(QStringLiteral("Office"), withOptions(), {}, {}, false, false);
    printed.copies = 7;
    printed.duplex = QStringLiteral("vertical");
    printed.color = false;
    printed.collate = false;
    printed.scale = 50;
    printed.options.insert(QStringLiteral("print-quality"), QStringLiteral("5"));
    const Preset last = presetOf(printed);
    EXPECT_EQ(last.duplex, QStringLiteral("vertical"));
    EXPECT_FALSE(last.color);
    EXPECT_FALSE(last.collate);
    EXPECT_EQ(last.options.value(QStringLiteral("print-quality")), QStringLiteral("5"));

    const Choices fresh = initialChoices(QStringLiteral("Office"), withOptions(), {}, {}, false, false);
    const Choices applied = withPreset(fresh, last, withOptions());
    EXPECT_EQ(applied.duplex, QStringLiteral("vertical"));
    EXPECT_FALSE(applied.color);
    EXPECT_FALSE(applied.collate);
    EXPECT_EQ(applied.options.value(QStringLiteral("print-quality")), QStringLiteral("5"));
    EXPECT_EQ(applied.copies, 1) << "the copies are the document's";
    EXPECT_EQ(applied.scale, 100);
    EXPECT_EQ(applied.media, fresh.media);
    // A printer with neither two sides, colour nor options takes none of them.
    const Choices mono = withPreset(initialChoices(QStringLiteral("Mono"), monoSimplex(), {}, {}, false, false), last, monoSimplex());
    EXPECT_EQ(mono.duplex, QStringLiteral("simplex"));
    EXPECT_FALSE(mono.color);
    EXPECT_TRUE(mono.options.isEmpty());
    // An option value this printer does not list stays at its default.
    Preset other = last;
    other.options.insert(QStringLiteral("media-source"), QStringLiteral("tray-9"));
    EXPECT_EQ(withPreset(fresh, other, withOptions()).options.value(QStringLiteral("media-source")), QStringLiteral("auto"));

    const QJsonObject json = toJson(last);
    const auto read = presetFromJson(QJsonDocument::fromJson(QJsonDocument(json).toJson()).object());
    ASSERT_TRUE(read.has_value());
    EXPECT_EQ(*read, last);
    EXPECT_FALSE(json.contains(QStringLiteral("copies")));
    EXPECT_FALSE(presetFromJson({}).has_value());
    EXPECT_FALSE(presetFromJson({{QStringLiteral("collate"), true}, {QStringLiteral("color"), true}, {QStringLiteral("duplex"), QStringLiteral("sideways")}})
                     .has_value());
    EXPECT_FALSE(presetFromJson({{QStringLiteral("collate"), QStringLiteral("yes")}, {QStringLiteral("color"), true},
                                 {QStringLiteral("duplex"), QStringLiteral("simplex")}})
                     .has_value());
    const auto cleaned = presetFromJson({{QStringLiteral("collate"), true}, {QStringLiteral("color"), true}, {QStringLiteral("duplex"), QStringLiteral("simplex")},
                                         {QStringLiteral("options"), QJsonObject{{QStringLiteral("print-quality"), QStringLiteral("a,b")},
                                                                                {QStringLiteral("job-hold-until"), QStringLiteral("x")},
                                                                                {QStringLiteral("media-type"), QStringLiteral("photo")}}}});
    ASSERT_TRUE(cleaned.has_value());
    EXPECT_EQ(cleaned->options, (QMap<QString, QString>{{QStringLiteral("media-type"), QStringLiteral("photo")}}));
    // The preset named goes to the sheet and back.
    Choices named = fresh;
    named.preset = QStringLiteral("last");
    EXPECT_EQ(fromQml(toQml(named), Choices{}).preset, QStringLiteral("last"));
    EXPECT_EQ(fromQml({{QStringLiteral("preset"), QStringLiteral("mine")}}, named).preset, QStringLiteral("last"));
}
