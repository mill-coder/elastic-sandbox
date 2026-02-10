# Kibana module

The `kibana/` module adds a Kibana frontend to the sandbox. It deploys Kibana-specific resources (spaces, data views) and the Elasticsearch resources that Kibana depends on.

## What it provides

When the stack starts with the `kibana` profile, the Kibana init container deploys:

- **Elasticsearch resources** — any additional ES definitions that Kibana needs (e.g., roles granting access to Kibana features)
- **Kibana spaces** — each team gets its own dedicated space that it can customize autonomously (dashboards, saved queries, alerting rules); sibling teams can access each other's spaces
- **Data views** — pre-configured data views matching the log categories, so users can start exploring data in Discover immediately

## Directory layout

```
kibana/
  definitions/
    elasticsearch/               # ES resources Kibana depends on (roles, etc.)
    kibana/                      # Kibana API resources
      space/                     # Space definitions
      data-view/                 # Data view definitions
  definitions-local/             # Local sandbox only
    kibana/                      # Local-only Kibana resources (sample dashboards, etc.)
```

## What you can do as a user

- **Create or customize spaces** — add a `.request` file in `definitions/kibana/space/` to define a new Kibana space for a team
- **Add data views** — create data views in `definitions/kibana/data-view/` so users can explore specific data streams in Discover
- **Build dashboards locally** — use the Kibana UI to build dashboards, saved queries, and visualizations in your sandbox, then export them as definitions
- **Test alerting rules** — configure alerting rules in a team's space and verify they trigger correctly (combine with the Mattermost module to test notifications end-to-end)
- **Test role-based access** — log in as different sample users to verify that each team sees only the spaces and data relevant to their role

## Compose profile

Kibana is opt-in. Add `--profile kibana` to enable it:

```bash
podman compose -f install/compose.yaml --env-file install/local/.env --profile kibana up -d
```
