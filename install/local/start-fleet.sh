#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# start-fleet.sh — Start Elastic stack with Fleet profile
#                  and deploy definitions
#
# Orchestrates services manually because podman-compose does not support
# depends_on conditions (service_healthy, service_completed_successfully).
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$INSTALL_DIR/compose.yaml"
ENV_FILE="$SCRIPT_DIR/.env"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
step() { printf '\033[1;32m-->\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mERR\033[0m %s\n' "$*" >&2; exit 1; }

# Load environment
set -a
# shellcheck source=.env
source "$ENV_FILE"
set +a

log "Starting Elastic stack with Fleet"
log "  Compose file: $COMPOSE_FILE"
log "  Env file:     $ENV_FILE"
log "  Profiles:     kibana, fleet"

cd "$INSTALL_DIR"

compose() {
    podman-compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" \
        --profile kibana --profile fleet "$@"
}

wait_healthy() {
    local name="$1" timeout="${2:-120}" elapsed=0
    step "Waiting for $name to be healthy..."
    while [ "$elapsed" -lt "$timeout" ]; do
        local status
        status="$(podman inspect -f '{{.State.Health.Status}}' "$name" 2>/dev/null)" || true
        if [ "$status" = "healthy" ]; then
            log "  $name is healthy"
            return 0
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done
    fail "$name did not become healthy after ${timeout}s"
}

wait_exited() {
    local name="$1" timeout="${2:-120}" elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        local status exit_code
        status="$(podman inspect -f '{{.State.Status}}' "$name" 2>/dev/null)" || true
        if [ "$status" = "exited" ]; then
            exit_code="$(podman inspect -f '{{.State.ExitCode}}' "$name" 2>/dev/null)" || true
            if [ "$exit_code" = "0" ]; then
                log "  $name completed successfully"
                return 0
            else
                podman logs "$name" 2>&1 | tail -5
                fail "$name exited with code $exit_code"
            fi
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    fail "$name did not complete after ${timeout}s"
}

# --- Elasticsearch ---------------------------------------------------------
step "Starting elasticsearch..."
compose up -d --no-deps elasticsearch 2>&1 | sed 's/^/  /'
wait_healthy elasticsearch 120

# --- ES init ---------------------------------------------------------------
step "Starting es-init..."
compose up -d --no-deps es-init 2>&1 | sed 's/^/  /'
wait_exited es-init 120

# --- Kibana pre-init -------------------------------------------------------
step "Starting kibana-pre-init..."
compose up -d --no-deps kibana-pre-init 2>&1 | sed 's/^/  /'
wait_exited kibana-pre-init 120

# --- Kibana ----------------------------------------------------------------
step "Starting kibana..."
compose up -d --no-deps kibana 2>&1 | sed 's/^/  /'
wait_healthy kibana 300

# --- Fleet init (runs in parallel with kibana-init) ------------------------
step "Starting fleet-init and kibana-init..."
compose up -d --no-deps kibana-init fleet-init 2>&1 | sed 's/^/  /'
wait_exited kibana-init 120
wait_exited fleet-init 180

# --- Fleet Server ----------------------------------------------------------
step "Starting fleet-server..."
compose up -d --no-deps fleet-server 2>&1 | sed 's/^/  /'
wait_healthy fleet-server 180

# --- Elastic Agents --------------------------------------------------------
step "Starting elastic-agent-lan and elastic-agent-www..."
compose up -d --no-deps elastic-agent-lan elastic-agent-www 2>&1 | sed 's/^/  /'

log ""
log "Stack with Fleet ready."
log "  Elasticsearch:  http://localhost:${ES_PORT:-9200}"
log "  Kibana:         http://localhost:${KIBANA_PORT:-5601}"
log "  Fleet Server:   http://localhost:${FLEET_SERVER_PORT:-8220}"
log "  Kibana Fleet:   http://localhost:${KIBANA_PORT:-5601}/app/fleet"
