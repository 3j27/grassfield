pragma Singleton
import QtQuick

// qs.services.ThemeIcons for the agent harness (authagent_flows.sh): no theme, so no icon; the sheet shows its lock alone.
QtObject {
    function source(name: string): url {
        return "";
    }
}
