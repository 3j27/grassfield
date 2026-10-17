#include "Layout.h"

#include <QDBusArgument>
#include <QDBusMessage>
#include <QDBusVariant>
#include <QMetaType>
#include <QStringList>

#include <array>
#include <optional>
#include <utility>

namespace gf::menubridge {

    namespace {
        // The DBusMenu properties the bridge uses; everything else an application sends is skipped.
        constexpr std::array<const char*, 9> kKnownProperties = {"label", "enabled", "visible", "type", "toggle-type", "toggle-state", "children-display", "icon-name", "shortcut"};

        bool isKnownProperty(const QString& key) {
            for (const char* k : kKnownProperties) {
                if (key == QLatin1String(k))
                    return true;
            }
            return false;
        }

        // "aas" -> QVariantList of QStringList (at most limits::kShortcuts entries; keys are sanitized when mapped).
        QVariant readShortcut(const QVariant& value) {
            QVariantList out;
            if (value.metaType() != QMetaType::fromType<QDBusArgument>())
                return out;
            const auto arg = qvariant_cast<QDBusArgument>(value);
            if (arg.currentSignature() != QLatin1String("aas"))
                return out;
            arg.beginArray();
            while (!arg.atEnd()) {
                QStringList keys;
                arg >> keys;
                if (out.size() < limits::kShortcuts)
                    out.append(QVariant(keys));
            }
            arg.endArray();
            return out;
        }

        QString stringProperty(const QVariantMap& p, const char* key) {
            const QVariant v = p.value(QLatin1String(key));
            return v.metaType() == QMetaType::fromType<QString>() ? v.toString() : QString();
        }

        bool boolProperty(const QVariantMap& p, const char* key, bool fallback) {
            const QVariant v = p.value(QLatin1String(key));
            return v.metaType() == QMetaType::fromType<bool>() ? v.toBool() : fallback;
        }

        std::optional<int> intProperty(const QVariantMap& p, const char* key) {
            const QVariant v = p.value(QLatin1String(key));
            if (v.metaType() == QMetaType::fromType<int>() || v.metaType() == QMetaType::fromType<uint>() || v.metaType() == QMetaType::fromType<qlonglong>())
                return static_cast<int>(qBound(qlonglong(-1), v.toLongLong(), qlonglong(2)));
            return std::nullopt;
        }

        bool isBidiControl(char16_t u) {
            return u == 0x061C || u == 0x200E || u == 0x200F || (u >= 0x202A && u <= 0x202E) || (u >= 0x2066 && u <= 0x2069);
        }

        // Key names as DBusMenu sends them ("Control", "Shift", "N", "F5", "plus"): printable, no spaces, short.
        QString keyName(const QString& key) {
            if (key.isEmpty() || key.size() > limits::kKeyName)
                return {};
            for (const QChar c : key) {
                if (c.isSpace() || !c.isPrint())
                    return {};
            }
            return key;
        }

        QJsonArray shortcuts(const QVariantMap& p) {
            QJsonArray out;
            const QVariant v = p.value(QStringLiteral("shortcut"));
            if (v.metaType() != QMetaType::fromType<QVariantList>())
                return out;
            for (const QVariant& entry : v.toList()) {
                if (out.size() >= limits::kShortcuts)
                    break;
                const QStringList keys = entry.toStringList();
                if (keys.isEmpty() || keys.size() > limits::kShortcutKeys)
                    continue;
                QJsonArray mapped;
                for (const QString& k : keys) {
                    const QString name = keyName(k);
                    if (name.isEmpty()) {
                        mapped = {};
                        break;
                    }
                    mapped.append(name);
                }
                if (!mapped.isEmpty())
                    out.append(mapped);
            }
            return out;
        }

