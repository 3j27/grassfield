# Environmental lines of a nested dev session (GF-035), sourced by global_menus.sh and tested by tests/shell/gates.sh.
# `filter_env_lines` reads shell.log lines on stdin and prints the ones that are NOT environmental. A line of .dev/shell.log looks
# like "2026-10-23 03:35:20.400  WARN qml: <message>". It is dropped only when it ENDS with one of these messages, complete
# (the timestamp, level and category before it are free, nothing after it), so no other warning of the same component is hidden:
# the polkit agent cannot register because another agent owns the session; the lock announcing that PAM is suppressed in dev
# sessions (GRASSFIELD_DEV_ALLOW_PAM gate); and Quickshell's own line for the polkit refusal, whose text continues with the
# system's error: that one entry, marked with "~", must START the message, right after the line's timestamp and level word.
ENV_LINES=(
  "grassfield-polkit: not registered (another authentication agent owns this session); no dialog will be shown, nothing is approved"
  "~quickshell.service.polkit: failed to register listener"
  "grassfield-lock: dev: PAM is suppressed on the lock (no real authentication; set GRASSFIELD_DEV_ALLOW_PAM=1 for the L2 failure-path test)"
)
filter_env_lines() {
  awk 'BEGIN { for (i = 1; i < ARGC; i++) { env[i] = ARGV[i]; ARGV[i] = "" } n = ARGC - 1 }
       { for (i = 1; i <= n; i++) {
           m = env[i]
           if (substr(m, 1, 1) == "~") {
             t = substr(m, 2)
             if (match($0, /^[ \t]*([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9:.]+[ \t]+)?[A-Z]+[ \t]+/) && substr($0, RLENGTH + 1, length(t)) == t) next
             continue
           }
           if (length($0) >= length(m) && substr($0, length($0) - length(m) + 1) == m) next
         }
         print }' "${ENV_LINES[@]}"
}
