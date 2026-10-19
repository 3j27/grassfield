#!/usr/bin/env bash
# Stand-in for branding/cursors/build.sh in tests/shell/pointer_theme: same arguments, no tools needed.
#   fill #00ff00  slow (4 s), stops on SIGTERM and logs "term"
#   fill #ff0000  fails with the message of a missing tool
#   anything else builds in 0.3 s
# Every run appends to $out/fake.log: "start OUTLINE FILL", "done OUTLINE FILL", "term FILL", "removed".
set -u
out="" name="" outline="" fill="" remove=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --out) out=$2; shift ;;
    --name) name=$2; shift ;;
    --outline) outline=$2; shift ;;
    --fill) fill=$2; shift ;;
    --remove) remove=1 ;;
  esac
  shift
done
mkdir -p "$out"
log=$out/fake.log
if ((remove)); then
  rm -rf -- "${out:?}/${name:?}"
  echo "removed" >>"$log"
  exit 0
fi
echo "start $outline $fill" >>"$log"
case $fill in
  '#00ff00')
    trap 'echo "term $fill" >>"$log"; exit 143' TERM
    sleep 4 &
    wait $!
    ;;
  '#ff0000')
    echo "cursors: rsvg-convert not found" >&2
    exit 1
    ;;
  *) sleep 0.3 ;;
esac
mkdir -p "$out/$name"
echo "$outline $fill" >"$out/$name/colors"
echo "done $outline $fill" >>"$log"
