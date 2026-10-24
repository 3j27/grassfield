// QML plugin of Grassfield.I18n. It installs the translation catalog in initializeEngine(), which runs on the
// engine's (GUI) thread when the module is imported, before any binding of the engine is evaluated. The same moment
// applies the shell's icon search policy (iconsearchpaths.h): only grassfield-shell imports this module, and the policy
// must be in place before any icon lookup.
#include <QtQml/qqmlextensionplugin.h>
#include <QtQml/qqmlengine.h>

#include "iconsearchpaths.h"
#include "translator.h"

extern void qml_register_types_Grassfield_I18n();

class GrassfieldI18nPlugin : public QQmlEngineExtensionPlugin
{
    Q_OBJECT
    Q_PLUGIN_METADATA(IID QQmlEngineExtensionInterface_iid)
public:
    explicit GrassfieldI18nPlugin(QObject *parent = nullptr)
        : QQmlEngineExtensionPlugin(parent)
    {
        volatile auto registration = &qml_register_types_Grassfield_I18n;
        Q_UNUSED(registration);
    }

    void initializeEngine(QQmlEngine *, const char *) override
    {
        GrassfieldIconPolicy::restrictToSystemDirectories();
        Translator::installCatalog();
    }
};

#include "plugin.moc"
