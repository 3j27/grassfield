// Shared by the Grassfield.I18n QML plugin and the three apps (R5: one loader, no copies).
// English is the source language; a missing catalog simply leaves the source strings.
#pragma once

#include <QCoreApplication>
#include <QDir>
#include <QLocale>
#include <QString>
#include <QTranslator>

namespace grassfield::i18n {

// GRASSFIELD_LANG (dev override) wins; otherwise the system locale (LC_ALL/LC_MESSAGES/LANG).
inline QString systemLanguage()
{
    const QString forced = qEnvironmentVariable("GRASSFIELD_LANG");
    if (!forced.isEmpty())
        return forced;
    const QString name = QLocale::system().name(); // "fr_FR", or "C" when unset
    return name == QLatin1String("C") ? QStringLiteral("en") : name;
}

inline QString translationsDir()
{
    const QString dir = qEnvironmentVariable("GRASSFIELD_TRANSLATIONS_DIR");
    return dir.isEmpty() ? QStringLiteral("/usr/share/grassfield/translations") : dir;
}

// Loads grassfield_<lang>.qm ("fr_FR" falls back to "fr") and installs it on the application.
// Returns the translator now installed (owned by the application), or nullptr for English / no catalog.
inline QTranslator *install(const QString &language, QTranslator *previous = nullptr)
{
    if (previous) {
        QCoreApplication::removeTranslator(previous);
        delete previous;
    }
    QString lang = language;
    lang.replace(QLatin1Char('-'), QLatin1Char('_'));
    lang = lang.section(QLatin1Char('.'), 0, 0).section(QLatin1Char('@'), 0, 0);
    if (lang.isEmpty())
        return nullptr;
    // Dates, numbers and Qt.locale() follow the UI language too (also with the GRASSFIELD_LANG override).
    QLocale::setDefault(QLocale(lang));
    if (lang.startsWith(QLatin1String("en")))
        return nullptr;

    const QDir dir(translationsDir());
    auto *translator = new QTranslator(QCoreApplication::instance());
    for (const QString &candidate : {lang, lang.section(QLatin1Char('_'), 0, 0)}) {
        if (translator->load(dir.absoluteFilePath(QStringLiteral("grassfield_%1.qm").arg(candidate)))) {
            QCoreApplication::installTranslator(translator);
            return translator;
        }
    }
    delete translator;
    return nullptr;
}

// Call before creating the QML engine.
inline void installForApplication()
{
    install(systemLanguage());
}

} // namespace grassfield::i18n
