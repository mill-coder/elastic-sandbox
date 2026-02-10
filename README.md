# elastic-sandbox

A local Elastic Stack sandbox for developing, debugging, testing, and fixing Elastic resources before pushing to production.

## Overview

**elastic-sandbox** gives developers and ops teams a fully functional local Elastic Stack that mirrors the structure and conventions of the production deployment of an organization. Instead of experimenting directly on shared infrastructure, you spin up an isolated sandbox, iterate locally, and promote only validated changes.

The project follows **platform engineering** principles: it provides opinionated **golden paths** — documented, repeatable workflows for common tasks, to let teams work autonomously within well-defined guardrails.

> **Note:** This project is under active development. Contributions and feedback are welcome.

## Key features

- **Golden path documentation** — step-by-step guides for common development workflows
- **Single-command startup** — bring up the full stack (or just the parts you need) with one `podman compose` command.
- **Production-like structure** — define the same resources (ILM policies, index templates, security roles, data views) that exist in your production Elastic Stack, so your local sandbox closely mirrors the real environment
- **Modular approach** — spin up as much or as little of the stack as you need: a pre-configured Elasticsearch instance on its own, add a Kibana frontend, include a managed Logstash, or bring up the full stack
- **Disposable by design** — destroy and recreate your local stack from scratch in seconds, so you can experiment freely without worrying about leaving it in a broken state
- **Compose profiles** — opt in to additional services (Kibana, Logstash, Mattermost) without changing the base configuration
- **Works on managed workstations** — designed for organization-managed workstations where developers have no admin rights.

## Out-of-the-box scenario

The sandbox ships with a ready-to-use example scenario that you can adapt to your own needs. See [doc/org-builtin-scenario.md](doc/org-builtin-scenario.md) for the full description of the sample organization, its teams, access model, and platform conventions.

## Quick start

**Prerequisites:** Windows 11 with WSL2, [Podman Desktop](https://podman-desktop.io/) with the Compose plugin. See [doc/getting-started.md](doc/getting-started.md) for detailed setup instructions.

```bash
# Clone the repository
git clone https://github.com/nouknouk/elastic-sandbox.git
cd elastic-sandbox

# Start Elasticsearch only
podman compose -f install/compose.yaml --env-file install/local/.env up -d

# Start Elasticsearch + Kibana
podman compose -f install/compose.yaml --env-file install/local/.env --profile kibana up -d

# Start the full stack (Elasticsearch + Kibana + Logstash)
podman compose -f install/compose.yaml --env-file install/local/.env --profile kibana --profile logstash up -d
```

See [doc/getting-started.md](doc/getting-started.md) for the full setup guide.

## Documentation

| Guide | Description |
|-------|-------------|
| [Getting started](doc/getting-started.md) | Prerequisites, installation, first run |
| [Built-in scenario](doc/org-builtin-scenario.md) | Sample organization, teams, access model, platform conventions that you can customize |
| [Project structure](doc/project-structure.md) | Repository layout, definitions system, deploy scripts |
| **Modules** | |
| [Elasticsearch](doc/modules/elasticsearch.md) | Core cluster: ILM policies, templates, security roles |
| [Kibana](doc/modules/kibana.md) | Spaces, data views, dashboards, alerting |
| [Logstash](doc/modules/logstash.md) | Managed ingest pipelines, Elastic Agent |
| [Mattermost](doc/modules/mattermost.md) | Alert notifications and connector testing |
| **How-tos** | |
| [Deploy the stack locally](doc/howtos/deploy-stack-locally.md) | Compose profiles, starting, stopping, recreating the stack |
| [Customize the scenario](doc/howtos/customize-scenario.md) | Adapt the built-in organization to match your own |


## Project structure

See [doc/project-structure.md](doc/project-structure.md) for the full repository layout.

## Contributing

This project is in its early stages. If you find it useful or have ideas for improvement, feel free to open an issue or submit a pull request.

## License

[MIT](LICENSE)
