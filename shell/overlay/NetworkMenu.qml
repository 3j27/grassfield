import QtQuick
import Grassfield.Ui
import qs.services

// Network status menu: Wi-Fi power and the current connection (read from NetworkManager).
PopupMenu {

    accessibleName: qsTr("Network")
    currentIndex: -1

    model: [
        {id: "wifi", text: Connectivity.wifiEnabled ? qsTr("Turn Wi-Fi Off") : qsTr("Turn Wi-Fi On"), enabled: Connectivity.available && Connectivity.wifiDevice !== null},
        {separator: true},
        {id: "state", text: Connectivity.available ? Connectivity.description : qsTr("NetworkManager is not available"), enabled: false},
        {id: "wired", text: qsTr("Ethernet: connected"), enabled: false, visible: Connectivity.wiredConnected}
    ].filter(i => i.visible !== false)

    onCloseRequested: Popups.close()

    onActivated: item => {
        if (item.id === "wifi")
            Connectivity.setWifiEnabled(!Connectivity.wifiEnabled);
        Popups.close();
    }
}
