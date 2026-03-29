#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# deploy-fleet.sh — Set up Fleet Server and enroll an Elastic Agent.
#
# Creates a Fleet Server service token, configures Fleet settings in Kibana,
# creates a default agent policy, and writes tokens to a shared volume for
# fleet-server and elastic-agent containers to consume.
# ---------------------------------------------------------------------------

# --- Configuration (from environment, with defaults) -----------------------
ES_URL="${ES_URL:-http://elasticsearch:9200}"
KB_URL="${KB_URL:-http://kibana:5601}"
ELASTIC_USER="${ELASTIC_USER:-elastic}"
ELASTIC_PASSWORD="${ELASTIC_PASSWORD:-changeme}"
FLEET_TOKENS_DIR="${FLEET_TOKENS_DIR:-/fleet-tokens}"
FLEET_SERVER_HOST="${FLEET_SERVER_HOST:-http://fleet-server:8220}"
FLEET_AGENT_POLICY_NAME="${FLEET_AGENT_POLICY_NAME:-org-default-agent-policy}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-120}"

# --- Counters --------------------------------------------------------------
total=0
ok=0
failed=0

# --- Helpers ---------------------------------------------------------------

log()  { printf '%s\n' "$*" >&2; }
warn() { printf '%s\n' "$*" >&2; }

es_api() {
    local method="$1" path="$2"
    shift 2
    curl -sS -w '\n%{http_code}' -X "$method" \
        -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
        -H "Content-Type: application/json" \
        "$@" \
        "${ES_URL}/${path}" 2>&1
}

kb_api() {
    local method="$1" path="$2"
    shift 2
    curl -sS -w '\n%{http_code}' -X "$method" \
        -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
        -H "Content-Type: application/json" \
        -H "kbn-xsrf: true" \
        "$@" \
        "${KB_URL}${path}" 2>&1
}

# Extract HTTP status code (last line) and body (everything else).
parse_response() {
    local response="$1"
    HTTP_CODE="$(echo "$response" | tail -n1)"
    HTTP_BODY="$(echo "$response" | sed '$d')"
}

# Write content to file atomically.
write_token() {
    local file="$1" content="$2"
    printf '%s' "$content" > "${file}.tmp"
    mv "${file}.tmp" "$file"
}

# --- Wait functions --------------------------------------------------------

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
    warn "ERROR: Elasticsearch not ready after $((WAIT_TIMEOUT * 2))s."
    return 1
}

wait_for_kibana() {
    local attempt=1
    local status_url="$KB_URL/api/status"
    log "Waiting for Kibana ($status_url) ..."
    while [ "$attempt" -le "$WAIT_TIMEOUT" ]; do
        local body
        body="$(curl -sS "$status_url" 2>/dev/null)" || true
        if echo "$body" | grep -q '"level":"available"'; then
            log "Kibana is ready."
            return 0
        fi
        sleep 2
        attempt=$((attempt + 1))
    done
    warn "ERROR: Kibana not ready after $((WAIT_TIMEOUT * 2))s."
    return 1
}

# --- Step 1: Create Fleet Server service token -----------------------------

create_service_token() {
    log ""
    log "--- Creating Fleet Server service token ---"
    total=$((total + 1))

    # Delete existing token (ignore 404)
    es_api DELETE "_security/service/elastic/fleet-server/credential/token/fleet-server-local" > /dev/null 2>&1 || true

    local response
    response="$(es_api POST "_security/service/elastic/fleet-server/credential/token/fleet-server-local")"
    parse_response "$response"

    if [[ "$HTTP_CODE" =~ ^2 ]]; then
        local token_value
        token_value="$(echo "$HTTP_BODY" | jq -r '.token.value')"
        if [ -n "$token_value" ] && [ "$token_value" != "null" ]; then
            write_token "$FLEET_TOKENS_DIR/service-token" "$token_value"
            log "  OK   Service token created and written to $FLEET_TOKENS_DIR/service-token"
            ok=$((ok + 1))
            return 0
        fi
    fi

    warn "  FAIL Service token creation ($HTTP_CODE)"
    warn "       $HTTP_BODY"
    failed=$((failed + 1))
    return 1
}

