# Getting started

This guide walks you through setting up elastic-sandbox on your local machine and running your first Elastic Stack instance.

## Prerequisites

- Linux workstation or Windows 11 workstation with WSL2 installed.
- Podman and podman-compose installation ; podman desktop optional.
- Setting `vm.max_map_count` for Elasticsearch
- Verifying your environment is ready

## Clone and run

- Cloning the repository
- Understand and adapt the `.env` file
- Start the base stack (Elasticsearch only)

## Verifying the stack is healthy

- Checking container status
- Querying the Elasticsearch API
- Accessing Kibana in the browser
- Reviewing init container logs

## Stopping and cleaning up

- Stopping the stack
- Removing volumes for a fresh start
- Reclaiming disk space
