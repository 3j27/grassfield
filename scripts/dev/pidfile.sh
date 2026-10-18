# Process records of the nested dev session (.dev/*.pid). Sourced by the dev scripts and tests (bash).
#
# A record is the PID in NAME.pid plus the process start time (/proc/<pid>/stat field 22) in NAME.pid.start. A PID alone
# is not an identity: a record written inside the Claude Code sandbox (its own PID namespace) or left by a crashed run
# can name an unrelated live process of the owner. A record counts only while the start time still matches, and nothing
# that is, leads or shares a group or session with a compositor other than the one being stopped, or with this script,
# is ever signalled (incident 2026-10-18: a stale record made nested-down.sh kill the owner's Hyprland session).

# True in the host PID namespace. Outside the sandbox PID 1 is systemd; a namespace that mounts the host's /proc also
# shows systemd, but there /proc/self names the host PID, not $BASHPID. Inside a Hyprland session its compositor must
# also be visible under the PID in its hyprland.lock (the sandbox does not see it).
dev_host_namespace() {
  # The kernel's initial PID namespace always has inode 0xEFFFFFFC (PROC_PID_INIT_INO); a child namespace never does.
  [[ $(readlink /proc/self/ns/pid 2>/dev/null) == "pid:[4026531836]" ]] || return 1
  [[ $(cat /proc/1/comm 2>/dev/null) == systemd ]] || return 1
  local self _ lock hpid
  read -r self _ </proc/self/stat 2>/dev/null || return 1
  [[ $self == "$BASHPID" ]] || return 1
  if [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} && -n ${XDG_RUNTIME_DIR:-} ]]; then
    lock=$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/hyprland.lock
    if [[ -r $lock ]]; then
      read -r hpid <"$lock" || return 1
      [[ $hpid =~ ^[0-9]+$ && $(cat "/proc/$hpid/comm" 2>/dev/null) == Hyprland ]] || return 1
    fi
  fi
}

# Exits 3 inside a PID namespace: records written or read there name other processes than on the host.
dev_require_host() { # <script name>
  dev_host_namespace && return 0
  echo "$1: refusing inside a PID namespace (PID 1 is not systemd: the Claude Code sandbox?); run it as a bare command" >&2
  exit 3
}

# Start time of a process in clock ticks since boot (field 22; the command name in field 2 may hold spaces).
dev_start_time() { # <pid>
  local stat rest
  stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  rest=${stat##*) }
  local -a f
  read -ra f <<<"$rest"
  [[ -n ${f[19]:-} ]] || return 1
  echo "${f[19]}"
}

dev_record_pid() { # <file> <pid>
  local start=""
  start=$(dev_start_time "$2") || start=""
  printf '%s\n' "$2" >"$1"
  printf '%s\n' "$start" >"$1.start"
}

# Prints the recorded PID while it is still the recorded process; fails otherwise (no record, no start time, gone,
# reused PID, sandboxed caller).
dev_live_pid() { # <file>
  [[ -s $1 && -s $1.start ]] || return 1
  dev_host_namespace || return 1
  local pid start
  local now
  pid=$(<"$1")
  start=$(<"$1.start")
  [[ $pid =~ ^[0-9]+$ ]] && ((pid > 1)) || return 1
  # An empty start time (the process exited before it was read) never matches.
  [[ $start =~ ^[0-9]+$ ]] || return 1
  now=$(dev_start_time "$pid") || return 1
  [[ $now == "$start" ]] || return 1
  echo "$pid"
}

# True when <pid> may be signalled (alone or as a process group): it is not a compositor (other than <allowed>), not the
# group or session of one, and not this script, its group, session or ancestors.
# Fails closed: without ps and pgrep, or when the target cannot be inspected, nothing may be signalled.
dev_may_signal() { # <pid> [<allowed compositor pid>]
  local target=$1 allowed=${2:-} p hypr comm
  local -A bad=()
  [[ $target =~ ^[0-9]+$ ]] && ((target > 1)) || return 1
  command -v ps >/dev/null && command -v pgrep >/dev/null || return 1
  comm=$(cat "/proc/$target/comm" 2>/dev/null) || return 1
  if [[ $target != "$allowed" ]]; then
    case $comm in Hyprland | start-hyprland) return 1 ;; esac
  fi
  [[ -n $(ps -o pgid= -p "$target" 2>/dev/null) ]] || return 1
  for hypr in $(pgrep -x Hyprland 2>/dev/null) $(pgrep -x start-hyprland 2>/dev/null) \
    $(hyprctl instances -j 2>/dev/null | jq -r '.[].pid' 2>/dev/null); do
    [[ $hypr == "$allowed" ]] && continue
    bad[$hypr]=1
    for p in $(ps -o pgid=,sid= -p "$hypr" 2>/dev/null); do bad[$p]=1; done
  done
  for p in $(ps -o pgid=,sid= -p $$ 2>/dev/null); do bad[$p]=1; done
  p=$$
  while [[ $p =~ ^[0-9]+$ ]] && ((p > 1)); do
    bad[$p]=1
    p=$(awk '/^PPid:/ {print $2}' "/proc/$p/status" 2>/dev/null)
  done
  [[ -z ${bad[$target]:-} ]]
}

