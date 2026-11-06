#!/usr/bin/env bash
# ADR-0048 D-3: where the PID of an audio stream comes from. A PRIVATE PipeWire daemon (own temporary runtime folder, own socket,
# no session manager, no D-Bus) and a pw-cat stream that FORGES `pipewire.sec.pid` and `application.process.id`; pw-dump on
# the private socket then shows which properties the server kept, on the stream node and on the Client object it belongs to.
# The finding of the security review of the Luma pull request (finding 3) asked whether the node's own `pipewire.sec.pid` is
# unforgeable: this test records the answer. Never touches the default socket: every client runs with PIPEWIRE_REMOTE set to
# a path under the temporary folder, checked before any client starts. SKIP (exit 0) when pipewire, pw-cat, pw-cli or pw-dump
# are missing, or when the private daemon does not come up.
set -uo pipefail

for t in pipewire pw-cat pw-cli pw-dump jq timeout; do
  command -v "$t" >/dev/null || { echo "SKIP: $t is not installed"; exit 0; }
done

tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/gfpw.XXXXXX") || exit 2
pids=()
cleanup() {
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
  wait 2>/dev/null
  rm -rf "$tmp"
}
trap cleanup EXIT
fails=0
check() { if [[ $2 == 0 ]]; then echo "PASS $1"; else echo "FAIL $1"; fails=1; fi; }

sock=$tmp/pipewire-0
if [[ ${#sock} -gt 100 ]]; then
  echo "SKIP: the socket path would be too long (${#sock} bytes)"
  exit 0
fi
case $sock in "$tmp"/*) ;; *) echo "FAIL the socket is not under the temporary folder"; exit 1 ;; esac
[[ -n $tmp && $tmp != / ]] || exit 2
# Every PipeWire client below sees only this environment: never the owner's session.
pwenv=(env -i PATH="$PATH" HOME="$tmp" XDG_RUNTIME_DIR="$tmp" PIPEWIRE_RUNTIME_DIR="$tmp" PIPEWIRE_REMOTE="$sock"
  DBUS_SESSION_BUS_ADDRESS="unix:path=$tmp/no-bus" XDG_CONFIG_HOME="$tmp/cfg")
mkdir -p "$tmp/cfg"
chmod 700 "$tmp"

"${pwenv[@]}" pipewire >"$tmp/daemon.log" 2>&1 &
pids+=($!)
for _ in $(seq 1 50); do
  [[ -S $sock ]] && break
  sleep 0.1
done
if [[ ! -S $sock ]]; then
  echo "SKIP: the private PipeWire daemon did not start"; cat "$tmp/daemon.log" | head -c 1500 >&2
  exit 0
fi

pwcli() { timeout 10 "${pwenv[@]}" pw-cli "$@"; }
if ! pwcli create-node adapter '{ factory.name=support.null-audio-sink node.name=gf-null media.class=Audio/Sink object.linger=true }' >"$tmp/cli.log" 2>&1; then
  echo "SKIP: cannot create a null sink on the private daemon ($(head -c 200 "$tmp/cli.log" | tr '\n' ' '))"
  exit 0
fi

# A playing stream that claims to be pid 1 (init) twice over.
head -c 4000000 /dev/zero >"$tmp/silence.raw"
"${pwenv[@]}" pw-cat -p --raw --rate 48000 --channels 1 --format s16 --target gf-null \
  -P '{ "pipewire.sec.pid" = "1", "application.process.id" = "1", "node.name" = "gf-forger" }' "$tmp/silence.raw" \
  >"$tmp/cat.log" 2>&1 &
cat_pid=$!
pids+=($cat_pid)
dump=$tmp/dump.json
node=""
for _ in $(seq 1 50); do
  timeout 10 "${pwenv[@]}" pw-dump >"$dump" 2>/dev/null
  node=$(jq -c '[.[] | select(.type == "PipeWire:Interface:Node" and .info.props["node.name"] == "gf-forger")][0] // empty' "$dump" 2>/dev/null)
  [[ -n $node ]] && break
  sleep 0.2
done
if [[ -z $node ]]; then
  echo "SKIP: the stream node did not appear on the private daemon ($(head -c 200 "$tmp/cat.log" | tr '\n' ' '))"
  exit 0
fi

client_id=$(jq -r '.info.props["client.id"] // empty' <<<"$node")
client=$(jq -c --argjson id "${client_id:-0}" '[.[] | select(.type == "PipeWire:Interface:Client" and .id == $id)][0] // empty' "$dump")
node_sec=$(jq -r '.info.props["pipewire.sec.pid"] // "absent"' <<<"$node")
node_app=$(jq -r '.info.props["application.process.id"] // "absent"' <<<"$node")
client_sec=$(jq -r '.info.props["pipewire.sec.pid"] // "absent"' <<<"$client")
echo "node.client.id=${client_id:-none} node.sec.pid=$node_sec node.application.process.id=$node_app client.sec.pid=$client_sec real.pid=$cat_pid"

check "the stream node names its client (client.id)" "$([[ -n $client_id && -n $client ]] && echo 0 || echo 1)"
check "the client's pipewire.sec.pid is the real pid of the process on the socket, set by the server" "$([[ $client_sec == "$cat_pid" ]] && echo 0 || echo 1)"
check "the client's pipewire.sec.pid is not the forged value" "$([[ $client_sec != 1 ]] && echo 0 || echo 1)"
# The two outcomes that decide the code (ADR-0048 D-3): printed as facts, not asserted either way.
if [[ $node_sec == absent ]]; then
  echo "FACT the stream node carries no pipewire.sec.pid: reading it from the node would never exempt an app"
elif [[ $node_sec == 1 ]]; then
  echo "FACT the forged pipewire.sec.pid survived on the stream node: the node's value is as forgeable as application.process.id"
else
  echo "FACT the stream node's pipewire.sec.pid is $node_sec (not the forged value)"
fi
check "the forged application.process.id survives on the node (so it is not a source to trust)" "$([[ $node_app == 1 ]] && echo 0 || echo 1)"
exit $fails
