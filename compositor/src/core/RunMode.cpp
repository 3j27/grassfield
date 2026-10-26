#include "RunMode.hpp"

#include <string_view>

namespace gf::runmode {

    namespace {
        bool isOne(const char* value) {
            return value != nullptr && std::string_view{value} == "1";
        }
    } // namespace

    bool dev(const char* devValue, const char* sessionValue) {
        return isOne(devValue) && !isOne(sessionValue);
    }

    bool session(const char* sessionValue) {
        return isOne(sessionValue);
    }

} // namespace gf::runmode
