#!/usr/bin/env bash
# make-signing-key.sh: the OWNER runs this on their own machine to create Grassfield's package signing key
# (ADR-0033 b.7, owner decision O11 of 2026-11-03). Agents and the integrator never run it and never see the private key.
# Le PROPRIETAIRE lance ce script sur sa propre machine pour creer la cle de signature des paquets de Grassfield.
#
# What it does / ce qu'il fait:
#   - makes the key in a throwaway GNUPGHOME on tmpfs ($XDG_RUNTIME_DIR); ~/.gnupg is never read or written;
#   - Ed25519, sign-only primary key, 2-year expiry, UID "Grassfield Packages <packages@grassfield.site>";
#   - asks the passphrase twice (read silently; never echoed, logged or put on a command line);
#   - writes five files to a new private folder (on tmpfs by default, so no secret reaches the btrfs disk), then checks
#     them, the secret file included (a signature made from a fresh home that holds only that file);
#   - always stops the temporary gpg-agent and shreds the temporary GNUPGHOME, whatever happens (not after SIGKILL: see --help).
# Prints only the fingerprint and the paths. Details: ADR-0033 and ADR-0043. Renewal: renew-signing-key.sh.
set -euo pipefail
umask 077
ulimit -c 0 # no core dump of a process that holds a passphrase

readonly UID_TEXT="Grassfield Packages <packages@grassfield.site>"
readonly EXPIRY="2y"
readonly MIN_PASSPHRASE=12

fr=0
case ${LC_ALL:-${LC_MESSAGES:-${LANG:-}}} in fr*) fr=1 ;; esac
# say "english" "francais": a message in the owner's language, on stdout.
say() { if ((fr)); then printf '%s\n' "$2"; else printf '%s\n' "$1"; fi; }
# die "english" "francais": the same on stderr, then exit 1.
die() { if ((fr)); then printf 'Erreur : %s\n' "$2" >&2; else printf 'Error: %s\n' "$1" >&2; fi; exit 1; }

