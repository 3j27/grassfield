// The Print portal's settings (org.freedesktop.impl.portal.Print, as xdg-desktop-portal 1.22.1 passes GTK's serialized print
// settings and page setup, data/org.freedesktop.portal.Print.xml) and what Grassfield's print sheet makes of them (ADR-0035
// D-7, step 6a; docs/specs/system-dialogs.md section 7, PR1-PR3). Pure: no bus, no window, no CUPS; Qt Core only.
//
// How GTK uses the answer (gtk/print/gtkprintoperation-portal.c, read as data): it renders the document itself into a file
// with the returned settings and page setup, and only the pages asked (print-pages, page-ranges), scaled (scale), turned to the
// orientation, in the collation, order and page set asked; then it sends that file to Print with the token. GTK 4 makes
// neither the copies nor the pages per sheet for a printer, but makes both for a file (output-uri set); GTK 3.24 always makes
// both (its manual_num_copies is the settings' n-copies). So the answer always gives GTK one copy, and the backend gives CUPS
// the copies, the collation, the paper, the two sides and the colour, never the page ranges, the scale or the orientation
// again (review of step 6a, MAJOR: GTK 3 applications printed n² copies).
//
// Step 6b adds: the document an application sends first (Print with no token: the sheet shows it, and the printer applies the
// page ranges, since the document is already made), Open in Preview, the Presets (Default Settings, Last Used Settings) and a
// printer's own options (Media & Quality, Printer Options), each sent as CUPS takes it and only with a value the printer lists.
#pragma once

#include <QJsonObject>
#include <QList>
#include <QMap>
#include <QPair>
#include <QString>
#include <QStringList>
#include <QVariantMap>

#include <optional>

