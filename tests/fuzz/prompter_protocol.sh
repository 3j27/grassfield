#!/usr/bin/env bash
# Fuzzing of prompter/1's reading of the shell (bridges/prompter/src/Protocol.cpp: parseShellLine, parseFlatObject,
# decodeJsonString, takeLines; ADR-0035 D-9): tests/fuzz/prompter_protocol.cpp, its contract in that file's header. With
# clang++ and libFuzzer it runs libFuzzer (ASan, UBSan) for GF_FUZZ_SECONDS; without them the same harness's mutation loop,
# built with g++ and ASan and UBSan, runs for GF_FUZZ_SECONDS (default 20) or GF_FUZZ_ITERATIONS inputs from GF_FUZZ_SEED.
# No bus, no socket, no file of the user's: the inputs are bytes in memory. Prints PASS/FAIL lines; exit 0 when nothing was
# found. SKIP without a C++ compiler or the Qt 6 Core headers.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/fuzz-prompter.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
pkg-config --exists Qt6Core 2>/dev/null || { echo "SKIP: prompter_protocol fuzz needs the Qt 6 Core headers"; exit 0; }
src=$root/bridges/prompter/src
version=$(tr -d '[:space:]' <"$root/VERSION")
flags=(-std=c++20 -O1 -g -fno-omit-frame-pointer "-fsanitize=address,undefined" -fno-sanitize-recover=undefined
  -DQT_NO_KEYWORDS "-DGRASSFIELD_VERSION=\"$version\"" -I"$src")
seconds=${GF_FUZZ_SECONDS:-20}
if command -v clang++ >/dev/null && echo 'extern "C" int LLVMFuzzerTestOneInput(const unsigned char*, unsigned long){return 0;}' \
    | clang++ -x c++ -fsanitize=fuzzer - -o "$tmp/probe" 2>/dev/null; then
  # shellcheck disable=SC2046
  clang++ "${flags[@]}" -fsanitize=fuzzer -DGF_LIBFUZZER $(pkg-config --cflags Qt6Core) "$root/tests/fuzz/prompter_protocol.cpp" "$src/Protocol.cpp" \
    $(pkg-config --libs Qt6Core) -o "$tmp/fuzz" >"$tmp/build.log" 2>&1 || { cat "$tmp/build.log"; echo "FAIL: prompter_protocol fuzz builds (libFuzzer)"; exit 1; }
  mkdir -p "$tmp/corpus"
  if "$tmp/fuzz" -max_total_time="$seconds" -max_len=20000 -seed="${GF_FUZZ_SEED:-1}" "$tmp/corpus" >"$tmp/run.log" 2>&1; then
    echo "PASS: prompter_protocol fuzz (libFuzzer, $seconds s): $(grep -o 'Done [0-9]* runs' "$tmp/run.log" | tail -n 1), no finding"
    exit 0
  fi
  tail -n 30 "$tmp/run.log"
  echo "FAIL: prompter_protocol fuzz (libFuzzer) found something"
  exit 1
fi
command -v g++ >/dev/null || { echo "SKIP: prompter_protocol fuzz needs g++ or clang++"; exit 0; }
# shellcheck disable=SC2046
g++ "${flags[@]}" -Wall -Wextra -Wno-sfinae-incomplete $(pkg-config --cflags Qt6Core) "$root/tests/fuzz/prompter_protocol.cpp" "$src/Protocol.cpp" \
  $(pkg-config --libs Qt6Core) -o "$tmp/fuzz" >"$tmp/build.log" 2>&1 || { cat "$tmp/build.log"; echo "FAIL: prompter_protocol fuzz builds"; exit 1; }
if out=$(GF_FUZZ_SECONDS=$seconds "$tmp/fuzz" 2>&1); then
  echo "PASS: prompter_protocol fuzz (mutation loop, ASan and UBSan): ${out#\[fuzz\] prompter-protocol: }"
  exit 0
fi
printf '%s\n' "$out" | tail -n 30
echo "FAIL: prompter_protocol fuzz found something"
exit 1
