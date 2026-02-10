# How to customize the built-in scenario

The sandbox ships with a [built-in scenario](../org-builtin-scenario.md) modeled after a mid-to-large organization called `org`. This guide explains how to adapt it to match your own organization's structure.

## What you can customize

The built-in scenario defines several things you may want to change:

| What | Where | Example change |
|------|-------|----------------|
| Organization prefix | All `.request` filenames and resource names | Rename `org-` / `org_` to `mycompany-` / `mycompany_` |
| Log categories | ILM policies, index templates, security roles | Add a `compliance` category, remove `other` |
| Retention policies | `elasticsearch/definitions/ilm/` | Change `app` retention from 30 days to 90 days |
| Security roles | `elasticsearch/definitions/security/role/` | Add roles for new teams, adjust index patterns |
| Kibana spaces | `kibana/definitions/kibana/space/` | Create spaces matching your team structure |
| Data views | `kibana/definitions/kibana/data-view/` | Add data views for new data streams |
| Sample users | `elasticsearch/definitions-local/security/user/` | Create users matching your local testing needs |
| Custom fields | Component templates in `elasticsearch/definitions/` | Add `mycompany.[product].*` field mappings |

## Step by step

### 1. Choose your prefix

The built-in scenario uses `org` as the prefix for all custom resources. Pick a prefix that represents your organization (e.g., `acme`). You will need to rename:

- Filenames: `org-*` becomes `acme-*`
- ES resource names inside `.request` files: `org_*` becomes `acme_*` (underscores for role names), `org-*` becomes `acme-*` (hyphens for ILM policies, templates)
- Custom field namespace: `org.[product].*` becomes `acme.[product].*`

### 2. Adapt log categories

Review the [log categories table](../org-builtin-scenario.md#log-categories-and-retention). For each category you want to change:

- **Add a category** — create a new ILM policy, component templates, index template, and read/write security roles following the existing patterns
- **Remove a category** — delete the corresponding `.request` files for its ILM policy, index template, and security roles
- **Change retention** — edit the ILM policy `.request` file to adjust rollover and delete timing

### 3. Adjust security roles

Review the security roles in `elasticsearch/definitions/security/role/`. Each role controls access to a specific log category or Kibana feature. Adapt them to match your team structure:

- One read role per log category per team that needs access
- Write roles for ingest agents (typically only `infra` and `app`)
- Kibana space roles matching your space layout

### 4. Update Kibana spaces and data views

If you changed log categories or team structure:

- Create or update space definitions in `kibana/definitions/kibana/space/`
- Create or update data views in `kibana/definitions/kibana/data-view/` to match your data stream naming

### 5. Update sample users

Adjust the local-only users in `elasticsearch/definitions-local/security/user/` so they reflect the roles in your organization. These users are only deployed in the local sandbox and are useful for testing role-based access in Kibana.

### 6. Rebuild the stack

After making changes, destroy and recreate the stack to apply everything from scratch:

```bash
podman compose -f install/compose.yaml --env-file install/local/.env down -v
podman compose -f install/compose.yaml --env-file install/local/.env up -d
```

## Tips

- Start from the existing `.request` files — copy and adapt rather than writing from scratch
- Keep the naming conventions consistent (hyphens in filenames, underscores in ES role names)
- Use `definitions-local/` for anything that should only exist in the local sandbox
- Test role-based access by logging into Kibana as different sample users after customizing
