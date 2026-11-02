#pragma once

// One line per event on stderr (the journal under systemd). Never a caller's text, never a password: ids, kinds, roles,
// paths (flattened) and refusals only.

#include <QString>

#include <cstdio>

namespace gf::prompter {

    inline void log(const QString& line) {
        std::fprintf(stderr, "grassfield-prompter: %s\n", qPrintable(line));
        std::fflush(stderr);
    }

} // namespace gf::prompter
