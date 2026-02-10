#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# start-mini.sh — Start minimal Elastic stack (Elasticsearch + Kibana only)
#                 and deploy definitions
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$INSTALL_DIR/compose.yaml"
ENV_FILE="$SCRIPT_DIR/.env"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
step() { printf '\033[1;32m-->\033[0m %s\n' "$*"; }

log "Starting minimal Elastic stack (Elasticsearch + Kibana)"
log "  Compose file: $COMPOSE_FILE"
log "  Env file:     $ENV_FILE"

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
    up -d 2>&1 | sed 's/^/  /'

log ""
step "Deploying definitions..."
"$INSTALL_DIR/deploy-definitions.sh"

log ""
log "Minimal stack ready."
log "  Elasticsearch: http://localhost:${ES_PORT:-9200}"
log "  Kibana:        http://localhost:${KIBANA_PORT:-5601}"
