#pragma once

// One line per event on stderr (the journal under systemd, .dev/menu-bridge.log in development).

#include <QString>

#include <cstdio>

namespace gf::menubridge {

    inline void log(const QString& line) {
        std::fprintf(stderr, "grassfield-menu-bridge: %s\n", qPrintable(line));
        std::fflush(stderr);
    }

} // namespace gf::menubridge
