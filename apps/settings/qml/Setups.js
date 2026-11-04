.pragma library

// Pure logic of the Omarchy capabilities Settings shows and sets up (ADR-0045 OC-5 to OC-10): the exact commands, the parsers of
// their answers and the states the panes show. No I/O here: the panes read through the Backend (readText, readOnlyQuery,
// busQuery, hasCommand) and act through SystemService.
//   Root goes through Omarchy's floating terminal, as Omarchy's own menu does (OC-0.4), and only where no system service has a
//   polkit action of its own (OC-0.7): each id of TERMINAL is one exact argument vector of apps/settings/src/systemguard.cpp
//   isLaunch (tst_settingssetups.qml reads that file and checks every one). The pane's sheet (TerminalSetupSheet.qml) says
//   what will happen and why a terminal opens before anything starts.
//   Remote Login's switch, the disk password and the fingerprints are native (systembus.h ssh.enable, disk.passphrase,
//   fprint.*); Omarchy's terminal stays for their first install only.

const LAUNCHER = "omarchy-launch-floating-terminal-with-presentation";

// id -> the Omarchy command run alone in Omarchy's floating terminal (the argv of default/omarchy/omarchy-menu.jsonc where the
// menu has the action; hibernation and dictation's model have none there: Omarchy runs them at install or from its bar).
var TERMINAL = {
    "fingerprint-setup": "omarchy-setup-security-fingerprint",
    "fingerprint-remove": "omarchy-remove-security-fingerprint",
    "fido2-setup": "omarchy-setup-security-fido2",
    "fido2-remove": "omarchy-remove-security-fido2",
    "sshd-setup": "omarchy-setup-security-sshd",
    "drive-password": "omarchy-drive-password",
    "hibernation-setup": "omarchy-hibernation-setup",
    "hibernation-remove": "omarchy-hibernation-remove",
    "dictation-setup": "omarchy-voxtype-install",
    "dictation-remove": "omarchy-voxtype-remove"
};

// Dictation's Language Model…: Omarchy's command opens its floating terminal itself (`voxtype setup model`, whose model picker
// is interactive); wrapped in the launcher it would open two terminals.
var MODEL = ["omarchy-voxtype-model"];

// The argument vector Settings launches for a setup id, null for anything else.
function launchArgv(id) {
    if (id === "dictation-model")
        return MODEL.slice();
    if (Object.prototype.hasOwnProperty.call(TERMINAL, id))
        return [LAUNCHER, TERMINAL[id]];
    return null;
}

// The read-only queries (systemguard.cpp isReadOnlyQuery; Backend.readOnlyQuery holds them to that list in every session).
var QUERY = {
    fingerprintReader: ["omarchy-hw-fingerprint"],
    hibernation: ["omarchy-hibernation-available"],
    blockDevices: ["lsblk", "-J", "-o", "NAME,TYPE,FSTYPE,MOUNTPOINTS"],
    networkQr: ["omarchy-network-qr", "--meta"]
};

// Files read as text (read-only; never written by Settings).
var FILES = {
    // Omarchy's PAM edits (omarchy-setup-security-fingerprint, omarchy-setup-security-fido2).
    pamSudo: "/etc/pam.d/sudo",
    pamPolkit: "/etc/pam.d/polkit-1",
    pamLockFingerprint: "/etc/pam.d/omarchy-lock-fingerprint",
    // omarchy-setup-security-fido2's registration file: one per system, root's, readable by everyone (mode 644).
    fido2Keys: "/etc/fido2/fido2",
    // omarchy-setup-security-sshd writes it once a key is authorized (password logins off): Omarchy's setup has run.
    sshdHardening: "/etc/ssh/sshd_config.d/10-omarchy-hardening.conf",
    // The kernel can hibernate (omarchy-hibernation-available's and -setup's first test).
    imageSize: "/sys/power/image_size",
    // omarchy-hibernation-setup's marker, which -remove tests: the resume hook.
    resumeConf: "/etc/mkinitcpio.conf.d/omarchy_resume.conf"
};

// ---- Remote Login (OC-7) -------------------------------------------------------------------------------------------

// `sharing.state` (systembus.h sharingState): {installed, enabled (unit file state "enabled"), active}; null when not that.
function parseSharing(text) {
    let j;
    try {
        j = JSON.parse(String(text));
    } catch (e) {
        return null;
    }
    if (j === null || typeof j !== "object" || typeof j.installed !== "boolean" || typeof j.unitFileState !== "string")
        return null;
    return {installed: j.installed, enabled: j.unitFileState === "enabled", active: j.active === true};
}

// What the switch does: "native" (systemd turns sshd on and off), or "terminal" (Omarchy's first setup: it installs OpenSSH,
// opens the firewall's SSH port and authorizes a key; without it, Omarchy's firewall denies incoming connections and no key
// may log in), or "" while the state is not known. Turning off is always native once the service is there.
function remoteLoginRoute(sharing, hardened, on) {
    if (sharing === null || sharing === undefined)
        return "";
    if (!sharing.installed)
        return "terminal";
    if (!on)
        return "native";
    return hardened ? "native" : "terminal";
}

