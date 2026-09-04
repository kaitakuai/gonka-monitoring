#!/bin/sh
# Epoch auto-discovery for the Gonka Grafana stack.
#
# Rebuilds the VictoriaMetrics file_sd target list from the CURRENT epoch's
# active participants, so the network overview follows the epoch on its own:
# a node that joins the epoch appears, one that leaves disappears. Also pushes
# each participant's weight as the gonka_wallet_weight metric.
#
# Pure shell (sh + jq + wget + inferenced — all in the node image). Sources:
#   - active members + weight:  inferenced query inference current-epoch-group-data  (RPC)
#   - member -> public URL:      <your node>/v1/participants                          (HTTP)
#
# Env:
#   GONKA_RPC     tcp://your-node:26657      (required)
#   GONKA_NODE    your-node.example.com:8000 (required; serves /v1/participants)
#   GONKA_SCHEME  http|https  (scheme for GONKA_NODE, default http)
#   VM_URL        http://victoriametrics:8428
#   SD_FILE       /sd/targets.json
#   DISCOVERY_INTERVAL  seconds (default 60)
set -u
RPC="${GONKA_RPC:?set GONKA_RPC=tcp://your-node:26657}"
NODE="${GONKA_NODE:?set GONKA_NODE=host:port}"
SCHEME="${GONKA_SCHEME:-http}"
VM="${VM_URL:-http://victoriametrics:8428}"
OUT="${SD_FILE:-/sd/targets.json}"
INTERVAL="${DISCOVERY_INTERVAL:-60}"
mkdir -p "$(dirname "$OUT")"
echo "discovery: RPC=$RPC node=$SCHEME://$NODE -> $OUT every ${INTERVAL}s"

while :; do
  EP=$(inferenced query inference current-epoch-group-data --node "$RPC" --output json 2>/dev/null)
  PARTS=$(wget -qO- "$SCHEME://$NODE/v1/participants" 2>/dev/null)
  if [ -z "$EP" ] || [ -z "$PARTS" ]; then
    echo "WARN: epoch data or participants unavailable (rpc=$([ -n "$EP" ] && echo ok || echo fail) participants=$([ -n "$PARTS" ] && echo ok || echo fail))"
    sleep "$INTERVAL"; continue
  fi
  printf '%s\n%s' "$EP" "$PARTS" | jq -s '
    ([.[0] | .. | objects | select(has("validation_weights")) | .validation_weights] | first // []) as $members
    | (.[1].participants // [] | map({key:.id, value:(.url // "")}) | from_entries) as $url
    | [ $members[] as $m
        | ($url[$m.member_address] // "" | sub("/+$"; "")) as $u
        | select($u != "")
        | ($u | test("^https://")) as $https
        | ($u | sub("^https?://"; "") | sub("/.*$"; "")) as $hp
        | (if ($hp | test(":")) then $hp else $hp + (if $https then ":443" else ":80" end) end) as $t
        | { targets: [$t],
            labels: ({ wallet: $m.member_address,
                       moniker: ($m.member_address[0:10] + "…" + $m.member_address[-4:]) }
                     + (if $https then {"__scheme__": "https"} else {} end)),
            weight: (($m.weight // "0") | tonumber) } ]
    | sort_by(-.weight)
  ' > "$OUT.tmp" 2>/dev/null
  N=$(jq 'length' "$OUT.tmp" 2>/dev/null || echo 0)
  if [ "${N:-0}" -gt 0 ]; then
    jq 'map(del(.weight))' "$OUT.tmp" > "$OUT.new" && mv "$OUT.new" "$OUT"
    { echo "# TYPE gonka_wallet_weight gauge"
      jq -r '.[] | "gonka_wallet_weight{wallet=\"\(.labels.wallet)\"} \(.weight)"' "$OUT.tmp"
    } > "$OUT.weights.prom"
    wget -q -O /dev/null --post-file="$OUT.weights.prom" "$VM/api/v1/import/prometheus" 2>/dev/null \
      && echo "targets=$N weights imported" || echo "targets=$N (weight import failed)"
  else
    echo "WARN: no targets built (epoch members unresolved)"
  fi
  sleep "$INTERVAL"
done