usage() {
  cat <<'EOF'
Usage: make-signing-key.sh [--output DIR] [--help]
Utilisation : make-signing-key.sh [--output DOSSIER] [--help]

  Creates Grassfield's package signing key in a throwaway GNUPGHOME and writes, to DIR
  (default $XDG_RUNTIME_DIR/grassfield-signing-key-YYYYMMDD, which is tmpfs; created 0700; never overwritten):
  Cree la cle de signature des paquets dans un GNUPGHOME jetable et ecrit, dans DOSSIER
  (defaut $XDG_RUNTIME_DIR/grassfield-signing-key-AAAAMMJJ, en tmpfs ; cree en 0700 ; jamais ecrase) :

    grassfield-signing-key.asc         public key / cle publique
    fingerprint.txt                    the 40-hex primary fingerprint / l'empreinte primaire (40 hex)
    SECRET-grassfield-signing-key.asc  SECRET key, 0600 / cle SECRETE, 0600
    revocation-certificate.asc         revocation certificate, GUARDED (first line starts with a colon), 0600 /
                                       certificat de revocation, PROTEGE (premiere ligne precedee de deux-points), 0600
    README.txt                         next steps, the expiry date and the renewal deadline / la suite, l'expiration, l'echeance

  Key: Ed25519, sign-only primary key, expires in 2 years, UID "Grassfield Packages <packages@grassfield.site>".
  You type the passphrase twice (at least 12 characters; nothing is shown). ~/.gnupg is never touched.
  Cle : Ed25519, cle primaire de signature seule, expire dans 2 ans. La phrase secrete est saisie deux fois
  (12 caracteres au moins ; rien ne s'affiche). ~/.gnupg n'est jamais touche.

  Without --output the folder is on tmpfs, which a logout or reboot erases: DO NOT LOG OUT OR REBOOT until you have copied ALL
  FIVE files to two offline media and checked each copy with cmp. Then set the GitHub secrets, send the integrator the
  public key and fingerprint.txt, and only LAST remove the folder. Never import the key into ~/.gnupg; never re-run the
  script to "recover" (it makes a different key). Do not rely on shred on btrfs. With --output ~/... a secret may land on
  the btrfs disk (copy-on-write: deleted files can survive): you are warned.
  Sans --output le dossier est en tmpfs, que la deconnexion ou le redemarrage efface : NE VOUS DECONNECTEZ PAS avant d'avoir
  copie les CINQ fichiers sur deux supports hors ligne et verifie chaque copie avec cmp. Puis les secrets GitHub, l'envoi
  de la cle publique, et EN DERNIER la suppression du dossier. Ne relancez jamais le script pour "recuperer".

  If the script is killed with SIGKILL (kill -9), a crash or a power cut, it cannot clean up. It leaves: the temporary
  folder (keys protected by your passphrase), a gpg-agent that may still hold the passphrase in memory, and perhaps a
  partial output folder. Clean up with this one line (and remove the partial output folder by hand):
  Si le script est tue par SIGKILL, plante ou si le courant est coupe, il ne peut pas nettoyer. Une ligne suffit :

    for d in "${XDG_RUNTIME_DIR:-/tmp}"/grassfield-key.*; do gpgconf --homedir "$d/gnupg" --kill all; gpgconf --homedir "$d/verify/home" --kill all; rm -rf "$d"; done

  Options:
    -o, --output DIR    output folder / dossier de sortie
    -h, --help          this help / cette aide
EOF
}

out=""
explicit=0
while (($#)); do
  case $1 in
    -h | --help) usage; exit 0 ;;
    -o | --output) [[ $# -ge 2 && -n $2 ]] || die "--output needs a folder" "--output demande un dossier"; out=$2; explicit=1; shift ;;
    --output=*) out=${1#--output=}; explicit=1 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
if [[ -z $out ]]; then
  [[ -n ${XDG_RUNTIME_DIR:-} && -d $XDG_RUNTIME_DIR && -w $XDG_RUNTIME_DIR ]] \
    || die "no \$XDG_RUNTIME_DIR (a tmpfs folder); pass --output FOLDER explicitly" \
      "pas de \$XDG_RUNTIME_DIR (dossier en tmpfs) ; passez --output DOSSIER explicitement"
  out="$XDG_RUNTIME_DIR/grassfield-signing-key-$(date +%Y%m%d)"
fi

for tool in gpg gpgconf gpgv mktemp; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is not installed (pacman -S gnupg)" "$tool n'est pas installe (pacman -S gnupg)"
done
[[ ! -e $out && ! -L $out ]] || die "$out already exists; nothing was written. Choose another folder (--output)." \
  "$out existe deja ; rien n'a ete ecrit. Choisissez un autre dossier (--output)."

# ---- cleanup on every exit path (except SIGKILL) ---------------------------------------------------------------------
base="" gh="" vh="" out_made=0 pass="" pass2=""

wipe() { # shred every regular file under $1, then remove it (shred is best effort: tmpfs holds nothing on disk)
  [[ -n $1 && -d $1 ]] || return 0
  if command -v shred >/dev/null 2>&1; then find "$1" -type f -exec shred -u -- {} + >/dev/null 2>&1 || true; fi
  rm -rf -- "$1"
}

cleanup() {
  local rc=$?
  trap '' INT TERM QUIT HUP # a second Ctrl-C must not abort the cleanup
  trap - EXIT
  set +e
  pass="" pass2=""
  local h
  for h in "$gh" "$vh"; do
    if [[ -n $h && -d $h ]]; then gpgconf --homedir "$h" --kill all >/dev/null 2>&1; fi
  done
  wipe "$base"
  # A run that did not finish leaves no partial folder (it may hold secret material).
  if ((rc != 0 && out_made)); then wipe "$out"; fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 131' QUIT
trap 'exit 129' HUP

# The temporary folder is on tmpfs when there is one: $XDG_RUNTIME_DIR (user only), else $TMPDIR, else /tmp.
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

# Every gpg call is quiet; its messages go to a log in the temporary folder, shown only when a step fails.
fail_step() {
  { ((fr)) && printf 'Erreur : %s\n' "$2" || printf 'Error: %s\n' "$1"; } >&2
  tail -n 8 "$log" >&2 2>/dev/null || true
  exit 1
}
gpgp() { gpg --batch --no-tty --yes --homedir "$gh" "$@"; }                       # no secret needed
gpgs() { printf '%s\n' "$pass" | gpg --batch --no-tty --yes --homedir "$gh" --pinentry-mode loopback --passphrase-fd 0 "$@"; }
gpgv_() { printf '%s\n' "$pass" | gpg --batch --no-tty --yes --homedir "$vh" --pinentry-mode loopback --passphrase-fd 0 "$@"; }

# ---- the passphrase --------------------------------------------------------------------------------------------------
ask() { # ask "english prompt" "french prompt" VARIABLE
  local p=$1
  ((fr)) && p=$2
  printf '%s' "$p" >&2
  IFS= read -rs "$3" || die "no passphrase was entered" "aucune phrase secrete saisie"
  [[ -t 0 ]] && printf '\n' >&2
  return 0
}
tries=0
while :; do
  ask "Passphrase for the new key: " "Phrase secrete de la nouvelle cle : " pass
  ask "Type it again to confirm: " "Saisissez-la a nouveau pour confirmer : " pass2
  if [[ $pass == "$pass2" && ${#pass} -ge $MIN_PASSPHRASE ]]; then break; fi
  pass="" pass2=""
  tries=$((tries + 1))
  [[ -t 0 && $tries -lt 3 ]] || die "the passphrases differ or are shorter than $MIN_PASSPHRASE characters" \
    "les phrases secretes different ou font moins de $MIN_PASSPHRASE caracteres"
  say "They differ or are shorter than $MIN_PASSPHRASE characters. Again." "Elles different ou font moins de $MIN_PASSPHRASE caracteres. Recommencez."
done
pass2=""

# ---- the key ---------------------------------------------------------------------------------------------------------
say "Creating the key (a few seconds)..." "Creation de la cle (quelques secondes)..."
gpgs --quick-generate-key "$UID_TEXT" ed25519 sign "$EXPIRY" >>"$log" 2>&1 \
  || fail_step "gpg could not create the key" "gpg n'a pas pu creer la cle"

fpr_of() { # the primary fingerprint (first fpr record) of a colon listing on stdin
  awk -F: '$1 == "fpr" { print toupper($10); exit }'
}
fpr=$(gpgp --with-colons --list-secret-keys 2>>"$log" | fpr_of)
[[ $fpr =~ ^[0-9A-F]{40}$ ]] || fail_step "could not read the new key's fingerprint" "empreinte de la nouvelle cle illisible"

# ---- the output folder (refuses to overwrite: mkdir without -p fails on an existing folder) ---------------------------
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
rev="$out/revocation-certificate.asc"
fpf="$out/fingerprint.txt"

gpgp --armor --export "$fpr" >"$pub" 2>>"$log" || fail_step "export of the public key failed" "export de la cle publique impossible"
printf '%s\n' "$fpr" >"$fpf"
gpgs --armor --export-secret-keys "$fpr" >"$sec" 2>>"$log" || fail_step "export of the secret key failed" "export de la cle secrete impossible"
# gpg writes a revocation certificate at creation, with a colon in front of its first line so that nobody uses it by accident.
# The colon is KEPT: the certificate stays guarded (README.txt says how to un-guard it, only when it must be used).
revsrc="$gh/openpgp-revocs.d/$fpr.rev"
[[ -s $revsrc ]] || fail_step "gpg wrote no revocation certificate" "gpg n'a pas ecrit de certificat de revocation"
cp -- "$revsrc" "$rev"
chmod 0600 "$sec" "$rev"
chmod 0644 "$pub" "$fpf"
grep -q '^:-----BEGIN PGP PUBLIC KEY BLOCK-----' "$rev" || fail_step "the revocation certificate is unreadable or not guarded" \
  "le certificat de revocation est illisible ou n'est pas protege"

# ---- the script checks its own output --------------------------------------------------------------------------------
say "Checking the files..." "Verification des fichiers..."
listing=$(gpgp --with-colons --show-keys "$pub" 2>>"$log") || fail_step "the public key file is unreadable" "le fichier de cle publique est illisible"
primaries=$(awk -F: '$1 == "pub"' <<<"$listing" | wc -l)
subs=$(awk -F: '$1 == "sub"' <<<"$listing" | wc -l)
pubfpr=$(fpr_of <<<"$listing")
[[ $primaries -eq 1 ]] || fail_step "expected exactly one primary key, found $primaries" "une seule cle primaire attendue, $primaries trouvee(s)"
[[ $subs -eq 0 ]] || fail_step "unexpected subkey in the public key" "sous-cle inattendue dans la cle publique"
[[ $pubfpr == "$(tr -d '[:space:]' <"$fpf")" ]] || fail_step "the public key's fingerprint differs from fingerprint.txt" \
  "l'empreinte de la cle publique differe de fingerprint.txt"
awk -F: '$1 == "pub" { exit ($12 ~ /s/ ? 0 : 1) }' <<<"$listing" || fail_step "the primary key cannot sign" "la cle primaire ne peut pas signer"
expiry=$(awk -F: '$1 == "pub" { print $7; exit }' <<<"$listing")
[[ $expiry =~ ^[0-9]+$ && $expiry -gt $(date +%s) ]] || fail_step "the public key has no future expiry date" "la cle publique n'a pas de date d'expiration future"

# The SECRET file must hold a secret key (a public-only export would pass a fingerprint check): a "sec" record, the same
# fingerprint, and it must sign from a fresh home that imports nothing else.
seclisting=$(gpgp --with-colons --show-keys "$sec" 2>>"$log") || fail_step "the secret key file is unreadable" "le fichier de cle secrete est illisible"
awk -F: '$1 == "sec" { f = 1 } END { exit f ? 0 : 1 }' <<<"$seclisting" \
  || fail_step "the secret key file holds no secret key (no sec record)" "le fichier de cle secrete ne contient pas de cle secrete (pas d'enregistrement sec)"
secfpr=$(fpr_of <<<"$seclisting")
[[ $secfpr == "$pubfpr" ]] || fail_step "the secret key file is not the public key's twin" "le fichier de cle secrete ne correspond pas a la cle publique"

# A throwaway signature made with the exported SECRET file alone (a fresh home), checked with gpgv against the exported
# public key alone.
gpgv_ --import "$sec" >>"$log" 2>&1 || fail_step "the secret key file cannot be imported into a fresh home" "le fichier de cle secrete ne s'importe pas dans un dossier neuf"
printf 'grassfield signing key self-test %s\n' "$fpr" >"$base/verify/data"
gpgv_ --detach-sign --local-user "$fpr!" --output "$base/verify/data.sig" "$base/verify/data" >>"$log" 2>&1 \
  || fail_step "the test signature failed" "la signature de test a echoue"
gpgp --dearmor <"$pub" >"$base/verify/pub.gpg" 2>>"$log" || fail_step "the public key cannot be converted for gpgv" "conversion de la cle publique pour gpgv impossible"
status=$(gpgv --homedir "$base/verify" --status-fd 1 --keyring "$base/verify/pub.gpg" "$base/verify/data.sig" "$base/verify/data" 2>>"$log") \
  || fail_step "gpgv rejects the test signature" "gpgv refuse la signature de test"
awk -v f="$fpr" '$1 == "[GNUPG:]" && $2 == "VALIDSIG" && $3 == f && $NF == f { ok = 1 } END { exit ok ? 0 : 1 }' <<<"$status" \
  || fail_step "the test signature is not by the primary key" "la signature de test n'est pas de la cle primaire"
[[ $(stat -c %a "$sec") == 600 && $(stat -c %a "$rev") == 600 && $(stat -c %a "$out") == 700 ]] \
  || fail_step "unexpected file modes" "modes de fichiers inattendus"

# ---- README.txt (written last: it carries the dates) -----------------------------------------------------------------
expiry_date=$(date -u -d "@$expiry" +%F)
deadline=$(date -u -d "$expiry_date -6 months" +%F)
reminder=$(date -u -d "$expiry_date -9 months" +%F)
cat >"$out/README.txt" <<EOF
GRASSFIELD SIGNING KEY / CLE DE SIGNATURE DE GRASSFIELD
Fingerprint / Empreinte : $fpr
UID : $UID_TEXT   (Ed25519, sign only / signature seule)
EXPIRES / EXPIRE LE : $expiry_date
RENEWAL DEADLINE / ECHEANCE DE RENOUVELLEMENT : $deadline (the extended key must be in grassfield-keyring by then /
  la cle prolongee doit etre dans grassfield-keyring a cette date). Reminder expected from / rappel attendu des : $reminder.
Renew with docs/owner-setup/renew-signing-key.sh (ADR-0033 b.9). After the expiry date every client's update fails.

DO NOT LOG OUT OR REBOOT UNTIL THE OFFLINE COPIES ARE CHECKED (step 1). / NE VOUS DECONNECTEZ PAS ET NE REDEMARREZ PAS AVANT
D'AVOIR VERIFIE LES COPIES HORS LIGNE (etape 1). This folder is on $fstype ($([[ $fstype == tmpfs || $fstype == ramfs ]] && echo "memory: a logout or reboot erases it" || echo "NOT tmpfs: a secret here may survive its deletion")).
Never import this key into ~/.gnupg. Never re-run the script to "recover" a lost folder: it makes a DIFFERENT key.
N'importez jamais cette cle dans ~/.gnupg. Ne relancez jamais le script pour "recuperer" : il cree une AUTRE cle.

EN - Next steps, in this order, in one sitting (background: ADR-0033, ADR-0043)
 1. Copy ALL FIVE files of this folder to two offline media (two separate USB keys, kept in two places) and check each copy
    with cmp against the original. Only then go on. Whoever has the revocation certificate can revoke the key.
 2. Add SECRET-grassfield-signing-key.asc and its passphrase to the protected environments publish-stable and publish-beta of
    grassfieldhq/grassfield-packages as GRASSFIELD_SIGNING_KEY and GRASSFIELD_SIGNING_PASSPHRASE (gh secret set ... --env ...).
    GitHub secrets cannot be read back: if the offline copies are lost, the key is lost.
 3. Send ONLY grassfield-signing-key.asc and fingerprint.txt to the integrator. Never send the SECRET file, the revocation
    certificate or the passphrase.
 4. LAST: delete this folder ("rm -rf" on tmpfs is enough; do not rely on shred on btrfs).
 5. The revocation certificate is GUARDED: its first line starts with a colon, so it cannot be used by accident. Only when
    the key must really be revoked: sed 's/^://' revocation-certificate.asc > use.asc, then import use.asc into a gpg home
    and publish it (ADR-0033 b.5).
 6. If this script was killed with SIGKILL it left the temporary folder and perhaps a gpg-agent. Clean up with:
    for d in "\${XDG_RUNTIME_DIR:-/tmp}"/grassfield-key.*; do gpgconf --homedir "\$d/gnupg" --kill all; gpgconf --homedir "\$d/verify/home" --kill all; rm -rf "\$d"; done

FR - La suite, dans cet ordre, en une seule fois (contexte : ADR-0033, ADR-0043)
 1. Copiez les CINQ fichiers de ce dossier sur deux supports hors ligne (deux cles USB, rangees a deux endroits) et verifiez
    chaque copie avec cmp contre l'original. Ensuite seulement, continuez. Qui possede le certificat de revocation peut
    revoquer la cle.
 2. Ajoutez SECRET-grassfield-signing-key.asc et sa phrase secrete aux environnements proteges publish-stable et publish-beta de
    grassfieldhq/grassfield-packages sous GRASSFIELD_SIGNING_KEY et GRASSFIELD_SIGNING_PASSPHRASE (gh secret set ... --env ...).
    Les secrets GitHub ne se relisent pas : sans les copies hors ligne, la cle est perdue.
 3. Envoyez UNIQUEMENT grassfield-signing-key.asc et fingerprint.txt a l'integrateur. N'envoyez jamais le fichier SECRET, le
    certificat de revocation ni la phrase secrete.
 4. EN DERNIER : supprimez ce dossier (« rm -rf » suffit en tmpfs ; ne comptez pas sur shred sous btrfs).
 5. Le certificat de revocation est PROTEGE : sa premiere ligne commence par deux-points, il ne peut pas servir par erreur.
    Seulement si la cle doit vraiment etre revoquee : sed 's/^://' revocation-certificate.asc > use.asc, puis importez use.asc
    et publiez-le (ADR-0033 b.5).
 6. Si le script a ete tue par SIGKILL, la ligne de nettoyage du point 6 ci-dessus s'applique.
EOF
chmod 0644 "$out/README.txt"

# ---- the report: the fingerprint and the paths, nothing secret -------------------------------------------------------
say "" ""
say "Done. Fingerprint:" "Termine. Empreinte :"
printf '  %s\n' "$fpr"
say "Expires $expiry_date; renew before $deadline (renew-signing-key.sh)." "Expire le $expiry_date ; a renouveler avant le $deadline (renew-signing-key.sh)."
say "Files in $out:" "Fichiers dans $out :"
printf '  %s\n' "$pub" "$fpf" "$sec  (SECRET)" "$rev  (SECRET)" "$out/README.txt"
say "Next: $out/README.txt." "Suite : $out/README.txt."
