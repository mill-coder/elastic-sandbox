#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# start-all.sh — Start full Elastic stack with all profiles
#                and deploy definitions
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$INSTALL_DIR/compose.yaml"
ENV_FILE="$SCRIPT_DIR/.env"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
step() { printf '\033[1;32m-->\033[0m %s\n' "$*"; }

log "Starting full Elastic stack (all profiles)"
log "  Compose file: $COMPOSE_FILE"
log "  Env file:     $ENV_FILE"
log "  Profiles:     kibana, logstash, mattermost"

# Load environment for deploy script
set -a
# shellcheck source=.env
source "$ENV_FILE"
set +a

log ""
step "Starting containers..."
podman compose \
    --project-directory "$INSTALL_DIR" \
    -f "$COMPOSE_FILE" \
    --env-file "$ENV_FILE" \
    --profile kibana \
    --profile logstash \
    --profile mattermost \
    up -d 2>&1 | sed 's/^/  /'

log ""
step "Deploying definitions..."
"$INSTALL_DIR/deploy-definitions.sh"

log ""
step "Deploying Mattermost configuration..."
"$INSTALL_DIR/deploy-mattermost.sh"

log ""
step "Deploying Kibana alerting rules..."
"$INSTALL_DIR/deploy-kibana-alerts.sh"

log ""
log "Full stack ready."
log "  Elasticsearch: http://localhost:${ES_PORT:-9200}"
log "  Kibana:        http://localhost:${KIBANA_PORT:-5601}"
log "  Mattermost:    http://localhost:${MM_PORT:-8065}"
log "  Logstash:      running (no exposed port)"
