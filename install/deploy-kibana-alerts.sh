#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# deploy-kibana-alerts.sh — Deploy Kibana alerting rules from .alert files
#
# Scans definitions-local/kibana/alerts/*.alert and creates/updates rules
# in Kibana. Supports multiple rule types with connector lookup by name.
# ---------------------------------------------------------------------------

# --- Configuration (from environment, with defaults) -----------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALERTS_DIR="${ALERTS_DIR:-$SCRIPT_DIR/../definitions-local/kibana/alerts}"
KB_URL="${KB_URL:-http://localhost:5601}"
ELASTIC_USER="${ELASTIC_USER:-elastic}"
ELASTIC_PASSWORD="${ELASTIC_PASSWORD:-changeme}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-60}"
VERBOSE="${VERBOSE:-false}"

# Mattermost config for connector creation
MM_URL="${MM_URL:-http://localhost:8065}"
MM_INTERNAL_URL="${MM_INTERNAL_URL:-http://mattermost:8065}"  # Docker network URL for Kibana→MM
MM_ADMIN_USER="${MM_ADMIN_USER:-admin}"
MM_ADMIN_PASSWORD="${MM_ADMIN_PASSWORD:-Admin123!}"
MM_CONFIG="${MM_CONFIG:-$SCRIPT_DIR/../definitions-local/mattermost/users-and-teams.json}"
DEPLOY_CONNECTORS="${DEPLOY_CONNECTORS:-true}"

# --- Counters --------------------------------------------------------------
total=0
ok=0
failed=0
skipped=0

# --- Connector counters ----------------------------------------------------
conn_total=0
conn_ok=0
conn_failed=0
conn_skipped=0

# --- Connector cache -------------------------------------------------------
CONNECTORS_CACHE=""

# --- Mattermost state ------------------------------------------------------
MM_AUTH_TOKEN=""
MM_WEBHOOKS_CACHE=""

# --- Helpers ---------------------------------------------------------------

log()  { printf '%s\n' "$*" >&2; }
warn() { printf '%s\n' "$*" >&2; }
debug() { [ "$VERBOSE" = "true" ] && printf '  [DEBUG] %s\n' "$*" >&2 || true; }

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

# ---------------------------------------------------------------------------
# Mattermost integration functions (for connector creation)
# ---------------------------------------------------------------------------

# Check if Mattermost is reachable.
check_mattermost_available() {
    local response
    response="$(curl -sS "$MM_URL/api/v4/system/ping" 2>/dev/null)" || true
    if echo "$response" | grep -q '"status":"OK"'; then
        return 0
    fi
    return 1
}

# Authenticate with Mattermost and store session token.
authenticate_mattermost() {
    debug "Authenticating with Mattermost..."

    local response
    response="$(curl -sS \
        -X POST \
        -H "Content-Type: application/json" \
        -d "{
            \"login_id\": \"${MM_ADMIN_USER}\",
            \"password\": \"${MM_ADMIN_PASSWORD}\"
        }" \
        -D - \
        "$MM_URL/api/v4/users/login" 2>&1)" || true

    # Extract token from headers
    MM_AUTH_TOKEN="$(echo "$response" | grep -i '^token:' | awk '{print $2}' | tr -d '\r')"

    if [ -n "$MM_AUTH_TOKEN" ]; then
        debug "Mattermost authentication successful"
        return 0
    else
        warn "Mattermost authentication failed"
        return 1
    fi
}

# Make an authenticated Mattermost API call.
# Usage: mm_api <method> <endpoint>
mm_api() {
    local method="$1"
    local endpoint="$2"

    curl -sS \
        -X "$method" \
        -H "Authorization: Bearer $MM_AUTH_TOKEN" \
        -H "Content-Type: application/json" \
        "$MM_URL$endpoint" 2>/dev/null
}

# Fetch and cache all incoming webhooks from Mattermost.
fetch_mattermost_webhooks() {
    debug "Fetching Mattermost webhooks..."
    MM_WEBHOOKS_CACHE="$(mm_api GET "/api/v4/hooks/incoming")"
    local count
    count=$(echo "$MM_WEBHOOKS_CACHE" | jq 'length' 2>/dev/null || echo "0")
    debug "Found $count Mattermost webhooks"
}