# --- Step 2: Configure Fleet server hosts ----------------------------------

configure_fleet_server_hosts() {
    log ""
    log "--- Configuring Fleet server hosts ---"
    total=$((total + 1))

    local response
    response="$(kb_api PUT "/api/fleet/settings" \
        -d "{\"fleet_server_hosts\": [\"${FLEET_SERVER_HOST}\"]}")"
    parse_response "$response"

    if [[ "$HTTP_CODE" =~ ^2 ]]; then
        log "  OK   Fleet server hosts set to ${FLEET_SERVER_HOST} ($HTTP_CODE)"
        ok=$((ok + 1))
    else
        warn "  FAIL Fleet server hosts ($HTTP_CODE)"
        warn "       $HTTP_BODY"
        failed=$((failed + 1))
    fi
}

# --- Step 3: Configure Fleet default ES output -----------------------------

configure_fleet_output() {
    log ""
    log "--- Configuring Fleet Elasticsearch output ---"
    total=$((total + 1))

    # Get the default output ID
    local response
    response="$(kb_api GET "/api/fleet/outputs")"
    parse_response "$response"

    local default_output_id
    default_output_id="$(echo "$HTTP_BODY" | jq -r '.items[] | select(.is_default == true) | .id')"

    if [ -z "$default_output_id" ] || [ "$default_output_id" = "null" ]; then
        warn "  FAIL Could not find default Fleet output"
        failed=$((failed + 1))
        return
    fi

    response="$(kb_api PUT "/api/fleet/outputs/${default_output_id}" \
        -d "{\"hosts\": [\"${ES_URL}\"]}")"
    parse_response "$response"

    if [[ "$HTTP_CODE" =~ ^2 ]]; then
        log "  OK   Default output configured to ${ES_URL} ($HTTP_CODE)"
        ok=$((ok + 1))
    else
        warn "  FAIL Fleet output configuration ($HTTP_CODE)"
        warn "       $HTTP_BODY"
        failed=$((failed + 1))
    fi
}

# --- Step 4: Create Fleet Server policy ------------------------------------

create_fleet_server_policy() {
    log ""
    log "--- Creating Fleet Server policy ---"
    total=$((total + 1))

    # Check if fleet-server policy already exists
    local response
    response="$(kb_api GET "/api/fleet/agent_policies?kuery=is_default_fleet_server:true")"
    parse_response "$response"

    local existing_id
    existing_id="$(echo "$HTTP_BODY" | jq -r '.items[0].id // empty')"

    if [ -n "$existing_id" ]; then
        log "  OK   Fleet Server policy already exists (id=$existing_id)"
        ok=$((ok + 1))
        return
    fi

    # Create the Fleet Server policy with has_fleet_server flag
    response="$(kb_api POST "/api/fleet/agent_policies" \
        -d '{
            "name": "Fleet Server Policy",
            "namespace": "default",
            "is_default_fleet_server": true,
            "has_fleet_server": true,
            "monitoring_enabled": ["logs", "metrics"]
        }')"
    parse_response "$response"

    if [[ "$HTTP_CODE" =~ ^2 ]]; then
        local policy_id
        policy_id="$(echo "$HTTP_BODY" | jq -r '.item.id')"
        log "  OK   Fleet Server policy created (id=$policy_id) ($HTTP_CODE)"
        ok=$((ok + 1))

        # Add fleet_server integration to the policy
        total=$((total + 1))
        response="$(kb_api POST "/api/fleet/package_policies" \
            -d "{
                \"name\": \"fleet-server-1\",
                \"namespace\": \"default\",
                \"policy_id\": \"${policy_id}\",
                \"package\": {\"name\": \"fleet_server\", \"version\": \"\"},
                \"inputs\": [{
                    \"type\": \"fleet-server\",
                    \"enabled\": true,
                    \"streams\": [],
                    \"vars\": {
                        \"host\": {\"value\": \"0.0.0.0\", \"type\": \"text\"},
                        \"port\": {\"value\": 8220, \"type\": \"integer\"}
                    }
                }]
            }")"
        parse_response "$response"

        if [[ "$HTTP_CODE" =~ ^2 ]]; then
            log "  OK   Fleet Server integration added ($HTTP_CODE)"
            ok=$((ok + 1))
        else
            warn "  FAIL Fleet Server integration ($HTTP_CODE)"
            warn "       $HTTP_BODY"
            failed=$((failed + 1))
        fi
    else
        warn "  FAIL Fleet Server policy creation ($HTTP_CODE)"
        warn "       $HTTP_BODY"
        failed=$((failed + 1))
    fi
}

