#!/usr/bin/env bash
# renew-signing-key.sh: the OWNER runs this to extend the expiry of Grassfield's package signing key (ADR-0033 b.9), from
# the OFFLINE copy of the secret key made by make-signing-key.sh. Same primary key, same fingerprint, a later expiry date.
# Le PROPRIETAIRE lance ce script pour prolonger la cle de signature, depuis la copie hors ligne de la cle secrete.
#
# What it does / ce qu'il fait:
#   - imports the secret key into a throwaway GNUPGHOME on tmpfs ($XDG_RUNTIME_DIR); ~/.gnupg is never read or written;
#   - asks the passphrase once (read silently; never echoed, logged or put on a command line);
#   - extends the expiry of the primary key (--quick-set-expire), checks the fingerprint did not change;
#   - writes the extended public key, the new SECRET file, fingerprint.txt, expiry.txt and README.txt to a new private folder,
#     then proves them: a signature made from a fresh home that holds only the new SECRET file, checked with gpgv against
#     the new public key alone;
#   - always stops the temporary gpg-agents and shreds the temporary GNUPGHOME, whatever happens (not after SIGKILL: see --help).
# Prints only the fingerprint, the dates and the paths. Details: ADR-0033 b.9, ADR-0043.
set -euo pipefail
umask 077
ulimit -c 0 # no core dump of a process that holds a passphrase

readonly DEFAULT_EXPIRY="2y"

fr=0
case ${LC_ALL:-${LC_MESSAGES:-${LANG:-}}} in fr*) fr=1 ;; esac
say() { if ((fr)); then printf '%s\n' "$2"; else printf '%s\n' "$1"; fi; }
die() { if ((fr)); then printf 'Erreur : %s\n' "$2" >&2; else printf 'Error: %s\n' "$1" >&2; fi; exit 1; }

usage() {
  cat <<'EOF'
Usage: renew-signing-key.sh --secret FILE --fingerprint HEX [--expire 2y] [--output DIR] [--help]
Utilisation : renew-signing-key.sh --secret FICHIER --fingerprint HEX [--expire 2y] [--output DOSSIER] [--help]

  Extends the expiry of the signing key held in FILE (the offline copy of SECRET-grassfield-signing-key.asc) and writes, to DIR
  (default $XDG_RUNTIME_DIR/grassfield-signing-key-renewed-YYYYMMDD, tmpfs; created 0700; never overwritten):
  Prolonge la cle de signature de FICHIER (la copie hors ligne de SECRET-grassfield-signing-key.asc) et ecrit, dans DOSSIER :

    grassfield-signing-key.asc         the extended public key / la cle publique prolongee
    fingerprint.txt                    the primary fingerprint, unchanged / l'empreinte primaire, inchangee
    SECRET-grassfield-signing-key.asc  the new SECRET key, 0600 (replaces the offline copies and the GitHub secret)
    expiry.txt                         the new expiry date and the renewal deadline / la nouvelle expiration et l'echeance
    README.txt                         next steps / la suite

  --fingerprint HEX   REQUIRED: refuse unless the key in FILE has this primary fingerprint (the one pinned in repository.conf)
  --expire 2y         the new validity counted from today (default 2y)
  The revocation certificate made at creation stays valid: it is not remade.
  You type the passphrase once (nothing is shown). ~/.gnupg is never touched.

  If the script is killed with SIGKILL (kill -9), a crash or a power cut, it cannot clean up. It leaves the temporary folder
  (keys protected by your passphrase), a gpg-agent that may still hold the passphrase, and perhaps a partial output folder.
  Clean up with this one line (and remove the partial output folder by hand):
  Si le script est tue par SIGKILL, plante ou si le courant est coupe : une ligne suffit :

    for d in "${XDG_RUNTIME_DIR:-/tmp}"/grassfield-key.*; do gpgconf --homedir "$d/gnupg" --kill all; gpgconf --homedir "$d/verify/home" --kill all; rm -rf "$d"; done
EOF
}