# Stops a recorded process (its group when it leads one: started with setsid) and removes the record. A stale record
# is removed without signalling anything; a record without a start time (older scripts) is kept and reported.
dev_stop() { # <file> <name> [<allowed compositor pid>]
  local pid target
  [[ -s $1 ]] || { rm -f "$1" "$1.start"; return 0; }
  if [[ ! -s $1.start ]]; then
    echo "dev: $2: record $1 has no start time (older script); nothing signalled. Check /proc/$(<"$1")/cmdline and stop it by hand" >&2
    return 0
  fi
  if ! pid=$(dev_live_pid "$1"); then
    echo "dev: $2: stale record (pid $(<"$1") is gone or reused); nothing signalled" >&2
    rm -f "$1" "$1.start"
    return 0
  fi
  if ! dev_may_signal "$pid" "${3:-}"; then
    echo "dev: refusing to signal $2 (pid $pid): a compositor, its group or session, or this script" >&2
    return 1
  fi
  target=$pid
  [[ $(ps -o pgid= -p "$pid" | tr -d ' ') == "$pid" ]] && target=-$pid
  kill -- "$target" 2>/dev/null
  for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  kill -0 "$pid" 2>/dev/null && kill -9 -- "$target" 2>/dev/null
  echo "dev: stopped $2 (pid $pid)"
  rm -f "$1" "$1.start"
}

# Validates this tree's nested session before anything talks to it (input, screenshots, IPC): the recorded compositor
# is live, runs this tree's dev config, and Hyprland lists it with the recorded instance and socket; never the owner's
# instance or socket. Sets DEV_NESTED_PID, DEV_NESTED_SIG, DEV_NESTED_SOCK; prints the reason and fails otherwise.
dev_nested_target() { # <dev dir>
  local dev=$1 root pid sig sock main line
  root=$(cd "$dev/.." && pwd)
  DEV_NESTED_PID="" DEV_NESTED_SIG="" DEV_NESTED_SOCK=""
  dev_host_namespace || { echo "nested: refusing inside a PID namespace (run it as a bare command)" >&2; return 1; }
  pid=$(dev_live_pid "$dev/nested.pid") || { echo "nested: no live nested instance of this tree (run: just nested-up)" >&2; return 1; }
  [[ $(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null) == *"--config $root/config/hypr/dev.lua"* ]] \
    || { echo "nested: PID $pid does not run this tree's dev config" >&2; return 1; }
  sig=$(cat "$dev/nested.instance" 2>/dev/null) && sock=$(cat "$dev/nested.wayland" 2>/dev/null) \
    || { echo "nested: records incomplete" >&2; return 1; }
  main=$(cat "$dev/main.instance" 2>/dev/null || true)
  [[ -n $sig && -n $sock && $sig != "$main" && $sig != "${HYPRLAND_INSTANCE_SIGNATURE:-}" && $sock != "${WAYLAND_DISPLAY:-}" ]] \
    || { echo "nested: refusing the main instance or socket" >&2; return 1; }
  line=$(hyprctl instances -j 2>/dev/null | jq -r --argjson p "$pid" '.[] | select(.pid == $p) | "\(.instance) \(.wl_socket)"')
  [[ $line == "$sig $sock" ]] || { echo "nested: Hyprland does not list PID $pid as $sig on $sock" >&2; return 1; }
  [[ -S ${XDG_RUNTIME_DIR:?}/$sock ]] || { echo "nested: socket $sock is gone" >&2; return 1; }
  DEV_NESTED_PID=$pid DEV_NESTED_SIG=$sig DEV_NESTED_SOCK=$sock
}
