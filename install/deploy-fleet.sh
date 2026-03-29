#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# deploy-fleet.sh — Set up Fleet Server, agent policies, and monitors.
#
# Data-driven: iterates over .policy files to create agent policies and
# over .monitor files to create Synthetics lightweight monitors.
# Tokens are written to a shared volume for fleet-server and elastic-agent
# containers to consume.
# ---------------------------------------------------------------------------

# --- Configuration (from environment, with defaults) -----------------------
ES_URL="${ES_URL:-http://elasticsearch:9200}"
KB_URL="${KB_URL:-http://kibana:5601}"
ELASTIC_USER="${ELASTIC_USER:-elastic}"
ELASTIC_PASSWORD="${ELASTIC_PASSWORD:-changeme}"
FLEET_TOKENS_DIR="${FLEET_TOKENS_DIR:-/fleet-tokens}"
FLEET_SERVER_HOST="${FLEET_SERVER_HOST:-http://fleet-server:8220}"
FLEET_POLICIES_DIR="${FLEET_POLICIES_DIR:-/definitions/fleet/agent-policies}"
FLEET_MONITORS_LOCAL_DIR="${FLEET_MONITORS_LOCAL_DIR:-/definitions-local/monitors}"
DEPLOY_SAMPLE_USERS="${DEPLOY_SAMPLE_USERS:-false}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-120}"

# --- Counters --------------------------------------------------------------
total=0
ok=0
failed=0

# --- State -----------------------------------------------------------------
declare -A POLICY_IDS

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

parse_response() {
    local response="$1"
    HTTP_CODE="$(echo "$response" | tail -n1)"
    HTTP_BODY="$(echo "$response" | sed '$d')"
}

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
    elif [[ "$HTTP_CODE" == "409" ]]; then
        log "  OK   Fleet Server policy already exists ($HTTP_CODE)"
        ok=$((ok + 1))
    else
        warn "  FAIL Fleet Server policy creation ($HTTP_CODE)"
        warn "       $HTTP_BODY"
        failed=$((failed + 1))
    fi
}

# --- Step 5: Create agent policies from .policy files ----------------------

