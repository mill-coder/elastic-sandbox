# Fleet module

The `fleet/` module deploys a Fleet Server and an Elastic Agent so you can manage agent policies, integrations, and Synthetics monitors locally through the Kibana Fleet UI.

## What it provides

When the stack starts with the `fleet` profile, the module sets up:

- **Fleet Server** — control plane for Elastic Agents, running over HTTP (no TLS) for local dev
- **Elastic Agent** — enrolled to Fleet Server, ready to receive policies and run integrations (uses the `elastic-agent-complete` image for Synthetics support)
- **Fleet Server policy** — `Fleet Server Policy` with the `fleet_server` integration
- **Default agent policy** — `org-default-agent-policy` with agent self-monitoring enabled
- **Fleet admin role** — `org_fleet_admin` for managing Fleet via Kibana
- **Fleet viewer role** — `org_fleet_viewer` (local-only) for read-only Fleet access
- **Automated token provisioning** — service token and enrollment token are generated at startup and passed to containers via a shared volume

## Directory layout

```
fleet/
  definitions/
    elasticsearch/security/role/   # Fleet admin role (org_fleet_admin)
  definitions-local/
    elasticsearch/security/role/   # Fleet viewer role (org_fleet_viewer)
```

## What you can do as a user

- **Create agent policies** — define policies via the Kibana Fleet UI or API, assign integrations to them
- **Add Synthetics monitors** — set up HTTP, TCP, or ICMP lightweight monitors that run on the enrolled agent (Private Location)
- **Manage integrations** — install and configure any Fleet integration (System, HTTP, custom, etc.)
- **Enroll additional agents** — use the enrollment token from the Kibana Fleet UI to enroll more agents
- **Test agent policy changes** — modify policies and verify agents pick up the changes in real time

## Security roles

Fleet RBAC in Elastic 8.x is not granular per-policy — access is all-or-nothing at the Fleet feature level.

| Role | Scope | Description |
|------|-------|-------------|
| `org_fleet_admin` | Production-like | Full Fleet and integration management via Kibana |
| `org_fleet_viewer` | Local sandbox only | Read-only access to Fleet status and agent list |

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
  ├── kibana-init    (existing — spaces, data views)
  └── fleet-init     (service token, Fleet settings, policies, enrollment token)
        └── fleet-server (healthy)
              └── elastic-agent
```

`fleet-init` runs in parallel with `kibana-init` since it only needs the Kibana Fleet API, not spaces or data views.
