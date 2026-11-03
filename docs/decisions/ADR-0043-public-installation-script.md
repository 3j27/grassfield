# ADR-0043 — Public installation script (amends ADR-0033 b.3a)

Status: Proposed (2026-11-03). The owner asked for it on 2026-11-03 (« il faut déjà préparer le script d'installation publique
du DE »). It is **prepared, not published**: hosting (O8) and the signing key (O11) are not chosen, and the legal review comes
before any public release. Cross-module (packaging, pacman helper contract, session login, docs), hence its own ADR rather than
an amendment. The script runs as the user and uses `sudo` for root steps, so it needs the opus security review before it ships.

## Context
ADR-0033 b.3a documents a first installation of five manual steps (key by pinned fingerprint, `lsign`, the section and its
file, sync and install, `grassfield-channel-set`). The final-1.0 audit (11-installation-and-updates.md: INST-01, INST-06,
ARCH-08) found the path never run from a clean Omarchy, and Omarchy 4.0.4 ordered `[omarchy]` after `[extra]`, where extra's
quickshell 0.3.2-1 (its session lock fails open) wins and `grassfield-desktop` conflicts with it on purpose. This script is
b.3a automated, with its preconditions checked first and an exact way back.

## Decision

### a. Where it lives, and who publishes it
`packaging/install/` in this repository:
- `grassfield-install.sh.in`, the template (bash, `set -euo pipefail`, every statement in a function, `main` last: a download
  cut short never runs half a script);
- `render.py`, which reads `packaging/pacman/repository.conf` with `packaging/pacman/generate.py`'s own parser (one source of
  truth) and writes `grassfield-install.sh` and `grassfield-install.sh.sha256` (`just render-install`).

`grassfieldhq/grassfield-packages` already reads `repository.conf` from this repository's checkout (g); its publishing job runs
`render.py` and uploads the two files next to the repository (`<base>/install/`), with the key file. Nothing here uploads.

### b. Host and fingerprint
Both are substituted at render time from `repository.conf`; the published script pins them as `readonly` constants.
`render.py` **refuses** (exit 1, nothing written) while the host ends in `.invalid`, the fingerprint is empty, or the base is not
`https://`; the unrendered template refuses to run (exit 2). So no placeholder can ever reach a user.

### c. Trust model and the command
Trust is b.3a with the fingerprint pinned **in the script** instead of typed by the user: the key is received by that full
fingerprint from `keys.openpgp.org` (gpg refuses another key), or, when the keyserver does not answer, from the host's `.asc`,
whose only primary key must equal the pinned fingerprint and which must hold no secret key, then `pacman-key --lsign-key`
(which signs only exactly that fingerprint). Every package is `SigLevel = Required` against that key. The script's own
integrity rests on TLS to the host plus a **published SHA-256** (also at the project site and the public repository's README,
the two out-of-band places b.3a requires), so the user checks the one file that pins the key.

The command (placeholders until O8/O11):
```
curl -fsSLO https://<host>/install/grassfield-install.sh
curl -fsSLO https://<host>/install/grassfield-install.sh.sha256
sha256sum -c grassfield-install.sh.sha256 && bash grassfield-install.sh
```
Download, check, run, rather than `curl … | bash`: the user can read the file and compare the checksum; the plan and the
confirmation run at a terminal; a truncated or tampered download is caught before any line runs. `curl | bash` still works (the
script reads the whole file first and reads answers from `/dev/tty`) but is not documented: it gives the user nothing to
verify, for the same TLS trust.

