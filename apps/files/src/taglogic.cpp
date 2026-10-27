#include "taglogic.h"

#include <QCoreApplication>
#include <QSet>

namespace TagLogic
{

namespace
{
// Stored keys of the colour tags, in palette order (tokens files.tagRed ... files.tagGray). The translated names are
// looked up in context "Tags".
const char *const kColorKeys[kColorCount] = {
    QT_TRANSLATE_NOOP("Tags", "Red"),
    QT_TRANSLATE_NOOP("Tags", "Orange"),
    QT_TRANSLATE_NOOP("Tags", "Yellow"),
    QT_TRANSLATE_NOOP("Tags", "Green"),
    QT_TRANSLATE_NOOP("Tags", "Blue"),
    QT_TRANSLATE_NOOP("Tags", "Purple"),
    QT_TRANSLATE_NOOP("Tags", "Gray"),
};

QString clean(const QString &tag)
{
    QString t = tag;
    t.replace(QLatin1Char(','), QLatin1Char(' '));
    t.replace(QLatin1Char('\n'), QLatin1Char(' '));
    t.replace(QLatin1Char('\r'), QLatin1Char(' '));
    return t.trimmed();
}
} // namespace

const char *attributeName()
{
    return "user.xdg.tags";
}

QStringList parse(const QByteArray &value)
{
    QStringList out;
    QSet<QString> seen;
    const QStringList parts = QString::fromUtf8(value).split(QLatin1Char(','));
    for (const QString &part : parts) {
        const QString tag = part.trimmed();
        if (tag.isEmpty() || seen.contains(tag))
            continue;
        seen.insert(tag);
        out.append(tag);
    }
    return out;
}

QByteArray serialize(const QStringList &tags)
{
    QStringList out;
    QSet<QString> seen;
    for (const QString &raw : tags) {
        const QString tag = clean(raw);
        if (tag.isEmpty() || seen.contains(tag))
            continue;
        seen.insert(tag);
        out.append(tag);
    }
    return out.join(QLatin1Char(',')).toUtf8();
}

namespace
{
// The stored bytes of `tag` (empty: nothing to add or remove).
QByteArray storedName(const QString &tag)
{
    const QString t = clean(tag);
    const int c = colorIndex(t);
    return (c >= 0 ? colorKey(c) : t).toUtf8();
}

// Whether a stored entry is `name`: a colour tag's key matches without regard to case (the menu shows a foreign "red"
// as Red, so clicking Red acts on it), any other tag exactly.
bool entryIs(const QByteArray &entry, const QByteArray &name, bool color)
{
    const QByteArray t = entry.trimmed();
    return color ? t.compare(name, Qt::CaseInsensitive) == 0 : t == name;
}
} // namespace

QByteArray applyTag(const QByteArray &stored, const QString &tag, bool on)
{
    const QByteArray name = storedName(tag);
    if (name.isEmpty())
        return stored;
    const bool color = colorIndex(tag) >= 0;
    const QList<QByteArray> entries = stored.isEmpty() ? QList<QByteArray>() : stored.split(',');
    QList<QByteArray> kept;
    bool found = false;
    for (const QByteArray &entry : entries) {
        if (entryIs(entry, name, color))
            found = true;
        else
            kept.append(entry);
    }
    if (on) {
        if (found)
            return stored;
        return stored.isEmpty() ? name : stored + ',' + name;
    }
    if (!found)
        return stored;
    return kept.join(',');
}

bool ownsTag(const QByteArray &stored, const QString &tag)
{
    const QByteArray name = storedName(tag);
    if (name.isEmpty() || stored.isEmpty())
        return false;
    const bool color = colorIndex(tag) >= 0;
    const QList<QByteArray> entries = stored.split(',');
    for (const QByteArray &entry : entries) {
        if (entryIs(entry, name, color))
            return true;
    }
    return false;
}

int colorIndex(const QString &tag)
{
    const QStringView t = QStringView(tag).trimmed();
    for (int i = 0; i < kColorCount; ++i) {
        if (t.compare(QLatin1String(kColorKeys[i]), Qt::CaseInsensitive) == 0)
            return i;
    }
    return -1;
}

QString colorKey(int index)
{
    return index >= 0 && index < kColorCount ? QString::fromLatin1(kColorKeys[index]) : QString();
}

QString displayName(const QString &tag)
{
    const int i = colorIndex(tag);
    return i >= 0 ? QCoreApplication::translate("Tags", kColorKeys[i]) : tag;
}

QString typedTag(const QString &typed)
{
    const QString text = typed.trimmed();
    for (int i = 0; i < kColorCount; i++) {
        const QString key = colorKey(i);
        if (text.compare(key, Qt::CaseInsensitive) == 0 || text.compare(displayName(key), Qt::CaseInsensitive) == 0)
            return key;
    }
    return text;
}

bool sameTag(const QString &a, const QString &b)
{
    const int ca = colorIndex(a);
    if (ca >= 0)
        return ca == colorIndex(b);
    return a == b;
}

bool hasTag(const QStringList &tags, const QString &tag)
{
    for (const QString &t : tags) {
        if (sameTag(t, tag))
            return true;
    }
    return false;
}

QStringList withTag(const QStringList &tags, const QString &tag, bool on)
{
    const QString t = clean(tag);
    if (t.isEmpty())
        return tags;
    if (on) {
        if (hasTag(tags, t))
            return tags;
        QStringList out = tags;
        const int c = colorIndex(t);
        out.append(c >= 0 ? colorKey(c) : t);
        return out;
    }
    QStringList out;
    for (const QString &existing : tags) {
        if (!sameTag(existing, t))
            out.append(existing);
    }
    return out;
}

QStringList displayOrder(const QStringList &tags)
{
    QStringList out;
    const QList<int> colors = colorIndices(tags);
    for (int c : colors)
        out.append(colorKey(c));
    for (const QString &t : tags) {
        if (colorIndex(t) < 0 && !out.contains(t))
            out.append(t);
    }
    return out;
}

QStringList mergeKnown(const QStringList &known, const QStringList &hidden, const QStringList &seen, int max)
{
    QStringList out = known;
    for (const QString &tag : seen) {
        if (!hasTag(out, tag) && !hasTag(hidden, tag))
            out = withTag(out, tag, true);
    }
    return displayOrder(out).mid(0, max);
}

QList<int> colorIndices(const QStringList &tags)
{
    bool present[kColorCount] = {};
    for (const QString &t : tags) {
        const int c = colorIndex(t);
        if (c >= 0)
            present[c] = true;
    }
    QList<int> out;
    for (int i = 0; i < kColorCount; ++i) {
        if (present[i])
            out.append(i);
    }
    return out;
}

QList<int> colorStates(const QList<QStringList> &tagLists)
{
    QList<int> states(kColorCount, 0);
    if (tagLists.isEmpty())
        return states;
    // One pass over every list (a selection of thousands is asked on each selection change).
    int counts[kColorCount] = {};
    for (const QStringList &tags : tagLists) {
        bool present[kColorCount] = {};
        for (const QString &t : tags) {
            const int c = colorIndex(t);
            if (c >= 0)
                present[c] = true;
        }
        for (int i = 0; i < kColorCount; ++i)
            counts[i] += present[i] ? 1 : 0;
    }
    for (int i = 0; i < kColorCount; ++i)
        states[i] = counts[i] == 0 ? 0 : counts[i] == tagLists.size() ? 2 : 1;
    return states;
}

QString searchScheme()
{
    return QStringLiteral("grassfield-tag");
}

QUrl searchUrl(const QString &tag, const QUrl &folder)
{
    QUrl url;
    url.setScheme(searchScheme());
    url.setPath(QLatin1Char('/') + tag, QUrl::DecodedMode);
    const QByteArray in = QUrl::toPercentEncoding(folder.adjusted(QUrl::StripTrailingSlash).toString(QUrl::FullyEncoded));
    url.setQuery(QStringLiteral("in=") + QString::fromLatin1(in), QUrl::StrictMode);
    return url;
}

bool isSearchUrl(const QUrl &url)
{
    return url.scheme() == searchScheme() && !searchTag(url).isEmpty();
}

QString searchTag(const QUrl &url)
{
    if (url.scheme() != searchScheme())
        return QString();
    return url.path(QUrl::FullyDecoded).mid(1);
}

QUrl searchFolder(const QUrl &url)
{
    if (url.scheme() != searchScheme())
        return QUrl();
    const QString query = url.query(QUrl::FullyEncoded);
    const QStringList items = query.split(QLatin1Char('&'));
    for (const QString &item : items) {
        if (item.startsWith(QLatin1String("in=")))
            return QUrl(QUrl::fromPercentEncoding(item.mid(3).toLatin1()), QUrl::StrictMode);
    }
    return QUrl();
}

} // namespace TagLogic
