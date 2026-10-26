#pragma once

#include <QObject>
#include <QPointer>
#include <QQmlEngine>
#include <QtQml/qqmlregistration.h>
#include <QString>
#include <QTranslator>

// Singleton `Translator` of the QML module Grassfield.I18n: loads the language catalog on first use and
// re-evaluates every qsTr() binding of the engine on change.
class Translator : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(QString language READ language WRITE setLanguage NOTIFY languageChanged FINAL)
    // `region.formats`: "auto" (the language's formats) or a locale name ("fr_CH"). It becomes the process's default locale,
    // so Qt.locale() everywhere formats with it; the words stay the language's.
    Q_PROPERTY(QString formats READ formats WRITE setFormats NOTIFY formatsChanged FINAL)

public:
    // The factory is the only way QML gets the singleton (the constructor is private on purpose: with a
    // public default constructor QML would use it, never call create(), and the instance would have no
    // engine to retranslate).
    static Translator *create(QQmlEngine *engine, QJSEngine *);
    // Installs the process-wide catalog (GRASSFIELD_LANG or the system locale) once. Called by the plugin's
    // initializeEngine(), on the engine's thread, before any binding of the engine is evaluated.
    static void installCatalog();

    QString language() const { return m_language; }
    void setLanguage(const QString &language);
    QString formats() const { return m_formats; }
    void setFormats(const QString &formats);
    // Re-evaluates all qsTr() bindings (also callable after external catalog changes).
    Q_INVOKABLE void retranslate();

signals:
    void languageChanged();
    void formatsChanged();

private:
    explicit Translator(QObject *parent = nullptr);

    QString m_language;
    QString m_formats = QStringLiteral("auto");
    QTranslator *m_translator = nullptr;
    QPointer<QQmlEngine> m_engine;
};
