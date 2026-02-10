# Getting started

This guide walks you through setting up elastic-sandbox on your local machine and running your first Elastic Stack instance.

## Prerequisites

- Linux workstation or Windows 11 workstation with WSL2 installed.
- Podman and podman-compose installation ; podman desktop optional.
- Setting `vm.max_map_count` for Elasticsearch
- Verifying your environment is ready

## Clone and run

- Cloning the repository
- Understand and adapt the `install/local/.env` file
- Start the base stack (Elasticsearch + Kibana + Logstash)
    ```
    podman compose -f install/compose.yaml \
      --env-file install/local/.env \
      --profile kibana \
      --profile logstash \
      up -d
    ```

- browse [http://localhost:5601](http://locahost:5601)

 - login with one user pre-defined in sample org:
    
    | user | password | type |
    |------|----------|------|
    | `elastic` | `changeme` | admin
    | `mobile_dev` | `password` | delivery dev
    | `mobile_ops` | `password` | delivery ops
    | `customer_dev` | `password` | delivery dev
    | `customer_ops` | `password` | delivery ops
    | `web_dev` | `password` | delivery dev
    | `web_ops` | `password` | delivery ops
    | `servers_ops` | `password` | infra ops
    | `databases_ops` | `password` | infra ops
    
