#include "appstream.h"

#include <QDateTime>
#include <QRegularExpression>
#include <QTimeZone>
#include <QXmlStreamReader>

#include <zlib.h>

namespace grassfield::store {

namespace {

constexpr int kLenName = 80, kLenSummary = 200, kLenDescription = 4000;

bool wantedLanguage(const QStringView lang)
{
    return lang.isEmpty() || lang == u"en" || lang.startsWith(u"en_") || lang == u"fr" || lang.startsWith(u"fr_");
}

void setText(LocalizedText *t, QStringView lang, const QString &value)
{
    if (lang.isEmpty() || lang.startsWith(u"en")) {
        if (lang.isEmpty() || t->en.isEmpty())
            t->en = value;
    } else if (t->fr.isEmpty() || lang == u"fr") {
        t->fr = value;
    }
}

// <description>: paragraphs and list items as plain lines; everything inside them as text.
QString readDescription(QXmlStreamReader &xml)
{
    QString out;
    int depth = 1;
    QString current;
    bool inItem = false;
    while (depth > 0 && !xml.atEnd()) {
        xml.readNext();
        if (xml.isStartElement()) {
            ++depth;
            if (xml.name() == u"p" || xml.name() == u"li") {
                current.clear();
                inItem = xml.name() == u"li";
            }
        } else if (xml.isEndElement()) {
            --depth;
            if (xml.name() == u"p" || xml.name() == u"li") {
                const QString line = cleanPlainText(current, kLenDescription, false);
                if (!line.isEmpty())
                    out += (out.isEmpty() ? QString() : QStringLiteral("\n")) + (inItem ? QStringLiteral("• ") : QString()) + line;
                current.clear();
            }
        } else if (xml.isCharacters()) {
            current += xml.text();
        }
    }
    return cleanPlainText(out, kLenDescription, true);
}

QString xmlLang(const QXmlStreamReader &xml)
{
    return xml.attributes().value(u"http://www.w3.org/XML/1998/namespace", u"lang").toString();
}

// A release's day: its `date` (ISO 8601, the day kept), else its `timestamp` (seconds, UTC); "" when neither parses.
QString releaseDate(QStringView date, QStringView timestamp)
{
    static const QRegularExpression day(QStringLiteral("^([0-9]{4}-[0-9]{2}-[0-9]{2})([T ].*)?$"));
    const QRegularExpressionMatch m = day.match(date.toString());
    if (m.hasMatch() && QDate::fromString(m.captured(1), Qt::ISODate).isValid())
        return m.captured(1);
    bool ok = false;
    const qint64 seconds = timestamp.toLongLong(&ok);
    if (ok && seconds > 0 && seconds < 32503680000) // before the year 3000
        return QDateTime::fromSecsSinceEpoch(seconds, QTimeZone::UTC).date().toString(Qt::ISODate);
    return {};
}

// <releases>: up to three, each with its version, day and notes; anything else inside is skipped.
void readReleases(QXmlStreamReader &xml, QList<AppStreamRelease> *releases)
{
    while (!xml.atEnd()) {
        xml.readNext();
        if (xml.isEndElement() && xml.name() == u"releases")
            return;
        if (!xml.isStartElement())
            continue;
        if (xml.name() != u"release") {
            xml.skipCurrentElement();
            continue;
        }
        AppStreamRelease release;
        const QXmlStreamAttributes a = xml.attributes();
        release.version = cleanPlainText(a.value(u"version").toString(), 64, false);
        release.date = releaseDate(a.value(u"date"), a.value(u"timestamp"));
        while (!xml.atEnd()) {
            xml.readNext();
            if (xml.isEndElement() && xml.name() == u"release")
                break;
            if (!xml.isStartElement())
                continue;
            const QString lang = xmlLang(xml);
            if (xml.name() == u"description" && wantedLanguage(lang))
                setText(&release.description, lang, readDescription(xml));
            else
                xml.skipCurrentElement();
        }
        if (!release.version.isEmpty() && releases->size() < 3)
            releases->append(release);
    }
}

// <content_rating>: the strongest intensity of each OARS group (violence-cartoon counts for violence).
void readContentRating(QXmlStreamReader &xml, QMap<QString, int> *rating)
{
    static const QStringList groups{QStringLiteral("violence"), QStringLiteral("drugs"), QStringLiteral("sex"),
                                    QStringLiteral("language"), QStringLiteral("social"), QStringLiteral("money")};
    static const QStringList levels{QStringLiteral("none"), QStringLiteral("mild"), QStringLiteral("moderate"),
                                    QStringLiteral("intense")};
    while (!xml.atEnd()) {
        xml.readNext();
        if (xml.isEndElement() && xml.name() == u"content_rating")
            return;
        if (!xml.isStartElement())
            continue;
        if (xml.name() != u"content_attribute") {
            xml.skipCurrentElement();
            continue;
        }
        const QString group = xml.attributes().value(u"id").toString().section(QLatin1Char('-'), 0, 0);
        const int level = int(levels.indexOf(xml.readElementText().trimmed()));
        if (groups.contains(group) && level > 0 && level > rating->value(group))
            rating->insert(group, level);
    }
}

// <languages>: the language codes, those translated at least by half when a percentage is given.
void readLanguages(QXmlStreamReader &xml, QStringList *languages)
{
    static const QRegularExpression code(QStringLiteral("^[A-Za-z]{2,3}([_-][A-Za-z0-9]{2,8})*(@[A-Za-z]{2,16})?$"));
    while (!xml.atEnd()) {
        xml.readNext();
        if (xml.isEndElement() && xml.name() == u"languages")
            return;
        if (!xml.isStartElement())
            continue;
        if (xml.name() != u"lang") {
            xml.skipCurrentElement();
            continue;
        }
        const QStringView percentage = xml.attributes().value(u"percentage");
        const QString value = xml.readElementText().trimmed();
        if ((percentage.isEmpty() || percentage.toInt() >= 50) && code.match(value).hasMatch() && !languages->contains(value)
            && languages->size() < 64)
            languages->append(value);
    }
}

} // namespace

QByteArray gunzip(const QByteArray &gz, qint64 maxBytes)
{
    if (gz.size() < 18 || uchar(gz.at(0)) != 0x1f || uchar(gz.at(1)) != 0x8b)
        return {};
    z_stream s{};
    if (inflateInit2(&s, 16 + MAX_WBITS) != Z_OK)
        return {};
    QByteArray out;
    char buffer[64 * 1024];
    s.next_in = reinterpret_cast<Bytef *>(const_cast<char *>(gz.constData()));
    s.avail_in = uInt(gz.size());
    int ret = Z_OK;
    while (ret == Z_OK) {
        s.next_out = reinterpret_cast<Bytef *>(buffer);
        s.avail_out = sizeof buffer;
        ret = inflate(&s, Z_NO_FLUSH);
        if (ret != Z_OK && ret != Z_STREAM_END)
            break;
        out.append(buffer, int(sizeof buffer - s.avail_out));
        if (out.size() > maxBytes) {
            ret = Z_MEM_ERROR;
            break;
        }
    }
    inflateEnd(&s);
    return ret == Z_STREAM_END ? out : QByteArray();
}

QList<AppStreamComponent> parseAppStream(const QByteArray &bytes)
{
    QList<AppStreamComponent> out;
    QXmlStreamReader xml(bytes);
    QString origin;
    while (!xml.atEnd()) {
        xml.readNext();
        if (!xml.isStartElement())
            continue;
        if (xml.name() == u"components") {
            origin = xml.attributes().value(u"origin").toString();
            continue;
        }
        if (xml.name() != u"component")
            continue;
        AppStreamComponent c;
        c.origin = origin;
        c.type = xml.attributes().value(u"type").toString();
        int bestIcon = 0;
        // Only the direct children of <component> are read, each one whole (the lists inside their own element): an <id>
        // of <provides>, <suggests> or <extends>, or a <name> or <description> of <agreement> or <release>, is never the
        // component's own.
        while (!xml.atEnd()) {
            xml.readNext();
            if (xml.isEndElement() && xml.name() == u"component")
                break;
            if (!xml.isStartElement())
                continue;
            const QStringView name = xml.name();
            const QString lang = xmlLang(xml);
            if (!wantedLanguage(lang) && (name == u"name" || name == u"summary" || name == u"description")) {
                xml.skipCurrentElement();
                continue;
            }
            if (name == u"id") {
                c.id = xml.readElementText().trimmed();
            } else if (name == u"pkgname") {
                c.pkgname = xml.readElementText().trimmed();
            } else if (name == u"name") {
                setText(&c.name, lang, cleanPlainText(xml.readElementText(), kLenName, false));
            } else if (name == u"summary") {
                setText(&c.summary, lang, cleanPlainText(xml.readElementText(), kLenSummary, false));
            } else if (name == u"description") {
                setText(&c.description, lang, readDescription(xml));
            } else if (name == u"developer_name") {
                setText(&c.developer, lang, cleanPlainText(xml.readElementText(), kLenName, false));
            } else if (name == u"developer") {
                // <developer id="…"><name>…</name></developer>
                while (!xml.atEnd()) {
                    xml.readNext();
                    if (xml.isEndElement() && xml.name() == u"developer")
                        break;
                    if (!xml.isStartElement())
                        continue;
                    const QString l = xmlLang(xml);
                    if (xml.name() == u"name" && wantedLanguage(l))
                        setText(&c.developer, l, cleanPlainText(xml.readElementText(), kLenName, false));
                    else
                        xml.skipCurrentElement();
                }
            } else if (name == u"project_license") {
                c.license = cleanPlainText(xml.readElementText(), 128, false);
            } else if (name == u"categories") {
                while (!xml.atEnd()) {
                    xml.readNext();
                    if (xml.isEndElement() && xml.name() == u"categories")
                        break;
                    if (!xml.isStartElement())
                        continue;
                    if (xml.name() != u"category") {
                        xml.skipCurrentElement();
                        continue;
                    }
                    const QString v = xml.readElementText().trimmed();
                    if (isAppId(v) && c.categories.size() < 16)
                        c.categories.append(v);
                }
            } else if (name == u"keywords") {
                while (!xml.atEnd()) {
                    xml.readNext();
                    if (xml.isEndElement() && xml.name() == u"keywords")
                        break;
                    if (!xml.isStartElement())
                        continue;
                    if (xml.name() != u"keyword") {
                        xml.skipCurrentElement();
                        continue;
                    }
                    const QString l = xmlLang(xml);
                    const QString v = cleanPlainText(xml.readElementText(), kLenName, false);
                    if ((l.isEmpty() || l.startsWith(u"en")) && !v.isEmpty() && c.keywords.size() < 32)
                        c.keywords.append(v);
                }
            } else if (name == u"launchable") {
                const bool desktop = xml.attributes().value(u"type") == u"desktop-id";
                const QString v = xml.readElementText().trimmed();
                if (desktop && c.desktopId.isEmpty() && isDesktopId(v))
                    c.desktopId = v;
            } else if (name == u"icon") {
                const auto a = xml.attributes();
                const bool cached = a.value(u"type") == u"cached";
                const int width = a.value(u"width").toInt(), height = a.value(u"height").toInt();
                const QString file = xml.readElementText().trimmed();
                if (cached && width > bestIcon && width <= 512 && height <= 512 && !file.contains(QLatin1Char('/'))
                    && !file.startsWith(QLatin1Char('.')) && !file.isEmpty()) {
                    bestIcon = width;
                    c.cachedIcon = QStringLiteral("%1x%2/%3").arg(width).arg(height).arg(file);
                }
            } else if (name == u"screenshots") {
                while (!xml.atEnd()) {
                    xml.readNext();
                    if (xml.isEndElement() && xml.name() == u"screenshots")
                        break;
                    if (!xml.isStartElement())
                        continue;
                    if (xml.name() != u"screenshot") {
                        xml.skipCurrentElement();
                        continue;
                    }
                    const bool isDefault = xml.attributes().value(u"type") == u"default";
                    QString source, caption;
                    while (!xml.atEnd()) {
                        xml.readNext();
                        if (xml.isEndElement() && xml.name() == u"screenshot")
                            break;
                        if (!xml.isStartElement())
                            continue;
                        if (xml.name() == u"image") {
                            const bool src = xml.attributes().value(u"type") == u"source";
                            const QString v = xml.readElementText().trimmed();
                            if (isHttpsUrl(v) && (src || source.isEmpty()))
                                source = v;
                        } else if (xml.name() == u"caption") {
                            const QString l = xmlLang(xml);
                            const QString v = cleanPlainText(xml.readElementText(), kLenSummary, false);
                            if (l.isEmpty() || (l.startsWith(u"en") && caption.isEmpty()))
                                caption = v;
                        } else {
                            xml.skipCurrentElement();
                        }
                    }
                    if (!source.isEmpty() && c.screenshots.size() < 12) {
                        if (isDefault) {
                            c.screenshots.prepend(source);
                            c.screenshotCaptions.prepend(caption);
                        } else {
                            c.screenshots.append(source);
                            c.screenshotCaptions.append(caption);
                        }
                    }
                }
            } else if (name == u"url") {
                const QStringView type = xml.attributes().value(u"type");
                const bool homepage = type == u"homepage", bugtracker = type == u"bugtracker";
                const QString v = xml.readElementText().trimmed();
                if (homepage && isHttpsUrl(v))
                    c.homepage = v;
                else if (bugtracker && isHttpsUrl(v))
                    c.bugtracker = v;
            } else if (name == u"releases") {
                readReleases(xml, &c.releases);
            } else if (name == u"content_rating") {
                c.rated = true;
                readContentRating(xml, &c.rating);
            } else if (name == u"languages") {
                readLanguages(xml, &c.languages);
            } else if (name == u"bundle") {
                // <bundle type="flatpak" runtime="<id>/<arch>/<branch>">app/<id>/<arch>/<branch></bundle> (Flathub's).
                const auto a = xml.attributes();
                const bool flatpak = a.value(u"type") == u"flatpak";
                const QString runtime = a.value(u"runtime").toString();
                const QStringList ref = xml.readElementText().trimmed().split(QLatin1Char('/'));
                if (flatpak && c.flatpak.isEmpty() && ref.size() == 4 && ref.at(0) == QLatin1String("app") && isFlatpakId(ref.at(1))) {
                    c.flatpak = ref.at(1);
                    c.flatpakRef = ref.join(QLatin1Char('/'));
                    c.runtime = isFlatpakRuntime(runtime) ? runtime : QString();
                }
            } else if (name == u"custom") {
                while (!xml.atEnd()) {
                    xml.readNext();
                    if (xml.isEndElement() && xml.name() == u"custom")
                        break;
                    if (!xml.isStartElement())
                        continue;
                    if (xml.name() != u"value") {
                        xml.skipCurrentElement();
                        continue;
                    }
                    const bool key = xml.attributes().value(u"key") == u"flathub::verification::verified";
                    if (xml.readElementText().trimmed() == QLatin1String("true") && key)
                        c.verified = true;
                }
            } else {
                xml.skipCurrentElement(); // provides, suggests, extends, requires, agreement, …
            }
        }
        if (!c.id.isEmpty() && (isPackageName(c.pkgname) || !c.flatpak.isEmpty()) && c.id.size() <= 255)
            out.append(c);
    }
    return out;
}

bool isFlatpakRuntime(const QString &runtime)
{
    static const QRegularExpression re(QStringLiteral(R"(\A[A-Za-z][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+){2,}/[A-Za-z0-9_]{1,32}/[A-Za-z0-9._-]{1,64}\z)"));
    return runtime.size() <= 360 && re.match(runtime).hasMatch();
}

} // namespace grassfield::store
