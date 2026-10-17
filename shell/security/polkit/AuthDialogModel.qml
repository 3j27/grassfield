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

    // The active AuthFlow, or null. Properties used: message, actionId, iconName, identities,
    // selectedIdentity, isResponseRequired, inputPrompt, responseVisible, supplementaryMessage,
    // supplementaryIsError; methods submit(string), cancelAuthenticationRequest().
    property var flow: null

    // Every binding tests `flow` itself: the flow object can disappear between two updates.
    readonly property bool active: !!flow
    readonly property string message: flow ? String(flow.message || "") : ""
    readonly property string actionId: flow ? String(flow.actionId || "") : ""
    readonly property var identities: flow && flow.identities ? flow.identities : []
    readonly property var selectedIdentity: flow ? flow.selectedIdentity : null
    readonly property string identityName: identityLabel(selectedIdentity)
    readonly property bool responseRequired: !!flow && flow.isResponseRequired === true
    readonly property bool responseVisible: !!flow && flow.responseVisible === true
    readonly property string prompt: flow ? cleanPrompt(String(flow.inputPrompt || "")) : ""
    // Polkit/PAM feedback, or our own message after a failed attempt.
    readonly property string feedback: priv.error !== "" ? priv.error : (flow ? String(flow.supplementaryMessage || "") : "")
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
        return String(identity.displayName || identity.string || "");
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
