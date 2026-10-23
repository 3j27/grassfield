#!/usr/bin/env bash
# Stages with three stages (three apps of one terminal each): the active stage in the centre, two thumbnails in the left
# strip with their app badges; then the Quick Settings tile. Needs the compositor plugin (stages-available); without it the
# scenario fails at the wait (the toggle and the strip do not exist then: that is the degraded rule, not a capture).
source "$(dirname "$0")/../lib.sh"
vs_session
vs_reset
vs_stage_foot() {
  local app=$1 title=$2 size=$3
  vs_spawn foot -c "$VS_HERE/fixtures/foot.ini" --app-id "$app" -T "$title" --window-size-chars "$size" \
    sh -c "printf '%s\\n' '$title' 'Grassfield visual fixture'; exec sleep 100000"
}
vs_stage_foot gf-stage-a 'Stage A' 60x16
vs_wait_clients 1
vs_stage_foot gf-stage-b 'Stage B' 64x18
vs_wait_clients 2
vs_stage_foot gf-stage-c 'Stage C' 70x20
vs_wait_clients 3
vs_ipc stages enable true
# The shell pushes the flag, maps the strip and sends op:on: wait for "ready GF-REF=2" (two strip stages).
for i in $(seq 1 40); do
  [[ $(vs_ipc stages status) == "ready GF-REF=2"* ]] && break
  sleep 0.5
done
[[ $(vs_ipc stages status) == "ready GF-REF=2"* ]] || { echo "stages: strip not ready: $(vs_ipc stages status)" >&2; exit 1; }
VS_SETTLE=2 vs_capture stages
vs_ipc menubar open controlcenter GF-REF
VS_SETTLE=1.5 vs_capture stages-quicksettings
vs_ipc menubar close >/dev/null || true
vs_ipc stages enable false
