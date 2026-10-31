# Software Update L2, test 1: Update Now refuses an update this Grassfield was not built for (owner-run)

Run by the owner, in the real Grassfield session (L2, master-prompt §9). Nothing is installed and nothing on the system
changes: the run stops at the compatibility check (ADR-0033 s3.4). That check comes before the snapshot, the keyring, the
switch to the new package databases and any install. Agents run nothing on your machine.

What it checks, end to end on real hardware (spec U24-U30, step 3, merged as 784350e):
- Grassfield's own password dialog, with no terminal;
- the root helper behind its polkit action;
- the compatibility check against the versions your Grassfield was built with (`/usr/share/grassfield/BUILD-DEPS`);
- the refusal shown in Settings, with nothing changed.

Why your machine refuses today: your Grassfield was built on your machine against the Qt it had then, and BUILD-DEPS
records that version. When this guide was written (2026-10-31), Omarchy's stable mirror served `qt6-base 6.12.0-3`.
Grassfield's check refuses a change of Qt's first two numbers (6.11 to 6.12), the same for Hyprland, aquamarine and
kcoreaddons, and any change of quickshell's version. Step 0 checks this on your machine before you click anything.

## 0. Before: check that the test applies (read-only)

In a terminal of the Grassfield session:

```bash
mkdir -p ~/grassfield-logs && cd ~/grassfield-logs
pacman -Q grassfield-desktop
cat /usr/share/grassfield/BUILD-COMMIT
git -C ~/workspace/grassfieldos merge-base --is-ancestor 784350e "$(cat /usr/share/grassfield/BUILD-COMMIT)" && echo "step 3: yes"
ls -l /usr/lib/grassfield/grassfield-update-helper /usr/lib/grassfield/grassfield-update-run \
  /usr/share/polkit-1/actions/org.grassfield.packages.policy
cat /usr/share/grassfield/BUILD-DEPS | tee su-build-deps.txt
checkupdates | tee su-checkupdates.txt | grep -E '^(qt6-base|quickshell|hyprland|aquamarine|kcoreaddons) '
df -h /
```

`checkupdates` compares a copy of the package databases in `/tmp`; it changes nothing on the system.

Go on only if all of these hold:
- `step 3: yes` is printed (otherwise your installed build predates Update Now without a terminal: rebuild first, section
  3 of `real-session.md`);
- the three files are listed and BUILD-DEPS has five lines (`qt6-base`, `quickshell`, `hyprland`, `aquamarine`,
  `kcoreaddons`);
- at least one `checkupdates` line changes a package whose BUILD-DEPS version differs in the way that refuses:
  - `qt6-base`, `hyprland`, `aquamarine`, `kcoreaddons`: the first two numbers differ (for example BUILD-DEPS
    `qt6-base 6.11.2-1` and checkupdates `qt6-base 6.11.2-1 -> 6.12.0-3`);
  - `quickshell`: any change of the version before its last dash;
- `/` has at least 10 GiB free, and the computer is on power or its battery is above 50 % (otherwise the run stops earlier,
  also changing nothing, but it does not test the compatibility check).

**If no line differs in that way, stop here and send me `su-build-deps.txt` and `su-checkupdates.txt`.** Update Now would
then install the updates for real. That is a later test, with its own guide and a snapshot first.

Record the state before:

```bash
cd ~/grassfield-logs
pacman -Q > su-before.txt
stat -c '%Y %n' /var/lib/pacman/sync/*.db >> su-before.txt
```

## 1. The test

1. Open Settings > General > Software Update. The updates are listed, with **Update Now**.
2. Click **Update Now**. Expected: "Waiting for permission…" and Grassfield's own password dialog (no terminal window).
3. Type your password. Expected: "Preparing the update…" for a few seconds to a minute (it reads fresh package databases
   into a temporary copy).
4. Expected end: **"This update needs a newer version of Grassfield, which isn't available yet."** with "Software Update
   checks again later and tells you when it's ready." under it. There is no restart sheet, and **Update Now** is still
   there.
5. Take a screenshot of the Settings window (your usual screenshot key, or `grim ~/grassfield-logs/su-pane.png` from a
   terminal).

## 2. Evidence to collect (read-only)

```bash
cd ~/grassfield-logs
op=$(cat /run/grassfield-update/last); echo "$op"
cat "/run/grassfield-update/$op.exit" | tee su-exit.txt
cp "/run/grassfield-update/$op.log" su-helper.log
cp "$XDG_RUNTIME_DIR/grassfield/software-update-run.json" su-run.json
cp "$XDG_RUNTIME_DIR/grassfield/software-update-run.log" su-runner.log
pacman -Q > su-after.txt
stat -c '%Y %n' /var/lib/pacman/sync/*.db >> su-after.txt
diff su-before.txt su-after.txt && echo "nothing changed"
```

Expected:
- `su-exit.txt`: first line `6`, then one `incompatible <package>` line for each package that refused (for example
  `incompatible qt6-base`). There is no `synced` line and no `snapshot` line.
- `su-run.json`: `"phase":"done"`, `"result":"incompatible"`, `"synced":false`.
- `su-helper.log`: for example `qt6-base 6.12.0-3: Grassfield was built with 6.11.2-1`, and at the end
  `this update needs a newer Grassfield: nothing was changed`.
- `nothing changed` is printed: no package and no package database changed.

The files under `/run` disappear at the next restart; copy them before restarting.

## 3. What to send me

Send these files, after looking at them: they hold package names, versions and the helper's messages, nothing else.
- `su-pane.png`;
- `su-exit.txt`, `su-run.json`, `su-helper.log`, `su-runner.log`;
- `su-build-deps.txt`, `su-checkupdates.txt`;
- the output of the `diff` line.

## 4. If you see something else

| You see | What it means | What to do |
|---|---|---|
| No **Update Now** (only "Update in Terminal…" or nothing) | the pane found no update, or the build predates step 3 | send step 0's output |
| A terminal window, or a password dialog that is not Grassfield's | the polkit agent is not Grassfield's (an Omarchy session?) | close it; check that you are in the Grassfield session |
| "This update asks questions that need Omarchy's terminal." | the run stopped before the compatibility check, or a migration needs a person; nothing was changed | send section 2's files |
| "Connect this computer to power to update." or "This computer needs 10 GB of free space to update." | the run stopped at its first checks; nothing was changed | plug in or free space, then try again |
| "Another update is running." | Omarchy's update or another run holds the lock | wait for it to finish, then try again |
| "The update could not be installed. Nothing was changed." | offline, or a mirror did not answer | send section 2's files |
| "Restart your computer to finish updating", or progress past "Preparing the update…" ("Saving a snapshot…", "Downloading…", "Installing…") | the check let the update through: it is installing for real | do not close anything; let it finish, then send section 2's files and `pacman -Q` |

Nothing to undo after the expected result: no package, no database, no snapshot and no file outside `/run` and your
runtime folder changed.
