#pragma once

// GfPrompt: Grassfield's GcrPrompt implementation (ADR-0035 D-9), a GObject class written in C++. libgcr's
// GcrSystemPrompter creates one per gcr caller (BeginPrompting), sets the caller's properties on it and asks it for a
// password or a confirmation (PerformPrompt); the prompt hands each request to its sink, the bridge, which shows it
// through the shell and answers it. The prompt never draws anything and never invents an answer: a request it cannot
// hand over, and one the caller withdraws (StopPrompting, the caller gone, the prompt closed), ends "cancelled".
//
// The password the shell typed arrives in gcr's secure memory (gcr_secure_memory_*: locked in RAM, zeroed when freed). It
// is handed to libgcr, which encrypts it for the caller at once (the sx-aes-1 exchange); the prompt then zeroes and frees
// its copy in the next main loop turn, and in any case before its next request and when it is disposed (gcr documents the
// password as valid until the next prompt).

#include <gcr/gcr.h>

#include <QList>
#include <QSet>
#include <QString>

#include <functional>

G_BEGIN_DECLS
#define GF_TYPE_PROMPT (gf_prompt_get_type())
G_DECLARE_FINAL_TYPE(GfPrompt, gf_prompt, GF, PROMPT, GObject)
G_END_DECLS

namespace gf::prompter {

    enum class PromptKind { None, Password, Confirm };

    class PromptSink {
      public:
        virtual ~PromptSink() = default;
        // The prompt asks (pendingKind says what). The sink answers later with answerPassword/answerConfirm/answerCancel,
        // or at once with answerCancel when it cannot show it.
        virtual void submit(GfPrompt* prompt) = 0;
        // The caller withdrew the pending request: the prompt is completed "cancelled" by itself, the sink only forgets it.
        virtual void withdraw(GfPrompt* prompt) = 0;
        // The prompt object goes away.
        virtual void forget(GfPrompt* prompt) = 0;
    };

    // A new prompt (full reference) reporting to `sink`; with sink == nullptr every request ends "cancelled" at once.
    GfPrompt*  newPrompt(PromptSink* sink);
    // The sink goes away: requests end "cancelled" from now on.
    void       detachSink(GfPrompt* prompt);

    PromptKind pendingKind(GfPrompt* prompt);
    // The unique bus name of the caller, as the bus daemon wrote it (Filter.h); empty when unknown.
    QString    promptCaller(GfPrompt* prompt);

    struct PromptFields {
        QString title, message, description, warning, choiceLabel, continueLabel, cancelLabel;
        bool    choiceChosen = false;
        bool    passwordNew  = false;
    };
    // The caller's properties as set (raw: the bridge flattens them).
    PromptFields promptFields(GfPrompt* prompt);

    // The sink's answers; each completes the pending request at most once and does nothing when none is pending or the
    // kind differs (the password is then zeroed and freed). `choice`: -1 leaves "choice-chosen" as the caller set it.
    // answerPassword takes `securePassword` (gcr secure memory, NUL-terminated; nullptr means the user cancelled).
    void answerPassword(GfPrompt* prompt, char* securePassword, int choice);
    void answerConfirm(GfPrompt* prompt, bool proceed, int choice);
    // The request ends "cancelled" in a later main loop turn (never inside the caller's own call).
    void answerCancel(GfPrompt* prompt);

    // For the tests: the prompt still holds a password.
    bool holdsPassword(GfPrompt* prompt);

    // Work on prompts left for a later turn of the default main context, so that nothing calls into gcr from inside gcr's
    // own callbacks (opus final check of step 9a). A job holds a reference to each of its prompts, released once it has
    // run; the jobs that have not run when their owner goes are removed with it, their references released, so no job
    // ever runs after its owner (opus re-check of step 9a, NIT).
    class PromptsLater {
      public:
        using Job = std::function<void(const QList<GfPrompt*>& prompts)>;

        PromptsLater() = default;
        ~PromptsLater();
        PromptsLater(const PromptsLater&)            = delete;
        PromptsLater& operator=(const PromptsLater&) = delete;

        // Takes over one reference to each prompt; `job` (may be empty: the references only go later) runs in a later turn.
        void schedule(QList<GfPrompt*> prompts, Job job);
        // Removes every job that has not run, without running it, and releases its references.
        void clear();
        // The jobs that have not run.
        qsizetype pending() const {
            return m_sources.size();
        }

      private:
        struct Entry;
        static gboolean run(gpointer data);
        static void     done(gpointer data);
        QSet<guint>     m_sources;
    };

} // namespace gf::prompter
