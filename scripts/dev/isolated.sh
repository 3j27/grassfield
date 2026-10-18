#!/usr/bin/env bash
# Run a command (a Grassfield app, foot, any test client) with every config/cache/state/data directory inside
# this worktree's .dev/, never the owner's home:
#
#   scripts/dev/isolated.sh [--name N] [--config-home DIR] [--state-home DIR] [--] CMD [ARGS...]
#
# Sets XDG_CONFIG_HOME, XDG_CACHE_HOME, XDG_STATE_HOME, XDG_DATA_HOME, GRASSFIELD_CONFIG_HOME and
# GRASSFIELD_STATE_HOME under .dev/isolated/<name>/ (default name "default"; --config-home/--state-home point the
# two GRASSFIELD_* homes at another directory under .dev/, e.g. the nested shell's .dev/config and .dev/state so
# that an app sees the settings the shell writes). Also exports GRASSFIELD_ISOLATED=1 and
# GRASSFIELD_DEV=1 (a dev session: Grassfield Files hides its Trash place and Empty Trash, ADR-0011).
# Every test or dev script that starts grassfield-settings, grassfield-files, grassfield-preview or foot must go
# through this helper (tests/tools/check-isolation.sh enforces it from `just check` and scripts/dev/test.sh).
set -euo pipefail

root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dev=$root/.dev
name=default config_home="" state_home=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --name) name=${2:?--name needs a value}; shift ;;
    --config-home) config_home=${2:?--config-home needs a path}; shift ;;
    --state-home) state_home=${2:?--state-home needs a path}; shift ;;
    --) shift; break ;;
    -*) echo "isolated: unknown option $1" >&2; exit 2 ;;
    *) break ;;
  esac
  shift
done
[[ $# -gt 0 ]] || { echo "usage: isolated.sh [--name N] [--config-home DIR] [--state-home DIR] [--] CMD [ARGS...]" >&2; exit 2; }
[[ $name =~ ^[A-Za-z0-9._-]+$ ]] || { echo "isolated: bad name $name" >&2; exit 2; }

base=$dev/isolated/$name
mkdir -p -m 700 "$base"/{config,cache,state,data,grassfield-config,grassfield-state}
config_home=${config_home:-$base/grassfield-config}
state_home=${state_home:-$base/grassfield-state}
for d in "$config_home" "$state_home"; do
  case $(realpath -m -- "$d") in
    "$dev"/*) ;;
    *) echo "isolated: refusing $d: not under $dev" >&2; exit 2 ;;
  esac
done
mkdir -p "$config_home" "$state_home"

exec env XDG_CONFIG_HOME="$base/config" XDG_CACHE_HOME="$base/cache" XDG_STATE_HOME="$base/state" \
  XDG_DATA_HOME="$base/data" GRASSFIELD_CONFIG_HOME="$config_home" GRASSFIELD_STATE_HOME="$state_home" \
  GRASSFIELD_ISOLATED=1 GRASSFIELD_DEV=1 "$@"
