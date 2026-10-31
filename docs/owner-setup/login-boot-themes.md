# Grassfield login and boot themes (ADR-0042), owner-run

Everything below is run by the owner. The package `grassfield-login-themes` only installs two themes; it changes nothing on
screen until you run the commands here, and each one has its revert. Read the whole page once before starting, and keep it
open on a phone or another machine for the reboot.

- `/usr/share/sddm/themes/grassfield/`: the login screen in the lock screen's layout (the default Grassfield artwork, the date
  and clock, your picture or initials, the password field, Restart and Shut Down, the session button). SDDM itself checks
  the password (its own PAM service `sddm`, unchanged); the theme only draws and hands the password to SDDM.
- `/usr/share/plymouth/themes/grassfield/`: the boot screen, the Grassfield mark on the green ground with Plymouth's own
  disk-password prompt (Plymouth's `two-step` module, no script). **Esc switches to the text view at any time.**

On an Omarchy install with an encrypted disk, SDDM logs you in automatically after the disk password: you see the login
theme only after a log out. The boot theme is what you see at every start, around the disk password.

## 0. Before you start

1. A snapshot, as for the session test: [real-session.md](real-session.md), section 2.
2. Know the ways back (they do not depend on these themes):
   - login: Ctrl+Alt+F3 gives a text console where you can log in and run the revert commands;
   - boot: Esc at the disk-password screen gives Plymouth's text prompt; Limine's menu still lists Omarchy's snapshots.
3. Build the packages as in real-session.md (the same `makepkg` run builds `grassfield-login-themes`), then:
   ```bash
   sudo pacman -U grassfield-login-themes-*.pkg.tar.zst
   ```
   Nothing changes on screen yet.

## 1. The login theme (SDDM)

1. Try it first, without root, in a window of your session (SDDM's test mode: nothing logs in, nothing is sent):
   ```bash
   sddm-greeter-qt6 --test-mode --theme /usr/share/sddm/themes/grassfield
   ```
   Check: the artwork and the clock, your picture or initials, the session button reads "Grassfield (uwsm)", the field shows
   dots. The picture is the one your account settings stored with AccountsService (`/var/lib/AccountsService/icons/`) or
   one an administrator put in `/usr/share/sddm/faces/<login>.face.icon`; a `~/.face.icon` in your home is never read by
   the login screen (a file there that is not a picture could freeze it for every user), so without one of those you see
   your initials. Do not click Restart or Shut Down there (VERIFY what test mode does with them). Close the window.
2. See which file sets the current theme today:
   ```bash
   grep -rn '^Current=' /usr/lib/sddm/sddm.conf.d/ /etc/sddm.conf.d/ /etc/sddm.conf 2>/dev/null
   ```
   Among the drop-ins the last file in name order wins; `zz-grassfield-theme.conf` below sorts after all of them (Omarchy's
   `99-omarchy-login.conf`, Grassfield's `grassfield.conf`). `/etc/sddm.conf` itself is read after every drop-in and wins
   over them (as `grassfield-login-check` reads it): if the `Current=` line comes from that file, the drop-in below has no
   effect until you change or remove that line (VERIFY with `man sddm.conf` on this version).
3. Make it the current theme (one file, written by you):
   ```bash
   printf '[Theme]\nCurrent=grassfield\n' | sudo tee /etc/sddm.conf.d/zz-grassfield-theme.conf
   grassfield-login-check
   ```
   `grassfield-login-check` should print `ok: login screen (logout): Grassfield's theme selects 'Grassfield (uwsm)' first`.
4. SDDM reads its configuration when it starts: restart the computer once. Then log out (Grassfield menu > Log Out) and check:
   a wrong password once (the field empties, "Incorrect password", the field shakes), then the right one (Grassfield starts).
   Restart and Shut Down are there when SDDM allows them.

Revert:
```bash
sudo rm /etc/sddm.conf.d/zz-grassfield-theme.conf
```
then restart the computer. If the login screen is ever unusable (blank, no field): Ctrl+Alt+F3, log in on the console, run the
revert, then `sudo systemctl restart sddm` (this ends any graphical session). SDDM is expected to fall back to its own
built-in theme when this one cannot load (VERIFY on this machine: ADR-0042 section 2).

## 2. The boot theme (Plymouth)

1. See the current theme and Omarchy's way of applying one:
   ```bash
   plymouth-set-default-theme
   grep -rln 'plymouth-set-default-theme' /usr/share/omarchy ~/.local/share/omarchy 2>/dev/null
   ```
   Open the script that comes back (Omarchy's Plymouth refresh) and note the command it runs after
   `plymouth-set-default-theme` to rebuild the boot image (VERIFY: on Limine installs it is expected to be
   `sudo limine-mkinitcpio`, elsewhere `sudo mkinitcpio -P`). Use exactly that command below, written here as
   `<rebuild>`.
2. Make Grassfield's the boot theme:
   ```bash
   sudo plymouth-set-default-theme grassfield
   sudo <rebuild>
   ```
3. **The first boot with it is a test** (do it now, on AC power):
   - restart; at the disk-password screen you should see the mark on the green ground and a password field;
   - press **Esc**: Plymouth's text view appears; type the disk password there and press Return. This proves the text prompt
     works with this theme installed;
   - restart again and type the password in the graphical field this time.
   If at any boot the screen shows no field: press Esc; if nothing appears, wait (the disk password is also asked on the
   console when Plymouth is not running). If still nothing, start without Plymouth, which does not depend on any theme:
   in Limine's menu, select the entry, open its editor (VERIFY the key on this Limine version, usually `E`), add
   `plymouth.enable=0` to the kernel command line (or remove `splash`), and boot it (usually F10): the disk password is
   asked on the console. Once in, revert below. A Limine snapshot entry may use the same boot image and so the same theme
   (VERIFY), so prefer the command-line edit.
4. The prompt's text may draw in another font than Inter: the boot image carries only the fonts Plymouth's hook copies
   (VERIFY; the look of the words only).

Revert (the theme you saw in step 1, normally `omarchy`):
```bash
sudo plymouth-set-default-theme omarchy
sudo <rebuild>
```

## 3. Removing the package

Revert both themes first (sections 1 and 2, restart once), then:
```bash
sudo pacman -Rns grassfield-login-themes
```
Removing it before reverting leaves SDDM and Plymouth pointing at a missing theme: SDDM is expected to use its built-in theme
and Plymouth its text view (VERIFY), so the computer still starts, but revert first.

## What was checked before this reached you

- `tests/ci/login_themes.py`: the login theme runs no process, opens no file or address, logs nothing; it hands the typed
  password to SDDM once and empties the field before that and after a failure; the boot theme is Plymouth's `two-step` module
  (no script) with images; the package installs files and activates nothing.
- An offscreen render of the login theme with stand-ins for SDDM (the layout, "Grassfield (uwsm)" picked, a failed login
  empties the field and says so).
- **NOT VERIFIED** (needs this machine): the login theme in `sddm-greeter-qt6` (test mode and a real log out, Restart, Shut
  Down, SDDM's fallback when the theme cannot load); the boot theme with the disk password, Esc to the text prompt, the
  font, the revert.
