#include "applicationslogic.h"

#include <QCollator>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QLocale>
#include <QRegularExpression>
#include <QStandardPaths>

#include <algorithm>

namespace ApplicationsLogic
{

namespace
{
constexpr qint64 kMaxEntryBytes = 256 * 1024;
constexpr int kMaxDepth = 8;
constexpr int kMaxEntries = 20000;

bool hasDesktop(const QString &list, const QStringList &current)
{
    for (const QString &name : list.split(QLatin1Char(';'), Qt::SkipEmptyParts)) {
        if (current.contains(name))
            return true;
    }
    return false;
}

bool terminalHelper(const QStringList &categories, const QString &exec)
{
    if (!categories.contains(QLatin1String("TerminalEmulator")))
        return false;
    const QStringList words = exec.split(QRegularExpression(QStringLiteral("[ \t]+")), Qt::SkipEmptyParts);
    if (words.isEmpty())
        return false;
    QString program = words.first();
    program = program.mid(program.lastIndexOf(QLatin1Char('/')) + 1);
    if (program.endsWith(QLatin1String("client")))
        return true;
    for (int i = 1; i < words.size(); ++i) {
        if (words.at(i) == QLatin1String("--server") || words.at(i) == QLatin1String("--daemon"))
            return true;
    }
    return false;
}

struct Fields {
    QString type, tryExec, exec, icon, onlyShowIn, notShowIn, categories;
    QString noDisplay, hidden;
    QString name, genericName, comment;
    QHash<QString, QString> names, genericNames, comments; // by locale suffix
};

// The [Desktop Entry] group, one "Key=value" per line; CR, spaces around "=" and a trailing blank are tolerated; a key
// given twice takes the last value (the same as hidden-entries.sh).
Fields readFields(const QByteArray &text)
{
    Fields f;
    bool inEntry = false;
    for (QByteArray raw : text.split('\n')) {
        QString line = QString::fromUtf8(raw);
        while (line.endsWith(QLatin1Char('\r')) || line.endsWith(QLatin1Char(' ')) || line.endsWith(QLatin1Char('\t')))
            line.chop(1);
        if (line.startsWith(QLatin1Char('['))) {
            inEntry = line == QLatin1String("[Desktop Entry]");
            continue;
        }
        if (!inEntry || line.startsWith(QLatin1Char('#')))
            continue;
        const int eq = line.indexOf(QLatin1Char('='));
        if (eq <= 0)
            continue;
        const QString key = line.left(eq).trimmed();
        const QString value = line.mid(eq + 1).trimmed();
        auto localized = [&](const QString &base, QString &plain, QHash<QString, QString> &byLocale) {
            if (key == base)
                plain = value;
            else if (key.startsWith(base + QLatin1Char('[')) && key.endsWith(QLatin1Char(']')))
                byLocale.insert(key.mid(base.size() + 1, key.size() - base.size() - 2), value);
        };
        if (key == QLatin1String("Type"))
            f.type = value;
        else if (key == QLatin1String("TryExec"))
            f.tryExec = value;
        else if (key == QLatin1String("Exec"))
            f.exec = value;
        else if (key == QLatin1String("Icon"))
            f.icon = value;
        else if (key == QLatin1String("OnlyShowIn"))
            f.onlyShowIn = value;
        else if (key == QLatin1String("NotShowIn"))
            f.notShowIn = value;
        else if (key == QLatin1String("Categories"))
            f.categories = value;
        else if (key == QLatin1String("NoDisplay"))
            f.noDisplay = value;
        else if (key == QLatin1String("Hidden"))
            f.hidden = value;
        else {
            localized(QStringLiteral("Name"), f.name, f.names);
            localized(QStringLiteral("GenericName"), f.genericName, f.genericNames);
            localized(QStringLiteral("Comment"), f.comment, f.comments);
        }
    }
    return f;
}

QString pick(const QString &plain, const QHash<QString, QString> &byLocale, const QStringList &locales)
{
    for (const QString &l : locales) {
        const auto it = byLocale.constFind(l);
        if (it != byLocale.cend() && !it->isEmpty())
            return *it;
    }
    return plain;
}

// The ids and paths of every desktop file below `dir` (symlinked folders followed, loops cut), in a stable order.
void collect(const QDir &base, const QDir &dir, int depth, QSet<QString> &visited, QList<QPair<QString, QString>> &out)
{
    if (depth > kMaxDepth || out.size() >= kMaxEntries)
        return;
    const QString canonical = QFileInfo(dir.absolutePath()).canonicalFilePath();
    if (canonical.isEmpty() || visited.contains(canonical))
        return;
    visited.insert(canonical);
    const QFileInfoList entries = dir.entryInfoList(QDir::Files | QDir::Dirs | QDir::NoDotAndDotDot | QDir::Readable, QDir::Name);
    for (const QFileInfo &info : entries) {
        if (info.fileName().contains(QLatin1Char('\n')))
            continue;
        if (info.isDir()) {
            collect(base, QDir(info.absoluteFilePath()), depth + 1, visited, out);
        } else if (info.fileName().endsWith(QLatin1String(".desktop"))) {
            QString id = base.relativeFilePath(info.absoluteFilePath());
            id.chop(8);
            id.replace(QLatin1Char('/'), QLatin1Char('-'));
            out.append({id, info.absoluteFilePath()});
        }
    }
    visited.remove(canonical);
}
} // namespace

QStringList defaultHelperIds()
{
    return {QStringLiteral("avahi-discover"), QStringLiteral("bssh"), QStringLiteral("bvnc"), QStringLiteral("lstopo"),
            QStringLiteral("org.fcitx.Fcitx5"), QStringLiteral("org.fcitx.fcitx5-qt5-gui-wrapper"),
            QStringLiteral("org.fcitx.fcitx5-qt6-gui-wrapper"), QStringLiteral("fcitx5-migrator")};
}

QStringList localeCandidates(const QString &localeName)
{
    QString name = localeName;
    const int dot = name.indexOf(QLatin1Char('.'));
    if (dot >= 0)
        name = name.left(dot);
    const int at = name.indexOf(QLatin1Char('@'));
    if (at >= 0)
        name = name.left(at);
    QStringList out;
    if (name.isEmpty() || name == QLatin1String("C") || name == QLatin1String("POSIX"))
        return out;
    out << name;
    const int underscore = name.indexOf(QLatin1Char('_'));
    if (underscore > 0)
        out << name.left(underscore);
    return out;
}

Environment processEnvironment()
{
    Environment env;
    const QString home = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation);
    if (!home.isEmpty())
        env.applicationDirs << home + QStringLiteral("/applications");
    for (const QString &dir : QStandardPaths::standardLocations(QStandardPaths::GenericDataLocation)) {
        const QString apps = dir + QStringLiteral("/applications");
        if (!env.applicationDirs.contains(apps))
            env.applicationDirs << apps;
    }
    env.currentDesktop = qEnvironmentVariable("XDG_CURRENT_DESKTOP").split(QLatin1Char(':'), Qt::SkipEmptyParts);
    env.locales = localeCandidates(QLocale().name());
    const QStringList helpers = defaultHelperIds();
    env.helperIds = QSet<QString>(helpers.cbegin(), helpers.cend());
    env.programExists = [](const QString &program) {
        if (program.startsWith(QLatin1Char('/')))
            return QFileInfo(program).isExecutable() && QFileInfo(program).isFile();
        return !QStandardPaths::findExecutable(program).isEmpty();
    };
    return env;
}

