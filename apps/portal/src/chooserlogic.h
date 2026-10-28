// The FileChooser options and results of xdg-desktop-portal's backend interface (org.freedesktop.impl.portal.FileChooser,
// as the frontend 1.22.1 passes them, src/file-chooser.c) and what Grassfield's Open and Save panels make of them (ADR-0035
// D-4, docs/specs/system-dialogs.md section 1, FC1-FC3, FC6). Pure: no bus, no window; QtDBus only for the D-Bus types.
#pragma once

#include <QDBusArgument>
#include <QList>
#include <QMetaType>
#include <QString>
#include <QStringList>
#include <QVariantMap>

namespace grassfield::portal::chooser {

// One rule of a filter: 0 a glob ("*.png"), 1 a MIME type ("image/png"). D-Bus (us).
struct FilterRule {
    uint type = 0;
    QString pattern;
    bool operator==(const FilterRule &o) const { return type == o.type && pattern == o.pattern; }
};
// A named filter, the Format pop-up's entries. D-Bus (sa(us)).
struct Filter {
    QString name;
    QList<FilterRule> rules;
    bool operator==(const Filter &o) const { return name == o.name && rules == o.rules; }
};
// An option of a choice, and an answer to a choice (both (ss)).
struct Pair {
    QString first;
    QString second;
    bool operator==(const Pair &o) const { return first == o.first && second == o.second; }
};
// A choice of the Options area: a pop-up with options, or a check box without ("true"/"false"). D-Bus (ssa(ss)s).
struct Choice {
    QString id;
    QString label;
    QList<Pair> options;
    QString initial;
};

enum class Kind { Open, Save, SaveFiles };

// What the frontend asked, checked and normalized.
struct Request {
    Kind kind = Kind::Open;
    QString appId;
    QString parentWindow;
    QString title;
    QString acceptLabel;
    // Modal to the application's window (the default): xdg-dialog's modal, Hyprland dims and blocks the parent.
    bool modal = true;
    bool multiple = false;
    bool directory = false;
    QList<Filter> filters;
    // Index into filters of the one shown first; -1 without filters.
    int currentFilter = -1;
    QList<Choice> choices;
    // Save: the suggested name; SaveFiles: the names of the files.
    QString currentName;
    QStringList files;
    // Absolute local paths ("" when not given or not usable).
    QString currentFolder;
    QString currentFile;
    // Why the request cannot be shown ("" when it can): it then ends with response 2 at once.
    QString error;
};

// Limits on what an application may pass (a panel lists them; anything beyond is dropped, never shown).
inline constexpr int kMaxFilters = 64;
inline constexpr int kMaxRules = 256;
inline constexpr int kMaxChoices = 16;
inline constexpr int kMaxChoiceOptions = 64;
inline constexpr int kMaxFiles = 4096;
inline constexpr int kMaxTextLength = 1024;

void registerTypes();

Request parse(Kind kind, const QString &appId, const QString &parentWindow, const QString &title, const QVariantMap &options);

// The request as the panel's QML reads it: {kind: "open"|"save"|"saveFiles", appId, title, acceptLabel, modal, multiple,
// directory, filters: [{name, globs, mimeTypes}], currentFilter, choices: [{id, label, options: [{id, label}], initial}],
// currentName, files, currentFolder (file URL or ""), currentFile (file URL or "")}.
QVariantMap toQml(const Request &request);

// The panel's answer (QML): {uris: [file URLs], choices: [{id, value}], filter: index}. The results the frontend gets for
// response 0: uris (as), choices (a(ss)), current_filter ((sa(us))) when the request had filters. Every URI must be a local
// absolute file URL (the interface allows only file://); a Save answer must be exactly one, SaveFiles one per name. An
// answer that breaks a rule gives `ok` false (the request then ends with response 2, nothing returned).
struct Results {
    bool ok = false;
    QVariantMap map;
};
Results results(const Request &request, const QVariantMap &answer);

// x-d-p-gtk's results, relayed as they are (FC7), with their D-Bus types: uris (as), choices (a(ss)), current_filter
// ((sa(us))), writable (b). Any other key is left out.
QVariantMap relayed(const QVariantMap &gtkResults);

} // namespace grassfield::portal::chooser

Q_DECLARE_METATYPE(grassfield::portal::chooser::FilterRule)
Q_DECLARE_METATYPE(grassfield::portal::chooser::Filter)
Q_DECLARE_METATYPE(grassfield::portal::chooser::Pair)
Q_DECLARE_METATYPE(grassfield::portal::chooser::Choice)

QDBusArgument &operator<<(QDBusArgument &arg, const grassfield::portal::chooser::FilterRule &rule);
const QDBusArgument &operator>>(const QDBusArgument &arg, grassfield::portal::chooser::FilterRule &rule);
QDBusArgument &operator<<(QDBusArgument &arg, const grassfield::portal::chooser::Filter &filter);
const QDBusArgument &operator>>(const QDBusArgument &arg, grassfield::portal::chooser::Filter &filter);
QDBusArgument &operator<<(QDBusArgument &arg, const grassfield::portal::chooser::Pair &pair);
const QDBusArgument &operator>>(const QDBusArgument &arg, grassfield::portal::chooser::Pair &pair);
QDBusArgument &operator<<(QDBusArgument &arg, const grassfield::portal::chooser::Choice &choice);
const QDBusArgument &operator>>(const QDBusArgument &arg, grassfield::portal::chooser::Choice &choice);
