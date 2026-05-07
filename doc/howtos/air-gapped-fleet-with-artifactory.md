# Air-gapped Fleet with Artifactory

How to run Fleet Server, Kibana, and Elastic Agents in an environment with no
direct internet access, using a corporate Artifactory (or any caching HTTP
proxy / registry) as the single egress point to Elastic's public download
origins.

This pattern is what the sandbox is intended to validate before rolling agents
out to VMs and bare-metal hosts in production: the sandbox and prod agents use
the **identical** download-source mechanism, so a working sandbox proves the
prod path.

## Elastic's three external dependencies

Fleet has exactly three places it reaches out to the public internet. Each one
maps cleanly onto an Artifactory remote (proxy) repository.

| Concern | Upstream origin | Artifactory repo type | Consumed by |
|---|---|---|---|
| Integration packages (Fleet UI) | `https://epr.elastic.co` | Generic remote | Kibana |
| Agent + sub-binaries (upgrades, endpoint, osquery, beats) | `https://artifacts.elastic.co` | Generic remote | Elastic Agent |
| Container images | `https://docker.elastic.co` | Docker remote | Sandbox compose host (and any prod host pulling Elastic images) |

Fleet Server itself **does not download anything from Elastic origins at
runtime**. Its only "download" is the initial container/binary pull, which
goes through the same Docker/artifacts proxy as any other host.

## Who downloads what, from where, when

| Who | What | From | When |
|---|---|---|---|
| Kibana | Integration package zips, EPR index/search metadata | Artifactory → EPR | User adds/updates an integration; policy compilation needs package assets |
| Fleet Server | (nothing — reads policies from ES) | ES `:9200` | Continuously |
| Elastic Agent | Agent binary upgrades, endpoint binary, osquery, beats sub-binaries | Artifactory → artifacts.elastic.co | On enroll (sub-binaries for integrations in policy); on upgrade action; on policy change adding an integration that needs a new binary |
| Sandbox compose host | Container images (`elasticsearch`, `kibana`, `elastic-agent`) | Artifactory → docker.elastic.co | `podman-compose up` |
| Prod VM / bare-metal host | `elastic-agent-X.Y.Z-linux-x86_64.tar.gz` for the **initial install** | Artifactory → artifacts.elastic.co (manual `curl` in install script) | Before `elastic-agent install` runs |

## Communication planes

Three independent flows. Keeping them mentally separate makes the air-gap
config much clearer.

### Control plane — policies, enrollment, check-ins
```
Agent  ──HTTPS:8220──▶  Fleet Server  ──HTTPS:9200──▶  Elasticsearch
                            ▲
Kibana ──HTTPS:9200──▶  Elasticsearch
```
Fleet UI writes policies into `.fleet-*` indices in ES; Fleet Server reads
them and pushes to agents on check-in.

### Data plane — ingest
```
Agent  ──HTTPS:9200──▶  Elasticsearch    (logs, metrics, traces — direct, NOT via Fleet Server)
```

### Download plane — the air-gap-relevant part
```
Kibana       ──HTTPS──▶  Artifactory  ──HTTPS──▶  epr.elastic.co
Agent        ──HTTPS──▶  Artifactory  ──HTTPS──▶  artifacts.elastic.co
Compose host ──HTTPS──▶  Artifactory  ──HTTPS──▶  docker.elastic.co
```

## Schema

```
                          ┌───────────────────────────────────────────────────┐
                          │                  PUBLIC INTERNET                   │
                          │                                                    │
                          │   epr.elastic.co     artifacts.elastic.co          │
                          │   (integrations)     (agent + sub-binaries)        │
                          │                                                    │
                          │             docker.elastic.co                      │
                          │             (container images)                     │
                          └───────────────────────▲───────────────────────────┘
                                                  │ (only Artifactory egresses)
                                                  │
                          ┌───────────────────────┴───────────────────────────┐
                          │                  ARTIFACTORY                       │
                          │  ┌────────────────┐ ┌─────────────────┐ ┌───────┐ │
                          │  │ elastic-epr    │ │ elastic-artifacts│ │ docker│ │
                          │  │ (generic proxy)│ │ (generic proxy)  │ │ proxy │ │
                          │  └────────┬───────┘ └────────┬────────┘ └───┬───┘ │
                          └───────────┼──────────────────┼──────────────┼─────┘
                                      │                  │              │
            ┌─────────────────────────┘                  │              │
            │ integration packages                       │              │
            │                                            │              │
            │              ┌─────────────────────────────┘              │
            │              │ agent + sub-binaries                       │
            │              │ (upgrades, endpoint, osquery, beats)       │
            │              │                                            │
            │              │                                  ┌─────────┘
            │              │                                  │ container images
            ▼              ▼                                  ▼
   ┌──────────────┐  ┌────────────────────┐         ┌──────────────────────┐
   │   KIBANA     │  │  ELASTIC AGENTS    │         │  SANDBOX COMPOSE     │
   │  (Fleet UI/  │  │  (VMs, bare metal, │         │  HOST (podman pulls) │
   │   API)       │  │   sandbox too)     │         └──────────────────────┘
   └──────┬───────┘  └─────────┬──────────┘
          │                    │
          │ writes policies    │ HTTPS:8220 check-in
          │ HTTPS:9200         │ (policy pull, ack, actions)
          │                    │
          │                    ▼
          │            ┌────────────────┐
          │            │  FLEET SERVER  │
          │            │  (itself an    │
          │            │   agent in a   │
          │            │   special      │
          │            │   policy)      │
          │            └───────┬────────┘
          │                    │ HTTPS:9200
          │                    │ reads/writes .fleet-* indices
          ▼                    ▼
   ┌────────────────────────────────────────┐
   │            ELASTICSEARCH                │
   │  ┌──────────────┐  ┌─────────────────┐ │
   │  │ .fleet-*     │  │ logs-*, metrics-*│ │
   │  │ (state)      │  │ (ingested data) │ │
   │  └──────────────┘  └─────────────────┘ │
   └────────────────────────────────────────┘
                    ▲
                    │ HTTPS:9200 (direct ingest, bypasses Fleet Server)
                    │
            ┌───────┴────────┐
            │ ELASTIC AGENTS │
            └────────────────┘
```

