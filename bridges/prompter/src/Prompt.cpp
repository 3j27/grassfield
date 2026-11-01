#include "Prompt.h"

#include "Filter.h"

#include <cstring>
#include <utility>

using gf::prompter::PromptKind;
using gf::prompter::PromptSink;

struct _GfPrompt {
    GObject parent_instance;

    // GcrPrompt's properties, as the caller set them.
    gchar*   title;
    gchar*   message;
    gchar*   description;
    gchar*   warning;
    gchar*   choice_label;
    gchar*   caller_window;
    gchar*   continue_label;
    gchar*   cancel_label;
    gboolean choice_chosen;
    gboolean password_new;
    gint     password_strength;

    gchar* caller; // "grassfield-caller": the sender of the PerformPrompt, set through the bus filter only

    // The pending request.
    GTask*        task;
    PromptKind    kind;
    GCancellable* cancellable;
    gulong        cancelled_id;
    guint         complete_id; // a scheduled "cancelled" completion
    gboolean      submitted;   // handed to the sink (only then is a withdrawal reported to it)

    gchar* password; // the last answer (gcr secure memory), until wiped
    guint  wipe_id;

    PromptSink* sink;
};

namespace {
    enum {
        PROP_0,
        PROP_TITLE,
        PROP_MESSAGE,
        PROP_DESCRIPTION,
        PROP_WARNING,
        PROP_PASSWORD_NEW,
        PROP_PASSWORD_STRENGTH,
        PROP_CHOICE_LABEL,
        PROP_CHOICE_CHOSEN,
        PROP_CALLER_WINDOW,
        PROP_CONTINUE_LABEL,
        PROP_CANCEL_LABEL,
        PROP_CALLER,
    };

    QString text(const gchar* value) {
        return value ? QString::fromUtf8(value) : QString();
    }

    void wipePassword(GfPrompt* self) {
        if (self->wipe_id) {
            g_source_remove(self->wipe_id);
            self->wipe_id = 0;
        }
        if (self->password) {
            // gcr_secure_memory_strfree zeroes the string too; this does not depend on it.
            volatile char* p = self->password;
            for (std::size_t i = 0, n = std::strlen(self->password); i < n; ++i)
                p[i] = 0;
            gcr_secure_memory_strfree(self->password);
            self->password = nullptr;
        }
    }

    gboolean wipeLater(gpointer data) {
        auto* self    = static_cast<GfPrompt*>(data);
        self->wipe_id = 0;
        wipePassword(self);
        return G_SOURCE_REMOVE;
    }

    // Detaches the pending request from the prompt and returns its task (nullptr when none).
    GTask* takeTask(GfPrompt* self) {
        GTask* task     = self->task;
        self->task      = nullptr;
        self->kind      = PromptKind::None;
        self->submitted = FALSE;
        if (self->complete_id) {
            g_source_remove(self->complete_id);
            self->complete_id = 0;
        }
        // Never called from inside the cancellable's own "cancelled" emission (onCancelled only schedules), so disconnecting
        // cannot wait on itself.
        if (self->cancelled_id && self->cancellable)
            g_cancellable_disconnect(self->cancellable, self->cancelled_id);
        self->cancelled_id = 0;
        g_clear_object(&self->cancellable);
        return task;
    }

    void returnCancelled(GfPrompt* self) {
        GTask* task = takeTask(self);
        if (!task)
            return;
        g_task_return_new_error(task, G_IO_ERROR, G_IO_ERROR_CANCELLED, "The request was cancelled");
        g_object_unref(task);
    }

    gboolean completeCancelled(gpointer data) {
        auto* self        = static_cast<GfPrompt*>(data);
        self->complete_id = 0;
        returnCancelled(self);
        return G_SOURCE_REMOVE;
    }

    // Completion in a later turn: at a high priority, so it runs before anything gcr schedules at the default one.
    void scheduleCancelled(GfPrompt* self) {
        if (!self->task || self->complete_id)
            return;
        self->complete_id = g_idle_add_full(G_PRIORITY_HIGH, completeCancelled, g_object_ref(self), g_object_unref);
    }

    // The caller withdrew (gcr cancels the cancellable on StopPrompting and when the caller leaves the bus).
    void onCancelled(GCancellable* /*cancellable*/, gpointer data) {
        auto* self = static_cast<GfPrompt*>(data);
        if (!self->task)
            return;
        if (self->sink && self->submitted)
            self->sink->withdraw(self);
        scheduleCancelled(self);
    }

