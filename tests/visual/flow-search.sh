#!/usr/bin/env bash
# GF-009 functional flow: Search, used the way a user does (macOS model: open, type, pick a result with the arrow keys,
# Return). Nested session only.
#
# Proves, with the shell's own state (`search status`) and the windows the compositor reports:
#   1. Search opens (IPC open, the dev stand-in for SUPER+SPACE) and keystrokes typed into the field become the query;
#   2. a file result (readme.txt in the Search root, the Files sandbox) is found, chosen with the arrows, opened with Return:
#      Search closes and Grassfield Preview opens that file (the dev open policy, ADR-0011);
#   3. an application result (foot) launches: a foot window appears;
#   4. a Settings page result (Appearance) opens Grassfield Settings;
#   5. the Lock Screen command is OFFERED for "lock". It is NOT activated: in the nested session the lock cannot be left
#      without the owner's password (the lock tests own that path: tests/security/reload_locked.sh), so the request itself is
#      not asserted here;
#   6. Escape closes Search.
# Captures: $VS_SHOTS/flow-search-*.en.png.
# Run (bare command, starts a nested session when none is up, cleans up its windows):  tests/visual/flow-search.sh
# Expected: a PASS line per check and "search: all checks passed"; exit 0.
source "$(dirname "$0")/flow-lib.sh"

# The shell's file provider is plocate (localsearch when installed): the system database never holds a file created a
# moment ago. A private database of the Search root (the Files sandbox, GRASSFIELD_SEARCH_ROOT) is built here; shell-run.sh
# hands .dev/plocate.db to the shell as GRASSFIELD_SEARCH_PLOCATE_DB, and vs_session below restarts the shell with it.
vs_fixtures
if type -P updatedb >/dev/null; then
  updatedb --database-root "$VS_FILES" --output "$VS_DEV/plocate.db" --require-visibility no || echo "NOTE: updatedb failed: the file steps cannot pass"
else
  echo "NOTE: updatedb (plocate) is not installed: the file steps cannot pass"
fi
fl_start search

st() { fl_jq search status -- "$1"; }
is() { [[ $(st "$1") == "$2" ]]; } # is FIELD VALUE: a field of `search status` equals VALUE (re-read on every call)
# Index in the flat result list of the first item of KIND whose title matches RE (-1 when none).
index_of() {
  fl_json search status | jq -r --arg k "$1" --arg re "$2" '[.groups[].items[]] | to_entries | map(select(.value.kind == $k and (.value.title | test($re; "i")))) | (.[0].key // -1)'
}
have_item() { [[ $(index_of "$1" "$2") != -1 ]]; }
# Move the selection to the item with the arrows (at most 15 presses), the way a user would.
select_item() {
  local want cur n
  want=$(index_of "$1" "$2")
  [[ $want != -1 ]] || return 1
  for n in $(seq 1 15); do
    cur=$(st .selected)
    [[ $cur == "$want" ]] && return 0
    if [[ $cur -lt $want ]]; then fl_tap Down; else fl_tap Up; fi
  done
  [[ $(st .selected) == "$want" ]]
}
# Open Search empty, check it is open, type TEXT, wait for the query to be what was typed.
open_and_type() {
  vs_ipc search close >/dev/null
  vs_sleep 0.4
  vs_ipc search open "" >/dev/null
  fl_wait 5 is .open true || { echo "search did not open" >&2; return 1; }
  fl_type "$1"
  fl_wait 5 is .query "$1"
}
foot_more_than() { [[ $(fl_window_count '^foot$') -gt $1 ]]; }
no_window() { [[ -z $(fl_clients "$1") ]]; }

# 1. open and type
fl_check "Search opens and the typed keys become the query 'readme'" open_and_type readme
fl_shot typed >/dev/null

# 2. a file: found, selected with the arrows, opened with Return
fl_check_wait "the file readme.txt is among the results" 10 have_item file 'readme\.txt'
fl_check "the arrow keys select the file result" select_item file 'readme\.txt'
fl_tap Return
fl_check_wait "Return closes Search" 5 is .open false
fl_check_wait "Preview opens (a Grassfield Preview window)" 20 fl_has_window 'org\.grassfield\.Preview'
fl_check_wait "Preview shows readme.txt" 10 fl_title_has 'org\.grassfield\.Preview' 'readme'
fl_shot preview-opened >/dev/null
fl_close_windows 'org\.grassfield\.Preview'
fl_check_wait "the Preview window is closed" 10 no_window 'org\.grassfield\.Preview'

# 3. an application: foot
before=$(fl_window_count '^foot$')
fl_check "type 'foot'" open_and_type foot
fl_check_wait "the foot application is among the results" 10 have_item app '^foot$'
fl_check "the arrow keys select the foot result" select_item app '^foot$'
fl_tap Return
fl_check_wait "Return launches it: a foot window appears" 20 foot_more_than "$before"
fl_shot app-launched >/dev/null
fl_close_windows '^foot$'

# 4. a Settings page
fl_check "type 'appearance'" open_and_type appearance
fl_check_wait "the Appearance page is among the results" 10 have_item setting '^appearance$'
fl_check "the arrow keys select the Appearance page" select_item setting '^appearance$'
fl_tap Return
fl_check_wait "Return opens Grassfield Settings" 20 fl_has_window 'org\.grassfield\.Settings'
fl_shot settings-opened >/dev/null
fl_close_windows 'org\.grassfield\.Settings'

# 5. the Lock Screen command is offered (not activated, see the header)
vs_ipc search close >/dev/null
vs_ipc search query lock >/dev/null
fl_check_wait "the Lock Screen command is offered for 'lock'" 10 have_item command '^lock screen$'
vs_ipc search query "" >/dev/null
fl_note "the Lock Screen command was not activated (it would lock the nested session for good); lock coverage: tests/security/"

# 6. Escape closes it
vs_ipc search open "" >/dev/null
fl_check_wait "Search is open again" 5 is .open true
fl_tap Escape
fl_check_wait "Escape closes Search" 5 is .open false

fl_done
