#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# prune.sh — Stop and remove all local Elastic stack containers and volumes
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$INSTALL_DIR/compose.yaml"
ENV_FILE="$SCRIPT_DIR/.env"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }

log "Pruning local Elastic stack..."
log "  Compose file: $COMPOSE_FILE"
log "  Env file:     $ENV_FILE"

# Stop and remove containers, networks, and volumes for all profiles
log ""
log "Stopping containers and removing volumes (all profiles)..."
podman compose \
    --project-directory "$INSTALL_DIR" \
    -f "$COMPOSE_FILE" \
    --env-file "$ENV_FILE" \
    --profile kibana \
    --profile logstash \
    --profile heartbeat \
    --profile mattermost \
    down -v --remove-orphans 2>&1 | sed 's/^/  /'

log ""
log "Prune complete."