# Get webhook URL for a team's elastic-alerts channel.
# Usage: get_webhook_url_for_team <team_name>
# Returns: webhook URL or empty string if not found
get_webhook_url_for_team() {
    local team_name="$1"

    # Get team ID
    local team_response team_id
    team_response="$(mm_api GET "/api/v4/teams/name/$team_name")"
    team_id="$(echo "$team_response" | jq -r '.id // empty' 2>/dev/null)"

    if [ -z "$team_id" ]; then
        debug "Team not found: $team_name"
        return 1
    fi

    # Get elastic-alerts channel ID
    local channel_response channel_id
    channel_response="$(mm_api GET "/api/v4/teams/$team_id/channels/name/elastic-alerts")"
    channel_id="$(echo "$channel_response" | jq -r '.id // empty' 2>/dev/null)"

    if [ -z "$channel_id" ]; then
        debug "Channel elastic-alerts not found for team: $team_name"
        return 1
    fi

    # Find webhook for this channel
    local webhook_id
    webhook_id="$(echo "$MM_WEBHOOKS_CACHE" | jq -r --arg cid "$channel_id" \
        '.[] | select(.channel_id == $cid) | .id' 2>/dev/null | head -1)"

    if [ -z "$webhook_id" ]; then
        debug "No webhook found for elastic-alerts channel in team: $team_name"
        return 1
    fi

    # Return the webhook URL using internal URL (for Kibana→Mattermost within Docker)
    echo "$MM_INTERNAL_URL/hooks/$webhook_id"
}

# Generate a deterministic UUID for a connector name.
# Usage: generate_connector_id <connector_name>
generate_connector_id() {
    uuidgen --sha1 --namespace @url --name "kibana-connector:$1"
}

# Create or update a Kibana webhook connector.
# Usage: create_webhook_connector <connector_name> <webhook_url>
create_webhook_connector() {
    local connector_name="$1"
    local webhook_url="$2"

    local connector_id
    connector_id="$(generate_connector_id "$connector_name")"

    conn_total=$((conn_total + 1))

    # Check if connector exists
    local check_response check_code
    check_response="$(curl -sS -w '\n%{http_code}' \
        -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
        -H "kbn-xsrf: true" \
        "$KB_URL/api/actions/connector/$connector_id" 2>&1)" || true
    check_code="$(echo "$check_response" | tail -n1)"

    # Build base config (shared between create and update)
    local base_config
    base_config=$(jq -n \
        --arg name "$connector_name" \
        --arg url "$webhook_url" \
        '{
            name: $name,
            config: {
                method: "post",
                url: $url,
                hasAuth: false,
                headers: {"Content-Type": "application/json"}
            },
            secrets: {}
        }')

    local response http_code body
    if [[ "$check_code" == "200" ]]; then
        # Connector exists - update with PUT (no connector_type_id allowed)
        response="$(curl -sS -w '\n%{http_code}' \
            -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
            -X PUT \
            -H "Content-Type: application/json" \
            -H "kbn-xsrf: true" \
            -d "$base_config" \
            "$KB_URL/api/actions/connector/$connector_id" 2>&1)" || true
    else
        # Connector doesn't exist - create with POST (include connector_type_id)
        local create_payload
        create_payload=$(echo "$base_config" | jq '. + {connector_type_id: ".webhook"}')
        response="$(curl -sS -w '\n%{http_code}' \
            -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
            -X POST \
            -H "Content-Type: application/json" \
            -H "kbn-xsrf: true" \
            -d "$create_payload" \
            "$KB_URL/api/actions/connector/$connector_id" 2>&1)" || true
    fi

    http_code="$(echo "$response" | tail -n1)"
    body="$(echo "$response" | sed '$d')"

    if [[ "$http_code" =~ ^2 ]]; then
        log "  OK   $connector_name ($connector_id) ($http_code)"
        conn_ok=$((conn_ok + 1))
    else
        warn "  FAIL $connector_name ($connector_id) ($http_code)"
        debug "$body"
        conn_failed=$((conn_failed + 1))
    fi
}

