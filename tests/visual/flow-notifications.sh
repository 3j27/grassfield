#!/usr/bin/env bash
# GF-009 functional flow: notifications, as an application and a user meet them. Nested session only, on the session's
# PRIVATE D-Bus (never the owner's bus: the notifications are sent to .dev/bus.address).
#
# Proves, with `notifications status` (dev hook: server, history, banners, DND, Center) and the sender's own exit output:
#   1. receive: notify-send reaches the shell's server; a banner shows (the screen differs from the same desktop without it)
#      and the notification is in the history;
#   2. act: a notification with actions (notify-send -A) is invoked through the dev hook as a click on its button, and the
#      SENDER receives the action id (notify-send prints it): the full D-Bus round trip, ActionInvoked included;
#   3. history: the Notification Center (`toggleCenter`, the macOS date-and-time click / SUPER+N) opens and holds what was
#      received, and closes again;
#   4. Do Not Disturb hides banners: while on, a normal notification goes to the history but no banner appears; a critical
#      one still shows (macOS: time-sensitive alerts break through); with DND off banners show again;
#   5. dismissing banners keeps the history; clearing empties it.
# Captures: $VS_SHOTS/flow-notifications-*.en.png.
# Run (bare command, starts a nested session when none is up, cleans up after itself):  tests/visual/flow-notifications.sh
# Expected: a PASS line per check and "notifications: all checks passed"; exit 0.
source "$(dirname "$0")/flow-lib.sh"
fl_start notifications

bus=$(<"$VS_DEV/bus.address")
send() { DBUS_SESSION_BUS_ADDRESS=$bus notify-send "$@"; }
n_is() { [[ $(fl_notif "$1") == "$2" ]]; }      # n_is KEY VALUE (re-read on every call)
n_ge() { [[ $(fl_notif "$1") -ge $2 ]]; }
out=$VS_STATE/flow-notifications-action.out

vs_ipc notifications clearAll >/dev/null
vs_ipc notifications dnd false >/dev/null
fl_check_wait "the notification server is up and empty (status: $(vs_ipc notifications status))" 10 n_is history 0
fl_check "no banner before anything is sent" n_is banners 0
vs_park
base=$(fl_shot base)

# 1. receive
send -a Mail -t 0 "Anna Martin" "Are we still on for lunch tomorrow?"
fl_check_wait "a banner shows (banners=1)" 10 n_is banners 1
fl_check_wait "the notification is in the history (history=1)" 5 n_is history 1
vs_sleep 1
banner=$(fl_shot banner)
n=$(vs_px_diff "$base" "$banner")
fl_check "the banner is on screen ($n px differ from the desktop without it, need >= 1000)" test "$n" -ge 1000

# 2. act: the action id comes back to the sender
rm -f "$out"
send -a Calendar -t 0 -A open=Open -A snooze=Snooze "Design review" "Starts in 10 minutes in Room 4." >"$out" 2>&1 &
sender=$!
vs_track "$sender"
fl_check_wait "the notification with actions arrives (history=2)" 10 n_is history 2
fl_check_wait "its banner shows (banners=2)" 5 n_is banners 2
vs_sleep 1
fl_shot banners-actions >/dev/null
r=$(vs_ipc notifications invoke open)
fl_check "the dev hook invokes 'open' on the newest live notification (got '$r')" bash -c '[[ $1 == "invoked open on Design review" ]]' _ "$r"
sender_got() { [[ $(tr -d '[:space:]' <"$out") == open ]]; }
fl_check_wait "the sender receives the action id 'open' (notify-send printed '$(tr -d '[:space:]' <"$out" 2>/dev/null)')" 10 sender_got
wait "$sender" 2>/dev/null

# 3. history in the Notification Center
vs_ipc notifications dismissAll >/dev/null
fl_check_wait "banners are dismissed (banners=0)" 5 n_is banners 0
fl_check "the history still holds what was received ($(fl_notif history) entries, need >= 2)" n_ge history 2
vs_ipc notifications toggleCenter >/dev/null
fl_check_wait "the Notification Center opens (center=true)" 5 n_is center true
vs_sleep 2
ctr=$(fl_shot center)
n=$(vs_px_diff "$base" "$ctr")
fl_check "the Center is on screen ($n px differ from the bare desktop, need >= 3000)" test "$n" -ge 3000
vs_ipc notifications toggleCenter >/dev/null
fl_check_wait "the Center closes (center=false)" 5 n_is center false

# 4. Do Not Disturb hides banners
hist=$(fl_notif history)
vs_ipc notifications dnd true >/dev/null
fl_check_wait "Do Not Disturb is on" 5 n_is dnd true
send -a Mail -t 0 "Silenced" "This one must not show a banner."
fl_check_wait "the notification still reaches the history while DND is on" 10 n_is history $((hist + 1))
vs_sleep 2
fl_check "no banner shows while DND is on (banners=$(fl_notif banners))" n_is banners 0
fl_shot dnd-quiet >/dev/null
send -a "Software Update" -u critical -t 0 "Critical alert" "Breaks through Do Not Disturb."
fl_check_wait "a critical notification still shows its banner (banners=1)" 10 n_is banners 1
vs_ipc notifications dismissAll >/dev/null
vs_ipc notifications dnd false >/dev/null
fl_check_wait "Do Not Disturb is off" 5 n_is dnd false
send -a Mail -t 0 "Back again" "Banners show again."
fl_check_wait "with DND off the banner shows again (banners=1)" 10 n_is banners 1

# 5. dismiss keeps the history, clear empties it
vs_ipc notifications dismissAll >/dev/null
fl_check_wait "dismissing the banner leaves banners=0" 5 n_is banners 0
fl_check "dismissing keeps the history ($(fl_notif history) entries, need >= 4)" n_ge history 4
vs_ipc notifications clearAll >/dev/null
fl_check_wait "clearing empties the history (history=0)" 5 n_is history 0

fl_done
