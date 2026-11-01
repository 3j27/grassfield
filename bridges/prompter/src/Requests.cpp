#include "Requests.h"

#include <algorithm>
#include <utility>
#include <vector>

namespace gf::prompter {

    RequestBook::RequestBook(int capacity) : m_capacity(capacity) {}

    QString RequestBook::reserve(const void* owner) {
        if (!owner || m_byOwner.contains(owner) || m_byId.size() >= m_capacity)
            return {};
        const quint64 n  = m_next++;
        const QString id = QStringLiteral("p%1").arg(n);
        m_byId.insert(id, owner);
        m_byOwner.insert(owner, id);
        m_serial.insert(id, n);
        return id;
    }

    const void* RequestBook::owner(const QString& id) const {
        return m_byId.value(id, nullptr);
    }

    QString RequestBook::idOf(const void* owner) const {
        return m_byOwner.value(owner);
    }

    bool RequestBook::release(const QString& id) {
        const auto it = m_byId.constFind(id);
        if (it == m_byId.constEnd())
            return false;
        m_byOwner.remove(it.value());
        m_serial.remove(id);
        m_byId.erase(it);
        return true;
    }

    QStringList RequestBook::ids() const {
        std::vector<std::pair<quint64, QString>> sorted;
        sorted.reserve(static_cast<std::size_t>(m_serial.size()));
        for (auto it = m_serial.constBegin(); it != m_serial.constEnd(); ++it)
            sorted.emplace_back(it.value(), it.key());
        std::sort(sorted.begin(), sorted.end());
        QStringList out;
        for (const auto& [n, id] : sorted)
            out.append(id);
        return out;
    }

} // namespace gf::prompter
