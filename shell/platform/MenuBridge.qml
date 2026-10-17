pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.services
import "MenuBridge.js" as Logic
import "Minimized.js" as Minimized

// Global menus of applications (T1/T2, master-prompt §5.7, ADR-0008, docs/specs/menu-bridge.md).
//
// The plugin announces, per window, the DBusMenu (service, path) its client registered through
// org_kde_kwin_appmenu, with the client's pid (gfc/1 `appmenu` events). This service keeps that map, connects to
// grassfield-menu-bridge (menu/1 socket), tells it whether the plugin serves appmenu (only then does the bridge own
// com.canonical.AppMenu.Registrar), asks it to open the focused window's menu and exposes the result to the menu
// bar. Without a bridge, a plugin or a menu for the window, `menus` stays empty and the bar keeps its T0 menus.
Singleton {
    id: root

    // Bridge socket. In development only GRASSFIELD_MENU_BRIDGE_SOCKET counts (scripts/dev/shell-run.sh sets it
    // together with the private bus); in the session the default is $XDG_RUNTIME_DIR/grassfield/menu-bridge.sock.
    readonly property string socketPath: {
        const explicit = Quickshell.env("GRASSFIELD_MENU_BRIDGE_SOCKET");
        if (explicit)
            return String(explicit);
        if (Quickshell.env("GRASSFIELD_DEV") === "1")
            return "";
        const runtime = Quickshell.env("XDG_RUNTIME_DIR");
        return runtime ? String(runtime) + "/grassfield/menu-bridge.sock" : "";
    }
    // The plugin serves org_kde_kwin_appmenu: the bridge may own the registrar (apps then hide in-window menus).
    readonly property bool appmenuFeature: Capabilities.has("appmenu")
    readonly property bool connected: socket.connected
    // The bridge owns com.canonical.AppMenu.Registrar (its latest status).
    property bool registrar: false
    property bool helloSent: false

    // Hyprland window address (lowercase hex) -> {service, path, pid}, from the plugin's appmenu events.
    property var registrations: ({})
    // Window whose menus the bar shows: the focused window, kept while a shell popup holds the keyboard focus.
    property string window: ""
    // Window whose menu the bridge was asked to open, and the registration it was opened with.
    property string openedWindow: ""
    property var openedRegistration: null
    // Latest sanitized menu tree of openedWindow ([] until the bridge answers) and its revision.
    property var items: []
    property string itemsWindow: ""
    property int revision: 0
    // Top-level menus of the shown window: [{dbusId, title, enabled}]; [] means "no T1/T2 menu" (T0 stays).
    readonly property var menus: connected && itemsWindow !== "" && itemsWindow === window ? Logic.topLevel(items) : []
    // App id of `window` (the bar shows bridge menus only for the app it names).
    readonly property string windowAppId: {
        const all = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        for (let i = 0; i < all.length; i++) {
            if (Minimized.normalizeAddress(all[i].address) === root.window)
                return all[i].wayland ? all[i].wayland.appId : "";
        }
        return "";
    }
    // The open bridge menu popup (BridgeMenu registers itself; read by the menubar test hook), null if none.
    property Item popup: null

    // PopupMenu model of a menu (its children) in the latest tree; `rev` makes bindings follow new revisions.
    function popupModel(dbusId: int, rev: int): var {
        const it = rev >= 0 ? Logic.findItem(root.items, dbusId) : null;
        return it ? Logic.popupModel(it.children) : [];
    }

    function aboutToShow(dbusId: int): void {
        send(Logic.itemLine("about-to-show", root.openedWindow, dbusId));
    }

    function activate(dbusId: int): void {
        send(Logic.itemLine("activate", root.openedWindow, dbusId));
    }

    function send(line: string): void {
        if (line === "" || !socket.connected)
            return;
        socket.write(line);
        socket.flush();
    }

    function sameRegistration(a: var, b: var): bool {
        return !!a && !!b && a.service === b.service && a.path === b.path && a.pid === b.pid;
    }

    // Makes the bridge's open menu follow `window` and its registration.
    function syncOpen(): void {
        const reg = root.window !== "" ? root.registrations[root.window] : undefined;
        const wanted = reg ? root.window : "";
        if (root.openedWindow !== "" && (root.openedWindow !== wanted || !sameRegistration(root.openedRegistration, reg))) {
            send(Logic.closeLine(root.openedWindow));
            root.openedWindow = "";
            root.openedRegistration = null;
            root.items = [];
            root.itemsWindow = "";
        }
        if (wanted === "" || root.openedWindow !== "" || !socket.connected || !root.helloSent)
            return;
        const line = Logic.openLine(wanted, reg);
        if (line === "")
            return; // e.g. a plugin without the pid field: no T1/T2 menu
        send(line);
        root.openedWindow = wanted;
        root.openedRegistration = reg;
    }

    function setWindow(address: string): void {
        if (address === root.window)
            return;
        root.window = address;
        syncOpen();
    }

    // The foreign-toplevel focused window's Hyprland address, once Hyprland's window data maps it. A binding: it
    // follows the list and each window's mapping (`wayland`), which arrive asynchronously after a shell start.
    readonly property string mappedFocus: {
        const focused = Compositor.focusedToplevel;
        const mapped = focused ? Compositor.hyprlandToplevel(focused) : null;
        return mapped ? Minimized.normalizeAddress(mapped.address) : "";
    }

    onMappedFocusChanged: updateFocus()

    // Hyprland address of the focused window. Hyprland's active window is known only after its first focus event,
    // so right after a (shell) start the foreign-toplevel activated state (mappedFocus) stands in for it.
    function focusedAddress(): string {
        const top = Hyprland.activeToplevel;
        const address = top ? Minimized.normalizeAddress(top.address) : "";
        return address !== "" ? address : root.mappedFocus;
    }

    function updateFocus(): void {
        const address = focusedAddress();
        // A shell popup (menus) takes the keyboard: the bar keeps showing the app's menus meanwhile.
        if (address !== "" || !Popups.active)
            setWindow(address);
    }

    function handlePluginEvent(data: string): void {
        const ev = Logic.parseAppmenuEvent(data);
        if (!ev)
            return;
        const next = Object.assign({}, root.registrations);
        if (ev.service === "")
            delete next[ev.address];
        else
            next[ev.address] = {service: ev.service, path: ev.path, pid: ev.pid};
        root.registrations = next;
        if (ev.address === root.window || ev.address === root.openedWindow)
            syncOpen();
    }

    function sendHello(): void {
        send(Logic.helloLine(root.appmenuFeature));
        root.helloSent = true;
        syncOpen();
    }

    function handleLine(line: string): void {
        const msg = Logic.parseBridgeLine(line);
        if (!msg) {
            console.info("grassfield: menu bridge: ignored a malformed line");
            return;
        }
        switch (msg.type) {
        case "status":
            if (root.registrar !== msg.registrar)
                console.info("grassfield: menu bridge", msg.state, msg.registrar ? "(registrar owned)" : "(registrar not owned)");
            root.registrar = msg.registrar;
            break;
        case "menu":
            if (msg.window === root.openedWindow) {
                root.items = msg.items;
                root.itemsWindow = msg.window;
                root.revision = msg.revision;
            }
            break;
        case "error":
            console.info("grassfield: menu bridge:", msg.code, msg.window, msg.message);
            // The window's menu is unusable (spoofed name, app gone, unreadable layout): back to T0 for it.
            if (msg.window !== "" && msg.window === root.openedWindow && ["pid-mismatch", "no-owner", "gone", "layout-failed"].indexOf(msg.code) >= 0) {
                root.items = [];
                root.itemsWindow = "";
            }
            break;
        }
    }

    // After a shell restart the plugin knows registrations the shell missed: ask it to re-post them (FR22).
    function requery(): void {
        if (!root.appmenuFeature)
            return;
        const all = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        for (let i = 0; i < all.length; i++) {
            const call = Minimized.appmenuCall(all[i].address);
            if (call !== "")
                Hyprland.dispatch(call);
        }
    }

    onAppmenuFeatureChanged: {
        if (socket.connected)
            sendHello();
        if (appmenuFeature)
            requeryTimer.restart();
    }

    Socket {
        id: socket
        path: root.socketPath
        parser: SplitParser {
            onRead: data => root.handleLine(data)
        }
        onConnectedChanged: {
            if (connected) {
                root.helloSent = false;
                root.sendHello();
                return;
            }
            root.helloSent = false;
            root.registrar = false;
            root.openedWindow = "";
            root.openedRegistration = null;
            root.items = [];
            root.itemsWindow = "";
        }
    }

    // Connects once the capabilities handshake settled (the hello must carry the real appmenu state) and retries
    // while the bridge is not there (it starts independently, may restart).
    Timer {
        interval: 2000
        repeat: true
        triggeredOnStart: true
        running: root.socketPath !== "" && Capabilities.settled && !socket.connected
        onTriggered: socket.connected = true
    }

    Timer {
        id: requeryTimer
        interval: 500
        onTriggered: root.requery()
    }

    Connections {
        target: Hyprland

        function onActiveToplevelChanged(): void {
            root.updateFocus();
        }

        function onRawEvent(event: HyprlandEvent): void {
            if (event.name === "grassfield")
                root.handlePluginEvent(event.data);
        }
    }

    Connections {
        target: Popups

        function onActiveChanged(): void {
            if (!Popups.active)
                root.updateFocus();
        }
    }
    Component.onCompleted: updateFocus()
}
