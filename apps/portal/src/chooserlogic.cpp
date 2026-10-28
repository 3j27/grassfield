#include "chooserlogic.h"

#include "filelogic.h"

#include <QDBusMetaType>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QSet>
#include <QUrl>

QDBusArgument &operator<<(QDBusArgument &arg, const grassfield::portal::chooser::FilterRule &rule)
{
    arg.beginStructure();
    arg << rule.type << rule.pattern;
    arg.endStructure();
    return arg;
}

const QDBusArgument &operator>>(const QDBusArgument &arg, grassfield::portal::chooser::FilterRule &rule)
{
    arg.beginStructure();
    arg >> rule.type >> rule.pattern;
    arg.endStructure();
    return arg;
}

QDBusArgument &operator<<(QDBusArgument &arg, const grassfield::portal::chooser::Filter &filter)
{
    arg.beginStructure();
    arg << filter.name << filter.rules;
    arg.endStructure();
    return arg;
}

const QDBusArgument &operator>>(const QDBusArgument &arg, grassfield::portal::chooser::Filter &filter)
{
    arg.beginStructure();
    arg >> filter.name >> filter.rules;
    arg.endStructure();
    return arg;
}

QDBusArgument &operator<<(QDBusArgument &arg, const grassfield::portal::chooser::Pair &pair)
{
    arg.beginStructure();
    arg << pair.first << pair.second;
    arg.endStructure();
    return arg;
}

const QDBusArgument &operator>>(const QDBusArgument &arg, grassfield::portal::chooser::Pair &pair)
{
    arg.beginStructure();
    arg >> pair.first >> pair.second;
    arg.endStructure();
    return arg;
}

QDBusArgument &operator<<(QDBusArgument &arg, const grassfield::portal::chooser::Choice &choice)
{
    arg.beginStructure();
    arg << choice.id << choice.label << choice.options << choice.initial;
    arg.endStructure();
    return arg;
}

const QDBusArgument &operator>>(const QDBusArgument &arg, grassfield::portal::chooser::Choice &choice)
{
    arg.beginStructure();
    arg >> choice.id >> choice.label >> choice.options >> choice.initial;
    arg.endStructure();
    return arg;
}