# Deploy webhook connectors for all teams defined in the Mattermost config.
deploy_webhook_connectors() {
    if [ "$DEPLOY_CONNECTORS" != "true" ]; then
        log "Connector deployment disabled (DEPLOY_CONNECTORS=$DEPLOY_CONNECTORS)"
        return 0
    fi

    # Check if Mattermost config exists
    if [ ! -f "$MM_CONFIG" ]; then
        log "Mattermost config not found ($MM_CONFIG), skipping connector deployment"
        return 0
    fi

    # Check if Mattermost is available
    if ! check_mattermost_available; then
        log "Mattermost not available at $MM_URL, skipping connector deployment"
        return 0
    fi

    # Authenticate with Mattermost
    if ! authenticate_mattermost; then
        warn "Failed to authenticate with Mattermost, skipping connector deployment"
        return 0
    fi

    # Fetch webhooks
    fetch_mattermost_webhooks

    log ""
    log "--- Deploying webhook connectors ---"

    # Iterate over teams in config
    local team_name display_name connector_name webhook_url
    for team_name in $(jq -r '.teams[].name' "$MM_CONFIG"); do
        display_name=$(jq -r --arg t "$team_name" '.teams[] | select(.name == $t) | .display_name' "$MM_CONFIG")
        connector_name="Mattermost - $display_name"

        # Get webhook URL for this team
        webhook_url="$(get_webhook_url_for_team "$team_name")" || {
            warn "  SKIP $connector_name: webhook not found for team $team_name"
            conn_skipped=$((conn_skipped + 1))
            continue
        }

        debug "Creating connector: $connector_name -> $webhook_url"
        create_webhook_connector "$connector_name" "$webhook_url"
    done

    log "Connectors: total=$conn_total  ok=$conn_ok  failed=$conn_failed  skipped=$conn_skipped"
}

# Generate a deterministic UUID v5 from a string (for Kibana rule IDs).
# Usage: generate_uuid <string>
generate_uuid() {
    uuidgen --sha1 --namespace @url --name "$1"
}

# Fetch and cache all connectors from Kibana.
# Called once at startup to avoid repeated API calls.
fetch_connectors() {
    log "Fetching Kibana connectors..."
    CONNECTORS_CACHE=$(curl -sS -u "$ELASTIC_USER:$ELASTIC_PASSWORD" \
        -H "kbn-xsrf: true" "$KB_URL/api/actions/connectors")
    local count
    count=$(echo "$CONNECTORS_CACHE" | jq 'length')
    log "Found $count connectors."
}

# Lookup connector ID by display name.
# Fast-fails if connector not found or if multiple connectors have the same name.
# Usage: get_connector_id_by_name <name>
# Returns: connector ID or empty string on error (with error message to stderr)
get_connector_id_by_name() {
    local name="$1"

    local matches
    matches=$(echo "$CONNECTORS_CACHE" | jq -r --arg n "$name" \
        '[.[] | select(.name == $n)] | length')

    if [ "$matches" -eq 0 ]; then
        warn "ERROR: Connector not found: $name"
        return 1
    elif [ "$matches" -gt 1 ]; then
        warn "ERROR: Multiple connectors named '$name' ($matches found) - name must be unique"
        return 1
    fi

    echo "$CONNECTORS_CACHE" | jq -r --arg n "$name" '.[] | select(.name == $n) | .id'
}

# ---------------------------------------------------------------------------
# Rule deployment functions (one per rule_type)
# ---------------------------------------------------------------------------

