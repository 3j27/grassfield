#include "Askpass.h"

#include "Text.h"

#include <cerrno>
#include <unistd.h>

namespace gf::askpass {

    QString diskName(const char* argument) {
        return prompter::flattenUtf8(argument, kDiskNameCap);
    }

    bool writeAll(int fd, const char* data, std::size_t length) {
        while (length > 0) {
            const ssize_t n = ::write(fd, data, length);
            if (n < 0) {
                if (errno == EINTR)
                    continue;
                return false;
            }
            data += n;
            length -= static_cast<std::size_t>(n);
        }
        return true;
    }

} // namespace gf::askpass