secret="" want="" expire=$DEFAULT_EXPIRY out="" explicit=0
while (($#)); do
  case $1 in
    -h | --help) usage; exit 0 ;;
    --secret) [[ $# -ge 2 && -n $2 ]] || die "--secret needs a file" "--secret demande un fichier"; secret=$2; shift ;;
    --secret=*) secret=${1#--secret=} ;;
    --fingerprint) [[ $# -ge 2 && -n $2 ]] || die "--fingerprint needs a value" "--fingerprint demande une valeur"; want=$2; shift ;;
    --fingerprint=*) want=${1#--fingerprint=} ;;
    --expire) [[ $# -ge 2 && -n $2 ]] || die "--expire needs a value" "--expire demande une valeur"; expire=$2; shift ;;
    --expire=*) expire=${1#--expire=} ;;
    -o | --output) [[ $# -ge 2 && -n $2 ]] || die "--output needs a folder" "--output demande un dossier"; out=$2; explicit=1; shift ;;
    --output=*) out=${1#--output=}; explicit=1 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
[[ -n $secret && -n $want ]] || { usage >&2; exit 2; }
[[ -f $secret && -r $secret ]] || die "$secret is not a readable file" "$secret n'est pas un fichier lisible"
[[ $expire =~ ^[0-9]+[dwmy]$ ]] || die "--expire is a number and d, w, m or y (for example 2y)" "--expire est un nombre suivi de d, w, m ou y (par exemple 2y)"
want=$(tr -d '[:space:]' <<<"$want" | tr a-f A-F)
[[ $want =~ ^[0-9A-F]{40}$ ]] || die "--fingerprint is 40 hexadecimal digits" "--fingerprint fait 40 chiffres hexadecimaux"
if [[ -z $out ]]; then
  [[ -n ${XDG_RUNTIME_DIR:-} && -d $XDG_RUNTIME_DIR && -w $XDG_RUNTIME_DIR ]] \
    || die "no \$XDG_RUNTIME_DIR (a tmpfs folder); pass --output FOLDER explicitly" \
      "pas de \$XDG_RUNTIME_DIR (dossier en tmpfs) ; passez --output DOSSIER explicitement"
  out="$XDG_RUNTIME_DIR/grassfield-signing-key-renewed-$(date +%Y%m%d)"
fi

for tool in gpg gpgconf gpgv mktemp; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is not installed (pacman -S gnupg)" "$tool n'est pas installe (pacman -S gnupg)"
done
[[ ! -e $out && ! -L $out ]] || die "$out already exists; nothing was written. Choose another folder (--output)." \
  "$out existe deja ; rien n'a ete ecrit. Choisissez un autre dossier (--output)."

# ---- cleanup on every exit path (except SIGKILL) ---------------------------------------------------------------------
base="" gh="" vh="" out_made=0 pass=""

wipe() {
  [[ -n $1 && -d $1 ]] || return 0
  if command -v shred >/dev/null 2>&1; then find "$1" -type f -exec shred -u -- {} + >/dev/null 2>&1 || true; fi
  rm -rf -- "$1"
}

cleanup() {
  local rc=$?
  trap '' INT TERM QUIT HUP # a second Ctrl-C must not abort the cleanup
  trap - EXIT
  set +e
  pass=""
  local h
  for h in "$gh" "$vh"; do
    if [[ -n $h && -d $h ]]; then gpgconf --homedir "$h" --kill all >/dev/null 2>&1; fi
  done
  wipe "$base"
  if ((rc != 0 && out_made)); then wipe "$out"; fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 131' QUIT
trap 'exit 129' HUP

tmproot=${TMPDIR:-/tmp}
[[ -n ${XDG_RUNTIME_DIR:-} && -d $XDG_RUNTIME_DIR && -w $XDG_RUNTIME_DIR ]] && tmproot=$XDG_RUNTIME_DIR
base=$(mktemp -d "$tmproot/grassfield-key.XXXXXX")
chmod 0700 "$base"
gh="$base/gnupg"
mkdir -m 0700 "$gh"
vh="$base/verify/home"
mkdir -m 0700 "$base/verify" "$vh"
export GNUPGHOME="$gh"
log="$base/gpg.log"
: >"$log"

fail_step() {
  { ((fr)) && printf 'Erreur : %s\n' "$2" || printf 'Error: %s\n' "$1"; } >&2
  tail -n 8 "$log" >&2 2>/dev/null || true
  exit 1
}
gpgp() { gpg --batch --no-tty --yes --homedir "$gh" "$@"; }
gpgs() { printf '%s\n' "$pass" | gpg --batch --no-tty --yes --homedir "$gh" --pinentry-mode loopback --passphrase-fd 0 "$@"; }
gpgv_() { printf '%s\n' "$pass" | gpg --batch --no-tty --yes --homedir "$vh" --pinentry-mode loopback --passphrase-fd 0 "$@"; }
fpr_of() { awk -F: '$1 == "fpr" { print toupper($10); exit }'; }

# ---- the passphrase --------------------------------------------------------------------------------------------------
if ((fr)); then printf 'Phrase secrete de la cle : ' >&2; else printf 'Passphrase of the key: ' >&2; fi
IFS= read -rs pass || die "no passphrase was entered" "aucune phrase secrete saisie"
[[ -t 0 ]] && printf '\n' >&2
[[ -n $pass ]] || die "the passphrase is empty" "la phrase secrete est vide"

# ---- import, then extend ---------------------------------------------------------------------------------------------
say "Importing the secret key..." "Importation de la cle secrete..."
gpgs --import "$secret" >>"$log" 2>&1 || fail_step "gpg could not import the secret key (wrong passphrase or not a secret key file)" \
  "gpg n'a pas pu importer la cle secrete (mauvaise phrase secrete ou fichier qui n'est pas une cle secrete)"
before=$(gpgp --with-colons --list-secret-keys 2>>"$log") || fail_step "cannot list the imported key" "impossible de lister la cle importee"
nsec=$(awk -F: '$1 == "sec"' <<<"$before" | wc -l)
[[ $nsec -eq 1 ]] || fail_step "expected exactly one secret key in the file, found $nsec" "une seule cle secrete attendue dans le fichier, $nsec trouvee(s)"
nssb=$(awk -F: '$1 == "ssb"' <<<"$before" | wc -l)
[[ $nssb -eq 0 ]] || fail_step "unexpected secret subkey in the file" "sous-cle secrete inattendue dans le fichier"
fpr=$(fpr_of <<<"$before")
[[ $fpr =~ ^[0-9A-F]{40}$ ]] || fail_step "could not read the key's fingerprint" "empreinte de la cle illisible"
[[ $fpr == "$want" ]] || fail_step "the key in the file has fingerprint $fpr, not the expected $want" \
  "la cle du fichier a l'empreinte $fpr, pas l'empreinte attendue $want"
oldexp=$(awk -F: '$1 == "sec" { print $7; exit }' <<<"$before")

say "Extending the expiry to $expire from today..." "Prolongation de l'expiration de $expire a partir d'aujourd'hui..."
gpgs --quick-set-expire "$fpr" "$expire" >>"$log" 2>&1 || fail_step "gpg could not extend the expiry" "gpg n'a pas pu prolonger l'expiration"
fpr2=$(gpgp --with-colons --list-secret-keys 2>>"$log" | fpr_of)
[[ $fpr2 == "$fpr" ]] || fail_step "the fingerprint changed while extending" "l'empreinte a change pendant la prolongation"

# ---- the output folder -----------------------------------------------------------------------------------------------
mkdir -p -- "$(dirname -- "$out")"
mkdir -m 0700 -- "$out" 2>/dev/null || die "$out already exists; nothing was written." "$out existe deja ; rien n'a ete ecrit."
out_made=1
fstype=$(stat -f -c %T -- "$out" 2>/dev/null || echo unknown)
case $fstype in
  tmpfs | ramfs) ;;
  *) say "WARNING: $out is on a '$fstype' filesystem, not tmpfs: a secret written here may survive its deletion (btrfs is copy-on-write). Prefer the default folder." \
       "ATTENTION : $out est sur un systeme de fichiers '$fstype', pas en tmpfs : un secret ecrit ici peut survivre a sa suppression (btrfs copie a l'ecriture). Preferez le dossier par defaut." >&2 ;;
esac
pub="$out/grassfield-signing-key.asc"
sec="$out/SECRET-grassfield-signing-key.asc"
fpf="$out/fingerprint.txt"
exf="$out/expiry.txt"

gpgp --armor --export "$fpr" >"$pub" 2>>"$log" || fail_step "export of the public key failed" "export de la cle publique impossible"
printf '%s\n' "$fpr" >"$fpf"
gpgs --armor --export-secret-keys "$fpr" >"$sec" 2>>"$log" || fail_step "export of the secret key failed" "export de la cle secrete impossible"
chmod 0600 "$sec"
chmod 0644 "$pub" "$fpf"

# ---- the script checks its own output --------------------------------------------------------------------------------
say "Checking the files..." "Verification des fichiers..."
listing=$(gpgp --with-colons --show-keys "$pub" 2>>"$log") || fail_step "the public key file is unreadable" "le fichier de cle publique est illisible"
primaries=$(awk -F: '$1 == "pub"' <<<"$listing" | wc -l)
subs=$(awk -F: '$1 == "sub"' <<<"$listing" | wc -l)
pubfpr=$(fpr_of <<<"$listing")
[[ $primaries -eq 1 ]] || fail_step "expected exactly one primary key, found $primaries" "une seule cle primaire attendue, $primaries trouvee(s)"
[[ $subs -eq 0 ]] || fail_step "unexpected subkey in the public key" "sous-cle inattendue dans la cle publique"
[[ $pubfpr == "$fpr" ]] || fail_step "the public key's fingerprint differs from the key that was renewed" \
  "l'empreinte de la cle publique differe de la cle prolongee"
awk -F: '$1 == "pub" { exit ($12 ~ /s/ ? 0 : 1) }' <<<"$listing" || fail_step "the primary key cannot sign" "la cle primaire ne peut pas signer"
newexp=$(awk -F: '$1 == "pub" { print $7; exit }' <<<"$listing")
[[ $newexp =~ ^[0-9]+$ ]] || fail_step "the public key has no expiry date" "la cle publique n'a pas de date d'expiration"
now=$(date +%s)
[[ $newexp -gt $now ]] || fail_step "the new expiry date is in the past" "la nouvelle date d'expiration est dans le passe"
[[ -z $oldexp || $newexp -gt $oldexp ]] || fail_step "the new expiry date is not later than the old one" "la nouvelle date d'expiration n'est pas posterieure a l'ancienne"
# At least 300 days from now (a shorter extension would be renewed again at once).
[[ $newexp -ge $((now + 300 * 86400)) ]] || fail_step "the new expiry is less than 300 days away" "la nouvelle expiration est a moins de 300 jours"

seclisting=$(gpgp --with-colons --show-keys "$sec" 2>>"$log") || fail_step "the secret key file is unreadable" "le fichier de cle secrete est illisible"
awk -F: '$1 == "sec" { f = 1 } END { exit f ? 0 : 1 }' <<<"$seclisting" \
  || fail_step "the secret key file holds no secret key (no sec record)" "le fichier de cle secrete ne contient pas de cle secrete (pas d'enregistrement sec)"
secfpr=$(fpr_of <<<"$seclisting")
[[ $secfpr == "$pubfpr" ]] || fail_step "the secret key file is not the public key's twin" "le fichier de cle secrete ne correspond pas a la cle publique"
secexp=$(awk -F: '$1 == "sec" { print $7; exit }' <<<"$seclisting")
[[ $secexp == "$newexp" ]] || fail_step "the secret key file does not carry the new expiry date" "le fichier de cle secrete ne porte pas la nouvelle date d'expiration"

gpgv_ --import "$sec" >>"$log" 2>&1 || fail_step "the secret key file cannot be imported into a fresh home" "le fichier de cle secrete ne s'importe pas dans un dossier neuf"
printf 'grassfield signing key renewal self-test %s\n' "$fpr" >"$base/verify/data"
gpgv_ --detach-sign --local-user "$fpr!" --output "$base/verify/data.sig" "$base/verify/data" >>"$log" 2>&1 \
  || fail_step "the test signature failed" "la signature de test a echoue"
gpgp --dearmor <"$pub" >"$base/verify/pub.gpg" 2>>"$log" || fail_step "the public key cannot be converted for gpgv" "conversion de la cle publique pour gpgv impossible"
status=$(gpgv --homedir "$base/verify" --status-fd 1 --keyring "$base/verify/pub.gpg" "$base/verify/data.sig" "$base/verify/data" 2>>"$log") \
  || fail_step "gpgv rejects the test signature" "gpgv refuse la signature de test"
awk -v f="$fpr" '$1 == "[GNUPG:]" && $2 == "VALIDSIG" && $3 == f && $NF == f { ok = 1 } END { exit ok ? 0 : 1 }' <<<"$status" \
  || fail_step "the test signature is not by the primary key" "la signature de test n'est pas de la cle primaire"
[[ $(stat -c %a "$sec") == 600 && $(stat -c %a "$out") == 700 ]] || fail_step "unexpected file modes" "modes de fichiers inattendus"

# ---- the dates, README.txt and expiry.txt ----------------------------------------------------------------------------
expiry_date=$(date -u -d "@$newexp" +%F)
deadline=$(date -u -d "$expiry_date -6 months" +%F)
reminder=$(date -u -d "$expiry_date -9 months" +%F)
printf 'expires: %s\nrenewal deadline (extended key in grassfield-keyring): %s\nreminder expected from: %s\n' "$expiry_date" "$deadline" "$reminder" >"$exf"
chmod 0644 "$exf"
cat >"$out/README.txt" <<EOF
GRASSFIELD SIGNING KEY, RENEWED / CLE DE SIGNATURE DE GRASSFIELD, PROLONGEE
Fingerprint / Empreinte (unchanged / inchangee) : $fpr
NEW EXPIRY / NOUVELLE EXPIRATION : $expiry_date
NEXT RENEWAL DEADLINE / PROCHAINE ECHEANCE : $deadline (extended key in grassfield-keyring / cle prolongee dans grassfield-keyring)
Reminder expected from / rappel attendu des : $reminder

EN - Next steps (ADR-0033 b.9)
 DO NOT LOG OUT OR REBOOT until step 1 is done and checked: this folder is on tmpfs. Never import the key into ~/.gnupg.
 1. Replace the two offline copies of SECRET-grassfield-signing-key.asc (and the public key and expiry.txt) with the files of
    this folder, and check each copy with cmp. The revocation certificate is unchanged: keep it.
 2. Replace GRASSFIELD_SIGNING_KEY in publish-stable and publish-beta (gpg refuses to sign once the key has expired, and CI
    needs the extended secret key).
 3. Send ONLY grassfield-signing-key.asc (the extended public key) to the integrator, who puts it in grassfield-keyring (and
    packaging/pacman/) and ships it NOW: it must reach every client before the old expiry date, at least six months ahead.
    The fingerprint did not change, so repository.conf does not change.
 4. LAST: delete this folder AND the copy of the SECRET file you placed in \$XDG_RUNTIME_DIR as this script's input
    ("rm -rf" on tmpfs is enough; do not rely on shred on btrfs).
 5. Never send the SECRET file or the passphrase. If this script was killed with SIGKILL, run its --help cleanup line.

FR - La suite (ADR-0033 b.9 )
 NE VOUS DECONNECTEZ PAS ET NE REDEMARREZ PAS avant la fin de l'etape 1 : ce dossier est en tmpfs. N'importez jamais la cle dans ~/.gnupg.
 1. Remplacez les deux copies hors ligne de SECRET-grassfield-signing-key.asc (et la cle publique et expiry.txt) par les
    fichiers de ce dossier, et verifiez chaque copie avec cmp. Le certificat de revocation est inchange : gardez-le.
 2. Remplacez GRASSFIELD_SIGNING_KEY dans publish-stable et publish-beta (gpg refuse de signer avec une cle expiree, et la CI
    a besoin de la cle secrete prolongee).
 3. Envoyez UNIQUEMENT grassfield-signing-key.asc (la cle publique prolongee) a l'integrateur, qui la met dans grassfield-keyring
    (et packaging/pacman/) et la livre MAINTENANT : elle doit atteindre tous les clients avant l'ancienne expiration, six mois
    avant au moins. L'empreinte n'a pas change : repository.conf non plus.
 4. EN DERNIER : supprimez ce dossier ET la copie du fichier SECRET placee dans \$XDG_RUNTIME_DIR comme entree de ce script
    (« rm -rf » suffit en tmpfs ; ne comptez pas sur shred sous btrfs).
 5. N'envoyez jamais le fichier SECRET ni la phrase secrete. Apres un SIGKILL, voir la ligne de nettoyage de --help.
EOF
chmod 0644 "$out/README.txt"

# ---- the report ------------------------------------------------------------------------------------------------------
say "" ""
say "Done. Fingerprint (unchanged):" "Termine. Empreinte (inchangee) :"
printf '  %s\n' "$fpr"
say "New expiry $expiry_date; renew again before $deadline." "Nouvelle expiration le $expiry_date ; a renouveler avant le $deadline."
say "Files in $out:" "Fichiers dans $out :"
printf '  %s\n' "$pub" "$fpf" "$sec  (SECRET)" "$exf" "$out/README.txt"
say "Next: $out/README.txt." "Suite : $out/README.txt."