# Deploy an ES Query rule (.es-query)
# Usage: deploy_es_query_rule <file_path>
deploy_es_query_rule() {
    local file="$1"

    local key name enabled tags schedule_interval
    key=$(jq -r '.key' "$file")
    name=$(jq -r '.name' "$file")
    enabled=$(jq -r '.enabled // true' "$file")
    tags=$(jq -c '.tags // []' "$file")
    schedule_interval=$(jq -r '.schedule_interval // "1m"' "$file")

    # Extract params
    local index_pattern time_field time_window_size time_window_unit
    local threshold_comparator threshold_value size query
    index_pattern=$(jq -r '.params.index_pattern' "$file")
    time_field=$(jq -r '.params.time_field // "@timestamp"' "$file")
    time_window_size=$(jq -r '.params.time_window.size // 5' "$file")
    time_window_unit=$(jq -r '.params.time_window.unit // "m"' "$file")
    threshold_comparator=$(jq -r '.params.threshold.comparator // ">="' "$file")
    threshold_value=$(jq -r '.params.threshold.value // 1' "$file")
    size=$(jq -r '.params.size // 100' "$file")
    query=$(jq -c '.params.query' "$file")

    # Build actions array by resolving connector names to IDs
    local actions_json="[]"
    local action_count
    action_count=$(jq '.actions | length' "$file")

    for i in $(seq 0 $((action_count - 1))); do
        local connector_name group message connector_id
        connector_name=$(jq -r ".actions[$i].connector_name" "$file")
        group=$(jq -r ".actions[$i].group" "$file")
        message=$(jq -r ".actions[$i].message" "$file")

        # Lookup connector ID
        connector_id=$(get_connector_id_by_name "$connector_name") || {
            warn "  SKIP Rule $key: connector lookup failed for '$connector_name'"
            skipped=$((skipped + 1))
            return 0
        }

        # Build action object with Mattermost webhook format
        local action_obj
        action_obj=$(jq -n \
            --arg id "$connector_id" \
            --arg group "$group" \
            --arg message "$message" \
            '{
                id: $id,
                group: $group,
                params: {
                    body: ({text: $message} | tostring)
                },
                frequency: {
                    summary: false,
                    notify_when: "onActionGroupChange",
                    throttle: null
                }
            }')

        actions_json=$(echo "$actions_json" | jq --argjson a "$action_obj" '. + [$a]')
    done

    # Generate deterministic UUID from key
    local rule_id
    rule_id="$(generate_uuid "$key")"

    total=$((total + 1))

    # Check if rule exists
    local check_response check_code
    check_response="$(curl -sS -w '\n%{http_code}' \
        -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
        -H "kbn-xsrf: true" \
        "$KB_URL/api/alerting/rule/$rule_id" 2>&1)" || true
    check_code="$(echo "$check_response" | tail -n1)"

    # Build the base payload
    # esQuery expects a stringified JSON for the query
    local base_payload
    base_payload=$(jq -n \
        --arg name "$name" \
        --arg index "$index_pattern" \
        --arg esQuery "$query" \
        --arg timeField "$time_field" \
        --argjson timeWindowSize "$time_window_size" \
        --arg timeWindowUnit "$time_window_unit" \
        --arg thresholdComparator "$threshold_comparator" \
        --argjson thresholdValue "$threshold_value" \
        --argjson size "$size" \
        --argjson tags "$tags" \
        --arg scheduleInterval "$schedule_interval" \
        --argjson actions "$actions_json" \
        '{
            name: $name,
            schedule: {interval: $scheduleInterval},
            params: {
                searchType: "esQuery",
                index: [$index],
                esQuery: $esQuery,
                timeField: $timeField,
                timeWindowSize: $timeWindowSize,
                timeWindowUnit: $timeWindowUnit,
                threshold: [$thresholdValue],
                thresholdComparator: $thresholdComparator,
                size: $size
            },
            actions: $actions,
            tags: $tags
        }')

    local response http_code body
    if [[ "$check_code" == "200" ]]; then
        # Rule exists - update with PUT (no rule_type_id or consumer)
        response="$(curl -sS -w '\n%{http_code}' \
            -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
            -X PUT \
            -H "Content-Type: application/json" \
            -H "kbn-xsrf: true" \
            -d "$base_payload" \
            "$KB_URL/api/alerting/rule/$rule_id" 2>&1)" || true
    else
        # Rule doesn't exist - create with POST (include rule_type_id, consumer, enabled)
        local create_payload
        create_payload=$(echo "$base_payload" | jq --argjson enabled "$enabled" \
            '. + {rule_type_id: ".es-query", consumer: "alerts", enabled: $enabled}')
        response="$(curl -sS -w '\n%{http_code}' \
            -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
            -X POST \
            -H "Content-Type: application/json" \
            -H "kbn-xsrf: true" \
            -d "$create_payload" \
            "$KB_URL/api/alerting/rule/$rule_id" 2>&1)" || true
    fi

    http_code="$(echo "$response" | tail -n1)"
    body="$(echo "$response" | sed '$d')"

    if [[ "$http_code" =~ ^2 ]]; then
        log "  OK   $key ($rule_id) ($http_code)"
        ok=$((ok + 1))
    else
        warn "  FAIL $key ($rule_id) ($http_code)"
        debug "$body"
        failed=$((failed + 1))
    fi
}

