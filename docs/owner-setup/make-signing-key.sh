#!/usr/bin/env bash
# make-signing-key.sh: the OWNER runs this on their own machine to create Grassfield's package signing key
# (ADR-0033 b.7, owner decision O11 of 2026-11-03). Agents and the integrator never run it and never see the private key.
# Le PROPRIETAIRE lance ce script sur sa propre machine pour creer la cle de signature des paquets de Grassfield.
#
# What it does / ce qu'il fait:
#   - makes the key in a throwaway GNUPGHOME (mktemp -d, 0700); ~/.gnupg is never read or written;
#   - Ed25519, sign-only primary key, 2-year expiry, UID "Grassfield Packages <packages@grassfield.site>";
#   - asks the passphrase twice (read silently; never echoed, logged or put on a command line);
#   - writes five files to a new private folder, then checks them;
#   - always stops the temporary gpg-agent and shreds the temporary GNUPGHOME, whatever happens.
# Prints only the fingerprint and the paths. Details: docs/owner-setup/hosting-and-key.md.
set -euo pipefail
umask 077

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
  (default ~/grassfield-signing-key-YYYYMMDD; created 0700; the script refuses to overwrite it):
  Cree la cle de signature des paquets dans un GNUPGHOME jetable et ecrit, dans DOSSIER
  (defaut ~/grassfield-signing-key-AAAAMMJJ ; cree en 0700 ; le script refuse d'ecraser) :

    grassfield-signing-key.asc         public key / cle publique
    fingerprint.txt                    the 40-hex primary fingerprint / l'empreinte primaire (40 hex)
    SECRET-grassfield-signing-key.asc  SECRET key, 0600 / cle SECRETE, 0600
    revocation-certificate.asc         revocation certificate, 0600 / certificat de revocation, 0600
    README.txt                         next steps / la suite

  Key: Ed25519, sign-only primary key, expires in 2 years, UID "Grassfield Packages <packages@grassfield.site>".
  You type the passphrase twice (at least 12 characters; nothing is shown). ~/.gnupg is never touched.
  Cle : Ed25519, cle primaire de signature seule, expire dans 2 ans. La phrase secrete est saisie deux fois
  (12 caracteres au moins ; rien ne s'affiche). ~/.gnupg n'est jamais touche.

  Options:
    -o, --output DIR    output folder / dossier de sortie
    -h, --help          this help / cette aide
EOF
}

out=""
while (($#)); do
  case $1 in
    -h | --help) usage; exit 0 ;;
    -o | --output) [[ $# -ge 2 && -n $2 ]] || die "--output needs a folder" "--output demande un dossier"; out=$2; shift ;;
    --output=*) out=${1#--output=} ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
[[ -n $out ]] || out="$HOME/grassfield-signing-key-$(date +%Y%m%d)"

for tool in gpg gpgconf gpgv mktemp; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is not installed (pacman -S gnupg)" "$tool n'est pas installe (pacman -S gnupg)"
done
[[ ! -e $out && ! -L $out ]] || die "$out already exists; nothing was written. Choose another folder (--output)." \
  "$out existe deja ; rien n'a ete ecrit. Choisissez un autre dossier (--output)."

# ---- cleanup on every exit path --------------------------------------------------------------------------------------
base="" gh="" out_made=0 pass="" pass2=""

wipe() { # shred every regular file under $1, then remove it
  [[ -n $1 && -d $1 ]] || return 0
  if command -v shred >/dev/null 2>&1; then find "$1" -type f -exec shred -u -- {} + >/dev/null 2>&1 || true; fi
  rm -rf -- "$1"
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM HUP
  set +e
  pass="" pass2=""
  if [[ -n $gh && -d $gh ]]; then gpgconf --homedir "$gh" --kill all >/dev/null 2>&1; fi
  wipe "$base"
  # A run that did not finish leaves no partial folder (it may hold secret material).
  if ((rc != 0 && out_made)); then wipe "$out"; fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

base=$(mktemp -d "${TMPDIR:-/tmp}/grassfield-key.XXXXXX")
chmod 0700 "$base"
gh="$base/gnupg"
mkdir -m 0700 "$gh"
mkdir -m 0700 "$base/verify"
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

fpr_of() { # fpr_of FILE-OR-"" : the primary fingerprint (first fpr record) of the colon listing on stdin
  awk -F: '$1 == "fpr" { print toupper($10); exit }'
}
fpr=$(gpgp --with-colons --list-secret-keys 2>>"$log" | fpr_of)
[[ $fpr =~ ^[0-9A-F]{40}$ ]] || fail_step "could not read the new key's fingerprint" "empreinte de la nouvelle cle illisible"

# ---- the output folder (refuses to overwrite: mkdir without -p fails on an existing folder) ---------------------------
mkdir -p -- "$(dirname -- "$out")"
mkdir -m 0700 -- "$out" 2>/dev/null || die "$out already exists; nothing was written." "$out existe deja ; rien n'a ete ecrit."
out_made=1
pub="$out/grassfield-signing-key.asc"
sec="$out/SECRET-grassfield-signing-key.asc"
rev="$out/revocation-certificate.asc"
fpf="$out/fingerprint.txt"

gpgp --armor --export "$fpr" >"$pub" 2>>"$log" || fail_step "export of the public key failed" "export de la cle publique impossible"
printf '%s\n' "$fpr" >"$fpf"
gpgs --armor --export-secret-keys "$fpr" >"$sec" 2>>"$log" || fail_step "export of the secret key failed" "export de la cle secrete impossible"
# gpg writes a revocation certificate at creation, with a colon in front of its first line so that nobody uses it by accident.
revsrc="$gh/openpgp-revocs.d/$fpr.rev"
[[ -s $revsrc ]] || fail_step "gpg wrote no revocation certificate" "gpg n'a pas ecrit de certificat de revocation"
sed '/^:-----BEGIN PGP PUBLIC KEY BLOCK-----/s/^://' "$revsrc" >"$rev"
chmod 0600 "$sec" "$rev"
chmod 0644 "$pub" "$fpf"
grep -q '^-----BEGIN PGP PUBLIC KEY BLOCK-----' "$rev" || fail_step "the revocation certificate is unreadable" "le certificat de revocation est illisible"

cat >"$out/README.txt" <<EOF
GRASSFIELD SIGNING KEY / CLE DE SIGNATURE DE GRASSFIELD
Fingerprint / Empreinte : $fpr
UID : $UID_TEXT   (Ed25519, sign only / signature seule, expires in 2 years / expire dans 2 ans)

EN - Next steps (full guide: docs/owner-setup/hosting-and-key.md, sections e to g)
 1. Add SECRET-grassfield-signing-key.asc and its passphrase to the protected environments publish-stable and publish-beta of grassfieldhq/grassfield-packages
    as GRASSFIELD_SIGNING_KEY and GRASSFIELD_SIGNING_PASSPHRASE (gh secret set ... --env ...).
 2. Copy SECRET-grassfield-signing-key.asc and revocation-certificate.asc to two offline media, then delete the SECRET file
    from this folder (shred -u). Keep the revocation certificate offline: whoever has it can revoke the key.
 3. Send ONLY grassfield-signing-key.asc and fingerprint.txt to the integrator. Never send the SECRET file, the revocation
    certificate or the passphrase.
 4. Renew the key before it expires in two years (ADR-0033 b.5).

FR - La suite (guide complet : docs/owner-setup/hosting-and-key.md, sections e a g)
 1. Ajoutez SECRET-grassfield-signing-key.asc et sa phrase secrete aux environnements proteges publish-stable et publish-beta de grassfieldhq/grassfield-packages
    sous GRASSFIELD_SIGNING_KEY et GRASSFIELD_SIGNING_PASSPHRASE (gh secret set ... --env ...).
 2. Copiez SECRET-grassfield-signing-key.asc et revocation-certificate.asc sur deux supports hors ligne, puis supprimez le
    fichier SECRET de ce dossier (shred -u). Gardez le certificat de revocation hors ligne : qui le possede peut revoquer la cle.
 3. Envoyez UNIQUEMENT grassfield-signing-key.asc et fingerprint.txt a l'integrateur. N'envoyez jamais le fichier SECRET, le
    certificat de revocation ni la phrase secrete.
 4. Renouvelez la cle avant son expiration, dans deux ans (ADR-0033 b.5).
EOF
chmod 0644 "$out/README.txt"

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
secfpr=$(gpgp --with-colons --show-keys "$sec" 2>>"$log" | fpr_of)
[[ $secfpr == "$pubfpr" ]] || fail_step "the secret key file is not the public key's twin" "le fichier de cle secrete ne correspond pas a la cle publique"

# A throwaway signature, checked with gpgv against the exported public key only.
printf 'grassfield signing key self-test %s\n' "$fpr" >"$base/verify/data"
gpgs --detach-sign --local-user "$fpr!" --output "$base/verify/data.sig" "$base/verify/data" >>"$log" 2>&1 \
  || fail_step "the test signature failed" "la signature de test a echoue"
gpgp --dearmor <"$pub" >"$base/verify/pub.gpg" 2>>"$log" || fail_step "the public key cannot be converted for gpgv" "conversion de la cle publique pour gpgv impossible"
status=$(gpgv --homedir "$base/verify" --status-fd 1 --keyring "$base/verify/pub.gpg" "$base/verify/data.sig" "$base/verify/data" 2>>"$log") \
  || fail_step "gpgv rejects the test signature" "gpgv refuse la signature de test"
awk -v f="$fpr" '$1 == "[GNUPG:]" && $2 == "VALIDSIG" && $3 == f && $NF == f { ok = 1 } END { exit ok ? 0 : 1 }' <<<"$status" \
  || fail_step "the test signature is not by the primary key" "la signature de test n'est pas de la cle primaire"
[[ $(stat -c %a "$sec") == 600 && $(stat -c %a "$rev") == 600 && $(stat -c %a "$out") == 700 ]] \
  || fail_step "unexpected file modes" "modes de fichiers inattendus"

# ---- the report: the fingerprint and the paths, nothing secret -------------------------------------------------------
say "" ""
say "Done. Fingerprint:" "Termine. Empreinte :"
printf '  %s\n' "$fpr"
say "Files in $out:" "Fichiers dans $out :"
printf '  %s\n' "$pub" "$fpf" "$sec  (SECRET)" "$rev  (SECRET)" "$out/README.txt"
say "Next: $out/README.txt and docs/owner-setup/hosting-and-key.md." "Suite : $out/README.txt et docs/owner-setup/hosting-and-key.md."