namespace grassfield::portal::chooser {

namespace {

// A value of the options vardict: a QDBusArgument when it came over the bus, the type itself when a test built it.
template<class T>
T fromVariant(const QVariant &value)
{
    if (value.metaType() == QMetaType::fromType<QDBusArgument>())
        return qdbus_cast<T>(value.value<QDBusArgument>());
    return value.value<T>();
}

// A string an application gave, as the panel shows it (spec common rule 5): one line, plain, capped. Control characters
// become spaces; the bidi embedding, override and isolate controls go (they could make "fdp.exe" read "exe.pdf").
QString oneLine(const QString &text)
{
    QString out;
    out.reserve(qMin(text.size(), qsizetype(kMaxTextLength)));
    for (const QChar c : text) {
        if (out.size() >= kMaxTextLength)
            break;
        const char16_t u = c.unicode();
        if ((u >= 0x202A && u <= 0x202E) || (u >= 0x2066 && u <= 0x2069))
            continue;
        out.append(c.category() == QChar::Other_Control || u == 0x2028 || u == 0x2029 ? QChar(u' ') : c);
    }
    return out.simplified();
}

// GTK's mnemonic marker ("_Open" is "Open"; "__" is "_"): the labels GTK applications pass for the default button and the
// choices. Grassfield's buttons show no mnemonics (macOS has none).
QString withoutMnemonic(const QString &label)
{
    QString out;
    out.reserve(label.size());
    for (qsizetype i = 0; i < label.size(); ++i) {
        if (label.at(i) == u'_') {
            if (i + 1 < label.size() && label.at(i + 1) == u'_')
                out.append(u'_');
            else
                continue;
            ++i;
            continue;
        }
        out.append(label.at(i));
    }
    return out;
}

// A bytestring path (ay, NUL-terminated by the interface) as an absolute local path, "" when it is not one.
QString pathFromBytes(const QVariant &value)
{
    QByteArray bytes = value.toByteArray();
    if (bytes.endsWith('\0'))
        bytes.chop(1);
    if (bytes.isEmpty() || bytes.contains('\0') || !bytes.startsWith('/'))
        return {};
    return QDir::cleanPath(QFile::decodeName(bytes));
}

bool validFilter(const Filter &filter)
{
    if (filter.name.isEmpty() || filter.rules.isEmpty() || filter.rules.size() > kMaxRules)
        return false;
    for (const FilterRule &rule : filter.rules)
        if (rule.type > 1 || rule.pattern.isEmpty() || rule.pattern.size() > kMaxTextLength)
            return false;
    return true;
}

QString fileUrl(const QString &path)
{
    return path.isEmpty() ? QString() : QUrl::fromLocalFile(path).toString(QUrl::FullyEncoded);
}

// A local absolute path from a file URL the panel returned, "" when it is not one.
QString localPath(const QString &uri)
{
    const QUrl url(uri, QUrl::StrictMode);
    if (!url.isValid() || url.scheme() != QLatin1String("file") || !url.host().isEmpty() || url.hasQuery() || url.hasFragment())
        return {};
    const QString path = url.toLocalFile();
    if (!path.startsWith(u'/') || QDir::cleanPath(path) != path || path.contains(QChar(u'\0')))
        return {};
    return path;
}

} // namespace

void registerTypes()
{
    qDBusRegisterMetaType<FilterRule>();
    qDBusRegisterMetaType<QList<FilterRule>>();
    qDBusRegisterMetaType<Filter>();
    qDBusRegisterMetaType<QList<Filter>>();
    qDBusRegisterMetaType<Pair>();
    qDBusRegisterMetaType<QList<Pair>>();
    qDBusRegisterMetaType<Choice>();
    qDBusRegisterMetaType<QList<Choice>>();
    qDBusRegisterMetaType<QByteArrayList>();
}

Request parse(Kind kind, const QString &appId, const QString &parentWindow, const QString &title, const QVariantMap &options)
{
    Request r;
    r.kind = kind;
    r.appId = appId.left(kMaxTextLength);
    r.parentWindow = parentWindow.left(kMaxTextLength);
    r.title = oneLine(title);
    r.acceptLabel = oneLine(withoutMnemonic(options.value(QStringLiteral("accept_label")).toString()));
    r.modal = options.value(QStringLiteral("modal"), true).toBool();
    if (kind == Kind::Open) {
        r.multiple = options.value(QStringLiteral("multiple")).toBool();
        r.directory = options.value(QStringLiteral("directory")).toBool();
    }

    // Filters (Open and Save): the valid ones, as given; the current one is shown first. With no list, the current filter
    // alone is the list (the interface allows any current filter then).
    if (kind != Kind::SaveFiles) {
        const auto given = fromVariant<QList<Filter>>(options.value(QStringLiteral("filters")));
        for (const Filter &f : given) {
            if (r.filters.size() >= kMaxFilters)
                break;
            if (validFilter(f))
                r.filters.append(Filter{oneLine(f.name), f.rules});
        }
        if (options.contains(QStringLiteral("current_filter"))) {
            Filter current = fromVariant<Filter>(options.value(QStringLiteral("current_filter")));
            if (validFilter(current)) {
                current.name = oneLine(current.name);
                if (r.filters.isEmpty())
                    r.filters.append(current);
                r.currentFilter = qMax(0, int(r.filters.indexOf(current)));
            }
        }
        if (r.currentFilter < 0 && !r.filters.isEmpty())
            r.currentFilter = 0;
    }

    // Choices: a pop-up when it has options (its initial value one of them, else the first), a check box without.
    QSet<QString> ids;
    const auto choices = fromVariant<QList<Choice>>(options.value(QStringLiteral("choices")));
    for (const Choice &given : choices) {
        if (r.choices.size() >= kMaxChoices)
            break;
        if (given.id.isEmpty() || ids.contains(given.id))
            continue;
        Choice c;
        c.id = given.id.left(kMaxTextLength);
        c.label = oneLine(withoutMnemonic(given.label));
        QSet<QString> optionIds;
        for (const Pair &o : given.options) {
            if (c.options.size() >= kMaxChoiceOptions)
                break;
            if (o.first.isEmpty() || optionIds.contains(o.first))
                continue;
            optionIds.insert(o.first);
            c.options.append(Pair{o.first.left(kMaxTextLength), oneLine(withoutMnemonic(o.second))});
        }
        if (c.options.isEmpty())
            c.initial = given.initial == QLatin1String("true") ? QStringLiteral("true") : QStringLiteral("false");
        else
            c.initial = optionIds.contains(given.initial) ? given.initial : c.options.first().first;
        ids.insert(c.id);
        r.choices.append(c);
    }

    r.currentFolder = pathFromBytes(options.value(QStringLiteral("current_folder")));
    if (kind == Kind::Save) {
        // A suggested name is a name, never a path: the part after the last "/".
        QString name = options.value(QStringLiteral("current_name")).toString();
        name = name.mid(name.lastIndexOf(u'/') + 1);
        r.currentName = FileLogic::isValidFileName(name) ? name.left(kMaxTextLength) : QString();
        // current_file wins: its folder and its name (GTK's set_file).
        r.currentFile = pathFromBytes(options.value(QStringLiteral("current_file")));
        if (!r.currentFile.isEmpty()) {
            const QFileInfo info(r.currentFile);
            if (FileLogic::isValidFileName(info.fileName())) {
                r.currentFolder = info.absolutePath();
                r.currentName = info.fileName();
            } else {
                r.currentFile.clear();
            }
        }
    }
    if (kind == Kind::SaveFiles) {
        const auto names = fromVariant<QByteArrayList>(options.value(QStringLiteral("files")));
        for (QByteArray bytes : names) {
            if (r.files.size() >= kMaxFiles)
                break;
            if (bytes.endsWith('\0'))
                bytes.chop(1);
            const QString name = QFile::decodeName(bytes);
            if (!FileLogic::isValidFileName(name) || bytes.contains('\0')) {
                r.error = QStringLiteral("SaveFiles: an invalid file name");
                break;
            }
            r.files.append(name);
        }
        if (r.files.isEmpty() && r.error.isEmpty())
            r.error = QStringLiteral("SaveFiles: no file names");
    }
    return r;
}

QVariantMap toQml(const Request &r)
{
    QVariantList filters;
    for (const Filter &f : r.filters) {
        QStringList globs, mimes;
        for (const FilterRule &rule : f.rules)
            (rule.type == 0 ? globs : mimes).append(rule.pattern);
        filters.append(QVariantMap{{QStringLiteral("name"), f.name}, {QStringLiteral("globs"), globs}, {QStringLiteral("mimeTypes"), mimes}});
    }
    QVariantList choices;
    for (const Choice &c : r.choices) {
        QVariantList options;
        for (const Pair &o : c.options)
            options.append(QVariantMap{{QStringLiteral("id"), o.first}, {QStringLiteral("label"), o.second}});
        choices.append(QVariantMap{{QStringLiteral("id"), c.id}, {QStringLiteral("label"), c.label}, {QStringLiteral("options"), options},
                                   {QStringLiteral("initial"), c.initial}});
    }
    static const char *const kinds[] = {"open", "save", "saveFiles"};
    return {
        {QStringLiteral("kind"), QString::fromLatin1(kinds[int(r.kind)])},
        {QStringLiteral("appId"), r.appId},
        {QStringLiteral("title"), r.title},
        {QStringLiteral("acceptLabel"), r.acceptLabel},
        {QStringLiteral("modal"), r.modal},
        {QStringLiteral("parented"), r.parentWindow.startsWith(QLatin1String("wayland:")) && r.parentWindow.size() > 8},
        {QStringLiteral("multiple"), r.multiple},
        {QStringLiteral("directory"), r.directory},
        {QStringLiteral("filters"), filters},
        {QStringLiteral("currentFilter"), r.currentFilter},
        {QStringLiteral("choices"), choices},
        {QStringLiteral("currentName"), r.currentName},
        {QStringLiteral("files"), r.files},
        {QStringLiteral("currentFolder"), fileUrl(r.currentFolder)},
        {QStringLiteral("currentFile"), fileUrl(r.currentFile)},
    };
}

Results results(const Request &r, const QVariantMap &answer)
{
    Results out;
    QStringList uris;
    const QVariantList given = answer.value(QStringLiteral("uris")).toList();
    for (const QVariant &v : given) {
        const QString path = localPath(v.toString());
        if (path.isEmpty())
            return out;
        uris.append(QUrl::fromLocalFile(path).toString(QUrl::FullyEncoded));
    }
    switch (r.kind) {
    case Kind::Open:
        if (uris.isEmpty() || (!r.multiple && uris.size() != 1))
            return out;
        break;
    case Kind::Save:
        if (uris.size() != 1 || !FileLogic::isValidFileName(QFileInfo(localPath(uris.first())).fileName()))
            return out;
        break;
    case Kind::SaveFiles: {
        // One URI per name, in order, each in one folder (the names may have been changed to keep both).
        if (uris.size() != r.files.size() || uris.isEmpty())
            return out;
        const QString folder = QFileInfo(localPath(uris.first())).absolutePath();
        for (const QString &uri : std::as_const(uris)) {
            const QFileInfo info(localPath(uri));
            if (info.absolutePath() != folder || !FileLogic::isValidFileName(info.fileName()))
                return out;
        }
        break;
    }
    }
    out.map.insert(QStringLiteral("uris"), uris);

    // Every choice of the request, with the panel's value when it is one the choice allows, else its initial value.
    QHash<QString, QString> chosen;
    for (const QVariant &v : answer.value(QStringLiteral("choices")).toList()) {
        const QVariantMap m = v.toMap();
        chosen.insert(m.value(QStringLiteral("id")).toString(), m.value(QStringLiteral("value")).toString());
    }
    QList<Pair> choices;
    for (const Choice &c : r.choices) {
        QString value = chosen.value(c.id, c.initial);
        bool allowed = false;
        if (c.options.isEmpty())
            allowed = value == QLatin1String("true") || value == QLatin1String("false");
        else
            for (const Pair &o : c.options)
                allowed = allowed || o.first == value;
        choices.append(Pair{c.id, allowed ? value : c.initial});
    }
    if (!choices.isEmpty())
        out.map.insert(QStringLiteral("choices"), QVariant::fromValue(choices));

    if (!r.filters.isEmpty()) {
        bool isInt = false;
        const int index = answer.value(QStringLiteral("filter")).toInt(&isInt);
        const int shown = isInt && index >= 0 && index < r.filters.size() ? index : qMax(0, r.currentFilter);
        out.map.insert(QStringLiteral("current_filter"), QVariant::fromValue(r.filters.at(shown)));
    }
    out.ok = true;
    return out;
}

QVariantMap relayed(const QVariantMap &given)
{
    QVariantMap out;
    if (given.contains(QStringLiteral("uris")))
        out.insert(QStringLiteral("uris"), fromVariant<QStringList>(given.value(QStringLiteral("uris"))));
    if (given.contains(QStringLiteral("choices")))
        out.insert(QStringLiteral("choices"), QVariant::fromValue(fromVariant<QList<Pair>>(given.value(QStringLiteral("choices")))));
    if (given.contains(QStringLiteral("current_filter")))
        out.insert(QStringLiteral("current_filter"), QVariant::fromValue(fromVariant<Filter>(given.value(QStringLiteral("current_filter")))));
    if (given.contains(QStringLiteral("writable")))
        out.insert(QStringLiteral("writable"), given.value(QStringLiteral("writable")).toBool());
    return out;
}

} // namespace grassfield::portal::chooser
