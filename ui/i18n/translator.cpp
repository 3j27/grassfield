#include "translator.h"

#include "translationloader.h"

namespace {
// The catalog is process-wide. It is installed when the plugin is loaded (that is, while shell.qml's imports
// are resolved, before any object is created) so that no qsTr() is evaluated against an empty catalog.
QString g_language;
QTranslator *g_translator = nullptr;
bool g_loaded = false;

void ensureLoaded()
{
    if (g_loaded || !QCoreApplication::instance())
        return;
    g_loaded = true;
    g_language = grassfield::i18n::systemLanguage();
    g_translator = grassfield::i18n::install(g_language);
}

struct EarlyInstall
{
    EarlyInstall() { ensureLoaded(); }
} earlyInstall;
} // namespace

Translator::Translator(QObject *parent)
    : QObject(parent)
{
    ensureLoaded();
    m_language = g_language;
    m_translator = g_translator;
}

Translator *Translator::create(QQmlEngine *engine, QJSEngine *)
{
    auto *translator = new Translator;
    translator->m_engine = engine;
    // Strings evaluated before the catalog was installed are refreshed once the engine is running.
    if (translator->m_translator)
        QMetaObject::invokeMethod(translator, &Translator::retranslate, Qt::QueuedConnection);
    return translator;
}

void Translator::setLanguage(const QString &language)
{
    if (language == m_language)
        return;
    m_language = language;
    m_translator = g_translator = grassfield::i18n::install(language, g_translator);
    g_language = language;
    emit languageChanged();
    retranslate();
}

void Translator::retranslate()
{
    if (m_engine)
        m_engine->retranslate();
}