        // Freedesktop icon names only ([A-Za-z0-9_.+-]); anything else (paths, URLs) is dropped.
        QString iconName(const QString& name) {
            if (name.size() > limits::kIconName)
                return {};
            for (const QChar c : name) {
                const bool ok = (c >= u'a' && c <= u'z') || (c >= u'A' && c <= u'Z') || (c >= u'0' && c <= u'9') || c == u'_' || c == u'.' || c == u'+' || c == u'-';
                if (!ok)
                    return {};
            }
            return name;
        }

        QJsonArray mapList(const QList<RawItem>& items, int depth, LayoutBudget& budget);

        QJsonObject mapItem(const RawItem& raw, int depth, LayoutBudget& budget) {
            const QVariantMap& p         = raw.properties;
            const bool         separator = stringProperty(p, "type") == QLatin1String("separator");
            const QString      toggle    = stringProperty(p, "toggle-type");
            const bool         toggles   = toggle == QLatin1String("checkmark") || toggle == QLatin1String("radio");
            const bool         submenu   = !separator && (stringProperty(p, "children-display") == QLatin1String("submenu") || !raw.children.isEmpty());

            QJsonObject        o;
            o.insert(QStringLiteral("id"), raw.id);
            o.insert(QStringLiteral("type"), separator ? QStringLiteral("separator") : QStringLiteral("standard"));
            o.insert(QStringLiteral("label"), separator ? QString() : plainLabel(stringProperty(p, "label")));
            o.insert(QStringLiteral("enabled"), boolProperty(p, "enabled", true));
            o.insert(QStringLiteral("visible"), boolProperty(p, "visible", true));
            o.insert(QStringLiteral("toggle-type"), toggles ? toggle : QString());
            const auto state = intProperty(p, "toggle-state");
            o.insert(QStringLiteral("toggle-state"), toggles && state && (*state == 0 || *state == 1) ? *state : -1);
            o.insert(QStringLiteral("shortcut"), separator ? QJsonArray() : shortcuts(p));
            o.insert(QStringLiteral("icon-name"), separator ? QString() : iconName(stringProperty(p, "icon-name")));
            o.insert(QStringLiteral("submenu"), submenu);
            QJsonArray children;
            if (submenu) {
                if (depth + 1 < limits::kDepth)
                    children = mapList(raw.children, depth + 1, budget);
                else if (!raw.children.isEmpty())
                    budget.truncated = true;
            }
            o.insert(QStringLiteral("children"), children);
            return o;
        }

        QJsonArray mapList(const QList<RawItem>& items, int depth, LayoutBudget& budget) {
            QJsonArray out;
            for (const RawItem& item : items) {
                if (item.id < 0)
                    continue; // menu/1 ids are >= 0
                if (budget.items <= 0) {
                    budget.truncated = true;
                    break;
                }
                --budget.items;
                out.append(mapItem(item, depth, budget));
            }
            return out;
        }

        void indexInto(const QJsonArray& items, ItemIndex& index) {
            for (const QJsonValue& v : items) {
                const QJsonObject o  = v.toObject();
                const int         id = o.value(QLatin1String("id")).toInt(-1);
                if (id < 0 || o.value(QLatin1String("type")).toString() == QLatin1String("separator") || !o.value(QLatin1String("visible")).toBool(true))
                    continue;
                if (o.value(QLatin1String("submenu")).toBool()) {
                    index.submenus.insert(id);
                    indexInto(o.value(QLatin1String("children")).toArray(), index);
                } else if (o.value(QLatin1String("enabled")).toBool(true))
                    index.activatable.insert(id);
            }
        }
    } // namespace

