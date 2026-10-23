#!/usr/bin/env bash
# Gate P5: session start to "usable menu bar and Dock" (<= 2 s, master-prompt §10), from the user journal of the real
# session. READ ONLY: journalctl output is parsed by scripts/gates/session_start.py; nothing is started or touched.
#
#   scripts/gates/session-start.sh [--boots N] [--max-s 2.0] [--file JOURNAL.txt]
#     --boots N     the last N boots of the user journal (default 1: this boot)
#     --file FILE   a saved `journalctl --user -o short-iso-precise` output instead of the live journal
#
# Start: the uwsm line "Starting <compositor> and waiting while it is running". End: the shell's
# "grassfield-shell: usable (...)" line, logged once when the menu bar of every output and the Dock of every output that
# shows one have drawn their first frame (shell/platform/Usable.qml). A shell older than that marker leaves no sample:
# INCONCLUSIVE, never a pass. Needs a journal the caller can read (the Claude sandbox cannot: run it as a bare command).
# Exit: 0 PASS, 1 FAIL, 2 INCONCLUSIVE or an unreadable journal.
set -uo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
boots=1 max=2.0 file=""
while (($#)); do
  case $1 in
    --boots) shift; boots=$1 ;;
    --max-s) shift; max=$1 ;;
    --file) shift; file=$1 ;;
    -h | --help) sed -n '2,/^set -uo/p' "$0" | sed '$d;s/^# \{0,1\}//'; exit 0 ;;
    *) echo "session-start: unknown argument $1 (--help)" >&2; exit 2 ;;
  esac
  shift
done
[[ $boots =~ ^[1-9][0-9]*$ ]] || { echo "session-start: --boots is a positive integer" >&2; exit 2; }
if [[ -n $file ]]; then
  exec python3 -I "$root/scripts/gates/session_start.py" --max-s "$max" "$file"
fi
command -v journalctl >/dev/null || { echo "session-start: journalctl not found" >&2; exit 2; }
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
for ((b = 0; b > -boots; b--)); do
  journalctl --user -b "$b" -o short-iso-precise --no-pager >>"$tmp" 2>/dev/null || true
done
[[ -s $tmp ]] || { echo "session-start: the user journal is empty or unreadable from here (bare command, member of systemd-journal or adm?)" >&2; exit 2; }
python3 -I "$root/scripts/gates/session_start.py" --max-s "$max" "$tmp"
