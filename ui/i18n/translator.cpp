#include "translator.h"

#include "translationloader.h"

namespace {
// The catalog is process-wide. It is installed by the plugin's initializeEngine() (on the engine's thread,
// while shell.qml's imports are resolved, before any object is created) so that no qsTr() is evaluated
// against an empty catalog. Never from a static initializer: that can run off the GUI thread.
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

} // namespace

Translator::Translator(QObject *parent)
    : QObject(parent)
{
    ensureLoaded();
    m_language = g_language;
    m_translator = g_translator;
}

void Translator::installCatalog()
{
    ensureLoaded();
}

Translator *Translator::create(QQmlEngine *engine, QJSEngine *)
{
    auto *translator = new Translator;
    translator->m_engine = engine;
    return translator;
}

void Translator::setLanguage(const QString &language)
{
    if (language == m_language)
        return;
    m_language = language;
    m_translator = g_translator = grassfield::i18n::install(language, g_translator);
    g_language = language;
    // install() set the language's own formats: the chosen ones stay.
    QLocale::setDefault(grassfield::i18n::formatsLocale(m_language, m_formats));
    emit languageChanged();
    retranslate();
}

void Translator::setFormats(const QString &formats)
{
    if (formats == m_formats)
        return;
    m_formats = formats;
    QLocale::setDefault(grassfield::i18n::formatsLocale(m_language, m_formats));
    emit formatsChanged();
    // The bindings that format with a qsTr() pattern follow at once; the others at their next evaluation (a clock's tick).
    retranslate();
}

void Translator::retranslate()
{
    if (m_engine)
        m_engine->retranslate();
}
