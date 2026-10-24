# Shared helpers of the gate scripts (scripts/gates/*.sh; sourced, not run). Read-only: /proc and the journal only.
# Verdict lines always carry the numbers, the sample counts and the threshold. Exit codes of every gate script:
#   0 PASS   1 FAIL   2 INCONCLUSIVE or usage/environment error (no valid evidence, never a pass)

gate_root() { git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel; }

# utime + stime of a process (clock ticks, whole process), read from /proc/<pid>/stat. The command name (field 2) may
# hold spaces and parentheses: fields are counted after its closing parenthesis.
gate_ticks() { # <pid>
  local stat rest
  local -a f
  stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  rest=${stat##*) }
  read -ra f <<<"$rest"
  [[ -n ${f[12]:-} ]] || return 1
  echo $((f[11] + f[12]))
}

# Start time (ticks since boot, field 22): a pid whose start time changed is another process.
gate_start() { # <pid>
  local stat rest
  local -a f
  stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  rest=${stat##*) }
  read -ra f <<<"$rest"
  [[ -n ${f[19]:-} ]] || return 1
  echo "${f[19]}"
}

gate_comm() { cat "/proc/$1/comm" 2>/dev/null || echo "?"; }

# Resident set size in kB.
gate_rss_kb() { # <pid>
  awk '/^VmRSS:/ {print $2}' "/proc/$1/status" 2>/dev/null
}

# CPU of a process over an interval, in percent of one core.
gate_cpu_pct() { # <ticks delta> <elapsed seconds> <clock ticks per second>
  awk -v d="$1" -v s="$2" -v hz="$3" 'BEGIN { if (s <= 0 || hz <= 0) { print "nan"; exit } printf "%.3f", d / hz / s * 100 }'
}

# True when <a> <= <b> (decimal numbers).
gate_le() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a <= b) }'; }

# Prints "<pid> <label>" for every live pid of a name, read-only (pgrep). Never signals anything.
gate_find() { # <pgrep -f pattern>
  command -v pgrep >/dev/null || return 1
  pgrep -u "$(id -u)" -f -- "$1" 2>/dev/null
}