create_agent_policies() {
    log ""
    log "--- Creating agent policies ---"

    if [ ! -d "$FLEET_POLICIES_DIR" ]; then
        log "  No policy directory found at $FLEET_POLICIES_DIR — skipping"
        return
    fi

    local count
    count=$(find "$FLEET_POLICIES_DIR" -maxdepth 1 -name '*.policy' 2>/dev/null | wc -l)
    if [ "$count" -eq 0 ]; then
        log "  No .policy files found — skipping"
        return
    fi

    for policy_file in "$FLEET_POLICIES_DIR"/*.policy; do
        local policy_name
        policy_name="$(jq -r '.name' "$policy_file")"
        total=$((total + 1))

        # Check if policy already exists
        local response
        response="$(kb_api GET "/api/fleet/agent_policies?kuery=name:${policy_name}")"
        parse_response "$response"

        local existing_id
        existing_id="$(echo "$HTTP_BODY" | jq -r '.items[0].id // empty')"

        if [ -n "$existing_id" ]; then
            log "  OK   Policy $policy_name already exists (id=$existing_id)"
            ok=$((ok + 1))
            POLICY_IDS[$policy_name]="$existing_id"
        else
            # Create the policy using the file's JSON content
            response="$(kb_api POST "/api/fleet/agent_policies" -d "@${policy_file}")"
            parse_response "$response"

            if [[ "$HTTP_CODE" =~ ^2 ]]; then
                local policy_id
                policy_id="$(echo "$HTTP_BODY" | jq -r '.item.id')"
                log "  OK   Policy $policy_name created (id=$policy_id) ($HTTP_CODE)"
                ok=$((ok + 1))
                POLICY_IDS[$policy_name]="$policy_id"
            elif [[ "$HTTP_CODE" == "409" ]]; then
                # Policy exists but kuery didn't find it — extract ID from error message
                local conflict_id
                conflict_id="$(echo "$HTTP_BODY" | jq -r '.message' | grep -oP "Agent Policy '\K[^']+")" || true
                log "  OK   Policy $policy_name already exists ($HTTP_CODE)"
                ok=$((ok + 1))
                if [ -n "$conflict_id" ]; then
                    POLICY_IDS[$policy_name]="$conflict_id"
                fi
            else
                warn "  FAIL Policy $policy_name ($HTTP_CODE)"
                warn "       $HTTP_BODY"
                failed=$((failed + 1))
                continue
            fi
        fi

        # Get enrollment token for this policy
        total=$((total + 1))
        local pid="${POLICY_IDS[$policy_name]}"
        response="$(kb_api GET "/api/fleet/enrollment-api-keys")"
        parse_response "$response"

        local token
        token="$(echo "$HTTP_BODY" | jq -r --arg pid "$pid" \
            '.items[] | select(.policy_id == $pid) | .api_key | select(. != null)' | head -1)"

        if [ -n "$token" ] && [ "$token" != "null" ]; then
            write_token "$FLEET_TOKENS_DIR/enrollment-token-${policy_name}" "$token"
            log "  OK   Enrollment token for $policy_name written"
            ok=$((ok + 1))
        else
            warn "  FAIL Could not find enrollment token for policy $policy_name (id=$pid)"
            failed=$((failed + 1))
        fi
    done
}

# --- Step 6: Create Private Locations for each policy ----------------------

create_private_locations() {
    log ""
    log "--- Creating Private Locations ---"

    if [ ${#POLICY_IDS[@]} -eq 0 ]; then
        log "  No agent policies — skipping"
        return
    fi

    # Get existing Private Locations
    local response
    response="$(kb_api GET "/api/synthetics/private_locations")"
    parse_response "$response"
    local existing_locations="$HTTP_BODY"

    for policy_name in "${!POLICY_IDS[@]}"; do
        total=$((total + 1))
        local policy_id="${POLICY_IDS[$policy_name]}"

        # Check if Private Location with this label already exists
        local existing_id
        existing_id="$(echo "$existing_locations" | jq -r --arg label "$policy_name" \
            '.[] | select(.label == $label) | .id // empty' 2>/dev/null)" || true

        if [ -n "$existing_id" ]; then
            log "  OK   Private Location $policy_name already exists"
            ok=$((ok + 1))
            continue
        fi

        response="$(kb_api POST "/api/synthetics/private_locations" \
            -d "{\"label\": \"${policy_name}\", \"agentPolicyId\": \"${policy_id}\"}")"
        parse_response "$response"

        if [[ "$HTTP_CODE" =~ ^2 ]]; then
            log "  OK   Private Location $policy_name created ($HTTP_CODE)"
            ok=$((ok + 1))
        else
            warn "  FAIL Private Location $policy_name ($HTTP_CODE)"
            warn "       $HTTP_BODY"
            failed=$((failed + 1))
        fi
    done
}

# --- Step 7: Deploy monitors from .monitor files ---------------------------

deploy_monitors() {
    local monitors_dir="$1"
    local label="${2:-monitors}"

    log ""
    log "--- Deploying $label ($monitors_dir) ---"

    if [ ! -d "$monitors_dir" ]; then
        log "  No monitor directory found — skipping"
        return
    fi

    local count
    count=$(find "$monitors_dir" -maxdepth 1 -name '*.monitor' 2>/dev/null | wc -l)
    if [ "$count" -eq 0 ]; then
        log "  No .monitor files found — skipping"
        return
    fi

    for monitor_file in "$monitors_dir"/*.monitor; do
        local monitor_name monitor_space
        monitor_name="$(jq -r '.name' "$monitor_file")"
        monitor_space="$(jq -r '.space // empty' "$monitor_file")"
        total=$((total + 1))

        # Build space-prefixed API path
        local api_path="/api/synthetics/monitors"
        if [ -n "$monitor_space" ]; then
            api_path="/s/${monitor_space}/api/synthetics/monitors"
        fi

        # Check if monitor already exists by name in the target space
        local response
        response="$(kb_api GET "${api_path}?perPage=1000")"
        parse_response "$response"

        local existing_id
        existing_id="$(echo "$HTTP_BODY" | jq -r --arg name "$monitor_name" \
            '.monitors[] | select(.name == $name) | .id // empty' 2>/dev/null)" || true

        if [ -n "$existing_id" ]; then
            log "  OK   Monitor $monitor_name already exists${monitor_space:+ (space=$monitor_space)}"
            ok=$((ok + 1))
            continue
        fi

        # Read monitor definition
        local monitor_type monitor_urls monitor_schedule monitor_policy monitor_tags monitor_labels
        monitor_type="$(jq -r '.type' "$monitor_file")"
        monitor_urls="$(jq -r '.urls' "$monitor_file")"
        monitor_schedule="$(jq -c '.schedule' "$monitor_file")"
        monitor_policy="$(jq -r '.policy' "$monitor_file")"
        monitor_tags="$(jq -c '.tags' "$monitor_file")"
        monitor_labels="$(jq -c '.labels // {}' "$monitor_file")"

        # Build the API payload (space is NOT part of the payload — it's in the URL)
        local payload
        payload="$(jq -n \
            --arg type "$monitor_type" \
            --arg name "$monitor_name" \
            --arg urls "$monitor_urls" \
            --argjson schedule "$monitor_schedule" \
            --arg policy "$monitor_policy" \
            --argjson tags "$monitor_tags" \
            --argjson labels "$monitor_labels" \
            '{
                type: $type,
                name: $name,
                urls: $urls,
                schedule: $schedule,
                locations: [],
                private_locations: [$policy],
                tags: $tags,
                labels: $labels
            }')"

        response="$(kb_api POST "$api_path" -d "$payload")"
        parse_response "$response"

        if [[ "$HTTP_CODE" =~ ^2 ]]; then
            log "  OK   Monitor $monitor_name ($HTTP_CODE)${monitor_space:+ [space=$monitor_space]}"
            ok=$((ok + 1))
        else
            warn "  FAIL Monitor $monitor_name ($HTTP_CODE)"
            warn "       $HTTP_BODY"
            failed=$((failed + 1))
        fi
    done
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
create_agent_policies
create_private_locations

# Deploy monitors
if [ "$DEPLOY_SAMPLE_USERS" = "true" ]; then
    deploy_monitors "$FLEET_MONITORS_LOCAL_DIR" "local monitors"
fi

# --- Summary ---------------------------------------------------------------
log ""
log "Done. total=$total  ok=$ok  failed=$failed"

if [ "$failed" -gt 0 ]; then
    exit 1
fi
