#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# import-saved-objects.sh — Import *.ndjson saved-object bundles into Kibana
# via the Saved Objects Import API.  Idempotent (overwrite=true).
#
# Files at the root of OBJECTS_DIR are imported into the default space.
# Files under spaces/{space_id}/ subdirectories are imported into that space.
# ---------------------------------------------------------------------------

# --- Configuration (from environment, with defaults) -----------------------
KB_URL="${KB_URL:-http://localhost:5601}"
ELASTIC_USER="${ELASTIC_USER:-elastic}"
ELASTIC_PASSWORD="${ELASTIC_PASSWORD:?ELASTIC_PASSWORD must be set}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-60}"
VERBOSE="${VERBOSE:-false}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OBJECTS_DIR="${OBJECTS_DIR:-$REPO_ROOT/logstash/definitions-local/kibana/saved-objects}"

# --- Counters --------------------------------------------------------------
total=0
ok=0
failed=0

# --- Helpers ---------------------------------------------------------------

log()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

# Wait for Kibana to become fully available (overall status = "available").
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

# Import a single NDJSON file into a Kibana space.
#   import_file <file> [space_id]
import_file() {
    local file="$1"
    local space="${2:-}"
    local name
    name="$(basename "$file")"

    total=$((total + 1))

    # Build API URL (space-aware)
    local api_prefix=""
    if [ -n "$space" ]; then
        api_prefix="/s/${space}"
    fi
    local import_url="${KB_URL}${api_prefix}/api/saved_objects/_import?overwrite=true"

    local curl_out http_code response_body
    curl_out="$(curl -sS -w '\n%{http_code}' \
        -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
        -X POST \
        -H "kbn-xsrf: true" \
        -F "file=@${file}" \
        "$import_url" 2>&1)" || true

    http_code="$(echo "$curl_out" | tail -n1)"
    response_body="$(echo "$curl_out" | sed '$d')"

    # Check both HTTP status and the success field in the JSON response
    local success="false"
    if [[ "$http_code" =~ ^2 ]]; then
        if echo "$response_body" | grep -q '"success":true'; then
            success="true"
        fi
    fi

    local space_label=""
    if [ -n "$space" ]; then
        space_label=" [space=$space]"
    fi

    if [ "$success" = "true" ]; then
        log "  OK   $name ($http_code)$space_label"
        ok=$((ok + 1))
    elif [[ "$http_code" =~ ^2 ]]; then
        # HTTP 200 but success:false — partial failures (e.g. missing references)
        warn "  WARN $name ($http_code — partial failure)$space_label"
        if [ "$VERBOSE" = "true" ]; then
            warn "       $response_body"
        fi
        # Count as ok — objects were imported, some references may need attention
        ok=$((ok + 1))
    else
        warn "  FAIL $name ($http_code)$space_label"
        if [ "$VERBOSE" = "true" ]; then
            warn "       $response_body"
        fi
        failed=$((failed + 1))
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

log "import-saved-objects.sh — importing to KB=$KB_URL"

if [ ! -d "$OBJECTS_DIR" ]; then
    log "Objects directory not found: $OBJECTS_DIR — nothing to import."
    exit 0
fi

# Collect root-level NDJSON files (default space)
root_files=()
for f in "$OBJECTS_DIR"/*.ndjson; do
    [ -e "$f" ] && root_files+=("$f")
done

# Collect space-scoped NDJSON files
space_files=()
if [ -d "$OBJECTS_DIR/spaces" ]; then
    for f in "$OBJECTS_DIR/spaces"/*/*.ndjson; do
        [ -e "$f" ] && space_files+=("$f")
    done
fi

if [ ${#root_files[@]} -eq 0 ] && [ ${#space_files[@]} -eq 0 ]; then
    log "No *.ndjson files found in $OBJECTS_DIR — nothing to import."
    exit 0
fi

wait_for_kibana

# Import root-level files (default space)
if [ ${#root_files[@]} -gt 0 ]; then
    log ""
    log "--- Saved objects — default space (${#root_files[@]} files) ---"
    for file in "${root_files[@]}"; do
        import_file "$file"
    done
fi

# Import space-scoped files
if [ ${#space_files[@]} -gt 0 ]; then
    for file in "${space_files[@]}"; do
        space_id="$(basename "$(dirname "$file")")"
        log ""
        log "--- Saved objects — space '$space_id' ---"
        import_file "$file" "$space_id"
    done
fi

# --- Summary ---------------------------------------------------------------
log ""
log "Done. total=$total  ok=$ok  failed=$failed"

if [ "$failed" -gt 0 ]; then
    exit 1
fi
