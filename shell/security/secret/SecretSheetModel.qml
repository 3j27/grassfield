import QtQuick
import Grassfield.Ui
import "Prompter.js" as Prompter

// State of the secret sheet over one prompter/1 request (ADR-0035 D-9, step 9b; docs/specs/system-dialogs.md section 5):
// what the sheet shows and the holds of the polkit sheet's model (AuthDialogModel), the same rules and the same delays.
// Non-visual and free of Quickshell imports, so tests drive it without a socket (tests/security/tst_secretsheetmodel.qml).
//
// Never an answer of its own: the only ways out are submit() (the user's password or confirmation) and cancel(), each
// once per request; the agent sends the answer only for the request on screen (SecretAgent.respond).
//
// Who asks is the bridge's word, never the caller's (master-prompt R12): the sheet's title and its first row are
// Grassfield's own text built from `request.requester` (the role the bridge resolved from the caller's D-Bus credentials,
// and for an app the name of its desktop entry). The caller's own texts are shown under them, introduced as text sent by
// that program, in the secondary style, and for the programs that ask for others (Keyring, GnuPG, SSH: `onBehalf`) as
// another program's unverified text (spec SC3b). Its button labels are never shown (decision 9-16).
//
// A NetworkManager request (kind "nm", step 9c) is the macOS Wi-Fi alert: its title is Grassfield's sentence with the
// network's SSID as a quoted field ("The Wi-Fi network “%1” requires a WPA2 password."), under it who asked (NetworkManager),
// then the name field (enterprise), the password field, Show password, Cancel and Join. It has no caller text.
QtObject {
    id: root

    // The request on screen or held (a parsed prompt, Prompter.parseBridgeLine, plus `waited` and `arrivedAt` from the
    // agent), or null.
    property var request: null

    readonly property bool active: !!request
    readonly property string id: request ? request.id : ""
    readonly property string kind: request ? request.kind : ""
    // NetworkManager's Wi-Fi secrets (step 9c).
    readonly property bool network: kind === "nm"
    readonly property bool asksPassword: kind === "password" || network
    readonly property bool passwordNew: asksPassword && request.passwordNew === true
    readonly property bool showsStrength: passwordNew && request.strength === true
    readonly property string role: request ? request.requester.role : ""
    readonly property bool onBehalf: !!request && request.requester.onBehalf === true

    // The requester row (only the bridge fills it): the name in Grassfield's words for the fixed roles, the desktop entry's
    // name for an app; the executable's path under it for an unidentified program.
    readonly property string requesterName: requesterNameOf(role, request ? request.requester.name : "")
    readonly property string requesterPath: role === "unidentified" && request ? Prompter.flatten(request.requester.path, Prompter.CAPS.path) : ""
    // The app's theme icon name (a plain name only, the notification icons' rule), "" otherwise: the sheet then draws the
    // role's glyph.
    readonly property string appIcon: role === "app" && request ? NotificationPrefs.safeIconName(request.requester.icon) : ""
    readonly property string glyph: role === "app" ? "apps" : role === "unidentified" ? "exclamationmark-triangle" : role === "network" ? "wifi-3" : role === "disk" ? "drive" : "key"
    // Who asked, under a NetworkManager request's title (the program the bridge checked the call came from); "" otherwise.
    readonly property string requesterDetail: network ? qsTr("Requested by NetworkManager") : ""

    // The network of an nm request: its SSID (plain, a field of the title's sentence), its security, whether it asks for a
    // name (WPA2 Enterprise). The name typed (not a secret: the connection's own identity at first) and whether the
    // password is shown as typed (Show password; back to hidden for each request and whenever the fields are emptied).
    readonly property string networkSsid: network ? Prompter.flatten(request.network.ssid, Prompter.CAPS.ssid) : ""
    readonly property string networkSecurity: network ? request.network.security : ""
    readonly property bool needsIdentity: networkSecurity === "enterprise"
    property string identity: ""
    property bool showPassword: false

    // The sheet's own title, Grassfield's words: who asks, and for what.
    readonly property string title: network ? networkTitleOf(networkSecurity, networkSsid) : titleOf(role, requesterName, kind, passwordNew)
    // The line that introduces the caller's text (spec SC3b): whose text it is.
    readonly property string callerIntro: callerIntroOf(role, requesterName)
    // The caller's own text: its title, message and description (plain lines, capped by the bridge and again here).
    readonly property string callerTitle: request ? Prompter.flatten(request.texts.title, Prompter.CAPS.title) : ""
    readonly property string callerMessage: request ? Prompter.flatten(request.texts.message, Prompter.CAPS.message) : ""
    readonly property string callerDescription: request ? Prompter.flatten(request.texts.description, Prompter.CAPS.description) : ""
    readonly property string callerWarning: request ? Prompter.flatten(request.texts.warning, Prompter.CAPS.warning) : ""
    readonly property bool hasCallerText: callerTitle !== "" || callerMessage !== "" || callerDescription !== "" || callerWarning !== ""
    // The check box (its label is the caller's text, attached to its control) and its state.
    readonly property bool hasChoice: !!request && request.choice !== null
    readonly property string choiceLabel: hasChoice ? Prompter.flatten(request.choice.label, Prompter.CAPS.choice) : ""
    property bool choice: false
    // Our own message under the field (the passwords do not match, one is too long), else "".
    readonly property string error: priv.error
    // An answer to this request went out (the sheet then takes nothing more). Read from the request itself, never from a
    // flag a handler resets: bindings that follow `request` see a new request as unanswered whatever order they run in. The
    // key is its id and the agent's serial number (a bridge that restarts counts its ids from p1 again).
    readonly property bool answered: !!request && priv.answeredKey === keyOf(request)
    readonly property bool canSubmit: !!request && priv.answeredKey !== keyOf(request)

    // The same delays as the polkit sheet's (AuthDialogModel; tests/security/secret_sheets.sh checks they are equal).
    readonly property int heldGuardMs: 500
    readonly property int heldAfterUnlockMs: 1000
    readonly property int sinkLingerMaxMs: 3000
    // Timed by Timers (a monotonic clock), never by the wall clock.
    readonly property Timer unlockHold: Timer {
        interval: root.heldAfterUnlockMs
    }
    readonly property Timer clickGuard: Timer {
        interval: root.heldGuardMs
    }
    readonly property Timer afterRequest: Timer {
        interval: root.heldAfterUnlockMs
    }

    // The session was unlocked: requests shown in the next heldAfterUnlockMs are held.
    function noteUnlock(): void {
        unlockHold.restart();
    }

    // The sheet appeared: a click counts only heldGuardMs from now.
    function noteShown(): void {
        priv.shown = true;
        clickGuard.restart();
    }

    // When in doubt, no: a click before the sheet was ever noted as shown does not count either.
    function heldClickAccepted(): bool {
        return priv.shown && !clickGuard.running;
    }

    // The screen saver that covered a held sheet ended: a click counts only heldGuardMs from now.
    function noteUncovered(): void {
        clickGuard.restart();
    }

    // A sheet ended (this one, or the polkit sheet: SheetQueue.sheetEnded): one shown in the next heldAfterUnlockMs is held.
    function noteEnded(): void {
        afterRequest.restart();
    }

    function followsAnother(): bool {
        return afterRequest.running;
    }

    // Held when shown while the session is locked or the screen saver shows (`locked`), within heldAfterUnlockMs of the
    // last unlock or of the end of another sheet.
    function arrivesHeld(locked: bool): bool {
        return locked || unlockHold.running || afterRequest.running;
    }

    // What the held sheet says, with the time the request arrived. `why`: "locked", "saver", "waited" (another sheet was on
    // screen when it arrived), "queued" (right after another one), "confirm" (a confirmation: always held, decision 9-23) or
    // "unlock".
    function heldNotice(arrivedAt: var, why: string): string {
        const at = Qt.formatTime(new Date(arrivedAt), Qt.locale().timeFormat(Locale.ShortFormat));
        if (why === "locked")
            return qsTr("This request arrived at %1, while the screen was locked. Click the alert to answer it.").arg(at);
        if (why === "saver")
            return qsTr("This request arrived at %1 and waited while the screen saver was on. Click the alert to answer it.").arg(at);
        if (why === "waited")
            return qsTr("This request arrived at %1, while another one was open. Click the alert to answer it.").arg(at);
        if (why === "queued")
            return qsTr("This request arrived at %1, right after another one. Click the alert to answer it.").arg(at);
        if (why === "confirm")
            return qsTr("This request arrived at %1. Click the alert to answer it: no key answers a confirmation before that.").arg(at);
        if (why === "network")
            return qsTr("This request arrived at %1. Click the alert to type the password: nothing typed elsewhere goes into it.").arg(at);
        return qsTr("This request arrived at %1, just as the screen was unlocked. Click the alert to answer it.").arg(at);
    }

    // Grassfield's names of the requesters the bridge resolves (prompter/1: the shell names them in its own words).
    function requesterNameOf(role: string, name: string): string {
        if (role === "app") {
            const n = Prompter.flatten(name, Prompter.CAPS.name);
            return n !== "" ? n : qsTr("Unidentified program");
        }
        if (role === "keyring")
            return qsTr("Keyring");
        if (role === "gnupg")
            return qsTr("GnuPG");
        if (role === "ssh")
            return qsTr("SSH");
        if (role === "disk")
            return qsTr("Disks");
        if (role === "network")
            return qsTr("Wi-Fi");
        return role === "" ? "" : qsTr("Unidentified program");
    }

    // The Wi-Fi alert's sentence (macOS's): the SSID is a field inside Grassfield's words, never the title itself.
    function networkTitleOf(security: string, ssid: string): string {
        if (security === "wpa3")
            return qsTr("The Wi-Fi network “%1” requires a WPA3 password.").arg(ssid);
        if (security === "wep")
            return qsTr("The Wi-Fi network “%1” requires a WEP password.").arg(ssid);
        if (security === "enterprise")
            return qsTr("The Wi-Fi network “%1” requires WPA2 enterprise credentials.").arg(ssid);
        return qsTr("The Wi-Fi network “%1” requires a WPA2 password.").arg(ssid);
    }

    // Join may be pressed: a password of an acceptable length for the network (read as a length, never as text) and, for
    // enterprise, a name.
    function networkReady(passwordLength: int, identityLength: int): bool {
        return network && canSubmit && Prompter.networkLengthOk(networkSecurity, passwordLength) && (!needsIdentity || identityLength > 0);
    }

    function titleOf(role: string, name: string, kind: string, isNew: bool): string {
        if (role === "")
            return "";
        if (role === "unidentified")
            return kind === "confirm" ? qsTr("An unidentified program asks you to confirm") : isNew ? qsTr("An unidentified program asks for a new password") : qsTr("An unidentified program asks for a password");
        if (kind === "confirm")
            return qsTr("%1 asks you to confirm").arg(name);
        return isNew ? qsTr("%1 asks for a new password").arg(name) : qsTr("%1 asks for a password").arg(name);
    }

    function callerIntroOf(role: string, name: string): string {
        // A network request carries no caller text at all.
        if (role === "" || role === "network")
            return "";
        if (role === "keyring" || role === "gnupg" || role === "ssh" || role === "disk")
            return qsTr("Another program sent this message through %1. It is not verified:").arg(name);
        if (role === "app")
            return qsTr("%1 sent this message:").arg(name);
        return qsTr("The program sent this message. It is not verified:");
    }

    // What tells one request from another: its id and the serial number the agent gave it when it arrived.
    function keyOf(r: var): string {
        return r ? r.id + "#" + r.serial : "";
    }

    // The strength meter of a new password, from its length only (decision 9-17: the meter never reads the password itself,
    // so no copy of it is made for the meter): 0 empty, 1 weak (under 8), 2 fair (under 12), 3 strong.
    function strengthOf(length: int): int {
        return length <= 0 ? 0 : length < 8 ? 1 : length < 12 ? 2 : 3;
    }

    // The dialog must empty its fields (after every attempt and outcome).
    signal clearRequested
    // An answer for the agent to send (SecretAgent.respond): `ok`, the password for a password or nm request answered ok,
    // the check box's state, the name for an enterprise network (else null). The agent calls noteAnswered when it sent it (a
    // cancellation or a confirmation gives the keyboard back at once; a password sent keeps it on the agent's key sink a
    // moment: its caller often asks again at once).
    signal answerRequested(bool ok, var password, bool choice, var identity)

    component Private: QtObject {
        property string answeredKey: ""
        property bool shown: false
        property string error: ""
    }

    readonly property Private priv: Private {}

    // The user's password (a password request; for a new password, `verify` is the second field: both must be equal) or
    // confirmation (a confirm request: password null). True when the answer went out.
    function submit(password: var, verify: var): bool {
        if (!canSubmit) {
            clearRequested();
            return false;
        }
        if (network) {
            if (typeof password !== "string" || password.length === 0) {
                clearRequested();
                return false;
            }
            if (!Prompter.networkLengthOk(networkSecurity, password.length)) {
                priv.error = qsTr("A WPA2 password has 8 to 63 characters, or 64 hexadecimal digits.");
                clearRequested();
                return false;
            }
            if (Prompter.utf8Length(password) > Prompter.MAX_PASSWORD_BYTES) {
                priv.error = qsTr("This password is too long.");
                clearRequested();
                return false;
            }
            if (needsIdentity && root.identity === "") {
                priv.error = qsTr("Type your username.");
                clearRequested();
                return false;
            }
        }
        if (asksPassword && !network) {
            if (typeof password !== "string" || (password.length === 0 && !passwordNew)) {
                clearRequested();
                return false;
            }
            if (passwordNew && password !== verify) {
                priv.error = qsTr("The passwords do not match. Type the new password again in both fields.");
                clearRequested();
                return false;
            }
            if (Prompter.utf8Length(password) > Prompter.MAX_PASSWORD_BYTES) {
                priv.error = qsTr("This password is too long.");
                clearRequested();
                return false;
            }
        }
        priv.error = "";
        root.answerRequested(true, asksPassword ? password : null, root.choice, needsIdentity ? root.identity : null);
        clearRequested();
        return answered;
    }

    function cancel(): void {
        clearRequested();
        if (canSubmit)
            root.answerRequested(false, null, root.choice, null);
    }

    // The agent sent the answer: nothing more is taken for this request.
    function noteAnswered(): void {
        if (request)
            priv.answeredKey = keyOf(request);
    }

    // Whenever the fields are emptied (an attempt, a hold, the lock, the screen saver), the password is hidden again.
    onClearRequested: root.showPassword = false

    // A new request (or none): nothing typed or chosen carries over.
    onRequestChanged: {
        priv.error = "";
        if (request)
            root.choice = request.choice !== null && request.choice.chosen === true;
        root.identity = request && request.kind === "nm" ? request.network.identity : "";
        clearRequested();
    }
}
