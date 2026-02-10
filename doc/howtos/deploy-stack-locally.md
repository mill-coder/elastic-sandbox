# How to deploy the stack locally

This guide walks you through starting and stopping the Elastic Stack on your local machine using Compose profiles.

## Base stack (Elasticsearch only)

The base configuration starts a single Elasticsearch instance, fully initialized with definitions (ILM policies, index templates, security roles).

```bash
podman compose -f install/compose.yaml --env-file install/local/.env up -d
```

## Compose profiles

Additional services are opt-in via Compose profiles. The base stack always runs; profiles add components on top.

| Profile | Service | Description |
|---------|---------|-------------|
| `kibana` | Kibana | Dashboards, Discover, data view management |
| `logstash` | Logstash | Ingest pipelines with Elastic Agent |
| `mattermost` | Mattermost | Chat integration for alerts and notifications |

## Starting with profiles

Add one or more `--profile` flags to enable additional services:

```bash
# Elasticsearch + Kibana
podman compose -f install/compose.yaml --env-file install/local/.env --profile kibana up -d

# Elasticsearch + Kibana + Logstash
podman compose -f install/compose.yaml --env-file install/local/.env --profile kibana --profile logstash up -d
```

Combine profiles as needed depending on what you are working on.

## Stopping the stack

```bash
podman compose -f install/compose.yaml --env-file install/local/.env down
```

## Destroying and recreating from scratch

To start fresh, remove volumes along with the containers:

```bash
podman compose -f install/compose.yaml --env-file install/local/.env down -v
```

Then bring the stack back up — init containers will redeploy all definitions automatically.