// "ssh chapdel@chapdels-laptop": the command another computer types (Omarchy's own words at the end of its setup:
// `ssh $USER@$(hostname)`). "" without a user or a host name; a name with a space or a control character is not shown.
function sshCommand(user, host) {
    const u = String(user || "");
    const h = String(host || "");
    if (u === "" || h === "" || /[\s\x00-\x1f\x7f]/.test(u + h))
        return "";
    return "ssh " + u + "@" + h;
}

// ---- Disk Encryption (OC-8) ----------------------------------------------------------------------------------------

// lsblk -J -o NAME,TYPE,FSTYPE,MOUNTPOINTS: whether the root file system lies on a LUKS device. {known, encrypted, device}:
// known false when the text is not lsblk's JSON or no device holds "/". The LUKS device is the nearest parent (or the
// device itself) whose FSTYPE is crypto_LUKS; `device` is its name ("nvme0n1p2").
function rootEncryption(text) {
    const none = {known: false, encrypted: false, device: ""};
    let j;
    try {
        j = JSON.parse(String(text));
    } catch (e) {
        return none;
    }
    if (j === null || typeof j !== "object" || !Array.isArray(j.blockdevices))
        return none;
    let found = null;
    const walk = (nodes, chain, depth) => {
        if (!Array.isArray(nodes) || depth > 16 || found !== null)
            return;
        for (const n of nodes) {
            if (n === null || typeof n !== "object")
                continue;
            const here = chain.concat([n]);
            const mounts = Array.isArray(n.mountpoints) ? n.mountpoints : [n.mountpoint];
            if (mounts.indexOf("/") >= 0) {
                found = here;
                return;
            }
            walk(n.children, here, depth + 1);
        }
    };
    walk(j.blockdevices, [], 0);
    if (found === null)
        return none;
    for (let i = found.length - 1; i >= 0; i--) {
        if (found[i].fstype === "crypto_LUKS")
            return {known: true, encrypted: true, device: typeof found[i].name === "string" ? found[i].name : ""};
    }
    return {known: true, encrypted: false, device: ""};
}

// `disk.state` (systembus.h diskState): {encrypted, device}; null when not that (UDisks2 did not answer: the page then offers
// Omarchy's terminal for the password).
function parseDisk(text) {
    let j;
    try {
        j = JSON.parse(String(text));
    } catch (e) {
        return null;
    }
    if (j === null || typeof j !== "object" || typeof j.encrypted !== "boolean")
        return null;
    return {encrypted: j.encrypted, device: typeof j.device === "string" ? j.device : ""};
}

// Change Password… opens the native sheet when UDisks2 found the root file system's LUKS device, else Omarchy's terminal.
function passwordRoute(disk) {
    return disk !== null && disk !== undefined && disk.encrypted ? "native" : "terminal";
}

// The sheet's rule (macOS's): the button acts once the current password is typed and the new one twice the same, at most 512
// characters each (cryptsetup's limit for a typed passphrase; systembus.cpp refuses anything else).
function passwordsReady(current, next, verify) {
    const c = String(current || ""), n = String(next || ""), v = String(verify || "");
    return c !== "" && n !== "" && n === v && c.length <= 512 && n.length <= 512 && c.indexOf("\u0000") < 0 && n.indexOf("\u0000") < 0;
}

// ---- Hibernation (OC-9) --------------------------------------------------------------------------------------------

// "unsupported" (the kernel cannot hibernate, or Omarchy's setup is not there), "off", "on" (Omarchy's
// omarchy-hibernation-available said yes) or "incomplete" (Omarchy's resume hook is there, but the swap is too small or
// missing: available said no).
function hibernationState(imageSizeExists, setupInstalled, resumeConfText, available) {
    if (!imageSizeExists || !setupInstalled)
        return "unsupported";
    if (available === true)
        return "on";
    return /^HOOKS\+=\(resume\)$/m.test(String(resumeConfText || "")) ? "incomplete" : "off";
}

// ---- Fingerprint & Security Key (OC-6) -----------------------------------------------------------------------------

// A PAM file's active lines that load `module` (comments dropped).
function pamUses(text, module) {
    return String(text || "").split("\n").some(line => {
        const l = line.replace(/#.*$/, "").trim();
        return l !== "" && l.split(/\s+/).indexOf(module) >= 0;
    });
}

// Where Omarchy's setups turned each one on, read from the files they edit: {lock, admin, sudo}. The fingerprint is used by
// the lock screen through Omarchy's PAM service omarchy-lock-fingerprint (`lockFingerprint`: that file exists), by
// administrator prompts (polkit-1) and by sudo; the security key by administrator prompts and sudo only.
function fingerprintUse(sudoText, polkitText, lockFingerprint) {
    return {lock: lockFingerprint === true, admin: pamUses(polkitText, "pam_fprintd.so"), sudo: pamUses(sudoText, "pam_fprintd.so")};
}

function securityKeyUse(sudoText, polkitText) {
    return {lock: false, admin: pamUses(polkitText, "pam_u2f.so"), sudo: pamUses(sudoText, "pam_u2f.so")};
}

function anyUse(use) {
    return use.lock || use.admin || use.sudo;
}