# --- Step 5: Create agent policy -------------------------------------------

create_agent_policy() {
    log ""
    log "--- Creating agent policy: ${FLEET_AGENT_POLICY_NAME} ---"
    total=$((total + 1))

    # Check if policy already exists
    local response
    response="$(kb_api GET "/api/fleet/agent_policies?kuery=name:${FLEET_AGENT_POLICY_NAME}")"
    parse_response "$response"

    local existing_id
    existing_id="$(echo "$HTTP_BODY" | jq -r '.items[0].id // empty')"

    if [ -n "$existing_id" ]; then
        log "  OK   Agent policy already exists (id=$existing_id)"
        ok=$((ok + 1))
        AGENT_POLICY_ID="$existing_id"
        return
    fi

    response="$(kb_api POST "/api/fleet/agent_policies" \
        -d "{
            \"name\": \"${FLEET_AGENT_POLICY_NAME}\",
            \"namespace\": \"default\",
            \"description\": \"Default agent policy for sandbox Elastic Agents\",
            \"monitoring_enabled\": [\"logs\", \"metrics\"]
        }")"
    parse_response "$response"

    if [[ "$HTTP_CODE" =~ ^2 ]]; then
        AGENT_POLICY_ID="$(echo "$HTTP_BODY" | jq -r '.item.id')"
        log "  OK   Agent policy created (id=$AGENT_POLICY_ID) ($HTTP_CODE)"
        ok=$((ok + 1))
    else
        warn "  FAIL Agent policy creation ($HTTP_CODE)"
        warn "       $HTTP_BODY"
        failed=$((failed + 1))
        AGENT_POLICY_ID=""
    fi
}

# --- Step 6: Get enrollment token ------------------------------------------

get_enrollment_token() {
    log ""
    log "--- Retrieving enrollment token ---"
    total=$((total + 1))

    if [ -z "${AGENT_POLICY_ID:-}" ]; then
        warn "  FAIL No agent policy ID — cannot retrieve enrollment token"
        failed=$((failed + 1))
        return 1
    fi

    local response
    response="$(kb_api GET "/api/fleet/enrollment-api-keys")"
    parse_response "$response"

    local token
    token="$(echo "$HTTP_BODY" | jq -r --arg pid "$AGENT_POLICY_ID" \
        '.items[] | select(.policy_id == $pid) | .api_key | select(. != null)' | head -1)"

    if [ -n "$token" ] && [ "$token" != "null" ]; then
        write_token "$FLEET_TOKENS_DIR/enrollment-token" "$token"
        log "  OK   Enrollment token written to $FLEET_TOKENS_DIR/enrollment-token"
        ok=$((ok + 1))
        return 0
    fi

    warn "  FAIL Could not find enrollment token for policy $AGENT_POLICY_ID"
    warn "       $HTTP_BODY"
    failed=$((failed + 1))
    return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

log "deploy-fleet.sh — setting up Fleet at $KB_URL"

wait_for_es
wait_for_kibana

create_service_token
configure_fleet_server_hosts
configure_fleet_output
create_fleet_server_policy
create_agent_policy
get_enrollment_token

# --- Summary ---------------------------------------------------------------
log ""
log "Done. total=$total  ok=$ok  failed=$failed"

if [ "$failed" -gt 0 ]; then
    exit 1
fi
