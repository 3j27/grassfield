# Grassfield real-session test (L2), owner-run

Everything below is run by the owner. Agents install nothing and never touch your session. Verified read-only on
2026-10-20 against: Omarchy 4, Hyprland 0.56.2-2, Quickshell 0.3.1, Qt 6.11.2, SDDM 0.21.0-7.

What the packages do: `grassfield-desktop` (shell, apps, cursors, session file, two user units that nothing enables) and
`grassfield-compositor` (the Hyprland plugin, built against the installed Hyprland). They add no scriptlet, no service
that starts by itself, no D-Bus service, no file under `$HOME`. The Omarchy session is not changed: Grassfield has its own
Hyprland config (`--config /usr/share/grassfield/hypr/session.lua`) and its units only start when `GRASSFIELD_SESSION=1`.

## 0. Decision before you start: how to get into the session

The Omarchy SDDM theme has **no session picker**: it logs in the first session whose name contains "uwsm"
(`/usr/share/omarchy/default/sddm/omarchy/Main.qml:12-19`). "Grassfield" will never be chosen from that greeter.
Pick one (section 4 gives the commands):

- **A (recommended): start from a TTY.** No system file changes. Log out of Omarchy, switch to a TTY, run the one
  `uwsm start` line from `grassfield.desktop`. Back to Omarchy: log out, then reboot or use the greeter.
- **B: temporary SDDM theme with a session list.** One new file in `/etc/sddm.conf.d/`, removed afterwards. Not verified
  by me (I did not read the stock themes); if the greeter fails to draw, use a TTY (Ctrl+Alt+F3) and remove the file.
- **C: autologin into Grassfield for one boot.** Edit `/etc/sddm.conf.d/autologin.conf` (`Session=`), reboot, restore it.

## 1. Prerequisites

1. Save your work. Be on AC power. Have this file open on a phone or another machine (the screen may be unusable).
2. Check the main checkout is the code you want:
   ```bash
   cd ~/workspace/grassfieldos && git status --short && git log --oneline -1
   ```
3. All dependencies are already installed (`pacman -T` of the depends list printed nothing, exit 0): pacman will pull
   nothing new. Optional dependencies brightnessctl, localsearch, kio-extras are installed too.
4. The password prompts you will see: `sudo` for pacman (install) and the lock screen (your real password, PAM service
   `omarchy-lock-password`). **10 wrong passwords lock your account for 120 s** (`pam_faillock deny=10 unlock_time=120`,
   `/etc/pam.d/omarchy-lock-password`). The faillock counter is per user: it also blocks TTY and sudo logins. Do not
   mash the keyboard on the lock screen.

## 2. Snapshot before installing

Omarchy has one snapper config, `root` (`/etc/snapper/configs/root`; I could not run `snapper list-configs`, the guard
hook blocks it: run it yourself first if you want to confirm).

```bash
snapper list-configs
sudo snapper -c root create -c number -d "before grassfield L2"
sudo snapper -c root list | tail -3
```

(`omarchy-snapshot create` does the same for every config.) The snapshot covers the root subvolume, including
`/var/lib/pacman` and `/etc`. It does not cover `/home`: Grassfield writes there only under its own names (section 9).

## 3. Build and install

```bash
cd ~/workspace/grassfieldos/packaging/arch && makepkg -si
```

Expected: build, `check()` runs 232 compositor tests and 49 menu-bridge tests (all pass), then two packages are
installed (about 6.2 MiB and 0.9 MiB installed). Check afterwards:

```bash
pacman -Q grassfield-desktop grassfield-compositor
pacman -Qk grassfield-desktop grassfield-compositor
Hyprland --verify-config --config /usr/share/grassfield/hypr/session.lua    # must end with "config ok"
systemctl --user cat omarchy-sleep-lock.service | tail -4                     # shows the Grassfield drop-in
```

The build leaves `packaging/arch/src`, `packaging/arch/pkg` and `*.pkg.tar.zst` (git-ignored) and writes
`compositor/build/` in the checkout.

## 4. Log out, enter Grassfield, come back

**Option A (TTY).**
1. Log out of Omarchy with its own menu. The SDDM greeter appears (autologin runs once per SDDM start; `Relogin` is not set).
2. Press Ctrl+Alt+F3 and log in with your user and password.
3. Run exactly the line of the session file:
   ```bash
   uwsm start -e -D Hyprland:Grassfield -N Grassfield -C "Grassfield Desktop" -- start-hyprland -- --config /usr/share/grassfield/hypr/session.lua
   ```