## Configuration — the two pointers that make it all work

### 1. Kibana → EPR via Artifactory

Set in the Kibana service environment (compose `.env` or container env):

```
XPACK_FLEET_REGISTRYURL=https://artifactory.corp/elastic-epr
```

### 2. Agents → artifacts via Artifactory

One-time Fleet API call (extend `install/deploy-fleet.sh`). The setting is
stored server-side in ES and pushed to every agent through its policy — no
per-host configuration needed.

```
POST /api/fleet/agent_download_sources
{
  "name": "artifactory",
  "host": "https://artifactory.corp/elastic-artifacts/downloads/",
  "is_default": true
}
```

The path **must end in `/downloads/`** because agents append upstream-style
suffixes (e.g. `beats/elastic-agent/elastic-agent-X.Y.Z-linux-x86_64.tar.gz`).
The proxy must preserve the upstream layout under `/downloads/`.

### 3. (Sandbox only) Container images via Artifactory Docker remote

If the sandbox host also has no direct internet, change compose `image:` lines
to point at the Docker remote:

```
image: artifactory.corp/elastic-docker/elasticsearch/elasticsearch:${STACK_VERSION}
```

Real-world agents installed on VMs / bare metal don't need this — they're
installed from the tarball, not a container.

## Production agent install flow

```
curl -O https://artifactory.corp/elastic-artifacts/downloads/beats/elastic-agent/elastic-agent-X.Y.Z-linux-x86_64.tar.gz
tar xzf elastic-agent-X.Y.Z-linux-x86_64.tar.gz
cd elastic-agent-X.Y.Z-linux-x86_64
sudo ./elastic-agent install \
  --url=https://fleet-server.corp:8220 \
  --enrollment-token=<token>
```

On first check-in the agent receives its policy, which carries the
`agent_download_sources` setting. From that point on, all upgrades and
sub-binary fetches go through Artifactory automatically.

## Why this fits "test before prod"

- **Same code path as prod.** The sandbox exercises the exact
  `XPACK_FLEET_REGISTRYURL` + `agent_download_sources` mechanism prod uses.
  No bundled-only shortcuts that would mask config drift.
- **Lazy population.** Nothing to pre-sync into Artifactory. The first request
  for a given asset triggers the cache fill on the proxy.
- **TLS / auth realism.** If Artifactory enforces a corporate CA or token
  auth, the sandbox surfaces those issues first: Kibana needs
  `NODE_EXTRA_CA_CERTS`; agents need `--certificate-authorities` at install
  time, or per-policy SSL settings in Fleet.
- **Single config knob propagates.** Once the sandbox-validated
  `agent_download_sources` row is in ES, every future agent enrolling against
  Fleet inherits it — no per-host setup beyond `elastic-agent install`.

## Gotchas worth validating in the sandbox

1. **EPR proxying.** EPR serves both an index (`/search`, `/categories`) and
   tarballs (`/epr/<pkg>/<pkg>-<ver>.zip`). A plain Generic remote works, but
   verify `Content-Type` handling and redirect behavior. Some Artifactory
   versions need "Bypass HEAD requests" or "Synchronize Properties" toggled
   for the search endpoints.
2. **Agent download path layout.** Trigger an actual agent upgrade in the
   sandbox — that's the cheapest way to confirm the proxy URL is shaped right
   and that the `/downloads/` prefix lines up with what agents append.
3. **Image pulls.** If you point compose at the Docker remote, validate the
   pull from a clean Podman store so you catch auth or path issues before
   prod hosts hit them.
4. **Certificates.** Artifactory typically terminates TLS with a corporate CA
   that Elastic images don't trust by default. Plan for: Kibana
   `NODE_EXTRA_CA_CERTS`, agent `--certificate-authorities` at enroll time,
   and any HTTPS-to-Artifactory steps in the agent's pre-install script.

## Summary

- Fleet Server is **not** a download proxy. It only brokers control-plane
  traffic.
- Kibana fetches integrations from EPR; agents fetch binaries from
  artifacts.elastic.co. Both are redirected to Artifactory generic remotes via
  exactly two settings (`XPACK_FLEET_REGISTRYURL`, `agent_download_sources`).
- Container images (sandbox-only concern) go through an Artifactory Docker
  remote.
- Once configured server-side, every new agent — sandbox or prod — picks up
  the air-gap configuration automatically through its Fleet policy.
