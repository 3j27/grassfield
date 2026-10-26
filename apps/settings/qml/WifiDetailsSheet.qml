pragma ComponentBehavior: Bound
import QtQuick
import Grassfield.Ui
import "System.js" as System

// Wi-Fi > Details…: the current network as NetworkManager has it (macOS 27 shows a sheet with its addresses and Forget This
// Network…): the band, the link rate, the security, the IPv4 address, subnet mask and router, the name servers, the IPv6
// address and the hardware address, read-only. `device` is the Wi-Fi device of `net.state` (System.parseNetState).
Sheet {
    id: root

    property var net: null
    property var device: null

    signal forgetRequested(var net)

    readonly property string ip4: root.device && root.device.ip4.length > 0 ? root.device.ip4[0] : ""
    readonly property string ip6: root.device && root.device.ip6.length > 0 ? root.device.ip6[0] : ""

    title: root.net ? root.net.label : ""
    confirmText: qsTr("OK")
    showCancel: false

    function openFor(net: var, device: var): void {
        root.net = net;
        root.device = device;
        root.open();
    }

    // "a.b.c.d/n" or "a::b/n" without its prefix length.
    function address(withPrefix: string): string {
        return withPrefix.split("/")[0];
    }

    SettingsGroup {
        Repeater {
            model: [
                {title: qsTr("Wi-Fi band"), value: root.device ? System.wifiBand(root.device.frequency) : ""},
                {title: qsTr("Link rate"), value: root.device && root.device.bitrate > 0 ? qsTr("%1 Mbit/s").arg(Math.round(root.device.bitrate / 1000)) : ""},
                {title: qsTr("Security"), value: root.net ? (root.net.security !== "" ? root.net.security : qsTr("None")) : ""},
                {title: qsTr("IP address"), value: root.address(root.ip4)},
                {title: qsTr("Subnet mask"), value: root.ip4 !== "" ? System.subnetMask(root.ip4.split("/")[1]) : ""},
                {title: qsTr("Router"), value: root.device ? root.device.router : ""},
                {title: qsTr("DNS servers"), value: root.device ? root.device.dns.join(", ") : ""},
                {title: qsTr("IPv6 address"), value: root.address(root.ip6)},
                {title: qsTr("MAC address"), value: root.device ? root.device.mac : ""}
            ].filter(r => r.value !== "")

            SettingsRow {
                required property var modelData
                title: modelData.title
                valueText: modelData.value
            }
        }
    }

    Button {
        push: true
        text: qsTr("Forget This Network…")
        onClicked: {
            root.close();
            root.forgetRequested(root.net);
        }
    }
}
