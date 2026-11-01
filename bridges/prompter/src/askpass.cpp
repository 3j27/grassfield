// SPDX-License-Identifier: MIT
// grassfield-askpass: udiskie's password command in the Grassfield session (ADR-0035 D-9, step 9c;
// docs/specs/system-dialogs.md section 5, SC7). grassfield-automount.service runs udiskie with
//   --password-prompt "/usr/lib/grassfield/grassfield-askpass udiskie {device_presentation}"
// and udiskie runs this for an encrypted disk, reading the passphrase from its standard output (udiskie 2.7.0 prompt.py
// DeviceCommand: the output with its last newline removed, given to udisks as the key; any exit status but 0 leaves the
// disk locked).
//
// It is a gcr client (libgcr-4's GcrSystemPrompt): it asks org.gnome.keyring.SystemPrompter, which is grassfield-prompter
// while the shell is connected (the shell's secret sheet draws the prompt, the requester row "Disks": the bridge names this
// executable by its root-owned path) and the stock gcr-prompter otherwise (D-Bus activation), with the sx-aes-1 exchange
// either way. Its text is caller text: the disk's name (udiskie's {device_presentation}) flattened inside a fixed
// sentence; any program of the user can run it with a name of its own, which is why the sheet shows that text as another
// program's (SC3b).
//
// The passphrase: never in the arguments, the environment or a log; it stays in gcr's secure memory (locked, zeroed when
// freed) and is written to standard output straight from there, then a newline; never to a terminal (refused at start).
// The process allows no core file; it turns non-dumpable once the passphrase is here (not before: the bridge identifies
// the caller through /proc/<pid>/exe, which a non-dumpable process of the user hides from it).
//
// Usage: grassfield-askpass udiskie <disk>
// Exit status: 0 the passphrase and a newline written; 1 cancelled (nothing written); 2 wrong arguments or standard output
// is a terminal; 3 no prompt could be shown.

#include "Askpass.h"

#include "translationloader.h"

#include <gcr/gcr.h>

#include <QCoreApplication>
#include <QString>

#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <unistd.h>

using namespace gf::askpass;

namespace {
    struct Answer {
        GMainLoop*   loop     = nullptr;
        const gchar* password = nullptr; // owned by the prompt (gcr secure memory)
        bool         failed   = false;
    };

    void onPassword(GObject* source, GAsyncResult* result, gpointer data) {
        auto*   answer = static_cast<Answer*>(data);
        GError* error  = nullptr;
        answer->password = gcr_prompt_password_finish(GCR_PROMPT(source), result, &error);
        if (error) {
            // Never the password; gcr's message names the failure (the prompter went away, a protocol error).
            std::fprintf(stderr, "grassfield-askpass: no answer: %s\n", error->message);
            answer->failed = true;
            g_clear_error(&error);
        }
        g_main_loop_quit(answer->loop);
    }
} // namespace

int main(int argc, char** argv) {
    // A passphrase passes through this process: never in a core file.
    const rlimit noCore{0, 0};
    ::setrlimit(RLIMIT_CORE, &noCore);
    // GDBus and GLib print messages with their contents under these.
    ::unsetenv("G_DBUS_DEBUG");
    ::unsetenv("G_MESSAGES_DEBUG");
    // udiskie gone while writing: an error, not a signal.
    std::signal(SIGPIPE, SIG_IGN);

    if (argc != 3 || std::strcmp(argv[1], "udiskie") != 0) {
        std::fprintf(stderr, "usage: grassfield-askpass udiskie <disk>\n");
        return kUsage;
    }
    if (::isatty(STDOUT_FILENO)) {
        std::fprintf(stderr, "grassfield-askpass: refusing to write a passphrase to a terminal\n");
        return kUsage;
    }

    // Qt sees no argument of udiskie's (the disk's name is never read as an option).
    int   qtArgc   = 1;
    char* qtArgv[] = {argv[0], nullptr};
    QCoreApplication app(qtArgc, qtArgv);
    QCoreApplication::setApplicationName(QStringLiteral("grassfield-askpass"));
    grassfield::i18n::installForApplication();

    const QString disk    = diskName(argv[2]);
    const QString message = disk.isEmpty() ? QCoreApplication::translate("GrassfieldAskpass", "Enter a password to unlock the disk.")
                                           : QCoreApplication::translate("GrassfieldAskpass", "Enter a password to unlock the disk “%1”.").arg(disk);

    GError*    error  = nullptr;
    GcrPrompt* prompt = gcr_system_prompt_open(-1, nullptr, &error);
    if (!prompt) {
        std::fprintf(stderr, "grassfield-askpass: no prompt: %s\n", error ? error->message : "unknown error");
        g_clear_error(&error);
        return kNoPrompt;
    }
    gcr_prompt_set_title(prompt, QCoreApplication::translate("GrassfieldAskpass", "Encrypted Disk").toUtf8().constData());
    gcr_prompt_set_message(prompt, message.toUtf8().constData());
    gcr_prompt_set_continue_label(prompt, QCoreApplication::translate("GrassfieldAskpass", "Unlock").toUtf8().constData());
    gcr_prompt_set_cancel_label(prompt, QCoreApplication::translate("GrassfieldAskpass", "Cancel").toUtf8().constData());

    // gcr's callbacks come through the default main context: its own loop runs here (Qt's event loop never does).
    Answer answer;
    answer.loop = g_main_loop_new(nullptr, FALSE);
    gcr_prompt_password_async(prompt, nullptr, onPassword, &answer);
    g_main_loop_run(answer.loop);
    g_main_loop_unref(answer.loop);

    int status = kCancelled;
    if (answer.password && !answer.failed) {
        // The caller is identified by now: nothing in this process may be read by another one from here on.
        ::prctl(PR_SET_DUMPABLE, 0, 0, 0, 0);
        const std::size_t length = std::strlen(answer.password);
        if (writeAll(STDOUT_FILENO, answer.password, length) && writeAll(STDOUT_FILENO, "\n", 1))
            status = kUnlocked;
        else
            std::fprintf(stderr, "grassfield-askpass: cannot write the passphrase (udiskie went away?)\n");
    }
    // StopPrompting: the prompt ends at the prompter; unref frees the passphrase, zeroed, with the prompt's secure memory.
    gcr_system_prompt_close(GCR_SYSTEM_PROMPT(prompt), nullptr, nullptr);
    g_object_unref(prompt);
    return status;
}
