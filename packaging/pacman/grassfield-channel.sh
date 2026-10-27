# shellcheck shell=bash
# Shared code of Grassfield's two root programs (ADR-0033 c.1; docs/specs/updates.md U16). OPUS SECURITY REVIEW REQUIRED.
#   /usr/lib/grassfield/grassfield-channel-helper     run by pkexec (polkit action org.grassfield.packages.set-channel)
#   /usr/lib/grassfield/grassfield-channel-scriptlet  run by grassfield-desktop's pacman scriptlets
# Installed as /usr/lib/grassfield/grassfield-channel.sh (not executable) and sourced only by them, after they replaced
# their environment (gf_start). The only input is the argument vector they checked.
#
# What it writes, and nothing else:
#   - the two lines at the end of /etc/pacman.conf: "[grassfield]" and "Include = /etc/pacman.d/grassfield.conf";
#   - /etc/pacman.d/grassfield.conf, copied from a root-owned packaged template (/usr/share/grassfield/pacman/
#     grassfield-<channel>.conf, generated at build time from packaging/pacman/repository.conf);
#   - pacman's synced [grassfield] files (<DBPath>/sync/grassfield.{db,files}{,.sig});
#   - the Grassfield keys in pacman's keyring (pacman-key --add/--lsign-key of the pinned key, --populate-from the
#     private keyring folder of grassfield-keyring, --delete).
# The lines go last, after the last repository of Omarchy's channel templates (default/pacman/pacman-stable.conf ends
# with [omarchy] in 4.0.4 and [multilib] in 4.0.6; ADR-0033 a.1-a.2, Q4), so [grassfield] never shadows a package of theirs.
# Every write to /etc goes through a temporary file in the same folder and a rename (mode and owner kept), so pacman never
# reads a half-written file. The lines are added after the file exists and removed before the file goes: pacman never
# sees an Include whose file is missing (P2: that stops every pacman command). No network, no package installed,
# nothing written in a user's home.

GF_PACMAN_CONF=/etc/pacman.conf
GF_CONF=/etc/pacman.d/grassfield.conf
GF_INCLUDE="Include = $GF_CONF"
GF_DATA=/usr/share/grassfield/pacman
GF_KEYRING=/usr/share/grassfield/pacman-keyring

gf_fail() {
  echo "${GF_PROG:-grassfield-channel}: $*" >&2
  exit 1
}

# Called first by both programs (their environment is already empty): a fixed PATH, locale, umask and directory.
gf_start() {
  export PATH=/usr/bin LC_ALL=C
  IFS=$' \t\n'
  umask 022
  set -uo pipefail
  cd / || exit 1
  ((EUID == 0)) || gf_fail "must run as root"
  gf_load
  gf_paths
}

# One change at a time: the helper can start just before a pacman transaction whose scriptlet runs the other program, and
# two rewrites of pacman.conf could lose one another (lines left without their file). Both take a lock only root can
# open: flock needs no write access, so a lock others can read could be held by any local user and would block
# "Turn Off…" and the removal (review of 0338116, MAJOR 1). /run/grassfield (root, 0700) and its channel.lock (root,
# 0600) are made under umask 077 and checked before use. The kernel drops the lock when its holder dies. The helper
# refuses when it is held; the scriptlet waits (pacman's transaction must not fail for it). A root without /run (a
# chroot) has no other program to race with: the scriptlet then goes on unlocked. Once the lock is held, temporary files
# a killed run left in /etc are removed.
GF_LOCK_DIR=/run/grassfield
GF_LOCK=$GF_LOCK_DIR/channel.lock
gf_lock() { # seconds to wait (0: refuse at once)
  if [[ ! -d /run ]]; then
    (($1 > 0)) || gf_fail "no /run: cannot take $GF_LOCK"
  else
    (umask 077 && mkdir -p -- "$GF_LOCK_DIR" && : >>"$GF_LOCK") || gf_fail "cannot create $GF_LOCK"
    [[ -d $GF_LOCK_DIR && ! -L $GF_LOCK_DIR && $(stat -c %u:%a -- "$GF_LOCK_DIR") == 0:700 && -f $GF_LOCK &&
      ! -L $GF_LOCK && $(stat -c %u:%a -- "$GF_LOCK") == 0:600 ]] ||
      gf_fail "$GF_LOCK_DIR (0700) or $GF_LOCK (0600) is not root's own: refused"
    exec 9<"$GF_LOCK" || gf_fail "cannot open $GF_LOCK"
    if (($1 == 0)); then
      flock -n 9 || gf_fail "another change of Grassfield's update channel is running: try again when it has finished"
    else
      flock -w "$1" 9 || gf_fail "another change of Grassfield's update channel did not finish within $1 s"
    fi
  fi
  rm -f -- /etc/.pacman.conf.grassfield.* /etc/pacman.d/.grassfield.conf.*
}

