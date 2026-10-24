# Images the shell does not own · security-engineer

Integrator decisions after the reviews of 5ee6240 and 423766f. Qt never reads a user-writable icon file, and **the shell
only ever decodes images it produced itself**. Before that, the shell copied files verbatim or checked SVG bytes with a
regex. Neither held: a gzip, UTF-16 or BOM-prefixed SVG, or SVG content in a `.png` file, still reached QtSvg. QtSvg then
followed `<image xlink:href>` to a FIFO and blocked the one image loader thread for good.

## Rule
- **Root-owned files only, by name.** A plain theme name (`NotificationPrefs.safeIconName`) is looked up by Qt only in
  directories the user can neither write nor replace (`ui/i18n/iconsearchpaths.h`) and shown by its `image://icon` URL.
  Raw pixels an application sent are shown as Quickshell holds them: notification `image-data` (`image://qsimage/`)
  and tray `IconPixmap` (`image://qspixmap/`). That is not a file format.
- **Everything else becomes a PNG the shell made.** This covers:
  - a name found only in the user's icon folders, a flatpak user export included;
  - an `Icon=` path;
  - a tray icon from the app's `IconThemePath`;
  - notification image and app-icon files;
  - MPRIS media art (`file://` only);
  - desktop thumbnails and stack previews;
  - the lock screen's `~/.face` and AccountsService picture.

  All of them go through `shell/services/image-copy.py`, which runs as `python3 -I`, in a process of its own. The Image
  then loads that `.png` asynchronously. Anything refused shows the caller's generic icon, or the initials on the lock.
- **Never.** No http(s) or `data:` media art. No tray `IconName` holding `/` or `..`. No URL built from an
  application's string, except the two pixel providers above.

## The helper
1. **Open.** The real path (`realpath`: flatpak exports are symlinks) must lie under an allowed root:
   - `$HOME`, `$XDG_DATA_HOME` and `$XDG_DATA_DIRS`;
   - `/usr`, `/opt`, `/var/lib/flatpak` and `/var/lib/AccountsService/icons`;
   - `/tmp`, `/var/tmp` and `$XDG_RUNTIME_DIR`;
   - `/media`, `/mnt`, `/run/media` and `/srv`.

   Never `/proc`, `/sys` or `/dev`. `lstat` must say a regular file. The file is then opened with
   `O_NOFOLLOW|O_NONBLOCK|O_NOCTTY`. `fstat` must say a regular, non-empty file within its cap (8 MiB, or 16 MiB for a
   picture), and `/proc/self/fd` must still name a path under an allowed root. The file is read once, into memory.
2. **Re-encode** with `rsvg-convert`, fed on STDIN, into a PNG of at most 256 x 256 px. 256 px is the largest any site
   shows: notification images, thumbnails, art and the avatar. With no base URL, librsvg resolves no reference to
   another file. This was checked against a FIFO for absolute, `file:`, relative and `../` hrefs, XInclude, CSS
   `@import`, `@font-face`, external entities and DTDs, parameter entities, and filter and `<use>` references. Fed the
   same file by its path, librsvg does follow a relative same-directory href (rc 124). rsvg-convert has no option to
   turn external loading off, so the bytes always go on stdin.
   - **PNG, JPEG, GIF and WebP**, recognised by their magic bytes, must declare a size of at most 16384 px per side and
     50 Mpx. They are wrapped as a `data:` URI in an SVG the helper writes itself (`--unlimited` only for that one).
   - **Anything else** is given to rsvg-convert as SVG: plain, gzip or any XML encoding. Whatever it cannot parse is
     refused.
   - **Limits.** The rsvg-convert child runs with `RLIMIT_AS` 1 GiB and `RLIMIT_CPU` 8 s, under an 8 s timeout. Its
     output must be a PNG of at most 4 MiB.
3. **Store** the result in a 0700 directory emptied at start, created with `O_CREAT|O_EXCL|O_NOFOLLOW`:
   - ThemeIcons: `$XDG_RUNTIME_DIR/grassfield-icons-<display>/<n>.png`. At most 128 MiB in all; the least recently
     used copies are deleted to make room. Past 4096 keys, the least recently used quarter is forgotten and its files
     deleted.
   - Notifications: `…/grassfield-notification-images-<display>/<n>.<sender>.png`, with its window, budget and
     per-sender share (notifications.md).

**Hangs.** A batch runs under `timeout -k 2 30 setpriv --pdeathsig KILL`. A QML watchdog sends TERM, then KILL, and
refuses the batch's keys. `timeout` signals its whole process group, which includes rsvg-convert. Each notification
file runs under `timeout -k 2 12`.

**The copy directory belongs to the user,** like every file of the session, the shell's own QML included. A process
running as the user can replace a copy. The design protects against what applications *name*: a path, a theme file, a
FIFO, a device, an SVG with references, or a hostile image for Qt's decoders. It does not protect against code already
running as the user.

## Tests
`tests/security/theme_icon_files.sh` runs offscreen with the REAL shell modules:
- **Part 1:** user icon files for a theme name: FIFO, symlinks, devices, an SVG referencing a FIFO, and the review's
  gzip, UTF-16, BOM and comment-prefixed SVG, and SVG-in-.png bypasses.
- **Part 2:** hostile `index.theme` files.
- **Part 3:** Launchpad, desktop, thumbnails, the About panel, media art `file://` naming a FIFO or an SVG that
  references one, the lock avatar, and flatpak symlinks.
- **Part 4:** the policy: the logged search paths, and an LD_PRELOAD open log. A user pixmap and a user theme that Qt
  would find without the policy make this part fail in the mutant.
- **Part 5:** the tray: the real `TrayButton` with fake items (IconThemePath FIFO, absolute and traversal `IconName`,
  pixmap and plain name). There is also a private-bus StatusNotifierItem run (`env -i`, a private
  `DBUS_SESSION_BUS_ADDRESS` and a guard refusing the session bus). It is skipped where Unix sockets are blocked.

`tests/shell/notif_image_files` and `notif_image_budget`, `notif_image_fairness` and `notif_clear` cover notification
images. They include an SVG in a `.img` file that names a FIFO.

## Residual risks
- librsvg, cairo and libxml2 parse hostile input. They do it out of the shell, under limits; a crash there costs one
  image.
- An image whose embedded raster fails to decode becomes a transparent PNG, not a refusal.
- A batch of slow documents delays other icons or notification images for up to its timeout. The shell itself never
  waits.
- The lock screen's avatar appears once the helper answers, usually within about 50 ms of start.
