## What and why

<!-- One change per pull request. Link the issue (Fixes #...) and the spec or ADR it follows. -->

## Checks run

<!-- Paste the result lines, or say what you could not run and why. -->

- [ ] `just check-quick` (or `just check` if `compositor/` changed)
- [ ] `just test`
- [ ] Nested or visual tests that this change touches (name them):
- [ ] New test files are listed in `tests/inventory.json`
- [ ] Visible strings use `qsTr()` / `tr()`; `just i18n-update` run if strings changed
- [ ] Commits follow Conventional Commits; external contributors: every commit has `Signed-off-by` (`git commit -s`)

## Screenshots (user-interface changes)

<!-- Before and after, at scale 1.25 and at scale 1, in light and in dark: four pairs. Say "no UI change" if none. -->

| | Light | Dark |
|---|---|---|
| Scale 1.25 | | |
| Scale 1 | | |

## Design rules

- [ ] Tokens only: no literal radius, size, opacity, duration or colour in QML
- [ ] Follows the macOS model; no Apple asset and no Apple trademark in the UI
- [ ] No new service, dependency or directory (or an ADR is included and a maintainer agreed)

## Security modules

- [ ] This pull request touches `shell/security/`, the prompter, the update helper, polkit policy or rules, the install script or
      package signing. **If checked, say so in the title: it needs the extra review described in CONTRIBUTING.md.**