    void begin(GfPrompt* self, PromptKind kind, GCancellable* cancellable, GAsyncReadyCallback callback, gpointer userData, gpointer tag) {
        GTask* task = g_task_new(self, cancellable, callback, userData);
        g_task_set_source_tag(task, tag);
        if (self->task) {
            // gcr never asks twice at once (its "ready" state); refused if anything else does.
            g_task_return_new_error(task, G_IO_ERROR, G_IO_ERROR_PENDING, "A request is already pending");
            g_object_unref(task);
            return;
        }
        wipePassword(self); // the previous answer is no longer valid
        self->task = task;
        self->kind = kind;
        if (cancellable) {
            self->cancellable  = G_CANCELLABLE(g_object_ref(cancellable));
            // Already cancelled: the handler runs now and schedules the completion; nothing is handed to the sink then.
            self->cancelled_id = g_cancellable_connect(cancellable, G_CALLBACK(onCancelled), self, nullptr);
        }
        if (self->complete_id)
            return;
        if (!self->sink) {
            scheduleCancelled(self);
            return;
        }
        self->submitted = TRUE;
        self->sink->submit(self);
    }

    void promptPasswordAsync(GcrPrompt* prompt, GCancellable* cancellable, GAsyncReadyCallback callback, gpointer userData) {
        begin(GF_PROMPT(prompt), PromptKind::Password, cancellable, callback, userData, reinterpret_cast<gpointer>(promptPasswordAsync));
    }

    const gchar* promptPasswordFinish(GcrPrompt* prompt, GAsyncResult* result, GError** error) {
        GfPrompt* self = GF_PROMPT(prompt);
        g_return_val_if_fail(g_task_is_valid(result, prompt), nullptr);
        auto* password = static_cast<gchar*>(g_task_propagate_pointer(G_TASK(result), error));
        wipePassword(self);
        self->password = password;
        // libgcr encrypts it for the caller right after this returns, in the same call: then it goes.
        if (password)
            self->wipe_id = g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, wipeLater, g_object_ref(self), g_object_unref);
        return password;
    }

    void promptConfirmAsync(GcrPrompt* prompt, GCancellable* cancellable, GAsyncReadyCallback callback, gpointer userData) {
        begin(GF_PROMPT(prompt), PromptKind::Confirm, cancellable, callback, userData, reinterpret_cast<gpointer>(promptConfirmAsync));
    }

    GcrPromptReply promptConfirmFinish(GcrPrompt* prompt, GAsyncResult* result, GError** error) {
        g_return_val_if_fail(g_task_is_valid(result, prompt), GCR_PROMPT_REPLY_CANCEL);
        const gssize reply = g_task_propagate_int(G_TASK(result), error);
        return reply == GCR_PROMPT_REPLY_CONTINUE ? GCR_PROMPT_REPLY_CONTINUE : GCR_PROMPT_REPLY_CANCEL;
    }

    // gcr_prompt_close: the prompt goes (gcr closes it on StopPrompting, after cancelling a pending request).
    void promptClose(GcrPrompt* prompt) {
        GfPrompt* self = GF_PROMPT(prompt);
        if (self->task && !self->complete_id) {
            if (self->sink && self->submitted)
                self->sink->withdraw(self);
            scheduleCancelled(self);
        }
        wipePassword(self);
    }

    void gfPromptIfaceInit(GcrPromptInterface* iface) {
        iface->prompt_password_async  = promptPasswordAsync;
        iface->prompt_password_finish = promptPasswordFinish;
        iface->prompt_confirm_async   = promptConfirmAsync;
        iface->prompt_confirm_finish  = promptConfirmFinish;
        iface->prompt_close           = promptClose;
    }

    void setString(gchar** field, const GValue* value) {
        g_free(*field);
        *field = g_value_dup_string(value);
    }
} // namespace

G_DEFINE_FINAL_TYPE_WITH_CODE(GfPrompt, gf_prompt, G_TYPE_OBJECT, G_IMPLEMENT_INTERFACE(GCR_TYPE_PROMPT, gfPromptIfaceInit))

static void gf_prompt_init(GfPrompt* /*self*/) {}

