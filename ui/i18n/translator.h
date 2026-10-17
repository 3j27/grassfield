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

public:
    explicit Translator(QObject *parent = nullptr);
    static Translator *create(QQmlEngine *engine, QJSEngine *);

    QString language() const { return m_language; }
    void setLanguage(const QString &language);
    // Re-evaluates all qsTr() bindings (also callable after external catalog changes).
    Q_INVOKABLE void retranslate();

signals:
    void languageChanged();

private:
    QString m_language;
    QTranslator *m_translator = nullptr;
    QPointer<QQmlEngine> m_engine;
};
