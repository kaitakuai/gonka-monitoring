# Gonka monitoring — Grafana + VictoriaMetrics

Self-contained dashboards for a [Gonka](https://gonka.ai) inference operator.
Point it at a node that serves `/v1/mlnodes/metrics`, run one command, and get
GPU / vLLM / host dashboards for every ML node behind it.

No code to build — this repo is only configuration.

## What you get

| Dashboard | Shows |
|-----------|-------|
| **Gonka fleet** | every ML node on the scraped endpoint: up/serving, tokens/s, requests, latency, a per-node table |
| **Gonka ML node** | drill-down for one ML node: version/model/config, GPU temp·power·throttle·VRAM, KV-cache & prefix-cache gauges, TTFT & inter-token latency, host CPU/mem/disk |

## Requirements

- Docker + Docker Compose
- A Gonka node URL that exposes `/v1/mlnodes/metrics` (your own network node, or any public one)

## Quickstart

```bash
cp .env.example .env
# edit .env → set GONKA_NODE to your node, e.g. my-node.example.com:8000
docker compose up -d
```

Open <http://localhost:3000> (anonymous view is on). First data appears within
~30 s (one scrape interval).

## Configuration (`.env`)

| Variable | Default | Meaning |
|----------|---------|---------|
| `GONKA_NODE` | — (required) | `host:port` serving `/v1/mlnodes/metrics` |
| `GONKA_SCHEME` | `http` | `http` or `https` (https ⇒ use `:443`) |
| `RETENTION` | `90d` | how long VictoriaMetrics keeps data (~50 MB per ML node at 90d) |
| `GRAFANA_PORT` | `3000` | host port for the UI |
| `ADMIN_PASSWORD` | `admin` | Grafana admin — **change before exposing** |

## How it works

```
your Gonka node  ──/v1/mlnodes/metrics──▶  VictoriaMetrics ──▶  Grafana
   (federated vLLM + GPU + host metrics)      (scrape+store)     (dashboards)
```

The node already federates every ML node it runs into one Prometheus endpoint;
this stack just scrapes and visualizes it. Nothing is installed on the ML nodes.

## A note on token counts

`Input tokens` / `Output tokens` reflect **all work the inference engines did**,
including validation re-runs (Gonka re-executes a share of inference to verify
it). They are therefore **higher than the chain's billed-inference numbers** —
that is expected, not a bug.

## Exposing it publicly

Defaults are safe for local use. Before putting it on the internet:

- put Grafana behind a reverse proxy with TLS and **do not** expose port 3000 directly;
- keep `GF_USERS_ALLOW_SIGN_UP=false` (already set) and change `ADMIN_PASSWORD`;
- anonymous access is **Viewer-only** and dashboards are read-only (provisioned).

## PoC / cPoC phase shading (optional)

Shade the graphs with the network's PoC and confirmation-PoC (cPoC) phases, so you
can see when a metric change lines up with a phase. It reads the phase from your
own Gonka node's RPC and posts Grafana region annotations.

```bash
# in .env, point GONKA_RPC at your node's Tendermint RPC (e.g. tcp://10.0.0.5:26657)
docker compose --profile phases up -d
```

The phase is global network state, so any synced Gonka node returns it; the poller
is a single shell script running on the node image (no extra dependencies). Leave
the profile off and the base stack is unchanged.

> Whole-network view across **all** participants (not just your own nodes) needs
> our epoch auto-discovery and is not part of this repo.

## License

MIT
