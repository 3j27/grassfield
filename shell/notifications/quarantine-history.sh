#!/bin/sh
# Moves a damaged notification history file aside and creates a fresh empty one (0600). Usage: quarantine-history.sh FILE TIME
# The fresh file is created only when the damaged one really went away: if the move fails (or would overwrite an earlier
# quarantine copy: mv -n), nothing is written and the exit status is not 0, so the shell keeps the history read only.
# Tested by tests/shell/history_quarantine.sh.
umask 077
file=$1
copy="$1.corrupt-$2"
mv -n -- "$file" "$copy" || exit 1
[ ! -e "$file" ] || exit 1
chmod 600 "$copy" || exit 1
install -m 600 /dev/null "$file"