namespace grassfield::portal::print {

// A paper size a printer takes (CUPS's cups_size_t): its PWG 5101.1 name ("iso_a4_210x297mm"), the name shown, its size and
// the margins it cannot print in, in millimetres.
struct Media {
    QString name;
    QString displayName;
    double widthMm = 0;
    double heightMm = 0;
    double topMm = 0;
    double bottomMm = 0;
    double leftMm = 0;
    double rightMm = 0;
    bool operator==(const Media &o) const
    {
        return name == o.name && displayName == o.displayName && widthMm == o.widthMm && heightMm == o.heightMm && topMm == o.topMm
            && bottomMm == o.bottomMm && leftMm == o.leftMm && rightMm == o.rightMm;
    }
};

// A CUPS destination (a queue, or a printer CUPS found on the network).
struct Destination {
    QString name;
    // printer-info, or the name.
    QString displayName;
    QString location;
    bool isDefault = false;
    bool operator==(const Destination &o) const
    {
        return name == o.name && displayName == o.displayName && location == o.location && isDefault == o.isDefault;
    }
};

// One value of a printer's own option: as CUPS takes it (a keyword, "tray-1", or an enum's number, "5") and the name shown
// (the printer's own, as CUPS localizes it, else the keyword in words).
struct OptionValue {
    QString value;
    QString label;
    // Its IPP keyword ("staple-top-left" for finishings' 20; the value itself for a keyword): the sheet names the standard ones
    // in the UI language where CUPS gives no name (security review of step 6b, NIT).
    QString keyword;
    bool operator==(const OptionValue &o) const { return value == o.value && label == o.label && keyword == o.keyword; }
};

// A printer's own option beyond paper, two sides and colour (step 6b): an IPP attribute CUPS reports for the printer
// (cupsCopyDestInfo; optionSection names the ones the sheet shows), the values it lists, in its order, and the one it uses
// when asked for none (the user's lpoptions, else the printer's default).
struct PrinterOption {
    QString name;
    QList<OptionValue> values;
    QString defaultValue;
    bool operator==(const PrinterOption &o) const { return name == o.name && values == o.values && defaultValue == o.defaultValue; }
    bool lists(const QString &value) const;
};

// What a destination supports, as CUPS reports it (cupsCopyDestInfo); `known` false while it is not known (being asked, or
// the printer did not answer): the sheet then offers the defaults below.
struct Capabilities {
    bool known = false;
    QList<Media> media;
    QString defaultMedia;
    bool twoSided = false;
    bool color = false;
    int maxCopies = 999;
    // Its own options with two values or more, in the sheet's order (printerOptionNames).
    QList<PrinterOption> options;
    bool operator==(const Capabilities &o) const
    {
        return known == o.known && media == o.media && defaultMedia == o.defaultMedia && twoSided == o.twoSided && color == o.color
            && maxCopies == o.maxCopies && options == o.options;
    }
    // The option named `name`, or null.
    const PrinterOption *option(const QString &name) const;
};

// The sheet's choices.
struct Choices {
    // A destination's name; "" when none is chosen (no printer, or Save as PDF).
    QString printer;
    int copies = 1;
    bool collate = true;
    // "all", "ranges", "current" or "selection" (GTK's print-pages).
    QString pages = QStringLiteral("all");
    // The pages as the user typed them, 1-based ("1-3, 5"); read with parseRanges.
    QString ranges;
    Media media;
    // "portrait" or "landscape".
    QString orientation = QStringLiteral("portrait");
    // Per cent, 1 to 1000.
    int scale = 100;
    // "simplex", "horizontal" (two-sided, bound on the long edge) or "vertical" (two-sided, short edge): GTK's duplex
    // (gtk 3.24 modules/printbackends/cups/gtkprintbackendcups.c: DuplexNoTumble is "horizontal", DuplexTumble "vertical").
    QString duplex = QStringLiteral("simplex");
    bool color = true;
    // Save as PDF: the file:// URI the document is written to; "" to print.
    QString outputUri;
    // Open in Preview: the document goes to Grassfield's viewer (a private copy), not to a printer.
    bool preview = false;
    // The printer's own options chosen (name, value as CUPS takes it).
    QMap<QString, QString> options;
    // The Presets pop-up: "default" (Default Settings) or "last" (Last Used Settings).
    QString preset = QStringLiteral("default");
};

// What Last Used Settings keeps of a print (macOS's preset, one for every printer): how it printed, never what belongs to the
// document (its pages, copies, paper, orientation and scale: the application's page setup gives those).
struct Preset {
    bool collate = true;
    QString duplex = QStringLiteral("simplex");
    bool color = true;
    QMap<QString, QString> options;
    bool operator==(const Preset &o) const { return collate == o.collate && duplex == o.duplex && color == o.color && options == o.options; }
};

// One closed range of pages, 0-based (GTK's page-ranges are 0-based; the sheet shows them 1-based).
struct PageRange {
    int first = 0;
    int last = 0;
    bool operator==(const PageRange &o) const { return first == o.first && last == o.last; }
};

constexpr int kMaxCopies = 999;
constexpr int kMinScale = 1;
constexpr int kMaxScale = 1000;
// A page number the sheet takes (a document of more pages than this is not printed in pieces by number).
constexpr int kMaxPage = 100000;
// The largest document an application may send, to the printer or to Save as PDF's file (2 GiB; a book of photographs stays far
// below it): more ends the job, so an application cannot fill the disk through the portal (integrator security review of step
// 6a, NIT).
constexpr qint64 kMaxDocumentBytes = qint64(2) << 30;
// What the application gets as its settings' output-uri for Save as PDF: never the user's path (integrator security review of
// step 6a, MINOR 3). GTK reads only whether the key is there (GTK 4: a file, so it makes the pages per sheet itself) and puts its
// own temporary file in its place before it renders (GTK 4.24 and 3.24 gtkprintoperation-portal.c); the backend writes the
// file chosen in the Save panel.
constexpr auto kPdfOutputUri = "file:///dev/null";

// "1-3, 5" (1-based, as typed) as 0-based ranges in order, merged where they touch; false (and `out` untouched) for anything
// else: an empty text, a page 0, a range that runs backwards, more than 64 ranges, a page over kMaxPage.
bool parseRanges(const QString &text, QList<PageRange> *out);
// The ranges in GTK's page-ranges form ("0-2,4") and back in the sheet's 1-based form ("1-3, 5").
QString gtkRanges(const QList<PageRange> &ranges);
QString shownRanges(const QList<PageRange> &ranges);

// The media of `capabilities` that matches `name` (a PWG name), else the one of the same size within a millimetre, else none
// (a default Media with an empty name).
Media findMedia(const QList<Media> &media, const QString &name, double widthMm = 0, double heightMm = 0);
// A PWG 5101.1 name's size ("iso_a4_210x297mm", "na_letter_8.5x11in"), false when the name gives none.
bool pwgSize(const QString &name, double *widthMm, double *heightMm);
// The name shown for a PWG name when CUPS gives none: the common sizes by name (A4, US Letter, …), others "W × H mm".
QString mediaDisplayName(const QString &name);

// The sheet's first state: the destination's defaults, then what the application asks (its settings and page setup, the
// frontend's hints), where the destination takes it. `printer` is the destination chosen ("" when none).
Choices initialChoices(const QString &printer, const Capabilities &capabilities, const QVariantMap &settings,
                       const QVariantMap &pageSetup, bool hasCurrentPage, bool hasSelection);

// The answer the application gets (PreparePrint's results): GTK's settings keys and page setup keys, with the D-Bus types GTK
// reads (strings in the settings, doubles in the page setup). n-copies is always "1" (GTK must not make the copies: the job
// carries them, cupsOptions); the page setup names its paper without a PPD name (GTK's gtk_paper_size_new_from_gvariant takes
// any PPDName key, an empty one too, over Name). Save as PDF and Open in Preview ask GTK for a PDF file (kPdfOutputUri). False
// when the choices cannot be printed (bad page ranges, no paper size).
bool toGtk(const Choices &choices, QVariantMap *settings, QVariantMap *pageSetup);

// The CUPS options of the job (name, value): copies, collation, paper, two sides, colour and the printer's own options; never
// pages, scale or orientation (GTK applied them, see above). Empty for Save as PDF and Open in Preview. The paper goes only as
// one the printer lists, or, when it lists none, as a PWG name (validMediaName): never the application's text as it came; a
// printer's own option only when it differs from the printer's default (a default sent would override the queue's own
// settings, a tray forced among them: security review of step 6b, MINOR 5) and with a value that printer lists
// (validOptionValue too).
QList<QPair<QString, QString>> cupsOptions(const Choices &choices, const Capabilities &capabilities);
// The same for a document the application sent first (Print with no token): it is made already, so the printer applies the
// page ranges ("page-ranges", 1-based); the scale and orientation are the document's own (the sheet does not offer them).
QList<QPair<QString, QString>> documentOptions(const Choices &choices, const Capabilities &capabilities);

// The printer's own options the sheet shows, in its order, and the section each belongs to, as macOS groups them: "quality"
// (Media & Quality: media-source, media-type, print-quality) or "printer" (Printer Options: output-bin, finishings); "" for
// any other.
const QStringList &printerOptionNames();
QString optionSection(const QString &name);
// A value of a printer's option as CUPS takes it without reading it as anything else: an IPP keyword or an enum's number
// ([a-z0-9][a-z0-9._-]*, at most 63 characters): never a comma, a space, a quote or a brace (cupsEncodeOptions would read
// several values or a collection).
bool validOptionValue(const QString &value);
// A keyword in words, for a value the printer names no other way ("staple-top-left" -> "Staple Top Left").
QString keywordLabel(const QString &keyword);
// The printer's own options as chosen: `wanted`'s value where the printer lists it, else the printer's default.
QMap<QString, QString> optionChoices(const Capabilities &capabilities, const QMap<QString, QString> &wanted);

// What Last Used Settings keeps of `choices`, and `choices` with `preset` applied where the printer takes it (two sides only on
// a printer that has them, colour only on a colour printer, an option only with a value the printer lists).
Preset presetOf(const Choices &choices);
Choices withPreset(Choices choices, const Preset &preset, const Capabilities &capabilities);
// Last Used Settings as grassfield-portal keeps it (its state file), and back; nullopt for anything malformed.
QJsonObject toJson(const Preset &preset);
std::optional<Preset> presetFromJson(const QJsonObject &object);
// A PWG 5101.1 media name as CUPS takes it ("iso_a4_210x297mm", "na_letter_8.5x11in"): lowercase letters, digits, "_", "." and
// "-", at most 64 characters; never a comma (CUPS would read several values) or anything else.
bool validMediaName(const QString &name);
// The document's type from its first bytes (at least five, or all there are): "application/pdf" for "%PDF-", else "". Only a
// PDF is sent: raw printer languages (PJL, PCL) and PostScript, which can program a PostScript printer, are not (integrator
// security review of step 6a, MINOR 2, and its counter-review); GTK always sends a PDF here (its file backend's default,
// toGtk never asks another format).
QString documentFormat(const QByteArray &head);
// The job's name as IPP takes it: UTF-8, at most 255 bytes, cut on a character's boundary.
QByteArray jobName(const QString &title);

// The choices as the QML reads and writes them (a map of the fields above, media as {name, displayName, widthMm, heightMm,
// ...}, options as {name: value}), and back; fromQml keeps `base` for what the map lacks and clamps what is out of range (an
// option whose name the sheet does not show, or whose value does not read, is dropped).
QVariantMap toQml(const Choices &choices);
Choices fromQml(const QVariantMap &map, const Choices &base);
// {known, media, defaultMedia, twoSided, color, maxCopies, options: [{name, section, defaultValue, values: [{value, label}]}]}.
QVariantMap toQml(const Capabilities &capabilities);
QVariantMap toQml(const Media &media);
QVariantMap toQml(const Destination &destination);

// The PreparePrint options the sheet reads: {modal, acceptLabel (one line, its mnemonic removed), hasCurrentPage,
// hasSelection, formats (the output formats the application can make: "pdf", "ps", "svg"; all three when it gives none)}.
QVariantMap prepareOptions(const QVariantMap &options);

// The name a document is saved or opened under: the first of `names` that is a plain file name (one line, no folder), else
// "Document"; ".pdf" added; at most 255 bytes in UTF-8, a file name's limit, cut on a character's boundary (a long title in
// Chinese or Japanese would otherwise fail the write: security review of step 6b, MINOR 4).
QString pdfFileName(const QStringList &names);

// The path of a local file URI Save as PDF may write to (an absolute path, no "." or "..", not a directory's URI); "" for
// anything else.
QString localPdfPath(const QString &uri);

} // namespace grassfield::portal::print
