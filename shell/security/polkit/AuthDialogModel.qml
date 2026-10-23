import QtQuick

// State of the authorization dialog over one polkit AuthFlow (Quickshell.Services.Polkit).
// Non-visual and free of Quickshell imports so tests drive it with a mock flow
// (tests/security/tst_authdialogmodel.qml).
//
// Never auto-approve: the only call that answers polkit is submit(), and only with a non-empty
// password typed by the user while polkit asks for a response. Nothing here calls submit() on
// its own, and cancel() is always available.
QtObject {
    id: root

    // The active AuthFlow, or null. Properties used: message, actionId, iconName (sanitized), identities,
    // selectedIdentity, isResponseRequired, inputPrompt, responseVisible, supplementaryMessage,
    // supplementaryIsError; methods submit(string), cancelAuthenticationRequest().
    property var flow: null

    // Length caps of the requester/polkit strings once flattened to one line (the dialog also caps
    // their rendered lines): a long or multi-line message cannot push the action ID and the buttons
    // away, nor draw a fake "Action:" line of its own.
    readonly property int maxMessageLength: 400
    readonly property int maxDetailLength: 200

    // Every binding tests `flow` itself: the flow object can disappear between two updates.
    readonly property bool active: !!flow
    readonly property string message: flow ? plainLine(flow.message, maxMessageLength) : ""
    readonly property string actionId: flow ? plainLine(flow.actionId, maxDetailLength) : ""
    // The action's theme icon (polkit `icon_name` of the root-installed .policy file, AuthFlow.iconName), shown with a lock
    // badge (D-4: macOS shows an icon for the request). It describes the action, not the program that asked: Quickshell
    // 0.3.1's AuthFlow exposes no subject, process or command line; the message (pkexec names the program there), the
    // action ID and this icon are all it offers. Only a plain theme icon name is accepted (no path, no URL), else "".
    readonly property string iconName: flow ? safeIconName(flow.iconName) : ""
    readonly property var identities: flow && flow.identities ? flow.identities : []
    readonly property var selectedIdentity: flow ? flow.selectedIdentity : null
    readonly property string identityName: identityLabel(selectedIdentity)
    readonly property bool responseRequired: !!flow && flow.isResponseRequired === true
    readonly property bool responseVisible: !!flow && flow.responseVisible === true
    readonly property string prompt: flow ? cleanPrompt(plainLine(flow.inputPrompt, maxDetailLength)) : ""
    // Polkit/PAM feedback, or our own message after a failed attempt.
    readonly property string feedback: priv.error !== "" ? priv.error : (flow ? plainLine(flow.supplementaryMessage, maxDetailLength) : "")
    readonly property bool feedbackIsError: priv.error !== "" || (!!flow && flow.supplementaryIsError === true)
    // An answer was sent and polkit has not asked again yet.
    readonly property bool submitted: priv.submitted
    readonly property bool canSubmit: responseRequired && !priv.submitted

    // The dialog must empty its password field (after every attempt and outcome).
    signal clearRequested
    // A wrong password: shake.
    signal failed

    component Private: QtObject {
        property bool submitted: false
        property string error: ""
    }

    readonly property Private priv: Private {}

    function identityLabel(identity: var): string {
        if (!identity)
            return "";
        return plainLine(identity.displayName || identity.string, maxDetailLength);
    }

    // Untrusted text as one plain line: C0/C1 control characters (newlines, tabs, escapes) and
    // line/paragraph separators become spaces, bidirectional overrides/isolates and marks are
    // removed (no reordered or spoofed text), whitespace runs collapse, and the result is capped
    // at maxLength characters with an ellipsis.
    function plainLine(text: var, maxLength: int): string {
        let t = String(text === undefined || text === null ? "" : text);
        t = t.replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g, " ");
        t = t.replace(/[\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, "");
        t = t.replace(/\s+/g, " ").trim();
        if (maxLength > 0 && t.length > maxLength)
            t = t.slice(0, maxLength - 1).trim() + "\u2026";
        return t;
    }

    // A theme icon name (letters, digits, ".", "_", "-"; 1 to 128 characters), else "".
    function safeIconName(name: var): string {
        const s = String(name === undefined || name === null ? "" : name);
        return /^[A-Za-z0-9._-]{1,128}$/.test(s) ? s : "";
    }

    // "Password: " → "Password"
    function cleanPrompt(text: string): string {
        return text.replace(/[:\s]+$/, "");
    }

    function submit(password: string): bool {
        if (!active || !canSubmit || password.length === 0) {
            clearRequested();
            return false;
        }
        priv.submitted = true;
        priv.error = "";
        clearRequested();
        flow.submit(password);
        return true;
    }

    function cancel(): void {
        clearRequested();
        priv.submitted = false;
        priv.error = "";
        if (active)
            flow.cancelAuthenticationRequest();
    }

    function selectIdentity(identity: var): void {
        if (active && identity && !priv.submitted)
            flow.selectedIdentity = identity;
    }

    onFlowChanged: {
        priv.submitted = false;
        priv.error = "";
        clearRequested();
    }

    readonly property Connections flowConnections: Connections {
        target: root.flow ? root.flow : null
        ignoreUnknownSignals: true

        function onIsResponseRequiredChanged(): void {
            if (root.flow && root.flow.isResponseRequired)
                root.priv.submitted = false;
        }

        function onAuthenticationFailed(): void {
            root.priv.submitted = false;
            root.priv.error = qsTr("Incorrect password. Try again.");
            root.clearRequested();
            root.failed();
        }

        function onAuthenticationSucceeded(): void {
            root.priv.submitted = false;
            root.clearRequested();
        }

        function onAuthenticationRequestCancelled(): void {
            root.priv.submitted = false;
            root.clearRequested();
        }
    }
}
