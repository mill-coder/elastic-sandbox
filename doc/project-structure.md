# Project structure

This page describes the repository layout, how the project is organized, and how Elastic Stack resources are declared and deployed.

The project is composed of modules ; a module owns its definitions and the resources it needs injected into its dependencies.

| Module | Purpose | Dependencies |
|--------|---------|--------------|
| [`elasticsearch`](modules/elasticsearch.md) | Core cluster definitions: ILM policies, component/index templates, security roles | — |
| [`kibana`](modules/kibana.md) | Kibana resources (spaces, data views) and the ES resources Kibana depends on | `elasticsearch` |
| [`logstash`](modules/logstash.md) | Deploys a managed logstash instance to let the developper write & test its own pipelines. | `elasticsearch`, `kibana` |
| [`mattermost`](modules/mattermost.md) | Deploy a mattemost instance with Teams having `elastic alerts` channels to dev/test kibana alerting rules & mattermost connector | — |

### Modular directory structure

- Each module (`elasticsearch/`, `kibana/`, `logstash/`) owns its `definitions/` directory
- Modules can include resources for other services (e.g., `kibana/definitions/elasticsearch/`)
- `definitions-local/` for resources only needed in the local sandbox (sample users, dev roles). Keeping local definitions separate from production-ready ones.

## Definitions system

Elastic Stack resources are declared as files and deployed automatically.

### The `*.request` file format

Each `.request` file defines a resource to inject in elasticsearch / kibana instance (ILM, user, role, index pattern, rule, alert, ...). 

A `.request` file is structured as follow:
- First line: HTTP method and (elastic/kibana) API path (e.g., `PUT _ilm/policy/org-roll-7d-retain-30d`)
- Remaining lines: JSON request body
- One API call per file for clarity and version control

Example `elasticsearch/definitions/security/role/org-role-data-logs-app.request`:
```
PUT _security/role/org_data_logs_app
{
  "indices": [
    {
      "names": ["logs-*-app*"],
      "privileges": ["read", "view_index_metadata"]
    }
  ]
}
```
### Naming conventions

- `org-` prefix for all custom resources
- Hyphens in filenames, underscores in Elasticsearch role names
- ILM policies: `org-roll-{rollover}-retain-{retention}`
- Component templates: `org-settings-*`, `org-mapping-*`


## Init containers and deploy scripts

Definitions are deployed automatically at stack startup using init containers. Each module that needs to inject resources into Elasticsearch or Kibana has its own init container defined in `compose.yaml`.

Init containers follow a two-phase pattern:

- **Pre-init** — waits for the target service (Elasticsearch or Kibana) to be healthy, then deploys the module's `definitions/` and `definitions-local/` resources using `deploy-definitions.sh`. Resources are applied in dependency order: ILM policies, component templates, index templates, security roles, then Kibana resources (spaces, data views).
- **Post-init** — runs additional setup scripts after definitions are deployed (e.g., `add-roles-to-users.sh` to merge roles into existing users, `deploy-logstash-pipelines.sh` to push pipeline configurations).

Init containers use `restart: "no"` and downstream services declare `depends_on` with `condition: service_completed_successfully`, ensuring the stack only becomes available once all resources have been deployed.

## Repository layout

```
elasticsearch/
  definitions/                 # ES definitions (ILM policies, templates, roles)
  definitions-local/           # Local-only definitions (sample users, roles)

kibana/
  definitions/
    elasticsearch/             # ES resources that Kibana depends on
    kibana/                    # Kibana API resources (spaces, data views)
  definitions-local/           # Local-only Kibana resources

logstash/
  definitions/
    elasticsearch/             # ES resources that Logstash depends on
  definitions-local/
    elasticsearch/             # Local-only satellite definitions
  config/                      # Logstash logging config
  elastic-agent/               # Standalone Elastic Agent config
  pipelines/                   # Managed pipeline .conf files
    reference/                 # Reference pipeline examples (not deployed)
  scripts/                     # Sidecar scripts (pipeline health checker)

install/
  compose.yaml                 # Shared Compose definition
  deploy-definitions.sh        # Generic definition deploy script
  deploy-logstash-pipelines.sh # Pipeline deploy script
  add-roles-to-users.sh        # Merge roles into existing ES users
  images/
    init/
      Dockerfile               # Init container base image (Alpine + curl/bash/jq)
  local/
    .env                       # Local dev environment variables

doc/                           # Documentation and golden path guides
  howtos/                      # Golden path how-to guides
```
