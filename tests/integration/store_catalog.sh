#!/usr/bin/env bash
# Grassfield Store, step 1: the catalog's signature checked by the real gpgv against throwaway keys (ADR-0037 g; spec
# acceptance A1), with the whole backend's unit tests, in a throwaway Arch container. Never on a real machine: outside a
# container it starts one; inside, it refuses unless it is root in a container with the repository at /src.
#
#   tests/integration/store_catalog.sh
#   Runs `docker run --rm --network host` on archlinux:base (digest pinned below) with the repository mounted read-only;
#   HTTPS_PROXY/HTTP_PROXY/NO_PROXY are passed through and GRASSFIELD_TEST_CA, when set, is mounted as the container's CA
#   bundle (for a proxied network). Exit 0 all PASS (or SKIP without docker), 1 a FAIL, 2 usage.
#
# Inside: qt6-base, gtest, gcc and gnupg from Arch; three throwaway ed25519 keys made in a temporary GnuPG home (good,
# revoked, rogue) and gone with the container; a keyring folder laid out as grassfield-keyring's private folder
# (grassfield.gpg with the three public keys, grassfield-trusted listing good and revoked, grassfield-revoked listing
# revoked); the fixture catalog signed by each key, and a copy with one byte changed. Then the unit tests (plain and
# ASan), with STORE_TEST_REAL_GPGV pointing at that folder.
set -uo pipefail

IMAGE=archlinux:base@sha256:52dfbd5afb23a220d5ee92dafcb4c788d96c026ed04179890c23adef4c897fa0

if [[ ! -f /.dockerenv && ! -f /run/.containerenv ]]; then
  root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
  if ! command -v docker >/dev/null || ! docker info >/dev/null 2>&1; then
    echo "SKIP: store_catalog (no docker)"
    exit 0
  fi
  ca=()
  [[ -n ${GRASSFIELD_TEST_CA:-} ]] && ca=(-v "$GRASSFIELD_TEST_CA:/test-ca.crt:ro")
  exec docker run --rm --network host -e HTTPS_PROXY -e HTTP_PROXY -e NO_PROXY -e https_proxy -e http_proxy -e no_proxy \
    "${ca[@]}" -v "$root":/src:ro "$IMAGE" bash /src/tests/integration/store_catalog.sh
fi

[[ $(id -u) == 0 && -d /src/apps/store ]] || { echo "refused: run as root in a container with the repository at /src"; exit 2; }
if [[ -f /test-ca.crt ]]; then
  cp /test-ca.crt /etc/ca-certificates/trust-source/anchors/test-ca.crt && update-ca-trust
fi
fail=0
step() { printf '\n== %s\n' "$*"; }

step "tools (a whole upgrade, never -Sy alone)"
pacman -Syu --noconfirm --needed qt6-base gtest gcc pkgconf gnupg zlib git >/tmp/pacman.log 2>&1 || { tail -5 /tmp/pacman.log; exit 1; }
pacman -Q qt6-base gtest gnupg | sed 's/^/  /'
cp -r /src /work && cd /work

step "throwaway keys (a temporary GnuPG home, gone with the container)"
export GNUPGHOME=$(mktemp -d)
keys=/tmp/keyring
mkdir -p "$keys"
fpr() { gpg --batch --with-colons --list-keys "$1" | awk -F: '$1 == "fpr" {print $10; exit}'; }
for name in good revoked rogue; do
  gpg --batch --pinentry-mode loopback --passphrase '' --quick-gen-key "Store test $name <$name@grassfield.invalid>" ed25519 sign 1d 2>/dev/null
done
good=$(fpr good@grassfield.invalid) revoked=$(fpr revoked@grassfield.invalid) rogue=$(fpr rogue@grassfield.invalid)
gpg --batch --export "$good" "$revoked" "$rogue" >"$keys/grassfield.gpg"
printf '%s:4:\n%s:4:\n' "$good" "$revoked" >"$keys/grassfield-trusted"
printf '%s\n' "$revoked" >"$keys/grassfield-revoked"
cp tests/fixtures/store/catalog-good.json "$keys/catalog.json"
sed 's/Discover/Discovrr/' "$keys/catalog.json" >"$keys/changed.json"
for name in good revoked rogue; do
  gpg --batch --yes --local-user "$(fpr "$name@grassfield.invalid")!" --detach-sign --output "$keys/$name.sig" "$keys/catalog.json"
done
echo "  good $good, revoked $revoked, rogue $rogue (rogue in the keyring, not trusted)"

for variant in "" --asan; do
  step "the backend's unit tests${variant:+ ($variant)}, the real gpgv included"
  if apps/store/build-direct.sh --tests $variant >/tmp/build.log 2>&1; then
    bin=.dev/build/store-unit-tests${variant:+-asan}
    if STORE_TEST_REAL_GPGV=$keys "$bin" --gtest_brief=1 >/tmp/tests.log 2>&1; then
      grep -E '^\[  (PASSED|SKIPPED|FAILED) ' /tmp/tests.log | sed 's/^/  /'
      if grep -q 'SKIPPED' /tmp/tests.log; then
        echo "FAIL: a test was skipped although the real gpgv is here"; fail=1
      else
        echo "PASS: unit tests${variant:+ ($variant)}, RealGpgv included"
      fi
    else
      tail -30 /tmp/tests.log; echo "FAIL: unit tests${variant:+ ($variant)}"; fail=1
    fi
  else
    tail -20 /tmp/build.log; echo "FAIL: build${variant:+ ($variant)}"; fail=1
  fi
done
rm -rf "$GNUPGHOME"
exit $fail
