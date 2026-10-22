#include "Protocol.h"

#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QJsonValue>

#include <cmath>
#include <limits>

namespace gf::menubridge {

    namespace {
        bool isAsciiAlpha(QChar c) {
            return (c >= u'A' && c <= u'Z') || (c >= u'a' && c <= u'z');
        }

        bool isAsciiDigit(QChar c) {
            return c >= u'0' && c <= u'9';
        }

        bool isBusNameChar(QChar c) {
            return isAsciiAlpha(c) || isAsciiDigit(c) || c == u'_' || c == u'-';
        }

        bool isPathChar(QChar c) {
            return isAsciiAlpha(c) || isAsciiDigit(c) || c == u'_';
        }

        bool isHexDigit(QChar c) {
            return isAsciiDigit(c) || (c >= u'a' && c <= u'f') || (c >= u'A' && c <= u'F');
        }

        // A JSON number that is an integer in [min, max].
        std::optional<qint64> integerIn(const QJsonValue& v, qint64 min, qint64 max) {
            if (!v.isDouble())
                return std::nullopt;
            const double d = v.toDouble();
            if (!std::isfinite(d) || std::floor(d) != d || d < static_cast<double>(min) || d > static_cast<double>(max))
                return std::nullopt;
            return static_cast<qint64>(d);
        }

        QByteArray line(const QJsonObject& o) {
            QByteArray out = QJsonDocument(o).toJson(QJsonDocument::Compact);
            out += '\n';
            return out;
        }
    } // namespace

    bool isValidBusName(QStringView name) {
        if (name.isEmpty() || name.size() > limits::kNameLength)
            return false;
        const bool unique = name.front() == u':';
        if (unique)
            name = name.mid(1);
        int elements = 0;
        while (true) {
            const qsizetype   dot     = name.indexOf(u'.');
            const QStringView element = dot < 0 ? name : name.left(dot);
            if (element.isEmpty())
                return false;
            for (const QChar c : element) {
                if (!isBusNameChar(c))
                    return false;
            }
            if (!unique && isAsciiDigit(element.front()))
                return false;
            ++elements;
            if (dot < 0)
                break;
            name = name.mid(dot + 1);
        }
        return elements >= 2;
    }

    bool isValidObjectPath(QStringView path) {
        if (path.isEmpty() || path.size() > limits::kNameLength || path.front() != u'/')
            return false;
        if (path.size() == 1)
            return true;
        path = path.mid(1);
        while (true) {
            const qsizetype   slash   = path.indexOf(u'/');
            const QStringView element = slash < 0 ? path : path.left(slash);
            if (element.isEmpty())
                return false;
            for (const QChar c : element) {
                if (!isPathChar(c))
                    return false;
            }
            if (slash < 0)
                return true;
            path = path.mid(slash + 1);
        }
    }

    bool isValidWindow(QStringView window) {
        if (window.isEmpty() || window.size() > 16)
            return false;
        for (const QChar c : window) {
            if (!isHexDigit(c))
                return false;
        }
        return true;
    }

