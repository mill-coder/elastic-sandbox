# Logstash module

The `logstash/` module deploys a managed Logstash instance so you can write, test, and debug ingest pipelines locally before promoting them to production.

## What it provides

When the stack starts with the `logstash` profile, the module sets up:

- **Managed Logstash instance** — pipelines are stored in Elasticsearch and managed via the Kibana Ingest Pipelines UI (Centralized Pipeline Management)
- **Standalone Elastic Agent** — feeds data into Logstash for pipeline testing
- **Pipeline deployment** — `deploy-logstash-pipelines.sh` pushes `.conf` files from `pipelines/` into Elasticsearch as managed pipelines
- **Heartbeat pipeline** — a system pipeline (`_heartbeat`) that keeps Logstash alive when no developer pipelines are deployed
- **Pipeline health checker** — a sidecar script that monitors pipeline status

## Directory layout

```
logstash/
  definitions/
    elasticsearch/               # ES resources Logstash depends on
  definitions-local/
    elasticsearch/               # Local-only satellite definitions
  config/                        # Logstash logging and runtime config
  elastic-agent/                 # Standalone Elastic Agent config
  pipelines/                     # Managed pipeline .conf files
    reference/                   # Reference pipeline examples (not deployed)
  scripts/                       # Sidecar scripts (pipeline health checker)
```

## Pipeline conventions

- **Filename = pipeline ID** — e.g., `my-pipeline.conf` becomes pipeline `my-pipeline` in Elasticsearch
- **First comment = description** — a `# Description: ...` comment on the first line is extracted as the pipeline description in Kibana
- **System pipelines** — prefixed with `_` (e.g., `_heartbeat.conf`), managed by the platform, not to be modified by users
- **Reference pipelines** — examples in `pipelines/reference/` are provided for learning but are not deployed to the cluster

## What you can do as a user

- **Write ingest pipelines** — add a `.conf` file in `pipelines/` and it will be deployed as a managed pipeline on next stack startup
- **Test with sample data** — use the Elastic Agent to feed data through your pipeline and verify the output in Kibana
- **Iterate quickly** — modify your pipeline, restart the stack (or redeploy pipelines), and check the results immediately
- **Use reference pipelines** — copy and adapt examples from `pipelines/reference/` as a starting point

## Compose profile

Logstash is opt-in and depends on Kibana. Add both profiles:

```bash
podman compose -f install/compose.yaml --env-file install/local/.env \
  --profile kibana --profile logstash up -d
```
