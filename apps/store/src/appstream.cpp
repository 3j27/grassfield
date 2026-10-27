#include "appstream.h"

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
        while (!xml.atEnd()) {
            xml.readNext();
            if (xml.isEndElement() && xml.name() == u"component")
                break;
            if (!xml.isStartElement())
                continue;
            const QStringView name = xml.name();
            const QString lang = xml.attributes().value(u"http://www.w3.org/XML/1998/namespace", u"lang").toString();
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
                    if (xml.isStartElement() && xml.name() == u"name") {
                        const QString l = xml.attributes().value(u"http://www.w3.org/XML/1998/namespace", u"lang").toString();
                        const QString v = cleanPlainText(xml.readElementText(), kLenName, false);
                        if (wantedLanguage(l))
                            setText(&c.developer, l, v);
                    }
                }
            } else if (name == u"project_license") {
                c.license = cleanPlainText(xml.readElementText(), 128, false);
            } else if (name == u"category") {
                const QString v = xml.readElementText().trimmed();
                if (isAppId(v) && c.categories.size() < 16)
                    c.categories.append(v);
            } else if (name == u"keyword") {
                const QString v = cleanPlainText(xml.readElementText(), kLenName, false);
                if ((lang.isEmpty() || lang.startsWith(u"en")) && !v.isEmpty() && c.keywords.size() < 32)
                    c.keywords.append(v);
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
            } else if (name == u"screenshot") {
                const bool isDefault = xml.attributes().value(u"type") == u"default";
                QString source;
                while (!xml.atEnd()) {
                    xml.readNext();
                    if (xml.isEndElement() && xml.name() == u"screenshot")
                        break;
                    if (xml.isStartElement() && xml.name() == u"image") {
                        const bool src = xml.attributes().value(u"type") == u"source";
                        const QString v = xml.readElementText().trimmed();
                        if (isHttpsUrl(v) && (src || source.isEmpty()))
                            source = v;
                    }
                }
                if (!source.isEmpty() && c.screenshots.size() < 12) {
                    if (isDefault)
                        c.screenshots.prepend(source);
                    else
                        c.screenshots.append(source);
                }
            } else if (name == u"url") {
                const bool homepage = xml.attributes().value(u"type") == u"homepage";
                const QString v = xml.readElementText().trimmed();
                if (homepage && isHttpsUrl(v))
                    c.homepage = v;
            }
        }
        if (!c.id.isEmpty() && isPackageName(c.pkgname) && c.id.size() <= 255)
            out.append(c);
    }
    return out;
}

} // namespace grassfield::store