### d. What it does, in order, and what it changes
Read-only **preflight** (all problems listed at once, each with its exact fix, exit 1, nothing changed): not root; `sudo`;
Arch x86_64; Omarchy ≥ 4.0.6 (`pacman -Q omarchy`); `[omarchy]` before `[extra]` and quickshell offered by `[omarchy]`, never the
installed 0.3.2-N build; no `db.lck`, no running Omarchy update; ≥ 4 GiB free; two HEAD requests to the host (database, key);
no pending system update (checkupdates). It **never edits the repository order**: it prints the remedy (move the whole
`[omarchy]` block just after `[options]`, the change `.claude/integrator/owner/omarchy-first.py` made on the owner's machine).
Then a **plan screen** and a confirmation (`--yes` skips it; `--dry-run` stops there; `--channel stable|beta`, `--help`; English
or French from `LC_ALL`/`LC_MESSAGES`/`LANG`). Then:
1. **Snapshot**: `omarchy-snapshot create` (SU-M1's tool). Exit 127 (no snapper): continue, as Omarchy does; another failure
   stops, unless `--no-snapshot`.
2. **Key** (root): recv, else verified file; `pacman-key --lsign-key`.
3. **Repository** (root): `/etc/pacman.d/grassfield.conf` (`SigLevel = Required`, `Server = <base>/<channel>/$arch`) written
   only when absent or naming another host (old copy kept as `.grassfield-install-bak`); then `[grassfield]` + `Include`
   appended to `/etc/pacman.conf` only when there is no such section, after a copy `/etc/pacman.conf.grassfield-install-bak`;
   `pacman-conf` must still list `grassfield` or the copy is put back. File first, Include second (P2).
4. **Install** (root): `pacman -Sy`; refused when other updates are pending (no partial upgrade); `pacman -S --print` resolves
   dependencies and conflicts (Hyprland, Qt, quickshell) with nothing installed; then `pacman -S --needed grassfield-desktop
   grassfield-compositor grassfield-store`. Dependencies (`grassfield-icons`, `-wallpapers`, `-keyring`) come with
   `grassfield-desktop`; `grassfield-login-themes` only with `--with-login-themes`.
5. **Hand over**: `grassfield-channel-set <channel>` (its polkit prompt; the helper then owns the file and links Omarchy's hook).
6. **Session**: `grassfield-login set grassfield` (the package's `/etc/sddm.conf.d/grassfield.conf` already makes the "Grassfield
   (uwsm)" entry the one Omarchy's greeter picks; ADR-0042; INST-01), so the next login after one restart starts Grassfield.

Root is used only by the commands above, each through one `as_root` function that logs it. Idempotent: a rerun skips what is
done, repairs a missing file, never duplicates a line, and updates. Log: `${XDG_STATE_HOME:-~/.local/state}/grassfield/install.log`
(mode 600). Nothing is written in the user's home besides the log and `~/.config/grassfield/login-session`.

### e. Undo: `--uninstall`
Reuses, never duplicates: snapshot; `grassfield-channel-set off` (Turn Off: section, file, keys, hook link); `grassfield-login set
omarchy` and the choice file deleted; the `zz-grassfield-theme.conf` drop-in of the login-themes guide if present; `pacman -Rns` of
the installed Grassfield packages (their `pre_remove` runs `off` again, b.8). Leftovers only if the packages were never installed
(an install that failed after step 3): `pacman.conf` goes back from the script's copy **only when it is exactly that copy plus
the two lines**, else the script prints the manual fix and exits 1; the key is deleted when still present. Omarchy is never
modified, so stock Omarchy is back after one restart.

### f. Tests
`tests/shell/public_install.sh` (logic layer): render refusals, then the rendered script on **stub** commands in a fake root
(the script's `PATH` holds only stubs and harmless coreutils, so nothing real can run): each preflight failure, dry-run, the
exact root commands in order, idempotent rerun, repair, fallback key, substituted/secret key refused, snapshot cases, partial
upgrade, unreadable conf rollback, uninstall (also after a failed install and with an edited pacman.conf), French, the log.
`GRASSFIELD_INSTALL_ROOT` (a file prefix, announced loudly when set) is the only test hook. shellcheck runs when installed.

### g. Container test in grassfield-packages (described, not done here)
As `tests/integration/update_helper.sh` does: an `archlinux:base@sha256:…` container, a local `file://` `[omarchy]`/`[extra]`
stand-in and a signed `[grassfield]` repository built with a throwaway key, `render.py` run with a conf whose base is served by a
local `https` server (or a build variant that allows `file://`), the real script run as an unprivileged user with passwordless
sudo, asserting the same cases against real pacman. That repository owns it; this one's test covers the logic.

## Open owner questions (recommendations, none decided)
| Id | Question | Options | Recommended |
|---|---|---|---|
| IN1 | Make Grassfield the next-login session at install? | yes (`--session grassfield`, default) · no (`--session omarchy`, the user switches later) | **yes**: it is why they installed it; Omarchy is one command away |
| IN2 | Install `grassfield-login-themes` by default? Its activation is root and owner-run (ADR-0042) | no, `--with-login-themes` · yes | **no**: it changes login and boot screens, which the guide keeps to a deliberate step |
| IN3 | Command published: download-check-run, or `curl \| bash` | as in c · both | **as in c only** |
| IN4 | Minimum free space (4 GiB) and Omarchy floor (4.0.6) | as built · other | **as built** (Qt WebEngine is large; 4.0.6 carries `[omarchy]` first and Qt 6.12) |
| IN5 | The `[omarchy]` order: print the remedy (built) or a separate `--fix-omarchy-order` step run on the user's yes | print only · opt-in fix | **print only**, as the task and the owner's rule: the order is Omarchy's configuration |
| IN6 | Snapshot failure other than "no snapper": stop (built) or warn | stop, `--no-snapshot` to override · warn | **stop**: a snapshot is the only undo of a failed transaction |
| IN7 | Languages of the script | EN + FR (built) · EN only | **EN + FR** |
| IN8 | Where the checksum is published | the host and the README and the site (b.3a's two places) | **all three**, plus the key fingerprint beside it |

## Consequences
- `just render-install` fails today by design (placeholder host, empty fingerprint): the first release needs O8 and O11.
- A source build (`makepkg -si`, the owner's flow) is unaffected; the script targets users of the repository.
- Hyprland is never pinned (packaging rule): a Hyprland newer than the plugin's ABI degrades the session (C2) rather than failing
  the install; the exact dependency check is pacman's own dry run after the sync.
- Review: security (root steps, trust bootstrap) with opus before any publication; the legal review precedes publication.
