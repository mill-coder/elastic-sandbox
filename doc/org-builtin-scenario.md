# Built-in scenario: sample organization

This page describes the reference organization (`org`) that elastic-sandbox ships with — its teams, roles, access model, and platform conventions. You can use this scenario as-is or customize it to match your own organization.

## Organization overview

- A mid-to-large organization with distinct IT functions
- Elastic Stack as a shared platform managed by an infrastructure team

### Teams and roles

- IT infrastructure teams — manage the underlying infrastructure and platform services
- Delivery teams (DevOps) — build and operate applications, instrument their own logging and observability
- Business analysts — consume analytics dashboards and KPIs derived from log data
- IT risk managers (SIEM) — monitor security events and compliance

### Access model

- Role-based access to data and Kibana features
- Each team sees only the log categories and spaces relevant to their function
- Each team has its own dedicated Kibana space that it can customize autonomously (dashboards, saved queries, alerting rules, etc.); sibling teams can access each other's spaces

### Developer workstation

- Organization-managed Windows 11 machine (no admin rights)
- WSL2 + Podman Desktop as the container runtime
- The sandbox replicates production governance locally so developers can validate changes before promoting them

## Platform governance

## Log categories and retention

| Category | Purpose | Retention | Access |
|----------|---------|-----------|--------|
| `infra` | Infrastructure monitoring | 30 days | Infrastructure teams |
| `app` | Application logs | 30 days | Delivery teams + Infrastructure teams |
| `analytics` | KPIs for business analysts (ELT) | 5 years | Business analysts, Delivery teams |
| `siem` | Security events (ELT) | 2 years | IT risk / SIEM team |
| `other` | Ad-hoc needs | ad-hoc | ad-hoc |

## Data stream naming convention

- The `[type]-[dataset]-[namespace]` naming scheme follows official [elastic data streams naming scheme](https://www.elastic.co/blog/an-introduction-to-the-elastic-data-stream-naming-scheme)
- namespaces correspond to log categories, and drive user's visibility according to their role.
- Examples of well-formed data stream names:
    * `logs-intranet-app`
    * `logs-website.frontent-app`
    * `logs-website.backend-app`
    * `logs-firewall-infra`
    * `logs-website.visitors-analytis`

## Field naming conventions

- [ECS (Elastic Common Schema)](https://www.elastic.co/docs/reference/ecs) as the first choice
- Vendor/integration fields when no ECS equivalent exists
- Custom fields under `org.[product_name].*`

## Ingestion strategy (ELT)

- Extract & Load: raw logs stored as-is into `infra` and `app`
- Transform: downstream jobs parse, enrich, and route into `analytics`, `siem`, and `other`
- Multiple independent transform loops on the same raw data
