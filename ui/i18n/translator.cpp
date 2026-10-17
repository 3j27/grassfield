#include "translator.h"

#include "translationloader.h"

Translator::Translator(QObject *parent)
    : QObject(parent)
    , m_language(grassfield::i18n::systemLanguage())
{
    m_translator = grassfield::i18n::install(m_language);
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
    m_translator = grassfield::i18n::install(language, m_translator);
    emit languageChanged();
    retranslate();
}

void Translator::retranslate()
{
    if (m_engine)
        m_engine->retranslate();
}
