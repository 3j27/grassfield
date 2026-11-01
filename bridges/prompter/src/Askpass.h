#pragma once

// grassfield-askpass's pure parts (ADR-0035 D-9, step 9c; docs/specs/system-dialogs.md section 5, SC7), unit-tested in
// tests/unit/prompter/. The program is askpass.cpp.

#include <QString>

#include <cstddef>

namespace gf::askpass {

    // Exit status, as udiskie reads it (udiskie 2.7.0 prompt.py DeviceCommand: any status but 0 leaves the disk locked).
    enum Exit : int {
        kUnlocked  = 0, // the passphrase and a newline on standard output
        kCancelled = 1, // the user cancelled, or the prompt ended without an answer: nothing written
        kUsage     = 2, // wrong arguments, or standard output is a terminal: nothing asked
        kNoPrompt  = 3, // no prompt could be shown (no session bus, gcr failed): nothing written
    };

    inline constexpr int kDiskNameCap = 128; // UTF-16 code units of the disk's name in the message

    // The disk's name as udiskie passes it ({device_presentation}, the device file): caller text, flattened (Text.h),
    // at most kDiskNameCap; invalid UTF-8 becomes U+FFFD; "" when nothing shows (the message then names no disk).
    QString diskName(const char* argument);

    // Writes `length` bytes of `data` to `fd` straight from that buffer (no stdio copy), through EINTR and partial
    // writes; false on any error (EPIPE: udiskie went away).
    bool writeAll(int fd, const char* data, std::size_t length);

} // namespace gf::askpass
