# Security policy

## Reporting a vulnerability

Report privately through GitHub Security Advisories: open the repository's **Security** tab and choose **Report a
vulnerability**. Do not open a public issue, pull request or discussion for a vulnerability, and do not post details elsewhere
until a fix is released.

Include what you can: the Grassfield version (`pacman -Q grassfield-desktop`), the Omarchy and Hyprland versions, what an attacker
needs (local user, another local process, network, physical access), the steps to reproduce, and the impact you see. A proof of
concept helps; please do not run it against systems you do not own.

## What is in scope

Reports about any of these are treated as security issues:

- the **lock screen** (`shell/security/lock/`): any way to see the desktop, bypass the password, or leave the session unlocked
  after a crash or a restart of the shell;
- the **polkit agent** and the **secret sheets** (`shell/security/`, `grassfield-prompter`): spoofed or mislabeled requests,
  leaking or logging a password or PIN, a sheet answering for another requester;
- the **update helper** and its **polkit action** and rule (`packaging/pacman/`: `org.grassfield.packages.policy`,
  `49-grassfield-update.rules`), including anything that lets a non-administrator run privileged code or change the channel;
- the **install script** (`packaging/install/`, served from `packages.grassfield.site`) and the checksum and key it checks;
- **package signing**: the signing key, the keyring package (`grassfield-keyring`), the repository metadata, and the way pacman is
  told to trust them;
- the systemd user units and helpers that handle credentials.

Out of scope: vulnerabilities in Omarchy, Hyprland, Quickshell, Qt, KDE or Arch Linux themselves (report them upstream; tell us if
Grassfield makes one worse), visual glitches without a security effect, and denial of service that needs an already compromised
account.

## Supported versions

Only the current beta (the 1.0.0 release candidates on the `beta` channel of `packages.grassfield.site`) gets fixes. There is no
stable channel yet. Update (Settings > General > Software Update) before reporting.

## What to expect

Grassfield is a small project and this is best effort: we read every report, answer as soon as we can, and fix confirmed issues in
scope as quickly as the severity and our time allow. We do not promise a response time. We credit the reporter in the advisory
unless you prefer to stay anonymous, and we ask for coordinated disclosure: please give us a reasonable time to fix the issue
before you publish.

If GitHub's private reporting is unavailable to you, write to chapdel.kamga2@gmail.com with the word "security" in the subject and
no technical details in the first message; we will arrange a private channel.
