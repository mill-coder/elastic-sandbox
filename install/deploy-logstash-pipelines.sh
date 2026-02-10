#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# deploy-logstash-pipelines.sh — Deploy *.conf files as Kibana-managed
# Logstash Centralized Pipeline Management pipelines via the Kibana API.
# Idempotent (PUT creates or overwrites).  PIPELINE_DIR is overridable.
# ---------------------------------------------------------------------------

# --- Configuration (from environment, with defaults) -----------------------
KB_URL="${KB_URL:-http://localhost:5601}"
ELASTIC_USER="${ELASTIC_USER:-elastic}"
ELASTIC_PASSWORD="${ELASTIC_PASSWORD:?ELASTIC_PASSWORD must be set}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-60}"          # max attempts (× 2s sleep)
VERBOSE="${VERBOSE:-false}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PIPELINE_DIR="${PIPELINE_DIR:-$REPO_ROOT/logstash/pipelines}"

# --- Counters --------------------------------------------------------------
total=0
ok=0
failed=0

# --- Pre-checks ------------------------------------------------------------

if ! command -v jq &>/dev/null; then
    printf 'ERROR: jq is required but not found in PATH.\n' >&2
    exit 1
fi

# --- Helpers ---------------------------------------------------------------

log()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

# Wait for Kibana to become fully available (overall status = "available").
# /api/status returns 200 before Kibana is actually ready to serve requests,
# so we must inspect the JSON response.
wait_for_kibana() {
    local attempt=1
    local status_url="$KB_URL/api/status"
    log "Waiting for Kibana ($status_url) ..."
    while [ "$attempt" -le "$WAIT_TIMEOUT" ]; do
        local body
        body="$(curl -sS -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" "$status_url" 2>/dev/null)" || true
        if echo "$body" | grep -q '"level":"available"'; then
            log "Kibana is ready."
            return 0
        fi
        sleep 2
        attempt=$((attempt + 1))
    done
    warn "ERROR: Kibana did not become ready after $((WAIT_TIMEOUT * 2))s."
    return 1
}

# Deploy a single .conf file as a Kibana-managed Logstash pipeline.
#   deploy_pipeline <file>
deploy_pipeline() {
    local file="$1"
    local pipeline_id
    pipeline_id="$(basename "$file" .conf)"

    total=$((total + 1))

    # Extract description from first comment line: # Description: ...
    local description=""
    local first_comment
    first_comment="$(head -n1 "$file" | tr -d '\r')"
    if [[ "$first_comment" =~ ^#\ Description:\ (.*) ]]; then
        description="${BASH_REMATCH[1]}"
    fi

    # Read pipeline content (skip the description comment line if present)
    local pipeline_content
    if [ -n "$description" ]; then
        pipeline_content="$(tail -n+2 "$file" | tr -d '\r')"
    else
        pipeline_content="$(cat "$file" | tr -d '\r')"
    fi

    # Build JSON payload using jq for proper escaping
    local payload
    payload="$(jq -n \
        --arg desc "$description" \
        --arg pipe "$pipeline_content" \
        '{description: $desc, pipeline: $pipe}')"

    # PUT to Kibana Logstash pipeline API
    local curl_out http_code response_body
    curl_out="$(curl -sS -w '\n%{http_code}' \
        -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
        -X PUT \
        -H "Content-Type: application/json" \
        -H "kbn-xsrf: true" \
        -d "$payload" \
        "${KB_URL}/api/logstash/pipeline/${pipeline_id}" 2>&1)" || true

    http_code="$(echo "$curl_out" | tail -n1)"
    response_body="$(echo "$curl_out" | sed '$d')"

    if [[ "$http_code" =~ ^2 ]]; then
        log "  OK   $pipeline_id ($http_code)"
        ok=$((ok + 1))
    else
        warn "  FAIL $pipeline_id ($http_code)"
        if [ "$VERBOSE" = "true" ]; then
            warn "       $response_body"
        fi
        failed=$((failed + 1))
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

log "deploy-logstash-pipelines.sh — deploying to KB=$KB_URL"

if [ ! -d "$PIPELINE_DIR" ]; then
    warn "ERROR: Pipeline directory not found: $PIPELINE_DIR"
    exit 1
fi

# Collect .conf files at root level only (not in subdirectories)
files=()
for f in "$PIPELINE_DIR"/*.conf; do
    [ -e "$f" ] && files+=("$f")
done

if [ ${#files[@]} -eq 0 ]; then
    log "No *.conf files found in $PIPELINE_DIR — nothing to deploy."
    exit 0
fi

wait_for_kibana

log ""
log "--- Logstash pipelines (${#files[@]} files) ---"
for file in "${files[@]}"; do
    deploy_pipeline "$file"
done

# --- Summary ---------------------------------------------------------------
log ""
log "Done. total=$total  ok=$ok  failed=$failed"

if [ "$failed" -gt 0 ]; then
    exit 1
fi
