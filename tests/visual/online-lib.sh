#!/usr/bin/env bash
# Shared by tests/visual/wallpaper-online*.sh (source it after lib.sh): the loopback stand-in for Wikimedia Commons
# (tests/unit/wallpaper-tool/fixtures/commons/server.py) and its fixtures. The nested shell reaches it through
# GRASSFIELD_ONLINE_BASE_URL (dev only, http://127.0.0.1:<port>); nothing here touches the network.

online_fix=$VS_DEV/online-fixtures
online_src=$VS_ROOT/tests/unit/wallpaper-tool/fixtures/commons
online_pid=""

# online_picture NAME COLOUR: a 1920x1080 solid-colour JPEG (generated, never a real picture) as the served picture.
online_picture() {
  magick -size 1920x1080 "xc:$2" -quality 92 "$online_fix/picture.jpg"
  echo "online fixture: picture $1 is $2"
}

online_mode() { printf '%s' "$1" > "$online_fix/mode"; }

online_requests() { [[ -f $online_fix/requests.log ]] && wc -l < "$online_fix/requests.log" || echo 0; }

# Starts the server (fresh fixtures) and exports GRASSFIELD_ONLINE_BASE_URL; stopped by online_stop (also on EXIT).
online_start() {
  rm -rf "$online_fix"
  mkdir -p "$online_fix"
  cp "$online_src"/expand-file.json "$online_src"/expand-caption-en.json "$online_src"/expand-caption-fr.json "$online_src"/imageinfo.json "$online_fix/"
  online_picture day1 "#1e64d2"
  python3 -I "$online_src/server.py" --dir "$online_fix" > "$online_fix/server.out" 2>&1 &
  online_pid=$!
  trap online_stop EXIT
  local i port=""
  for i in $(seq 1 50); do
    port=$(sed -n 's/^PORT //p' "$online_fix/server.out" 2>/dev/null | head -1)
    [[ -n $port ]] && break
    sleep 0.1
  done
  [[ -n $port ]] || { echo "online: the fixture server did not start" >&2; return 1; }
  export GRASSFIELD_ONLINE_BASE_URL=http://127.0.0.1:$port
  echo "online fixture server: $GRASSFIELD_ONLINE_BASE_URL (pid $online_pid)"
}

online_stop() {
  [[ -n $online_pid ]] && kill "$online_pid" 2>/dev/null || true
  online_pid=""
}

# The status the shell wrote for Settings.
online_status_file=$VS_DEV/config/wallpaper-state.json
online_cache=$VS_DEV/cache/wallpapers/online/commons