    std::optional<ShellMessage> parseShellMessage(const QByteArray& text, QString* error) {
        auto fail = [error](const QString& code) -> std::optional<ShellMessage> {
            if (error)
                *error = code;
            return std::nullopt;
        };
        if (text.size() > limits::kShellLine)
            return fail(QStringLiteral("too-long"));
        QJsonParseError     parseError{};
        const QJsonDocument doc = QJsonDocument::fromJson(text, &parseError);
        if (parseError.error != QJsonParseError::NoError || !doc.isObject())
            return fail(QStringLiteral("parse"));
        const QJsonObject o    = doc.object();
        const QString     type = o.value(QLatin1String("type")).toString();

        ShellMessage      msg;
        if (type == QLatin1String("hello")) {
            if (o.value(QLatin1String("v")).toString() != QLatin1String(kProtocol))
                return fail(QStringLiteral("version"));
            const QJsonValue appmenu = o.value(QLatin1String("appmenu"));
            if (!appmenu.isBool())
                return fail(QStringLiteral("field:appmenu"));
            msg.type    = ShellMessage::Type::Hello;
            msg.appmenu = appmenu.toBool();
            return msg;
        }

        if (type == QLatin1String("open"))
            msg.type = ShellMessage::Type::Open;
        else if (type == QLatin1String("about-to-show"))
            msg.type = ShellMessage::Type::AboutToShow;
        else if (type == QLatin1String("activate"))
            msg.type = ShellMessage::Type::Activate;
        else if (type == QLatin1String("close"))
            msg.type = ShellMessage::Type::Close;
        else
            return fail(QStringLiteral("type"));

        const QJsonValue window = o.value(QLatin1String("window"));
        if (!window.isString() || !isValidWindow(window.toString()))
            return fail(QStringLiteral("field:window"));
        msg.window = window.toString().toLower();

        switch (msg.type) {
            case ShellMessage::Type::Open: {
                const QJsonValue service = o.value(QLatin1String("service"));
                const QJsonValue path    = o.value(QLatin1String("path"));
                if (!service.isString() || !isValidBusName(service.toString()))
                    return fail(QStringLiteral("field:service"));
                if (!path.isString() || !isValidObjectPath(path.toString()))
                    return fail(QStringLiteral("field:path"));
                const auto pid = integerIn(o.value(QLatin1String("pid")), 1, std::numeric_limits<qint32>::max());
                if (!pid)
                    return fail(QStringLiteral("field:pid"));
                msg.service = service.toString();
                msg.path    = path.toString();
                msg.pid     = *pid;
                break;
            }
            case ShellMessage::Type::AboutToShow:
            case ShellMessage::Type::Activate: {
                const auto id = integerIn(o.value(QLatin1String("id")), 0, std::numeric_limits<qint32>::max());
                if (!id)
                    return fail(QStringLiteral("field:id"));
                msg.id = static_cast<int>(*id);
                break;
            }
            case ShellMessage::Type::Close:
            case ShellMessage::Type::Hello: break;
        }
        return msg;
    }

    QByteArray menuMessage(const QString& window, quint32 revision, const QJsonArray& items) {
        return line(QJsonObject{
            {QStringLiteral("type"), QStringLiteral("menu")},
            {QStringLiteral("window"), window},
            {QStringLiteral("revision"), static_cast<qint64>(revision)},
            {QStringLiteral("items"), items},
        });
    }

    QByteArray errorMessage(const QString& window, const QString& code, const QString& message) {
        return line(QJsonObject{
            {QStringLiteral("type"), QStringLiteral("error")},
            {QStringLiteral("window"), window},
            {QStringLiteral("code"), code},
            {QStringLiteral("message"), message.left(limits::kLabel)},
        });
    }

    QByteArray statusMessage(const QString& state, bool registrar) {
        return line(QJsonObject{
            {QStringLiteral("type"), QStringLiteral("status")},
            {QStringLiteral("v"), QLatin1String(kProtocol)},
            {QStringLiteral("state"), state},
            {QStringLiteral("registrar"), registrar},
        });
    }

    QByteArray launcherMessage(const QString& app, std::optional<qint64> count, std::optional<double> progress, std::optional<bool> urgent) {
        return line(QJsonObject{
            {QStringLiteral("type"), QStringLiteral("launcher")},
            {QStringLiteral("app"), app},
            {QStringLiteral("count"), count ? QJsonValue(*count) : QJsonValue(QJsonValue::Null)},
            {QStringLiteral("progress"), progress ? QJsonValue(*progress) : QJsonValue(QJsonValue::Null)},
            {QStringLiteral("urgent"), urgent ? QJsonValue(*urgent) : QJsonValue(QJsonValue::Null)},
        });
    }

} // namespace gf::menubridge
