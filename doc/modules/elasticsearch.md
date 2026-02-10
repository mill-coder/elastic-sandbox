# Elasticsearch module

The `elasticsearch/` module is the foundation of the sandbox. It configures a single-node Elasticsearch cluster and deploys the core resources that all other modules depend on.

## What it provides

When the stack starts, the Elasticsearch init container deploys the following resources into the cluster:

- **ILM policies** — lifecycle rules that control rollover and retention per log category (e.g., `org-roll-7d-retain-30d` for short-lived logs, `org-roll-30d-retain-5y` for analytics)
- **Component templates** — reusable building blocks for index templates:
  - Settings templates (ILM policy + shard config)
  - Dynamic mapping templates (date detection, strings-to-keyword)
  - ECS field mappings
  - Organization custom field mappings (`org.*`)
- **Index templates** — compose component templates into data stream and standard index templates for each log category
- **Security roles** — role-based access control matching the organization's team structure (read roles per category, write roles for ingest, management and admin roles)

## Directory layout

```
elasticsearch/
  definitions/                   # Production-like definitions
    ilm/                         # ILM policies
    component-template/          # Component templates (settings, mappings)
    index-template/              # Index templates (data streams, standard indices)
    security/
      role/                      # Security roles
  definitions-local/             # Local sandbox only
    security/
      user/                      # Sample users for local development
      role/                      # Additional dev/test roles
```

## What you can do as a user

- **Add or modify ILM policies** — create a new `.request` file in `definitions/ilm/` to define a custom lifecycle policy
- **Create index templates** — add component templates and compose them into index templates for new data streams
- **Define security roles** — add `.request` files in `definitions/security/role/` to control who can read or write which data
- **Add sample users** — create local-only users in `definitions-local/security/user/` for testing role-based access in Kibana

## Compose profile

Elasticsearch is part of the base stack and always runs — no profile flag needed.

```bash
podman compose -f install/compose.yaml --env-file install/local/.env up -d
```
