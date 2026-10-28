// Shared by the Grassfield.I18n QML plugin and the three apps (R5: one loader, no copies).
// English is the source language; a missing catalog simply leaves the source strings.
#pragma once

#include <QCoreApplication>
#include <QDir>
#include <QLocale>
#include <QRegularExpression>
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

// A dev session: GRASSFIELD_DEV exactly "1" and GRASSFIELD_SESSION not "1". The one run-mode predicate of ADR-0019,
// written out here until the C++ header apps/runmode.h (refactor wave 2, slice M6) reaches main; shell/lib/RunMode.js
// holds the same rule and tests/fixtures/run-mode-vectors.json the shared vectors.
inline bool devSession()
{
    return qgetenv("GRASSFIELD_DEV") == "1" && qgetenv("GRASSFIELD_SESSION") != "1";
}

// The catalogs. GRASSFIELD_TRANSLATIONS_DIR is dev plumbing (ADR-0019): honoured only in a dev session, so outside it
// the lock screen's and the polkit sheet's strings (and the apps') come only from the system catalogs, never from a
// directory the environment picks (re-review of 2b8e13a; tests/security/translations_dir.sh).
inline QString translationsDir()
{
    const QString dir = devSession() ? qEnvironmentVariable("GRASSFIELD_TRANSLATIONS_DIR") : QString();
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

// The locale whose formats dates, times and numbers use (`region.formats`, Settings > General > Language & Region). "auto" (or
// anything that is not a locale name, the contract's localeName rule): the language's own. A locale name such as "fr_CH": the
// language's words with that region's formats (macOS: the region changes the formats, never the words), i.e. the language in
// that territory when Qt has it ("en" + "fr_CH" = en_CH); else that region's own locale (Qt has no fr_US: the formats of en_US
// then come with its words).
inline QLocale formatsLocale(const QString &language, const QString &formats)
{
    static const QRegularExpression name(QRegularExpression::anchoredPattern(QStringLiteral("[a-z]{2,3}(_[A-Z][a-z]{3})?_([A-Z]{2}|[0-9]{3})")));
    QString lang = language;
    lang.replace(QLatin1Char('-'), QLatin1Char('_'));
    const QLocale words(lang.section(QLatin1Char('.'), 0, 0).section(QLatin1Char('@'), 0, 0));
    if (!name.match(formats).hasMatch())
        return words;
    const QLocale chosen(formats);
    const QLocale pair(words.language(), chosen.territory());
    return pair.language() == words.language() && pair.territory() == chosen.territory() ? pair : chosen;
}

// Call before creating the QML engine.
inline void installForApplication()
{
    install(systemLanguage());
}

} // namespace grassfield::i18n