# The packaged repository.conf: KEY=value lines checked by generate.py at build time, read here, never sourced.
gf_load() {
  local line key value file=$GF_DATA/repository.conf
  GF_BASE='' GF_FPR=''
  GF_PREVIOUS=()
  [[ -f $file ]] || gf_fail "missing $file"
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z $line || $line == \#* ]] && continue
    [[ $line == *=* ]] || gf_fail "malformed line in $file"
    key=${line%%=*} value=${line#*=}
    case $key in
      GRASSFIELD_REPO_BASE) GF_BASE=$value ;;
      GRASSFIELD_REPO_MIRRORS) ;;
      GRASSFIELD_REPO_BASE_PREVIOUS) read -r -a GF_PREVIOUS <<<"$value" ;;
      GRASSFIELD_SIGNING_FINGERPRINT) GF_FPR=$value ;;
      *) gf_fail "unknown key $key in $file" ;;
    esac
  done <"$file"
  [[ $GF_BASE =~ ^(https://|file:///)[A-Za-z0-9./:~+-]+$ ]] || gf_fail "malformed GRASSFIELD_REPO_BASE in $file"
  [[ $GF_FPR =~ ^([0-9A-F]{40})?$ ]] || gf_fail "malformed GRASSFIELD_SIGNING_FINGERPRINT in $file"
}

# pacman's DBPath and GPGDir. While pacman's configuration cannot be read (only when an Include's file is missing, the
# state gf_heal repairs) the defaults are used.
gf_paths() {
  GF_DBPATH=$(pacman-conf DBPath 2>/dev/null) || GF_DBPATH=/var/lib/pacman/
  GF_GPGDIR=$(pacman-conf GPGDir 2>/dev/null) || GF_GPGDIR=/etc/pacman.d/gnupg/
  [[ $GF_DBPATH == /* && $GF_GPGDIR == /* ]] || gf_fail "pacman's DBPath or GPGDir is not an absolute path"
  GF_DBPATH=${GF_DBPATH%/}
}

# A build that can set Grassfield updates up: a pinned key and a real host (ADR-0033 b.3, spec "Refusals").
gf_require_build() {
  local host=${GF_BASE#https://}
  host=${host%%/*}
  host=${host%%:*}
  [[ -n $GF_FPR ]] || gf_fail "no signing key in this build"
  [[ $GF_BASE == file://* || ($host != *.invalid && $host != invalid) ]] || gf_fail "no package repository in this build"
}

# pacman holds <DBPath>/db.lck while it runs (the helper's verbs wait for it; pacman's own scriptlets run under it).
gf_require_unlocked() {
  [[ ! -e $GF_DBPATH/db.lck ]] || gf_fail "pacman is running ($GF_DBPATH/db.lck exists): try again when it has finished"
}

# The number of [grassfield] sections of pacman.conf: lines that are [grassfield] once comments and blanks are removed.
gf_sections() {
  awk '{ l = $0; sub(/#.*/, "", l); gsub(/^[ \t]+|[ \t]+$/, "", l); if (l == "[grassfield]") n++ } END { print n + 0 }' \
    "$GF_PACMAN_CONF"
}

gf_has_section() {
  (($(gf_sections) > 0))
}

# The first Server value of the included file ("" when none).
gf_primary() {
  awk '{ l = $0; sub(/#.*/, "", l)
         if (match(l, /^[ \t]*Server[ \t]*=[ \t]*/)) { v = substr(l, RLENGTH + 1); gsub(/[ \t]+$/, "", v); print v; exit } }' \
    "$GF_CONF"
}

# Replace /etc/pacman.conf with the output of the function named $1 (given the current file), through a temporary file
# in /etc and a rename that keeps its mode and owner. A symbolic link or another kind of file is refused.
gf_rewrite_pacman_conf() {
  local tmp
  [[ -f $GF_PACMAN_CONF && ! -L $GF_PACMAN_CONF ]] || gf_fail "$GF_PACMAN_CONF is not a regular file"
  tmp=$(mktemp /etc/.pacman.conf.grassfield.XXXXXX) || gf_fail "cannot create a temporary file in /etc"
  if "$1" <"$GF_PACMAN_CONF" >"$tmp" && chmod --reference="$GF_PACMAN_CONF" -- "$tmp" &&
    chown --reference="$GF_PACMAN_CONF" -- "$tmp" && sync -- "$tmp" && mv -fT -- "$tmp" "$GF_PACMAN_CONF"; then
    return 0
  fi
  rm -f -- "$tmp"
  gf_fail "cannot write $GF_PACMAN_CONF (it is unchanged)"
}

gf_with_lines() {
  local text
  text=$(cat && echo x) || return 1 # keeps the trailing newlines; the x is dropped below
  text=${text%x}
  printf '%s' "$text"
  [[ -z $text || $text == *$'\n' ]] || echo
  printf '\n[grassfield]\n%s\n' "$GF_INCLUDE"
}

# Every [grassfield] section goes (its header up to the next header), with one blank line right before it.
gf_without_lines() {
  awk '
    function flush(n) { while (n-- > 0) print "" }
    {
      l = $0; sub(/#.*/, "", l); gsub(/^[ \t]+|[ \t]+$/, "", l)
      if (l ~ /^\[.*\]$/) {
        if (l == "[grassfield]") { if (blank > 0) flush(blank - 1); blank = 0; skip = 1; next }
        skip = 0
      }
      if (skip) next
      if ($0 ~ /^[ \t]*$/) { blank++; next }
      flush(blank); blank = 0; print
    }
    END { flush(blank) }'
}

# Exactly one section: added when missing; when there are several (the hook appending between this program's read and
# its rename, pacman then refuses "already registered"), they are replaced by one.
gf_add_lines() {
  case $(gf_sections) in
    1) return 0 ;;
    0) gf_rewrite_pacman_conf gf_with_lines ;;
    *) gf_rewrite_pacman_conf gf_one_section ;;
  esac
}

