# Gonka monitoring — Grafana + VictoriaMetrics

Self-hosted dashboards for the whole [Gonka](https://gonka.ai) inference network.
Point it at your own Gonka node, run one command, and get the same monitoring the
kaitakuai team runs: every active participant of the current epoch, their ML nodes,
and per-GPU drill-downs — discovered automatically from the chain.

Configuration plus two small shell scripts. No build step.

## What you get

| Dashboard | Shows |
|-----------|-------|
| **Gonka network overview** | every network node active in the current epoch: online, serving/idle, ML nodes up, requests & tokens over the selected range, participant weight. Click a row → |
| **Gonka network-node (wallet)** | one participant: aggregates, tokens/s and latency per ML node, per-node table. Click a row → |
| **Gonka mlnode drill-down** | one ML node: version/model/config, GPU temp·power·throttle·VRAM, KV-cache & prefix-cache gauges, TTFT & inter-token latency, host CPU/mem/disk |

## How it works

```
your node RPC  ──current epoch members──▶ discovery ──targets.json──▶ VictoriaMetrics ──▶ Grafana
your node API  ──member → public URL────▶    │                             ▲
                                              └── each participant's /v1/mlnodes/metrics ┘
```

`discovery` asks your node which participants are active this epoch and where they
serve `/v1/mlnodes/metrics`, then VictoriaMetrics scrapes every one of them. When the
epoch changes, the target list follows. Nothing is installed on anyone's ML nodes —
each Gonka node already federates its own ML nodes into that one endpoint.

## Requirements

- Docker + Docker Compose
- A synced Gonka network node you can reach: its Tendermint **RPC** (`:26657`) and its
  HTTP API (`:8000`, serves `/v1/participants`)

## Quickstart

```bash
cp .env.example .env
# set GONKA_RPC and GONKA_NODE to your node
docker compose up -d
```

Open <http://localhost:3000> (anonymous view is on). The overview fills within a
minute or two: one discovery run (60 s) plus one scrape interval (30 s).

## Configuration (`.env`)

| Variable | Default | Meaning |
|----------|---------|---------|
| `GONKA_RPC` | — (required) | your node's Tendermint RPC, e.g. `tcp://10.0.0.5:26657` |
| `GONKA_NODE` | — (required) | your node's API `host:port` (serves `/v1/participants`) |
| `GONKA_SCHEME` | `http` | scheme for `GONKA_NODE` |
| `INFERENCED_IMAGE` | `…/inferenced:0.2.15` | node image; discovery runs `inferenced` from it |
| `DISCOVERY_INTERVAL` | `60` | seconds between epoch re-discovery |
| `RETENTION` | `90d` | how long data is kept (~50 MB per ML node at 90d) |
| `GRAFANA_PORT` | `3000` | host port for the UI |
| `ADMIN_PASSWORD` | `admin` | Grafana admin — **change before exposing** |

## A note on token counts

`Input tokens` / `Output tokens` reflect **all work the inference engines did**,
including validation re-runs (Gonka re-executes a share of inference to verify it).
They are therefore **higher than the chain's billed-inference numbers** — expected,
not a bug.

## PoC / cPoC phase shading (optional)

Shade the graphs with the network's PoC and confirmation-PoC (cPoC) phases, read
from your node's RPC:

```bash
docker compose --profile phases up -d
```

Phases are global network state, so any synced node returns them. Leave the profile
off and nothing else changes.

## Exposing it publicly

Defaults are safe for local use. Before putting it on the internet:

- put Grafana behind a reverse proxy with TLS; **do not** expose port 3000 directly;
- keep sign-up off (already) and change `ADMIN_PASSWORD`;
- anonymous access is Viewer-only and dashboards are read-only (provisioned).

## License

MIT
