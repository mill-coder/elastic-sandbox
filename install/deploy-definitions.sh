#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# deploy-definitions.sh — Apply all *.request definition files to an Elastic
# stack in dependency order.  Idempotent (PUT + POST with override).
# ---------------------------------------------------------------------------

# --- Configuration (from environment, with defaults) -----------------------
ES_URL="${ES_URL:-http://localhost:9200}"
KB_URL="${KB_URL:-http://localhost:5601}"
ELASTIC_USER="${ELASTIC_USER:-elastic}"
ELASTIC_PASSWORD="${ELASTIC_PASSWORD:?ELASTIC_PASSWORD must be set}"
KIBANA_SYSTEM_PASSWORD="${KIBANA_SYSTEM_PASSWORD:-}"
START_TRIAL_LICENSE="${START_TRIAL_LICENSE:-false}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-60}"          # max attempts (× 2s sleep)
VERBOSE="${VERBOSE:-false}"

DEPLOY_MODE="${DEPLOY_MODE:-all}"    # all | es | kibana

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFS="${DEFS_DIR:-$REPO_ROOT/elasticsearch/definitions}"
DEFS_LOCAL="${DEFS_LOCAL_DIR:-$REPO_ROOT/elasticsearch/definitions-local}"

# --- Counters --------------------------------------------------------------
total=0
ok=0
failed=0

# --- Helpers ---------------------------------------------------------------

log()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

# Wait for Elasticsearch to become healthy.
wait_for_es() {
    local attempt=1
    log "Waiting for Elasticsearch ($ES_URL) ..."
    while [ "$attempt" -le "$WAIT_TIMEOUT" ]; do
        if curl -sS -o /dev/null -w '' -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" "$ES_URL" 2>/dev/null; then
            log "Elasticsearch is ready."
            return 0
        fi
        sleep 2
        attempt=$((attempt + 1))
    done
    warn "ERROR: Elasticsearch did not become ready after $((WAIT_TIMEOUT * 2))s."
    return 1
}

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

# Set the kibana_system built-in user password so Kibana can authenticate to ES.
setup_kibana_system_password() {
    if [ -z "$KIBANA_SYSTEM_PASSWORD" ]; then
        return 0
    fi

    log ""
    log "--- kibana_system password ---"
    total=$((total + 1))

    local curl_out http_code response_body
    curl_out="$(curl -sS -w '\n%{http_code}' \
        -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
        -X POST \
        -H "Content-Type: application/json" \
        -d "{\"password\":\"${KIBANA_SYSTEM_PASSWORD}\"}" \
        "${ES_URL}/_security/user/kibana_system/_password" 2>&1)" || true

    http_code="$(echo "$curl_out" | tail -n1)"
    response_body="$(echo "$curl_out" | sed '$d')"

    if [[ "$http_code" =~ ^2 ]]; then
        log "  OK   kibana_system password ($http_code)"
        ok=$((ok + 1))
    else
        warn "  FAIL kibana_system password ($http_code)"
        if [ "$VERBOSE" = "true" ]; then
            warn "       $response_body"
        fi
        failed=$((failed + 1))
    fi
}

# Start trial license (for dev/lab environments).
start_trial_license() {
    if [ "$START_TRIAL_LICENSE" != "true" ]; then
        return 0
    fi

    log ""
    log "--- Trial license ---"
    total=$((total + 1))

    local curl_out http_code response_body
    curl_out="$(curl -sS -w '\n%{http_code}' \
        -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
        -X POST \
        "${ES_URL}/_license/start_trial?acknowledge=true" 2>&1)" || true

    http_code="$(echo "$curl_out" | tail -n1)"
    response_body="$(echo "$curl_out" | sed '$d')"

    if [[ "$http_code" =~ ^2 ]]; then
        if echo "$response_body" | grep -q '"trial_was_started":true'; then
            log "  OK   Trial license started ($http_code)"
        else
            log "  OK   Trial license already active ($http_code)"
        fi
        ok=$((ok + 1))
    else
        # 403 = trial already used, not a fatal error for ephemeral setups
        if [[ "$http_code" == "403" ]]; then
            log "  OK   Trial license already used on this cluster ($http_code)"
            ok=$((ok + 1))
        else
            warn "  FAIL Trial license ($http_code)"
            if [ "$VERBOSE" = "true" ]; then
                warn "       $response_body"
            fi
            failed=$((failed + 1))
        fi
    fi
}

