# Fleet module

The `fleet/` module deploys a Fleet Server and Elastic Agents so you can manage agent policies, integrations, and Synthetics monitors locally through the Kibana Fleet UI.

## What it provides

When the stack starts with the `fleet` profile, the module sets up:

- **Fleet Server** — control plane for Elastic Agents, running over HTTP (no TLS) for local dev
- **Two Elastic Agents** — one per agent policy (`org-lan` for LAN monitoring, `org-www` for internet monitoring), using the `elastic-agent-complete` image for Synthetics support
- **Agent policies** — defined as `.policy` files in `definitions/fleet/agent-policies/`, created automatically at startup
- **Private Locations** — one per agent policy, enabling Synthetics monitors to target the correct agent
- **Synthetics monitors** — defined as `.monitor` files in `definitions-local/monitors/`, deployed when `DEPLOY_SAMPLE_USERS=true`
- **Fleet admin role** — `org_fleet_admin` for managing Fleet via Kibana
- **Fleet viewer role** — `org_fleet_viewer` for read-only Fleet access
- **Automated token provisioning** — service token and per-policy enrollment tokens generated at startup via a shared volume

## Directory layout

```
fleet/
  definitions/
    elasticsearch/security/role/       # Fleet roles (org_fleet_admin, org_fleet_viewer)
    fleet/agent-policies/              # Agent policy definitions (*.policy)
  definitions-local/
    monitors/                          # Synthetics monitor definitions (*.monitor)
```

## File formats

### `.policy` files — agent policy definitions

JSON objects consumed by `deploy-fleet.sh`. Each file creates one Fleet agent policy.

```json
{
  "name": "org-lan",
  "namespace": "default",
  "description": "Agent policy for monitoring internal/LAN services",
  "monitoring_enabled": ["logs", "metrics"]
}
```

### `.monitor` files — Synthetics monitor definitions

JSON objects defining lightweight HTTP monitors. The `policy` field links the monitor to an agent policy (via its Private Location).

```json
{
  "name": "infra-servers-elasticsearch-local",
  "type": "http",
  "urls": "http://elasticsearch:9200",
  "schedule": {"number": "1", "unit": "m"},
  "policy": "org-lan",
  "space": "org-infra-servers",
  "tags": ["infra-servers", "elasticsearch", "local"],
  "labels": {
    "org_team": "infra-servers",
    "org_environment": "local"
  }
}
```

- **`policy`** — links the monitor to an agent policy (via its Private Location)
- **`space`** — Kibana space where the monitor is created (Synthetics monitors are single-space; omit for `default`)
- Monitor naming convention: `{team}-{name}-{environment}` where team identifiers match Kibana space IDs (e.g., `infra-servers`, `team-customers`, `team-mobile`)

## What you can do as a user

- **Create agent policies** — add a `.policy` file in `definitions/fleet/agent-policies/` and it will be created on next startup
- **Add Synthetics monitors** — add a `.monitor` file in `definitions-local/monitors/` to create HTTP health checks
- **Manage integrations** — install and configure any Fleet integration via the Kibana Fleet UI or API
- **Enroll additional agents** — use enrollment tokens from the Kibana Fleet UI
- **Test agent policy changes** — modify policies and verify agents pick up changes in real time

## Security roles

Fleet RBAC in Elastic 8.x is not granular per-policy — access is all-or-nothing at the Fleet feature level.

| Role | Scope | Description |
|------|-------|-------------|
| `org_fleet_admin` | Production-like | Full Fleet and integration management via Kibana |
| `org_fleet_viewer` | Production-like | Read-only access to Fleet status and agent list |

## Compose profile

Fleet is opt-in and depends on Kibana. Add both profiles:

```bash
podman compose -f install/compose.yaml --env-file install/local/.env \
  --profile kibana --profile fleet up -d
```

Or use the convenience script:

```bash
install/local/start-fleet.sh
```

## Ports

| Service      | Port |
|-------------|------|
| Fleet Server | 8220 |

## Init chain

```
kibana (healthy)
  ├── kibana-init        (existing — spaces, data views)
  └── fleet-init         (roles, service token, policies, Private Locations, monitors)
        └── fleet-server (healthy)
              ├── elastic-agent-lan   (enrolled to org-lan)
              └── elastic-agent-www   (enrolled to org-www)
```

`fleet-init` runs in parallel with `kibana-init` since it only needs the Kibana Fleet API, not spaces or data views.
