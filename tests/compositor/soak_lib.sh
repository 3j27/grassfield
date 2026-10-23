# Verdict helpers of the C1 soak (sourced by tests/compositor/soak.sh; tested offline by tests/shell/soak_lib.sh).
# GF-006: a soak whose actions miss their target must not pass. Every action type counts attempts and EFFECTIVE
# actions (the effect was observed: the window moved, resized, closed, was minimized and restored).
#
#   soak_action_verdict <attempts> <effective> <min_pct> [others_effective 0|1]
#       prints "ok", "harness" (no attempt, or none took effect while nothing else did either: the harness could not
#       drive the run, no verdict on the product; exit code 2 of the soak) or "fail" (some took effect but fewer than
#       <min_pct> % of the attempts, or none took effect although other titlebar actions did: the harness works, so
#       this action is broken in the product; exit code 1)
#   soak_slope_mb_h <samples file> <warmup_s>
#       samples: lines "<epoch s> <rss kB>". Least-squares slope in MB per hour over the samples taken at least
#       <warmup_s> after the first; prints "n/a" when fewer than 5 samples or less than 600 s remain (a short run
#       is not judged: the caller says so)
#   soak_rss_verdict <slope|n/a> <max MB/h>   prints "ok", "fail" or "unjudged"

soak_action_verdict() { # <attempts> <effective> <min_pct>
  local attempts=${1:-0} effective=${2:-0} pct=${3:-50} others=${4:-0}
  if ((attempts == 0)); then
    echo harness
  elif ((effective == 0)); then
    if ((others)); then echo fail; else echo harness; fi
  elif ((effective * 100 < attempts * pct)); then
    echo fail
  else
    echo ok
  fi
}

soak_slope_mb_h() { # <samples file> <warmup_s>
  awk -v warm="${2:-0}" '
    NF >= 2 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { t[++n] = $1; r[n] = $2 }
    END {
      if (n == 0) { print "n/a"; exit }
      m = 0
      for (i = 1; i <= n; i++) if (t[i] - t[1] >= warm) { m++; x[m] = t[i]; y[m] = r[i] / 1024 }
      if (m < 5 || x[m] - x[1] < 600) { print "n/a"; exit }
      for (i = 1; i <= m; i++) { sx += x[i]; sy += y[i] }
      mx = sx / m; my = sy / m
      for (i = 1; i <= m; i++) { sxy += (x[i] - mx) * (y[i] - my); sxx += (x[i] - mx) ^ 2 }
      printf "%.2f\n", (sxy / sxx) * 3600
    }' "$1"
}

soak_rss_verdict() { # <slope|n/a> <max MB/h>
  if [[ $1 == n/a ]]; then echo unjudged
  elif awk -v s="$1" -v m="$2" 'BEGIN { exit !(s <= m) }'; then echo ok
  else echo fail; fi
}
