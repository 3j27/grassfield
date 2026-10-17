#pragma once

// After a large D-Bus reply (a layout of tens of MB) glibc keeps the freed pages in its arenas: give them back so
// the resident set returns near its idle size (ADR-0008 budget ~20 MB).

#include <QTimer>

#include <malloc.h>

namespace gf::menubridge {

    // malloc_trim(0) once the event loop has released the reply (the watcher is deleted later), at most one pending.
    inline void trimMemorySoon() {
        static bool pending = false;
        if (pending)
            return;
        pending = true;
        QTimer::singleShot(300, [] {
            pending = false;
            ::malloc_trim(0);
        });
    }

} // namespace gf::menubridge