static void gf_prompt_set_property(GObject* object, guint id, const GValue* value, GParamSpec* pspec) {
    GfPrompt* self = GF_PROMPT(object);
    switch (id) {
        case PROP_TITLE: setString(&self->title, value); break;
        case PROP_MESSAGE: setString(&self->message, value); break;
        case PROP_DESCRIPTION: setString(&self->description, value); break;
        case PROP_WARNING: setString(&self->warning, value); break;
        case PROP_CHOICE_LABEL: setString(&self->choice_label, value); break;
        case PROP_CALLER_WINDOW: setString(&self->caller_window, value); break;
        case PROP_CONTINUE_LABEL: setString(&self->continue_label, value); break;
        case PROP_CANCEL_LABEL: setString(&self->cancel_label, value); break;
        case PROP_CHOICE_CHOSEN: self->choice_chosen = g_value_get_boolean(value); break;
        case PROP_PASSWORD_NEW: self->password_new = g_value_get_boolean(value); break;
        case PROP_CALLER: setString(&self->caller, value); break;
        default: G_OBJECT_WARN_INVALID_PROPERTY_ID(object, id, pspec); break;
    }
}

static void gf_prompt_get_property(GObject* object, guint id, GValue* value, GParamSpec* pspec) {
    GfPrompt* self = GF_PROMPT(object);
    switch (id) {
        case PROP_TITLE: g_value_set_string(value, self->title); break;
        case PROP_MESSAGE: g_value_set_string(value, self->message); break;
        case PROP_DESCRIPTION: g_value_set_string(value, self->description); break;
        case PROP_WARNING: g_value_set_string(value, self->warning); break;
        case PROP_CHOICE_LABEL: g_value_set_string(value, self->choice_label); break;
        case PROP_CALLER_WINDOW: g_value_set_string(value, self->caller_window); break;
        case PROP_CONTINUE_LABEL: g_value_set_string(value, self->continue_label); break;
        case PROP_CANCEL_LABEL: g_value_set_string(value, self->cancel_label); break;
        case PROP_CHOICE_CHOSEN: g_value_set_boolean(value, self->choice_chosen); break;
        case PROP_PASSWORD_NEW: g_value_set_boolean(value, self->password_new); break;
        case PROP_PASSWORD_STRENGTH: g_value_set_int(value, self->password_strength); break;
        case PROP_CALLER: g_value_set_string(value, self->caller); break;
        default: G_OBJECT_WARN_INVALID_PROPERTY_ID(object, id, pspec); break;
    }
}

static void gf_prompt_dispose(GObject* object) {
    GfPrompt* self = GF_PROMPT(object);
    // A request still pending (gcr disposes a closed prompt right after cancelling it) ends "cancelled" in its scheduled
    // completion, which holds a reference; an unscheduled one is scheduled now.
    if (self->task && !self->complete_id)
        scheduleCancelled(self);
    wipePassword(self);
    if (PromptSink* sink = self->sink) {
        self->sink = nullptr;
        sink->forget(self);
    }
    G_OBJECT_CLASS(gf_prompt_parent_class)->dispose(object);
}

static void gf_prompt_finalize(GObject* object) {
    GfPrompt* self = GF_PROMPT(object);
    wipePassword(self);
    g_free(self->title);
    g_free(self->message);
    g_free(self->description);
    g_free(self->warning);
    g_free(self->choice_label);
    g_free(self->caller_window);
    g_free(self->continue_label);
    g_free(self->cancel_label);
    g_free(self->caller);
    G_OBJECT_CLASS(gf_prompt_parent_class)->finalize(object);
}

static void gf_prompt_class_init(GfPromptClass* klass) {
    GObjectClass* object_class = G_OBJECT_CLASS(klass);
    object_class->set_property = gf_prompt_set_property;
    object_class->get_property = gf_prompt_get_property;
    object_class->dispose      = gf_prompt_dispose;
    object_class->finalize     = gf_prompt_finalize;
    g_object_class_override_property(object_class, PROP_TITLE, "title");
    g_object_class_override_property(object_class, PROP_MESSAGE, "message");
    g_object_class_override_property(object_class, PROP_DESCRIPTION, "description");
    g_object_class_override_property(object_class, PROP_WARNING, "warning");
    g_object_class_override_property(object_class, PROP_PASSWORD_NEW, "password-new");
    g_object_class_override_property(object_class, PROP_PASSWORD_STRENGTH, "password-strength");
    g_object_class_override_property(object_class, PROP_CHOICE_LABEL, "choice-label");
    g_object_class_override_property(object_class, PROP_CHOICE_CHOSEN, "choice-chosen");
    g_object_class_override_property(object_class, PROP_CALLER_WINDOW, "caller-window");
    g_object_class_override_property(object_class, PROP_CONTINUE_LABEL, "continue-label");
    g_object_class_override_property(object_class, PROP_CANCEL_LABEL, "cancel-label");
    // Never notified: gcr echoes notified properties back to the caller, and this one is not the caller's business.
    g_object_class_install_property(object_class, PROP_CALLER,
                                    g_param_spec_string(gf::prompter::kCallerProperty, "Caller", "Unique bus name of the caller", nullptr,
                                                        static_cast<GParamFlags>(G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS | G_PARAM_EXPLICIT_NOTIFY)));
}