gf_one_section() {
  gf_without_lines | gf_with_lines
}

gf_remove_lines() {
  gf_has_section || return 0
  gf_rewrite_pacman_conf gf_without_lines
}

# /etc/pacman.d/grassfield.conf from the packaged template of a channel, through a temporary file and a rename.
gf_write_file() {
  local tpl=$GF_DATA/grassfield-$1.conf tmp
  [[ -f $tpl ]] || gf_fail "missing $tpl"
  tmp=$(mktemp /etc/pacman.d/.grassfield.conf.XXXXXX) || gf_fail "cannot create a temporary file in /etc/pacman.d"
  if cat -- "$tpl" >"$tmp" && chmod 0644 -- "$tmp" && sync -- "$tmp" && mv -fT -- "$tmp" "$GF_CONF"; then
    return 0
  fi
  rm -f -- "$tmp"
  gf_fail "cannot write $GF_CONF"
}

# pacman's synced copy of [grassfield]: after a Server change it would keep the other channel's database (P7).
gf_drop_synced() {
  local s=$GF_DBPATH/sync
  rm -f -- "$s/grassfield.db" "$s/grassfield.db.sig" "$s/grassfield.files" "$s/grassfield.files.sig" ||
    gf_fail "cannot remove pacman's synced [grassfield] files in $s"
}

# Lines without their file (pacman cannot run at all then): the lines go first, whatever the verb does next.
gf_heal() {
  if [[ ! -e $GF_CONF ]] && gf_has_section; then
    gf_remove_lines
    gf_paths
  fi
}

# The validity of a key in pacman's keyring ("" when it is absent; f or u when trusted).
gf_validity() {
  gpg --homedir "$GF_GPGDIR" --batch --no-tty --no-permission-warning --with-colons --list-keys -- "$1" 2>/dev/null |
    awk -F: '$1 == "pub" { print $2; exit }'
}