# Deploy a single .request file.
#   deploy_request <base_url> <file>
deploy_request() {
    local base_url="$1" file="$2"
    local name
    name="$(basename "$file")"

    # Parse first line: METHOD URL_PATH (strip CR for CRLF safety)
    local first_line method url_path
    first_line="$(head -n1 "$file" | tr -d '\r')"
    method="$(echo "$first_line" | awk '{print $1}')"
    url_path="$(echo "$first_line" | awk '{print $2}')"

    # Build full URL — url_path may or may not have a leading slash
    local full_url
    case "$url_path" in
        /*) full_url="${base_url}${url_path}" ;;
        *)  full_url="${base_url}/${url_path}" ;;
    esac

    # Body = everything after line 1
    local body
    body="$(tail -n+2 "$file" | tr -d '\r')"

    # Extra headers for Kibana
    local extra_headers=()
    if [[ "$base_url" == "$KB_URL" ]]; then
        extra_headers+=(-H "kbn-xsrf: true")
    fi

    # Execute
    local http_code curl_out
    total=$((total + 1))

    if [ -n "$body" ]; then
        curl_out="$(curl -sS -w '\n%{http_code}' \
            -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
            -X "$method" \
            -H "Content-Type: application/json" \
            "${extra_headers[@]+"${extra_headers[@]}"}" \
            -d "$body" \
            "$full_url" 2>&1)" || true
    else
        curl_out="$(curl -sS -w '\n%{http_code}' \
            -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
            -X "$method" \
            "${extra_headers[@]+"${extra_headers[@]}"}" \
            "$full_url" 2>&1)" || true
    fi

    http_code="$(echo "$curl_out" | tail -n1)"
    local response_body
    response_body="$(echo "$curl_out" | sed '$d')"

    if [[ "$http_code" =~ ^2 ]] || [[ "$http_code" == "409" ]]; then
        log "  OK   $name ($http_code)"
        ok=$((ok + 1))
    else
        warn "  FAIL $name ($http_code)"
        if [ "$VERBOSE" = "true" ]; then
            warn "       $response_body"
        fi
        failed=$((failed + 1))
    fi
}

# Deploy all .request files in a directory (glob-based, skips if empty).
#   deploy_phase <label> <base_url> <directory>
deploy_phase() {
    local label="$1" base_url="$2" dir="$3"
    local files=()

    if [ ! -d "$dir" ]; then
        return 0
    fi

    # Collect .request files (nullglob-safe)
    local f
    for f in "$dir"/*.request; do
        [ -e "$f" ] && files+=("$f")
    done

    if [ ${#files[@]} -eq 0 ]; then
        return 0
    fi

    log ""
    log "--- $label (${#files[@]} files) ---"
    local file
    for file in "${files[@]}"; do
        deploy_request "$base_url" "$file"
    done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

log "deploy-definitions.sh — mode=$DEPLOY_MODE  ES=$ES_URL  KB=$KB_URL"
log "  DEFS=$DEFS"
log "  DEFS_LOCAL=$DEFS_LOCAL"

DEPLOY_SAMPLE_USERS="${DEPLOY_SAMPLE_USERS:-false}"

if [[ "$DEPLOY_MODE" == "all" || "$DEPLOY_MODE" == "es" ]]; then
    # Elasticsearch must be healthy before deploying any ES definitions
    wait_for_es

    # Start trial license for dev/lab environments (unlocks webhook connectors, etc.)
    start_trial_license

    deploy_phase "ILM policies"                   "$ES_URL" "$DEFS/ilm-policies"
    deploy_phase "Component templates (settings)"  "$ES_URL" "$DEFS/component-templates/settings"
    deploy_phase "Component templates (mappings)"  "$ES_URL" "$DEFS/component-templates/mappings"
    deploy_phase "Index templates"                 "$ES_URL" "$DEFS/index-templates"
    deploy_phase "Ingest pipelines"                "$ES_URL" "$DEFS/ingest-pipelines"
    deploy_phase "Security roles"                  "$ES_URL" "$DEFS/security/role"
    deploy_phase "Security users"                  "$ES_URL" "$DEFS/security/user"

    # Set kibana_system password so Kibana can authenticate to Elasticsearch
    setup_kibana_system_password

    # Local-only definitions (sample users, test data)
    if [ "$DEPLOY_SAMPLE_USERS" = "true" ] && [ -d "$DEFS_LOCAL" ]; then
        log ""
        log "=== Local-only definitions ==="
        deploy_phase "Local: index templates" "$ES_URL" "$DEFS_LOCAL/index-templates"
        deploy_phase "Local: roles"           "$ES_URL" "$DEFS_LOCAL/security/role"
        deploy_phase "Local: users"           "$ES_URL" "$DEFS_LOCAL/security/user"
    fi
fi

if [[ "$DEPLOY_MODE" == "all" || "$DEPLOY_MODE" == "kibana" ]]; then
    # Kibana must be healthy before deploying Kibana definitions
    wait_for_kibana

    deploy_phase "Kibana spaces"       "$KB_URL" "$DEFS/spaces"
    deploy_phase "Kibana data views"   "$KB_URL" "$DEFS/data-views"

    for space_dir in "$DEFS/data-views/spaces"/*/; do
        [ -d "$space_dir" ] || continue
        deploy_phase "Kibana data views ($(basename "$space_dir"))" "$KB_URL" "$space_dir"
    done
fi

# --- Summary ---------------------------------------------------------------
log ""
log "Done. total=$total  ok=$ok  failed=$failed"

if [ "$failed" -gt 0 ]; then
    exit 1
fi