namespace gf::prompter {

    GfPrompt* newPrompt(PromptSink* sink) {
        auto* prompt = GF_PROMPT(g_object_new(GF_TYPE_PROMPT, nullptr));
        prompt->sink = sink;
        return prompt;
    }

    void detachSink(GfPrompt* prompt) {
        prompt->sink = nullptr;
    }

    PromptKind pendingKind(GfPrompt* prompt) {
        return prompt->task && !prompt->complete_id ? prompt->kind : PromptKind::None;
    }

    QString promptCaller(GfPrompt* prompt) {
        return text(prompt->caller);
    }

    PromptFields promptFields(GfPrompt* p) {
        PromptFields f;
        f.title         = text(p->title);
        f.message       = text(p->message);
        f.description   = text(p->description);
        f.warning       = text(p->warning);
        f.choiceLabel   = text(p->choice_label);
        f.continueLabel = text(p->continue_label);
        f.cancelLabel   = text(p->cancel_label);
        f.choiceChosen  = p->choice_chosen;
        f.passwordNew   = p->password_new;
        return f;
    }

    void answerPassword(GfPrompt* prompt, char* securePassword, int choice) {
        if (pendingKind(prompt) != PromptKind::Password) {
            if (securePassword) {
                std::memset(securePassword, 0, std::strlen(securePassword));
                gcr_secure_memory_strfree(securePassword);
            }
            return;
        }
        if (choice >= 0 && prompt->choice_label && *prompt->choice_label && prompt->choice_chosen != (choice != 0)) {
            prompt->choice_chosen = choice != 0;
            g_object_notify(G_OBJECT(prompt), "choice-chosen");
        }
        if (securePassword) {
            // As gcr's own dialog: 0 for an empty password (gnome-keyring then asks about storing unencrypted), 1 otherwise.
            prompt->password_strength = *securePassword ? 1 : 0;
            g_object_notify(G_OBJECT(prompt), "password-strength");
        }
        GTask* task = takeTask(prompt);
        g_task_return_pointer(task, securePassword, reinterpret_cast<GDestroyNotify>(gcr_secure_memory_strfree));
        g_object_unref(task);
    }

    void answerConfirm(GfPrompt* prompt, bool proceed, int choice) {
        if (pendingKind(prompt) != PromptKind::Confirm)
            return;
        if (choice >= 0 && prompt->choice_label && *prompt->choice_label && prompt->choice_chosen != (choice != 0)) {
            prompt->choice_chosen = choice != 0;
            g_object_notify(G_OBJECT(prompt), "choice-chosen");
        }
        GTask* task = takeTask(prompt);
        g_task_return_int(task, proceed ? GCR_PROMPT_REPLY_CONTINUE : GCR_PROMPT_REPLY_CANCEL);
        g_object_unref(task);
    }

    void answerCancel(GfPrompt* prompt) {
        scheduleCancelled(prompt);
    }

    bool holdsPassword(GfPrompt* prompt) {
        return prompt->password != nullptr;
    }

    struct PromptsLater::Entry {
        PromptsLater*    owner;
        QList<GfPrompt*> prompts; // references, released when the source goes (done)
        Job              job;
        guint            source = 0;
    };

    PromptsLater::~PromptsLater() {
        clear();
    }

    void PromptsLater::schedule(QList<GfPrompt*> prompts, Job job) {
        auto* entry   = new Entry{this, std::move(prompts), std::move(job)};
        entry->source = g_idle_add_full(G_PRIORITY_DEFAULT, run, entry, done);
        m_sources.insert(entry->source);
    }

    void PromptsLater::clear() {
        // Releasing a reference can dispose a prompt, whose sink may schedule more: until none is left.
        while (!m_sources.isEmpty()) {
            const QSet<guint> sources = std::exchange(m_sources, {});
            for (const guint source : sources)
                g_source_remove(source); // done() releases its references; run() never comes
        }
    }

    gboolean PromptsLater::run(gpointer data) {
        auto* entry = static_cast<Entry*>(data);
        entry->owner->m_sources.remove(entry->source);
        if (entry->job)
            entry->job(entry->prompts);
        return G_SOURCE_REMOVE;
    }

    void PromptsLater::done(gpointer data) {
        auto* entry = static_cast<Entry*>(data);
        for (GfPrompt* prompt : std::as_const(entry->prompts))
            g_object_unref(prompt);
        delete entry;
    }

} // namespace gf::prompter
