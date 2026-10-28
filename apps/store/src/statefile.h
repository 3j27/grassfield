// $XDG_STATE_HOME/grassfield/store.json (ADR-0037 c "Cache", f; ADR-0020): version 1, read and changed by the catalog's
// store (its accepted serial per channel, on the loading worker) and by the operations (the one in flight, on the GUI
// thread). Every change reads the file again and writes it whole (a temporary file, then a rename) under one lock, so
// neither loses the other's key.
#pragma once

#include <QJsonObject>
#include <QString>

#include <functional>

namespace grassfield::store {

// The state, or {"version": 1} when the file is missing, unreadable, larger than 1 MiB or of another version.
QJsonObject readStoreState(const QString &path);
// Reads the state, lets `change` edit it, writes it back; false when it could not be written.
bool updateStoreState(const QString &path, const std::function<void(QJsonObject &)> &change);

} // namespace grassfield::store