# ADR-0033 b.3 (owner decision O17): when the pinned key is not trusted (its validity, not its presence: pacman may have
# imported it untrusted), the shipped key file must hold exactly that key, which is then added and locally signed.
gf_bootstrap() {
  local key=$GF_DATA/grassfield-signing-key.asc listing
  [[ $(gf_validity "$GF_FPR") == [fu] ]] && return 0
  [[ -s $key ]] || gf_fail "no signing key in this build"
  listing=$(gpg --homedir "$GF_GPGDIR" --batch --no-tty --no-permission-warning --with-colons --show-keys -- "$key" 2>/dev/null) ||
    gf_fail "cannot read $key"
  [[ $(awk -F: '$1 == "sec" { s = 1 } END { print s + 0 }' <<<"$listing") == 0 &&
    $(awk -F: '$1 == "pub" { p = 1; next } $1 == "fpr" && p { print $10 } { p = 0 }' <<<"$listing") == "$GF_FPR" ]] ||
    gf_fail "$key is not the pinned key $GF_FPR: refused"
  pacman-key --add "$key" >/dev/null || gf_fail "pacman-key --add failed"
  pacman-key --lsign-key "$GF_FPR" >/dev/null || gf_fail "pacman-key --lsign-key failed"
  [[ $(gf_validity "$GF_FPR") == [fu] ]] || gf_fail "the pinned key $GF_FPR is still not trusted"
}

# Every key of the installed grassfield-keyring trusted again and every revoked one disabled (R3). A keyless keyring
# (ADR-0033 b.2, U23: until the owner's key exists) has nothing to populate.
gf_populate() {
  [[ -s $GF_KEYRING/grassfield.gpg ]] || return 0
  pacman-key --populate-from "$GF_KEYRING" --populate grassfield >/dev/null || gf_fail "pacman-key --populate-from failed"
}

# ADR-0033 b.8: every key of grassfield-trusted and the pinned key leave pacman's keyring; empty fingerprints are skipped.
gf_delete_keys() {
  local fpr failed=0
  local -a keys=()
  [[ -n $GF_FPR ]] && keys+=("$GF_FPR")
  if [[ -f $GF_KEYRING/grassfield-trusted ]]; then
    while IFS=: read -r fpr _ || [[ -n $fpr ]]; do
      [[ $fpr =~ ^[0-9A-Fa-f]{40}$ ]] && keys+=("${fpr^^}")
    done <"$GF_KEYRING/grassfield-trusted"
  fi
  ((${#keys[@]})) || return 0
  while IFS= read -r fpr; do
    [[ -n $(gf_validity "$fpr") ]] || continue
    pacman-key --delete "$fpr" >/dev/null || { echo "${GF_PROG}: pacman-key --delete $fpr failed" >&2; failed=1; }
  done < <(printf '%s\n' "${keys[@]}" | sort -u)
  ((failed == 0)) || gf_fail "a Grassfield key is still in pacman's keyring"
}

# set stable|beta (U16 order): trust, populate, the file, the lines, the synced files.
gf_set() {
  gf_require_build
  gf_heal
  gf_bootstrap
  gf_populate
  gf_write_file "$1"
  gf_add_lines
  gf_drop_synced
}

# restore ("Repair…" in the repair state): the two lines, only when the file exists.
gf_restore() {
  gf_heal
  [[ -f $GF_CONF ]] || gf_fail "Grassfield updates are not set up ($GF_CONF is missing)"
  gf_add_lines
}

# off ("Turn Off…") and the scriptlet's remove: the lines, the file, the synced files, the keys.
gf_off() {
  gf_remove_lines
  rm -f -- "$GF_CONF" || gf_fail "cannot remove $GF_CONF"
  gf_paths
  gf_drop_synced
  gf_delete_keys
}

# The scriptlet's upgrade (ADR-0033 h.3, O19): a file whose primary Server is <previous base>/<channel>/$arch is written
# again from this build's template of that channel; any other content is left alone.
gf_migrate() {
  local primary base channel
  [[ -f $GF_CONF ]] || return 0
  primary=$(gf_primary) || return 0
  for base in "${GF_PREVIOUS[@]}"; do
    for channel in stable beta; do
      if [[ $primary == "$base/$channel/\$arch" ]]; then
        gf_write_file "$channel"
        gf_drop_synced
        return 0
      fi
    done
  done
}
