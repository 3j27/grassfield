# Contributing to Grassfield

Thank you for helping. Grassfield is a desktop session for Omarchy 4 (Hyprland with a Lua config, one Quickshell shell, Qt Quick
apps, an optional compositor plugin). Issues and pull requests are welcome from anyone. Read this page once; it is short.

By taking part you agree to the [Code of Conduct](CODE_OF_CONDUCT.md). Security problems go to [SECURITY.md](SECURITY.md), never to
a public issue.

## Before you start

- **Small and focused wins.** One pull request, one change. For anything larger than a bug fix (a new module, a service, a
  dependency, a new top-level directory, a change that crosses modules), open an issue first. Such changes need an architecture
  decision record (ADR) in `docs/decisions/` before code; the existing ADRs show the format.
- **Look for the answer already written.** `docs/specs/` holds one specification per module and `docs/decisions/` the reasons for
  the choices. If a spec and your idea disagree, change the spec in the same pull request and say why.
- **Versions.** Hyprland 0.56.x (its config is Lua, `hl.*`; never write hyprlang `.conf`), Quickshell 0.3.x, Qt 6, Omarchy 4.x.
  Verify an option or an API against the version you have installed, not from memory. The Quickshell API is in
  `/usr/lib/qt6/qml/Quickshell/**/*.qmltypes`, the Hyprland plugin headers in `/usr/include/hyprland`.

## Build and run

Needs an Arch Linux system with Omarchy 4 (see the README), plus `cmake ninja just qt6-tools` and the packages named in
`packaging/arch/PKGBUILD`.

```bash
just --list           # every recipe, with its description
just check            # all offline checks (see below)
just test             # offscreen unit and logic tests
```

### The nested session (how you try a change)

Never run the shell or the plugin against your real session while developing. The development session is a Hyprland instance
nested in a window, with its own state in `.dev/` (git-ignored):

```bash
just nested-up        # nested Hyprland + grassfield-shell, state and logs in .dev/
just shell-run        # restart only the shell inside it after a QML change
just plugin-build     # build the compositor plugin against your installed Hyprland headers
just plugin-load      # load it into the nested instance (just plugin-unload removes it)
just shot NAME        # screenshot of the 1920x1080 reference output to .dev/shots/NAME.png
just scenario NAME    # a scripted scenario from tests/visual/scenarios/
just nested-down
```

`scripts/nestctl <hyprctl args>` is the only supported way to talk to the nested compositor; it refuses the instance you are
sitting in. Do not send commands to your own session's compositor from a script or a test.

### Run mode

One rule decides what a process may do (ADR-0019): it is a development process only when `GRASSFIELD_DEV=1` and
`GRASSFIELD_SESSION` is not `1`. Test hooks, fixtures and private state exist only there, so a leaked variable never changes a
real session. The scripts under `scripts/dev/` set this up for you, and `tests/ci/run_mode.py` checks that the rule is defined in
one place.

### Installing from your tree

`cd packaging/arch && makepkg -si` builds and installs the packages. Take a snapshot first and read
`docs/owner-setup/real-session.md`. Nothing in Grassfield runs as root, and packages never pin an exact Hyprland version.

## Checks to run before you open a pull request

```bash
just check-quick      # every offline check except clang-tidy (use `just check` when you touched compositor/)
just test             # QML and C++ unit tests, logic tests
```

`just check` covers: Hyprland Lua config validation (`Hyprland --verify-config`), QML lint (zero warnings), the token and
literal rules, i18n completeness, the test inventory, licence notices, and a secret scan. A new test file is listed in
`tests/inventory.json` (see `docs/testing/README.md`). Tests that need the nested session or screen captures are listed in the
same file; run the ones your change touches and say which in the pull request.

For a user-interface change, also attach screenshots (see the pull request template): scale 1.25 and 1x, light and dark.

## Commits

[Conventional Commits](https://www.conventionalcommits.org/): `type(scope): subject`, in English, no trailing period. Types in
use: `feat`, `fix`, `docs`, `test`, `build`, `chore`, `refactor`, `perf`. Keep commits small; the body says why, not what. Do not
rewrite the history of a branch someone has already reviewed.

## Design rules

These come from the specs (`docs/specs/ui.md`, ADR-0002, ADR-0003, ADR-0024, ADR-0039) and are partly enforced by `just check`.

- **macOS coherence.** Layout, proportions, radii, states and motion follow macOS 27; the glass material follows the macOS 26
  approach (per-surface translucency, adaptive tint, device-pixel rims). When a screen has no precedent here, ask how macOS does
  it and copy that model. A pull request that invents a new interaction needs a reason the macOS model does not cover.
- **Tokens only.** Radii, font sizes, opacities, scales, geometry, durations and colours come from `ui/tokens/tokens.json` through
  `Grassfield.Ui`, never as literals in QML. `just check-literals` fails on a literal. Every token names its source.
- **Blur is real.** Use the compositor's background effect or layer rules. Do not fake blur with a screenshot or an image.
- **No Apple assets, no Apple names.** No Apple icon, font, wallpaper, sound or artwork, traced or copied, and no Apple trademark
  in a user-visible string. `tests/ci/ui_names.py` checks the strings; ADR-0003 explains the line. Our own
  icons are drawn by hand (`branding/LICENSES.md` lists the provenance of every asset).
- **Every visible string is translatable** (`qsTr()` in QML, `tr()` in C++); English is the source, French the first translation.
  After changing strings run `just i18n-update` and complete the French catalog.
- **Accessibility and motion.** Honour Reduce Motion and Increase Contrast; contrast roles are tested (`just check-contrast`).
- **No new service, dependency, language or directory** without a need in the current work and, if it crosses modules, an ADR. A
  new dependency needs a maintainer's agreement before it enters the packaging.

Some comments, specs and ADRs cite the maintainers' private working notes (a "master prompt", audits, a project log). They are
history, not rules you must read: the decisions they led to are written in the ADRs and specs.

## Security modules get an extra review

`shell/security/` holds the lock screen (`WlSessionLock` and `PamContext("omarchy-lock-password")`), the polkit agent (the
Quickshell Polkit service) and the secret sheets fed by `grassfield-prompter` (system prompts, network passwords, NetworkManager
secrets, Bluetooth pairing; ADR-0010, ADR-0035). The rule: only those, nothing else, and any failure leaves the screen locked.

A pull request that touches `shell/security/`, the prompter, the update helper, the polkit policy and rules in `packaging/pacman/`,
the install script (`packaging/install/`) or package signing is flagged in its description and gets a second, dedicated review by
a maintainer before merge. Expect more questions and slower merges there; that is the point. Their tests are in `tests/security/`.

## Pull requests

Fill in the template. A reviewer looks at the checks you ran, the screenshots, and whether the change keeps to the rules above.
Keep the discussion on the pull request; a maintainer merges once checks and review pass.

## Licensing of contributions

Grassfield's code is MIT (`LICENSE`, ADR-0005). By submitting a contribution you license it under the same terms (inbound =
outbound) and confirm you have the right to do so. Artwork under `branding/` is CC-BY-SA-4.0 except the Grassfield logo
(`branding/LICENSES.md`); third-party material and its licences are listed in `THIRD_PARTY.md`.

Grassfield uses plain inbound = outbound licensing: there is no CLA, no copyright assignment and no sign-off line. Do not submit
anything copied from Apple software, from a theme or icon pack with an incompatible licence, or generated output whose terms you
have not read.