# Deploy an Index Threshold rule (.index-threshold)
# Usage: deploy_index_threshold_rule <file_path>
deploy_index_threshold_rule() {
    local file="$1"

    local key name enabled tags schedule_interval
    key=$(jq -r '.key' "$file")
    name=$(jq -r '.name' "$file")
    enabled=$(jq -r '.enabled // true' "$file")
    tags=$(jq -c '.tags // []' "$file")
    schedule_interval=$(jq -r '.schedule_interval // "1m"' "$file")

    # Extract params
    local index time_field time_window_size time_window_unit
    local agg_type agg_field group_by term_field term_size
    local threshold_comparator threshold
    index=$(jq -c '.params.index' "$file")
    time_field=$(jq -r '.params.time_field // "@timestamp"' "$file")
    time_window_size=$(jq -r '.params.time_window_size // 5' "$file")
    time_window_unit=$(jq -r '.params.time_window_unit // "m"' "$file")
    agg_type=$(jq -r '.params.agg_type // "count"' "$file")
    agg_field=$(jq -r '.params.agg_field // null' "$file")
    group_by=$(jq -r '.params.group_by // "all"' "$file")
    term_field=$(jq -r '.params.term_field // null' "$file")
    term_size=$(jq -r '.params.term_size // 5' "$file")
    threshold_comparator=$(jq -r '.params.threshold_comparator // ">"' "$file")
    threshold=$(jq -c '.params.threshold // [1]' "$file")

    # Build actions array by resolving connector names to IDs
    local actions_json="[]"
    local action_count
    action_count=$(jq '.actions | length' "$file")

    for i in $(seq 0 $((action_count - 1))); do
        local connector_name group message connector_id
        connector_name=$(jq -r ".actions[$i].connector_name" "$file")
        group=$(jq -r ".actions[$i].group" "$file")
        message=$(jq -r ".actions[$i].message" "$file")

        # Lookup connector ID
        connector_id=$(get_connector_id_by_name "$connector_name") || {
            warn "  SKIP Rule $key: connector lookup failed for '$connector_name'"
            skipped=$((skipped + 1))
            return 0
        }

        # Build action object with Mattermost webhook format
        local action_obj
        action_obj=$(jq -n \
            --arg id "$connector_id" \
            --arg group "$group" \
            --arg message "$message" \
            '{
                id: $id,
                group: $group,
                params: {
                    body: ({text: $message} | tostring)
                },
                frequency: {
                    summary: false,
                    notify_when: "onActionGroupChange",
                    throttle: null
                }
            }')

        actions_json=$(echo "$actions_json" | jq --argjson a "$action_obj" '. + [$a]')
    done

    # Generate deterministic UUID from key
    local rule_id
    rule_id="$(generate_uuid "$key")"

    total=$((total + 1))

    # Check if rule exists
    local check_response check_code
    check_response="$(curl -sS -w '\n%{http_code}' \
        -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
        -H "kbn-xsrf: true" \
        "$KB_URL/api/alerting/rule/$rule_id" 2>&1)" || true
    check_code="$(echo "$check_response" | tail -n1)"

    # Build the base payload
    local base_payload
    base_payload=$(jq -n \
        --arg name "$name" \
        --argjson index "$index" \
        --arg timeField "$time_field" \
        --argjson timeWindowSize "$time_window_size" \
        --arg timeWindowUnit "$time_window_unit" \
        --arg aggType "$agg_type" \
        --arg aggField "$agg_field" \
        --arg groupBy "$group_by" \
        --arg termField "$term_field" \
        --argjson termSize "$term_size" \
        --arg thresholdComparator "$threshold_comparator" \
        --argjson threshold "$threshold" \
        --argjson tags "$tags" \
        --arg scheduleInterval "$schedule_interval" \
        --argjson actions "$actions_json" \
        '{
            name: $name,
            schedule: {interval: $scheduleInterval},
            params: {
                index: $index,
                timeField: $timeField,
                timeWindowSize: $timeWindowSize,
                timeWindowUnit: $timeWindowUnit,
                aggType: $aggType,
                groupBy: $groupBy,
                thresholdComparator: $thresholdComparator,
                threshold: $threshold
            },
            actions: $actions,
            tags: $tags
        }')

    # Add optional fields if present
    if [ "$agg_field" != "null" ]; then
        base_payload=$(echo "$base_payload" | jq --arg f "$agg_field" '.params.aggField = $f')
    fi
    if [ "$term_field" != "null" ]; then
        base_payload=$(echo "$base_payload" | jq --arg f "$term_field" '.params.termField = $f')
        base_payload=$(echo "$base_payload" | jq --argjson s "$term_size" '.params.termSize = $s')
    fi

    local response http_code body
    if [[ "$check_code" == "200" ]]; then
        # Rule exists - update with PUT
        response="$(curl -sS -w '\n%{http_code}' \
            -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
            -X PUT \
            -H "Content-Type: application/json" \
            -H "kbn-xsrf: true" \
            -d "$base_payload" \
            "$KB_URL/api/alerting/rule/$rule_id" 2>&1)" || true
    else
        # Rule doesn't exist - create with POST
        local create_payload
        create_payload=$(echo "$base_payload" | jq --argjson enabled "$enabled" \
            '. + {rule_type_id: ".index-threshold", consumer: "alerts", enabled: $enabled}')
        response="$(curl -sS -w '\n%{http_code}' \
            -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
            -X POST \
            -H "Content-Type: application/json" \
            -H "kbn-xsrf: true" \
            -d "$create_payload" \
            "$KB_URL/api/alerting/rule/$rule_id" 2>&1)" || true
    fi

    http_code="$(echo "$response" | tail -n1)"
    body="$(echo "$response" | sed '$d')"

    if [[ "$http_code" =~ ^2 ]]; then
        log "  OK   $key ($rule_id) ($http_code)"
        ok=$((ok + 1))
    else
        warn "  FAIL $key ($rule_id) ($http_code)"
        debug "$body"
        failed=$((failed + 1))
    fi
}