    bool readLayout(const QDBusArgument& arg, RawItem& out, int depth, LayoutBudget& budget) {
        if (arg.currentType() != QDBusArgument::StructureType || arg.currentSignature() != QLatin1String("(ia{sv}av)"))
            return false;
        arg.beginStructure();
        arg >> out.id;
        arg.beginMap();
        while (!arg.atEnd()) {
            QString      key;
            QDBusVariant value;
            arg.beginMapEntry();
            arg >> key >> value;
            arg.endMapEntry();
            if (!isKnownProperty(key))
                continue;
            QVariant v = key == QLatin1String("shortcut") ? readShortcut(value.variant()) : value.variant();
            // Only what the mapping can use is kept: a label of megabytes would otherwise stay resident until the
            // whole tree is mapped (plainLabel keeps kLabel characters; whitespace runs and mnemonics need slack).
            if (key == QLatin1String("label") && v.metaType() == QMetaType::fromType<QString>() && v.toString().size() > limits::kLabel * 8)
                v = v.toString().left(limits::kLabel * 8);
            out.properties.insert(key, std::move(v));
        }
        arg.endMap();
        arg.beginArray();
        while (!arg.atEnd()) {
            if (depth >= limits::kDepth || budget.items <= 0) {
                // Over a cap: the rest of the array is not read at all (nothing is allocated for it).
                budget.truncated = true;
                break;
            }
            QDBusVariant child;
            arg >> child;
            const QVariant v = child.variant();
            if (v.metaType() != QMetaType::fromType<QDBusArgument>())
                continue;
            RawItem item;
            --budget.items;
            if (readLayout(qvariant_cast<QDBusArgument>(v), item, depth + 1, budget))
                out.children.append(std::move(item));
        }
        arg.endArray();
        arg.endStructure();
        return true;
    }

    QString plainLabel(const QString& label) {
        QString out;
        out.reserve(qMin<qsizetype>(label.size(), limits::kLabel));
        bool pendingSpace = false;
        for (qsizetype i = 0; i < label.size() && out.size() < limits::kLabel; ++i) {
            QChar c = label.at(i);
            if (c == u'_') {
                if (i + 1 < label.size() && label.at(i + 1) == u'_')
                    ++i; // "__" -> literal "_"
                else
                    continue; // mnemonic marker
            }
            const char16_t u = c.unicode();
            if (c.isSpace()) {
                // Whitespace (newlines and tabs included): runs collapse to one space between words.
                pendingSpace = !out.isEmpty();
                continue;
            }
            if (u < 0x20 || (u >= 0x7F && u < 0xA0) || isBidiControl(u))
                continue; // control and bidirectional formatting characters
            if (pendingSpace) {
                out += u' ';
                pendingSpace = false;
                if (out.size() >= limits::kLabel)
                    break;
            }
            out += c;
        }
        // Never end on half of a surrogate pair after truncation.
        if (!out.isEmpty() && out.back().isHighSurrogate())
            out.chop(1);
        return out;
    }

    QJsonArray mapChildren(const RawItem& root, LayoutBudget& budget) {
        return mapList(root.children, 0, budget);
    }

    ItemIndex indexItems(const QJsonArray& items) {
        ItemIndex index;
        indexInto(items, index);
        return index;
    }

    namespace {
        QDBusMessage dbusmenuCall(const QString& service, const QString& path, const char* method) {
            return QDBusMessage::createMethodCall(service, path, QStringLiteral("com.canonical.dbusmenu"), QLatin1String(method));
        }
    } // namespace

    QDBusMessage getLayoutCall(const QString& service, const QString& path) {
        QDBusMessage msg = dbusmenuCall(service, path, "GetLayout");
        msg << QVariant::fromValue<int>(0) << QVariant::fromValue<int>(-1) << QVariant::fromValue(QStringList{});
        return msg;
    }

    QDBusMessage aboutToShowCall(const QString& service, const QString& path, int id) {
        QDBusMessage msg = dbusmenuCall(service, path, "AboutToShow");
        msg << QVariant::fromValue<int>(id);
        return msg;
    }

    QDBusMessage eventCall(const QString& service, const QString& path, int id) {
        QDBusMessage msg = dbusmenuCall(service, path, "Event");
        msg << QVariant::fromValue<int>(id) << QStringLiteral("clicked") << QVariant::fromValue(QDBusVariant(QVariant::fromValue<int>(0))) << QVariant::fromValue<uint>(0);
        return msg;
    }

} // namespace gf::menubridge