4. Back to Omarchy: Grassfield menu (leaf) > Log Out. Then either `reboot` from the TTY (autologin brings the normal
   Omarchy session back) or Ctrl+Alt+F1 or F2 for the greeter and log in (it picks the "uwsm" Hyprland session).

**Option B (theme with a picker).**
```bash
printf '[Theme]\nCurrent=maldives\n' | sudo tee /etc/sddm.conf.d/zz-grassfield-test.conf
```
Log out, pick "Grassfield" in the greeter. Undo: `sudo rm /etc/sddm.conf.d/zz-grassfield-test.conf`.

**Option C (one boot).** Back up and edit the autologin file, then reboot:
```bash
sudo cp /etc/sddm.conf.d/autologin.conf ~/autologin.conf.orig
sudo sed -i 's/^Session=.*/Session=grassfield.desktop/' /etc/sddm.conf.d/autologin.conf
```
Undo (from Grassfield's terminal, SUPER+RETURN, or a TTY): `sudo cp ~/autologin.conf.orig /etc/sddm.conf.d/autologin.conf`, then reboot.

## 5. First-login checklist

Open a terminal first: **SUPER+RETURN** (`xdg-terminal-exec`). Keep it for recovery. Tick each line; note what you saw.
Gate names are the owner L2 items of `docs/STATE.md` (L3, L5, P1, P3, P5, R2, R3, bindings/gestures).

- [ ] Session comes up: menu bar, Dock, wallpaper in under ~10 s. Hyprland runs under `start-hyprland` (its watchdog,
      as in Omarchy's own session entry), so no "started without start-hyprland" banner should show; note it if one does.
- [ ] Lock: SUPER+CTRL+Q locks. A wrong password stays locked. The real password unlocks. Idle lock after 5 min.
      Use at most 2 wrong attempts.
- [ ] Idle and sleep: wait for the idle lock; then Grassfield menu > Sleep, wake: it must be locked. Closing the lid does the same.
- [ ] Polkit: run `pkexec true` in the terminal: a Grassfield dialog asks for the password; Cancel and a wrong password fail cleanly.
- [ ] Bindings: SUPER+SPACE (Search), SUPER+TAB (switcher), CTRL+UP (Overview), CTRL+LEFT/RIGHT (Spaces), CTRL+1..9,
      CTRL+F2 (focus the menu bar), CTRL+F3 (focus the Dock): both are open real-keyboard checks in `docs/STATE.md`.
- [ ] Trackpad: 3-finger swipe left/right (Space), up (Overview open), down (close), two-finger natural scroll, tap, two-finger click.
- [ ] Wi-Fi, Bluetooth, volume, brightness (Control Center and Settings). **These change real system state that survives
      into Omarchy** (NetworkManager radio, Bluetooth power, default audio device via wpctl, brightness). Put them back after.
- [ ] Multi-monitor (R3): plug an external display, mirror/extend, move windows, Dock and menu bar per output, unplug.
- [ ] Notifications: `notify-send test hello` three times, after 30 s of nothing each time. Note the delay of the first
      banner (the open "banner first-show stall" item; nested measured 100-1300 ms).
- [ ] Global menus (L5): open Files, Settings, a Qt or GTK app: the menu appears in the menu bar. Note apps that do not.
- [ ] Files, Settings, Preview: open each, browse, change a harmless setting, Space on a file in Files opens Glance.
- [ ] Log Out from the Grassfield menu returns to the greeter or TTY.

## 6. Known issues on main right now

- Search/Apps keyboard focus on two outputs: under a fix pass.
- Dock drag-out removal: under a fix pass (do not drag a pinned tile above the Dock while Search/Overview opens: it can unpin).
- Icon modes (Dark, Clear, Tinted) are not on main yet.
- Stages are off by default.
- The notification banner first-show delay is unmeasured on real hardware (you are the measurement).
- Omarchy's own shell (bar, notifications, launcher, lock) does not run inside Grassfield, by design; Omarchy keybinds
  and `udiskie` automount are not started. GTK applications keep the cursor theme already set in dconf (Grassfield does
  not write it; Qt and Hyprland get "grassfield-cursors" through the environment).
- Dock "Open at Login" writes `~/.config/autostart/<app>.desktop`, which Omarchy's session also reads. Remove the file to undo.
- Omarchy's crash-watch unit also runs in Grassfield: you may get "Process crashed ... click to diagnose with AI" banners for Grassfield
  crashes; the click does nothing in Grassfield.

## 7. Collecting logs for me

From a Grassfield terminal or a TTY, after the test (the files are in your home; look at them before sharing):

```bash
mkdir -p ~/grassfield-logs && cd ~/grassfield-logs
journalctl --user -b -u grassfield-shell      --no-pager > shell.log
journalctl --user -b -u grassfield-menu-bridge --no-pager > menu-bridge.log
journalctl --user -b -u 'wayland-wm@*'        --no-pager > compositor-unit.log
journalctl -b -p warning --no-pager > system-warnings.log
ls "$XDG_RUNTIME_DIR"/hypr/*/hyprland.log && cp "$XDG_RUNTIME_DIR"/hypr/*/hyprland.log .   # copy before reboot (tmpfs)
cp ~/.cache/hyprland/hyprlandCrashReport*.txt . 2>/dev/null                               # only after a crash
qs log -c grassfield --tail 2000 > quickshell.log
coredumpctl list --no-pager > coredumps.txt
```

Also write down: time of the problem, what you pressed, which monitor.

## 8. Recovery

**Lock stuck (cannot unlock).**
1. Wait 2 minutes if you typed 10 wrong passwords (`faillock`); `sudo faillock --user "$USER" --reset` clears it.
2. Ctrl+Alt+F3, log in. `loginctl list-sessions` lists the sessions; the Grassfield one is the graphical session
   (`loginctl session-status <id>` shows Hyprland in its process tree).
3. Restart the shell, which re-reads the lock marker and shows the lock screen again:
   `systemctl --user restart grassfield-shell.service`. Return with Ctrl+Alt+F1/F2 (the VT of the session).
   With packages older than 0.4.0-2, applications started from the Dock, Search, Apps or the desktop run inside the
   shell's unit and this restart closes them (ADR-0011 amendment); from 0.4.0-2 each runs in a scope of its own.
4. `loginctl unlock-session <id>` exists and its syntax is right, but **Grassfield does not listen for logind's Unlock
   signal** (nothing under `shell/` handles it), so it does not unlock. Do not rely on it.
5. Last resort, loses open windows: `loginctl terminate-session <id>` (the Grassfield session id from step 2), or `systemctl reboot`.
   A locked Hyprland stays locked when the shell dies by design; that is not a bug.

**Broken session (black screen, no bar).** Ctrl+Alt+F3, log in, `systemctl --user status grassfield-shell.service`,
then `systemctl --user restart grassfield-shell.service`. If the compositor itself is gone you are on the greeter or the
TTY: start Omarchy (`reboot`).

**Plugin refused.** After a Hyprland update the plugin checks the compositor hash and refuses to hook when it differs:
the session runs without titlebars/traffic lights and the global-menu protocol, and says so once. `hyprland.log` shows
the reason. Rebuild with `cd ~/workspace/grassfieldos/packaging/arch && makepkg -si`, or run without it:
`sudo pacman -Rns grassfield-compositor` (the session file skips a missing plugin).

**Cannot reach Omarchy.** `reboot` (autologin: Omarchy). If SDDM autologin points to Grassfield (option C), restore
`/etc/sddm.conf.d/autologin.conf` from the copy or the snapshot.

## 9. Uninstall

```bash
sudo pacman -Rns grassfield-desktop grassfield-compositor
```

This removes only Grassfield: every dependency is either explicitly installed or required by other packages (checked
with `pacman -Qi`). Left behind in your home (only Grassfield's own paths; remove if you want a clean state):

```bash
rm -rf ~/.config/grassfield ~/.local/state/grassfield ~/.local/share/icons/grassfield-cursors-custom
rm -rf "$XDG_RUNTIME_DIR/grassfield"   # tmpfs, gone at reboot anyway
ls ~/.config/autostart/               # delete only entries you added through the Grassfield Dock
```

Not Grassfield-only: `~/.local/share/Trash` (shared trash), Wi-Fi/Bluetooth/audio state you changed.

## 10. Rollback through the snapshot

If the system is broken (not just the session):
1. Reboot, open the Limine menu and boot the "before grassfield L2" snapshot.
2. Make it permanent: `omarchy-snapshot restore` (runs `sudo limine-snapper-restore`).

Home is not rolled back (the snapshot does not include it).
