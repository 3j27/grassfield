#pragma once

#include "filelogic.h"

#include <QDateTime>
#include <QJsonObject>
#include <QList>
#include <QString>
#include <QStringList>
#include <QUrl>

#include <optional>

// Pure logic of the Files search (ADR-0027, docs/specs/files.md "Search"; Qt Core only, unit tested): a search is a text,
// a scope (this computer or a local folder) and the Finder's criteria rows. It is a location, grassfield-search:/?…, so
// history, tabs and views work as for a folder; a saved search is the same query in a JSON file.
namespace SearchLogic
{

// The Finder's criteria (the + rows), without what Linux files cannot serve.
enum class Attribute { Kind = 0, Opened = 1, Modified = 2, Created = 3, Name = 4, Contents = 5, Size = 6, Tags = 7 };
constexpr int kAttributeCount = 8;

// The comparisons a row offers; each attribute takes its own (operatorsFor).
enum class Op {
    Is = 0,          // Kind (a category), Name (the whole name), Tags (has the tag)
    IsNot = 1,       // Kind
    Contains = 2,    // Name, Contents
    BeginsWith = 3,  // Name
    EndsWith = 4,    // Name
    WithinLast = 5,  // dates: value N, unit days|weeks|months|years
    Exactly = 6,     // dates: value yyyy-MM-dd
    Before = 7,      // dates
    After = 8,       // dates
    Today = 9,       // dates, no value
    Yesterday = 10,  // dates
    ThisWeek = 11,   // dates
    ThisMonth = 12,  // dates
    ThisYear = 13,   // dates
    Greater = 14,    // Size: value N, unit KB|MB|GB (decimal, as the Finder)
    Less = 15,       // Size
};
constexpr int kOpCount = 16;

struct Criterion {
    Attribute attribute = Attribute::Name;
    Op op = Op::Contains;
    QString value;
    QString unit;
    bool operator==(const Criterion &o) const { return attribute == o.attribute && op == o.op && value == o.value && unit == o.unit; }
};

struct Query {
    QString text;
    // Empty: this computer (the home folder); else a local folder.
    QUrl folder;
    QList<Criterion> criteria;
    bool operator==(const Query &o) const { return text == o.text && folder == o.folder && criteria == o.criteria; }
    bool inComputer() const { return folder.isEmpty(); }
};

QString scheme();
bool isSearchUrl(const QUrl &url);
// grassfield-search:/?q=<text>&in=<folder URL>&c=<attribute>:<op>:<unit>:<value>… (in absent: this computer).
QUrl toUrl(const Query &query);
// The query of a search location; nullopt for another URL or a malformed one (an unknown attribute, an operator the
// attribute does not take, a folder that is not a local file URL).
std::optional<Query> fromUrl(const QUrl &url);

// The operators of an attribute, in the order of its pop-up.
QList<Op> operatorsFor(Attribute attribute);
bool takesOp(Attribute attribute, Op op);
// Whether a criterion's value is needed and given (a date row's "today" needs none; "within last" needs a number).
bool isComplete(const Criterion &criterion);

// Stable names for URLs and saved searches ("kind", "within-last"...).
QString attributeKey(Attribute attribute);
std::optional<Attribute> attributeFromKey(const QString &key);
QString opKey(Op op);
std::optional<Op> opFromKey(const QString &key);
// Kind values: "any" and the categories ("image", "pdf"...).
QString kindKey(FileLogic::KindCategory category);
std::optional<FileLogic::KindCategory> kindFromKey(const QString &key);

// What a candidate is, read once (lstat, its type from its name, its tags).
struct Facts {
    QString name;
    bool isDir = false;
    qint64 size = -1;
    QDateTime modified;
    QDateTime created;
    QDateTime opened;
    FileLogic::KindCategory kind = FileLogic::KindCategory::Other;
    // Stored tag names (TagLogic): colour keys or the user's names.
    QStringList tags;
};

// Whether the criteria (all of them, as the Finder's rows) hold for `facts`. Contents rows are not evaluated here: the
// backend keeps only what the file index matched (FileSearch). Incomplete rows are ignored, as the Finder ignores an
// empty field. `now` serves the date rows (local dates).
bool matchesCriteria(const Query &query, const Facts &facts, const QDateTime &now);
// Whether the search text matches a name: every word of the text is in the name (folded for case and accents, as the
// folder filter). An empty text matches everything.
bool textMatchesName(const QString &text, const QString &name);
// The text of the query's Contents rows ("" without any).
QString contentsText(const Query &query);
// A term for the name indexes (localsearch, plocate): the text, else the value of a Name row; "" when there is none.
QString nameTerm(const Query &query);
// Whether a row needs the candidate's lstat, type or tags (a text-only search does not).
bool needsFacts(const Query &query);
// Whether the search asks for anything: text, or a complete row. A new smart folder asks for nothing and lists nothing
// (the Finder's empty New Smart Folder), rather than every file of the scope.
bool hasTerms(const Query &query);

// Saved searches (one JSON file each, ADR-0027): {"version":1,"name":…,"scope":"computer"|<folder URL>,"query":…,
// "filters":[{"attribute":…,"op":…,"value":…,"unit":…}],"sidebar":bool}.
struct Saved {
    QString name;
    Query query;
    bool sidebar = false;
};
constexpr int kSavedVersion = 1;
QJsonObject toJson(const Saved &saved);
// nullopt for a newer version, a missing name or a malformed query (the file is then left as it is).
std::optional<Saved> fromJson(const QJsonObject &object);
// The file name of a saved search: its name without '/', NUL or control characters, trimmed, at most 200 UTF-8 bytes, plus
// ".json"; "Search.json" when nothing is left.
QString savedFileName(const QString &name);

} // namespace SearchLogic
