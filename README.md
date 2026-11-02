# Grassfield

A polished, familiar desktop for Omarchy 4, delivered as **Grassfield Desktop**: an add-on Hyprland session installed
next to an unmodified Omarchy system ("built for Omarchy", "based on Arch Linux"). You choose Grassfield or Omarchy at
login; nothing of Omarchy is changed. **Grassfield OS** (an ISO and installer) comes after the desktop beta.

Status: pre-release, private repository. Current state and verified facts: [`docs/STATE.md`](docs/STATE.md).
Project brief: [`docs/master-prompt.md`](docs/master-prompt.md). Decisions: [`docs/decisions/`](docs/decisions/).
Independent audit of the 1.0 baseline: [`docs/audits/final-1.0/`](docs/audits/final-1.0/).

## What it is

- A Hyprland session (Lua config) with a menu bar on every display, one Dock that follows the display you use,
  Overview, Search, Quick Settings, Notifications, lock screen, polkit agent and idle handling, all drawn by one
  Quickshell instance (`grassfield-shell`, a systemd user unit that only runs inside the Grassfield session).
- Native apps on one Qt Quick design system: Settings, Files (on KDE KIO), Preview and a wallpaper tool.
- A global menu: a bridge exports the menus of Qt, KDE and Chromium apps to the menu bar.
- An optional compositor plugin (`grassfield-compositor`): titlebars, real minimize, window tiling preview and
  Stage-style layouts. Without it the shell runs in a reduced mode and tells you so.
- English and French, Dark and Light, a material with adjustable transparency, Reduce Motion, Increase Contrast.

## Install (Arch Linux with Omarchy 4)

Requirements: Omarchy 4, Hyprland 0.56.x, Quickshell 0.3.x, Qt 6.11. The packages never pin Hyprland to one version;
the plugin is built against the Hyprland you have and is rebuilt after a Hyprland update
(`grassfield-compositor-rebuild`).

```bash
cd packaging/arch && makepkg -si
```

This builds and installs `grassfield-desktop`, `grassfield-compositor` and `grassfield-icons`. `grassfield-desktop` depends
on `grassfield-keyring` (the keys of Grassfield's package repository, ADR-0033), built by `grassfieldhq/grassfield-packages`:
until that repository is published, install it first from there (`cd keyring && makepkg -si`). Then log out and choose
Grassfield (the login drop-in starts it; `grassfield-login set omarchy` goes back). The step-by-step guide with
checks and recovery is [`docs/owner-setup/real-session.md`](docs/owner-setup/real-session.md); take a snapshot first.
Nothing runs as root, no service starts by itself, no file is written under `$HOME` by the install.

## Uninstall

```bash
sudo pacman -Rns grassfield-login-themes grassfield-desktop grassfield-wallpapers grassfield-compositor grassfield-icons
```

If you made Grassfield's login or boot theme the current one, revert it first
([`docs/owner-setup/login-boot-themes.md`](docs/owner-setup/login-boot-themes.md), section 3).

Your own data stays and can be removed by hand: `~/.config/grassfield`, `~/.local/state/grassfield`,
`~/.local/share/icons/grassfield-cursors-custom` (section 9 of the guide above). Omarchy keeps working untouched.

## Architecture

| Path | What |
|---|---|
| `config/hypr/` | Grassfield Hyprland session (Lua): `session.lua` (real session), `dev.lua` (nested dev session) |
| `shell/` | `grassfield-shell`: menu bar, Dock, Overview, Search, Quick Settings, notifications, lock, polkit, idle |
| `ui/` | `Grassfield.Ui` QML design system: tokens, material, components |
| `apps/` | Settings, Files, Preview, wallpaper tool |
| `bridges/` | `grassfield-menu-bridge`: global menu (DBusMenu and appmenu) and app badges |
| `compositor/` | `grassfield-compositor`, optional C++ Hyprland plugin |
| `packaging/` | Arch package, systemd user units, session files, dconf, fontconfig, licences |
| `branding/` | Grassfield's own icons and artwork (see `branding/LICENSES.md`) |
| `docs/specs/`, `docs/decisions/` | Per-module specifications and architecture decision records |

The shell talks to the compositor plugin over a small versioned protocol and works without it. The lock screen is a
Wayland session lock held by the compositor, so killing the shell never unlocks the screen. Security modules
(`shell/security/`) use only the session-lock protocol, PAM and the Quickshell polkit service.

## Known limits

- Pre-release. Several gates need the owner's real hardware (suspend cycles, display hotplug, a multi-day soak, a
  hardware matrix); see the gate table in `docs/master-prompt.md` and the open items in the audit.
- After an update, a running session keeps the old compositor plugin until you log out. The shell has a "Log out to finish
  updating" notice for that, but it works only once the release build ships `/usr/share/grassfield/VERSION` and the plugin
  reports its version (not merged yet): until then nothing is announced.
- Settings > Mouse, Trackpad and Keyboard apply a choice through a reload of the session configuration (ADR-0031
  amendment); not yet verified on real hardware.
- Fonts requested by name that are not installed fall back to Liberation Sans, not Inter.
- Omarchy's own shell (bar, launcher, lock) does not run inside Grassfield, by design.
- The visual identity is close to macOS and carries trade-dress risk; the repository stays private until the legal
  review. Not affiliated with Apple, Arch Linux or Omarchy. No Apple assets are used.

## Development (nested only)

Requirements as above plus `cmake ninja just qt6-tools`.

```bash
just check          # Lua config validation, qmllint, i18n, inventory, secret scan
just test           # offscreen unit tests and logic tests
just nested-up      # nested Hyprland + grassfield-shell, state in .dev/
just shot NAME      # screenshot of the 1920x1080 reference output to .dev/shots/NAME.png
just nested-down
```

Never run the shell or the plugin against your real session while developing; see `docs/master-prompt.md` section 7.
Every gate run can leave a dated report: `scripts/dev/gate-run.sh` and `just gate-archive`
([`docs/testing/README.md`](docs/testing/README.md)).

## License

Grassfield's own code is MIT, see [`LICENSE`](LICENSE) (decision ADR-0005). Third-party components, their licences
and the open legal questions are in [`THIRD_PARTY.md`](THIRD_PARTY.md); the licence texts shipped with the packages are in
`packaging/licenses/`. Icons and wallpapers: [`branding/LICENSES.md`](branding/LICENSES.md).