bool parseEntry(const QByteArray &text, const QString &id, const QString &path, const Environment &env, Entry *out)
{
    const Fields f = readFields(text);
    if (f.type != QLatin1String("Application"))
        return false;
    if (f.noDisplay == QLatin1String("true") || f.hidden == QLatin1String("true"))
        return false;
    if (!f.onlyShowIn.isEmpty() && !hasDesktop(f.onlyShowIn, env.currentDesktop))
        return false;
    if (!f.notShowIn.isEmpty() && hasDesktop(f.notShowIn, env.currentDesktop))
        return false;
    if (!f.tryExec.isEmpty() && env.programExists && !env.programExists(f.tryExec))
        return false;
    const QStringList categories = f.categories.split(QLatin1Char(';'), Qt::SkipEmptyParts);
    if (terminalHelper(categories, f.exec))
        return false;
    Entry e;
    e.id = id;
    e.path = path;
    e.name = pick(f.name, f.names, env.locales);
    if (e.name.isEmpty())
        e.name = id;
    e.genericName = pick(f.genericName, f.genericNames, env.locales);
    e.comment = pick(f.comment, f.comments, env.locales);
    e.icon = f.icon;
    e.exec = f.exec;
    e.categories = categories;
    *out = e;
    return true;
}

QList<Entry> listApplications(const Environment &env)
{
    QSet<QString> seen;
    QList<Entry> result;
    for (const QString &dirPath : env.applicationDirs) {
        const QDir dir(dirPath);
        if (!dir.exists())
            continue;
        QList<QPair<QString, QString>> files;
        QSet<QString> visited;
        collect(dir, dir, 0, visited, files);
        for (const auto &file : std::as_const(files)) {
            // The highest-priority file of an id counts, also when it hides the entry.
            if (seen.contains(file.first))
                continue;
            seen.insert(file.first);
            if (env.helperIds.contains(file.first))
                continue;
            QFile f(file.second);
            if (!f.open(QIODevice::ReadOnly))
                continue;
            const QByteArray text = f.read(kMaxEntryBytes);
            Entry entry;
            if (parseEntry(text, file.first, file.second, env, &entry))
                result.append(entry);
        }
    }
    QCollator collator;
    collator.setCaseSensitivity(Qt::CaseInsensitive);
    collator.setNumericMode(true);
    std::sort(result.begin(), result.end(), [&collator](const Entry &a, const Entry &b) {
        const int c = collator.compare(a.name, b.name);
        return c != 0 ? c < 0 : a.id < b.id;
    });
    return result;
}

QUrl locationUrl()
{
    return QUrl(QStringLiteral("grassfield-apps:/"));
}

bool isLocationUrl(const QUrl &url)
{
    return url.scheme() == QLatin1String("grassfield-apps");
}

QUrl entryUrl(const QString &id)
{
    QUrl url;
    url.setScheme(QStringLiteral("grassfield-app"));
    url.setPath(QLatin1Char('/') + id);
    return url;
}

QString entryId(const QUrl &url)
{
    if (url.scheme() != QLatin1String("grassfield-app"))
        return {};
    return url.path().mid(1);
}

} // namespace ApplicationsLogic