# Dispatch rule deployment based on rule_type field
# Usage: deploy_rule <file_path>
deploy_rule() {
    local file="$1"
    local rule_type
    rule_type=$(jq -r '.rule_type' "$file")

    case "$rule_type" in
        es-query)
            deploy_es_query_rule "$file"
            ;;
        index-threshold)
            deploy_index_threshold_rule "$file"
            ;;
        *)
            warn "  SKIP Unknown rule type: $rule_type in $(basename "$file")"
            skipped=$((skipped + 1))
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

log "deploy-kibana-alerts.sh — deploying Kibana alerting rules"

# Check alerts directory exists
if [ ! -d "$ALERTS_DIR" ]; then
    warn "ERROR: Alerts directory not found: $ALERTS_DIR"
    exit 1
fi

# Find .alert files
alert_files=("$ALERTS_DIR"/*.alert)
if [ ! -e "${alert_files[0]}" ]; then
    log "No .alert files found in $ALERTS_DIR"
    exit 0
fi

log "Found ${#alert_files[@]} alert file(s) in $ALERTS_DIR"

# Wait for Kibana
wait_for_kibana

# Deploy webhook connectors (queries Mattermost, creates Kibana connectors)
deploy_webhook_connectors

# Fetch connectors once (now includes newly created connectors)
fetch_connectors

# Deploy each alert
log ""
log "--- Deploying alerting rules ---"
for file in "${alert_files[@]}"; do
    debug "Processing $(basename "$file")"

    # Validate JSON
    if ! jq empty "$file" 2>/dev/null; then
        warn "  SKIP Invalid JSON: $(basename "$file")"
        skipped=$((skipped + 1))
        continue
    fi

    deploy_rule "$file"
done

# --- Summary ---------------------------------------------------------------
log ""
log "=== Summary ==="
log "  total=$total  ok=$ok  failed=$failed  skipped=$skipped"

if [ "$failed" -gt 0 ]; then
    exit 1
fi
