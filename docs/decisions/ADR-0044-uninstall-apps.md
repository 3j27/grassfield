# ADR-0044 — Uninstalling apps from the launcher and Files (amends ADR-0037 b.1 "What the Store removes")

Status: Proposed (2026-11-04), applied provisionally on `feat/uninstall-apps`. Cross-module (Store, launcher, Files, the root
helper's deny list), hence its own ADR. The helper's deny list is root code: the opus security review is required before merge.
Owner report (second machine, rc1-22): "there is no way to uninstall software".

## Context: what exists, and why the owner found nothing
ADR-0037 already built the whole removal machinery: "Uninstall…" in the Store (spec SR22), one queue of operations
(`operations.cpp`), and a root path for repository packages: `pkexec grassfield-store-helper remove <op-id> <pkg>…` under
`org.grassfield.store.manage-packages` (`auth_admin`, no implicit allow; a strict name pattern; a lock; `db.lck`; refusal
while an update is unfinished; a deny list in code; `pacman -Rs --print` plan check, then `-Rns`; a log under
`/run/grassfield-store`). Flatpaks go through `flatpak uninstall --user`; web apps and recipes through Omarchy's commands;
AUR packages through Omarchy's terminal (`omarchy-pkg-drop`, b.2). **No new root path is needed**: the requested helper
exists and already refuses a package another one requires (pacman's own `-Rs --print` fails to resolve: exit 5).

Why the owner could not remove software (read on the owner's stack and on this machine; `docs` survey in the hand-back):
1. **Discoverability**: the only entries are the Store's product page "…" menu and the Installed page's context menu.
   Nothing in the launcher or Files, where macOS puts them.
2. **Too wide a deny list**: every name of Omarchy's two package lists was "Part of Omarchy". The lists hold the optional apps
   Omarchy preinstalls (LibreOffice, OBS, Pinta, Xournal++, Aether, Moonlight, kdenlive, cliamp, lazydocker…), which Omarchy
   itself offers to remove (`omarchy-remove-preinstalls` drops exactly: aether cliamp libreoffice-fresh xournalpp pinta
   obsidian obs-studio kdenlive moonlight-qt lazydocker omacut omacalc omawrite). On this machine 48 of 89 launcher entries
   belong to such a name or to the base list.
3. The other reasons the Store dims "Uninstall…" (`removal.h`, `uninstallBlock`): part of the system (the fixed list,
   kernels, systemd, limine, pacman, firmware, HoldPkg), part of Omarchy (prefix `omarchy`/`yay` or its lists), part of
   Grassfield (`grassfield-*`), installed with another app (not explicit: 22 entries here, such as gcr, papers, neovim), owns
   no application entry, not from a repository (AUR: terminal path, needs the AUR switch), Omarchy's lists unreadable,
   Flatpak with Flathub's source switched off (`flathubOff`), a dev session, helper or pkexec missing, Omarchy differs from
   the catalog's pins (setups).
4. **An app the Store's model does not know** (explicitly installed repository package with an entry, but neither in the
   catalog nor in Arch's AppStream data, `storemodel.cpp`): `actions().uninstall == "source"`, no page, no Installed row.
   Measured on this machine with `--removable`: 43 of 89 entries were known to the Store; Omarchy's own repository has no
   AppStream data, so Aether, Cliamp, Omacut, Omacalc and Omawrite (all preinstalls Omarchy offers to remove) had no Store
   app at all. **Fixed here (F1)**: `StoreBackend` lists an explicitly installed repository package that owns an entry and has
   no catalog or AppStream app as an app named by its package (no icon, no text), so "Uninstall…" reaches it.

## Decision
**D1. One backend, the Store, reached through its existing instance IPC.** No new service, no new D-Bus method.
- `grassfield-store --removable` (one-shot, offscreen, no window, no bus name, no operation, no state file; `loadOnly()`)
  prints `{"version":1,"entries":{"<id>.desktop":{"app","name","block"}}}`: every installed repository or Flatpak app by
  application entry (all entries of a package), `block` = `uninstallBlock` ("" = removable, else the reason).
- `grassfield-store --page=uninstall:<id>.desktop` (the Store's existing hand-over, `Open(page, token)`) asks the running
  Store, or starts one, to plan and run the removal through the operations queue. The launcher or Files already showed the
  alert, so the Store's sheet opens only when its plan says more than the alert did (a refusal, a second package, a
  dependent); otherwise the removal starts and polkit asks for the password (`Store.removalIsQuiet`).
- Flatpak and recipe apps keep their paths; web apps and recipe apps are not in `--removable` (follow-up F2).
**D2. The deny list loses Omarchy's optional preinstalls**: the 13 names above are removable unless in `HoldPkg`. The list is
code in the helper (`denied()`), in `removal.cpp` and in `tests/fixtures/store/removal-vectors.json`, which both run.
Everything else on Omarchy's lists stays "Part of Omarchy" (mpv, imv, foot, btop, fcitx5, cups, gnome-disk-utility…): macOS
keeps Preview. Justification: macOS lets the user delete its optional bundled apps (GarageBand, Pages) and keeps the ones
the system uses; Omarchy's own `omarchy-remove-preinstalls` is the authority for which are which.
**D3. The session's runtime joins the fixed list**: `hyprland quickshell networkmanager mesa wireplumber sddm uwsm
gnome-keyring`, `xdg-desktop-portal[-*]`, `qt6-*`, `pipewire[-*]` (all already protected by being required, now by name too).
**D4. The helper logs to the journal** (`logger -t grassfield-store-helper`, best effort) besides its `/run` log.
**D5. `-Rns` stays** (not a bare `-R`, not `-R` plus a second pass): `-s` only takes dependencies no installed package needs,
and the plan check refuses the whole removal when any of them is protected; `-n` drops the package's own saved config files,
never the user's home. Decided against a bare `-R`: it leaves orphans the user never sees.
**D6. The macOS model.** Launchpad (the Apps panel): a long press (`holdDelay`) on an icon, or Option, makes the icons jiggle
(`jiggleAngle`, `jigglePeriod`); an app the Store says is removable shows a delete badge; clicking it opens the alert
"Delete “App”?" with Delete and Cancel; the context menu offers "Delete…" on a removable app. Esc or Done ends the jiggle.
Apps that are system, Omarchy, Grassfield, or unknown to the Store show no badge. Files' Applications location: "Move to
Trash" is enabled on a removable app and opens the same alert (Finder: moving an app to the Trash uninstalls it); dimmed
otherwise, with the reason as the tooltip. Alert text: "Delete “App”?" / "The app is removed from this computer. Its documents
and settings in your home folder are kept." (macOS says the data goes too; here it stays, SD27 and `-Rns`: the text is the truth.)
**D7. Settings → Storage → Applications**: no Storage pane exists, so none is added.

## Slice shipped
The Store IPC and the launcher and Files entry points, for repository (pacman) apps and Flatpaks, **with the existing root
helper** (D2-D4 change its deny list: security review). Not built: a new polkit action (`org.grassfield.packages.remove`) or
a new helper — it would duplicate `grassfield-store-helper remove` without a gain. The owner's list of helper refusals maps
as: one name, strict charset (exists); required by another package (`-Rs --print` fails, exit 5); protected list (exists,
D3); base and base-devel (fixed list); `-Rns` only (D5); journal (D4); no concurrent pacman or update (`db.lck`, helper lock,
"unfinished update" exit 4).

## Follow-ups
F1 (done, above): a name and an icon for those apps from their application entry. F2 web apps and recipe apps by entry. F3 Settings → Storage when it exists.
F4 a Required By column in `--removable` (`pacman -Qt`) so the badge is hidden before the plan refuses. F5 the second
confirmation when the plan lists dependencies is the Store's sheet, by design.

## Verification
Unit: removal vectors (C++ and the helper's `denied()`), `UninstallLogic.js` (`tests/unit/tst_uninstall.qml`), Store sheet
quietness, the launcher's state and Files' menu. No package was removed on any machine: the helper is only run with stubs.
