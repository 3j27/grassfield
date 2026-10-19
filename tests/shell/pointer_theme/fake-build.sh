#!/usr/bin/env bash
# Stand-in for branding/cursors/build.sh in tests/shell/pointer_theme: same arguments, no tools needed.
#   fill #00ff00  slow (4 s), stops on SIGTERM and logs "term"
#   fill #ff0000  fails with the message of a missing tool
#   fill #123456  ignores SIGTERM and has a child (sleep 30, pid in $out/grandchild.pid) that does too: only SIGKILL of the group stops it
#   fill #0000ff  installs the theme at once, then keeps running 4 s (a build cancelled after it replaced the theme)
#   --clean       logs "clean" in $out/clean.log and exits
#   anything else builds in 0.3 s
# Every run appends to $out/fake.log: "start OUTLINE FILL", "done OUTLINE FILL", "term FILL", "removed".
set -u
out="" name="" outline="" fill="" remove=0 clean=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --out) out=$2; shift ;;
    --name) name=$2; shift ;;
    --outline) outline=$2; shift ;;
    --fill) fill=$2; shift ;;
    --remove) remove=1 ;;
    --clean) clean=1 ;;
  esac
  shift
done
mkdir -p "$out"
log=$out/fake.log
if ((clean)); then
  echo "clean" >>"$out/clean.log"
  exit 0
fi
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
  '#123456')
    trap '' TERM
    sleep 30 &
    echo $! >"$out/grandchild.pid"
    wait
    ;;
  '#0000ff')
    trap 'echo "term $fill" >>"$log"; exit 143' TERM
    mkdir -p "$out/$name"
    echo "$outline $fill" >"$out/$name/colors"
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
