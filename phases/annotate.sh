#!/bin/sh
# PoC / cPoC phase shading for the Gonka Grafana stack.
#
# Reads the epoch phase from a Gonka node's RPC and posts Grafana *region*
# annotations (tags: poc / cpoc) that the dashboards render as shaded zones on
# every time-series panel. Pure shell — needs only sh + jq + wget + inferenced,
# all of which ship in the node image. POST-only: each phase is posted once as a
# block-height window, so no PATCH/DELETE support is required.
#
# Env:
#   GONKA_RPC        tcp://your-node:26657   (required)
#   GRAFANA_URL      http://grafana:3000
#   ADMIN_PASSWORD   grafana admin password  (basic auth)
#   POLL_INTERVAL    seconds between samples  (default 30)
#   STATE_FILE       where to remember posted phases (default /data/phase_state)
set -u

RPC="${GONKA_RPC:?set GONKA_RPC=tcp://your-node:26657}"
GRAFANA="${GRAFANA_URL:-http://grafana:3000}"
INTERVAL="${POLL_INTERVAL:-30}"
STATE="${STATE_FILE:-/data/phase_state}"
AUTH="Authorization: Basic $(printf '%s' "admin:${ADMIN_PASSWORD:-admin}" | base64 | tr -d '\n')"

mkdir -p "$(dirname "$STATE")"; : > "$STATE.tmp" 2>/dev/null; touch "$STATE"

sget() { grep "^$1=" "$STATE" 2>/dev/null | tail -1 | cut -d= -f2-; }
sset() {
  { grep -v "^$1=" "$STATE" 2>/dev/null; printf '%s=%s\n' "$1" "$2"; } > "$STATE.new"
  mv "$STATE.new" "$STATE"
}

post_region() {  # tag start_ms end_ms text  -> returns wget status
  body=$(printf '{"time":%s,"timeEnd":%s,"tags":["%s"],"text":"%s"}' "$2" "$3" "$1" "$4")
  if wget -q -O /dev/null --header="Content-Type: application/json" --header="$AUTH" \
          --post-data="$body" "$GRAFANA/api/annotations" 2>/dev/null; then
    echo "posted $1 region: $4"; return 0
  fi
  echo "WARN: post failed ($1 $4)"; return 1
}

echo "phase-annotator: RPC=$RPC grafana=$GRAFANA interval=${INTERVAL}s"

while :; do
  J=$(inferenced query inference epoch-info --node "$RPC" --output json 2>/dev/null)
  H=$(printf '%s' "$J" | jq -r '.block_height // empty' 2>/dev/null)
  if [ -z "$H" ]; then echo "WARN: no epoch-info from $RPC"; sleep "$INTERVAL"; continue; fi
  NOW=$(( $(date +%s) * 1000 ))

  # live block time (sec/block) from the previous sample, for height->wall-clock
  PH=$(sget prev_h); PT=$(sget prev_ts); SPB=$(sget spb); [ -n "$SPB" ] || SPB=5
  if [ -n "$PH" ] && [ "$H" -gt "$PH" ] 2>/dev/null; then
    SPB=$(awk "BEGIN{v=(($NOW-$PT)/1000.0)/($H-$PH); if(v<0.5)v=0.5; if(v>30)v=30; print v}")
  fi
  sset prev_h "$H"; sset prev_ts "$NOW"; sset spb "$SPB"
  h2ms() { awk "BEGIN{printf \"%.0f\", $NOW-($H-$1)*$SPB*1000}"; }

  # window length shared by PoC and each confirmation-PoC event (generation +
  # validation), in blocks
  D=$(printf '%s' "$J" | jq -r '(.params.epoch_params.poc_stage_duration|tonumber)+(.params.epoch_params.poc_validation_delay|tonumber)+(.params.epoch_params.poc_validation_duration|tonumber)')

  # ---- PoC: deterministic window at epoch start, posted once per epoch ----
  PS=$(printf '%s' "$J" | jq -r '.latest_epoch.poc_start_block_height // 0')
  EIDX=$(printf '%s' "$J" | jq -r '.latest_epoch.index // 0')
  if [ "$PS" -gt 0 ] 2>/dev/null && [ "$(sget poc_epoch)" != "$EIDX" ]; then
    post_region poc "$(h2ms "$PS")" "$(h2ms $((PS+D)))" "PoC epoch $EIDX" \
      && sset poc_epoch "$EIDX"
  fi

  # ---- cPoC: each confirmation event as a window from its generation start ----
  EV=$(printf '%s' "$J" | jq -c '.active_confirmation_poc_event // {}')
  KEY=$(printf '%s' "$EV" | jq -r 'if .epoch_index then "\(.epoch_index):\(.event_sequence // 0)" else "" end')
  GS=$(printf '%s' "$EV" | jq -r '.generation_start_height // 0')
  if [ -n "$KEY" ] && [ "$GS" -gt 0 ] 2>/dev/null && [ "$(sget "cpoc_$KEY")" != "1" ]; then
    post_region cpoc "$(h2ms "$GS")" "$(h2ms $((GS+D)))" "cPoC $KEY" \
      && sset "cpoc_$KEY" 1
  fi

  sleep "$INTERVAL"
done
