#include "Quiet.hpp"

namespace gf::quiet {

    namespace {
        thread_local int g_depth = 0; // NOLINT(cppcoreguidelines-avoid-non-const-global-variables): the open scopes
    }

    CKeyPath::CKeyPath() noexcept {
        ++g_depth;
    }

    CKeyPath::~CKeyPath() {
        --g_depth;
    }

    bool inKeyPath() noexcept {
        return g_depth > 0;
    }

} // namespace gf::quiet
