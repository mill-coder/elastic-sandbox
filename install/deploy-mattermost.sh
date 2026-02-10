#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# deploy-mattermost.sh — Configure Mattermost users, teams, channels,
# and incoming webhooks.
# ---------------------------------------------------------------------------

# --- Configuration (from environment, with defaults) -----------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MM_URL="${MM_URL:-http://localhost:8065}"
MM_ADMIN_USER="${MM_ADMIN_USER:-admin}"
MM_ADMIN_PASSWORD="${MM_ADMIN_PASSWORD:-Admin123!}"
MM_ADMIN_EMAIL="${MM_ADMIN_EMAIL:-admin@example.com}"
MM_DEFAULT_USER_PASSWORD="${MM_DEFAULT_USER_PASSWORD:-password}"
MM_CONFIG="${MM_CONFIG:-$SCRIPT_DIR/../definitions-local/mattermost/users-and-teams.json}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-60}"
VERBOSE="${VERBOSE:-false}"

# --- Counters --------------------------------------------------------------
total=0
ok=0
failed=0

# --- State -----------------------------------------------------------------
AUTH_TOKEN=""

# --- Helpers ---------------------------------------------------------------

log()  { printf '%s\n' "$*" >&2; }
warn() { printf '%s\n' "$*" >&2; }
debug() { [ "$VERBOSE" = "true" ] && printf '  [DEBUG] %s\n' "$*" >&2 || true; }

# Load and validate configuration file.
load_config() {
    if [ ! -f "$MM_CONFIG" ]; then
        warn "ERROR: Config file not found: $MM_CONFIG"
        return 1
    fi
    if ! jq empty "$MM_CONFIG" 2>/dev/null; then
        warn "ERROR: Invalid JSON in $MM_CONFIG"
        return 1
    fi
    log "Loaded config from $MM_CONFIG"
}

# Wait for Mattermost to become healthy.
wait_for_mattermost() {
    local attempt=1
    log "Waiting for Mattermost ($MM_URL) ..."
    while [ "$attempt" -le "$WAIT_TIMEOUT" ]; do
        local response
        response="$(curl -sS "$MM_URL/api/v4/system/ping" 2>/dev/null)" || true
        if echo "$response" | grep -q '"status":"OK"'; then
            log "Mattermost is ready."
            return 0
        fi
        sleep 2
        attempt=$((attempt + 1))
    done
    warn "ERROR: Mattermost did not become ready after $((WAIT_TIMEOUT * 2))s."
    return 1
}

# Create the admin user (first user on a fresh instance).
create_admin_user() {
    log ""
    log "--- Creating admin user ---"
    total=$((total + 1))

    local response http_code
    response="$(curl -sS -w '\n%{http_code}' \
        -X POST \
        -H "Content-Type: application/json" \
        -d "{
            \"email\": \"${MM_ADMIN_EMAIL}\",
            \"username\": \"${MM_ADMIN_USER}\",
            \"password\": \"${MM_ADMIN_PASSWORD}\"
        }" \
        "$MM_URL/api/v4/users" 2>&1)" || true

    http_code="$(echo "$response" | tail -n1)"
    local body
    body="$(echo "$response" | sed '$d')"

    if [[ "$http_code" =~ ^2 ]]; then
        log "  OK   Admin user created ($http_code)"
        ok=$((ok + 1))
    elif echo "$body" | grep -q "already exists"; then
        log "  OK   Admin user already exists ($http_code)"
        ok=$((ok + 1))
    else
        warn "  FAIL Admin user creation ($http_code)"
        debug "$body"
        failed=$((failed + 1))
    fi
}

# Authenticate and get a session token.
authenticate() {
    log ""
    log "--- Authenticating ---"

    local response http_code
    response="$(curl -sS -w '\n%{http_code}' \
        -X POST \
        -H "Content-Type: application/json" \
        -d "{
            \"login_id\": \"${MM_ADMIN_USER}\",
            \"password\": \"${MM_ADMIN_PASSWORD}\"
        }" \
        -D - \
        "$MM_URL/api/v4/users/login" 2>&1)" || true

    # Extract token from headers
    AUTH_TOKEN="$(echo "$response" | grep -i '^token:' | awk '{print $2}' | tr -d '\r')"

    if [ -n "$AUTH_TOKEN" ]; then
        log "  OK   Authentication successful"
    else
        warn "  FAIL Authentication failed"
        debug "$response"
        return 1
    fi
}

# Make an authenticated API call.
# Usage: mm_api <method> <endpoint> [body]
mm_api() {
    local method="$1"
    local endpoint="$2"
    local body="${3:-}"

    local curl_args=(
        -sS
        -w '\n%{http_code}'
        -X "$method"
        -H "Authorization: Bearer $AUTH_TOKEN"
        -H "Content-Type: application/json"
    )

    if [ -n "$body" ]; then
        curl_args+=(-d "$body")
    fi

    curl "${curl_args[@]}" "$MM_URL$endpoint" 2>&1
}

# Create a user.
# Usage: create_user <username> <email> <password> <first_name> <last_name>
create_user() {
    local username="$1"
    local email="$2"
    local password="$3"
    local first_name="$4"
    local last_name="$5"

    total=$((total + 1))

    local response http_code body
    response="$(mm_api POST /api/v4/users "{
        \"email\": \"$email\",
        \"username\": \"$username\",
        \"password\": \"$password\",
        \"first_name\": \"$first_name\",
        \"last_name\": \"$last_name\"
    }")"

    http_code="$(echo "$response" | tail -n1)"
    body="$(echo "$response" | sed '$d')"

    if [[ "$http_code" =~ ^2 ]]; then
        log "  OK   User $username ($http_code)"
        ok=$((ok + 1))
        # Return user ID
        echo "$body" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4
    elif echo "$body" | grep -q "already exists"; then
        log "  OK   User $username already exists ($http_code)"
        ok=$((ok + 1))
        # Get existing user ID
        get_user_id "$username"
    else
        warn "  FAIL User $username ($http_code)"
        debug "$body"
        failed=$((failed + 1))
    fi
}

# Get user ID by username.
get_user_id() {
    local username="$1"
    local response
    response="$(mm_api GET "/api/v4/users/username/$username")"
    echo "$response" | sed '$d' | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4
}

# Create a team.
# Usage: create_team <name> <display_name> <type>
create_team() {
    local name="$1"
    local display_name="$2"
    local type="$3"

    total=$((total + 1))

    local response http_code body
    response="$(mm_api POST /api/v4/teams "{
        \"name\": \"$name\",
        \"display_name\": \"$display_name\",
        \"type\": \"$type\"
    }")"

    http_code="$(echo "$response" | tail -n1)"
    body="$(echo "$response" | sed '$d')"

    if [[ "$http_code" =~ ^2 ]]; then
        log "  OK   Team $name ($http_code)"
        ok=$((ok + 1))
        echo "$body" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4
    elif echo "$body" | grep -q "already exists"; then
        log "  OK   Team $name already exists ($http_code)"
        ok=$((ok + 1))
        get_team_id "$name"
    else
        warn "  FAIL Team $name ($http_code)"
        debug "$body"
        failed=$((failed + 1))
    fi
}

# Get team ID by name.
get_team_id() {
    local name="$1"
    local response
    response="$(mm_api GET "/api/v4/teams/name/$name")"
    echo "$response" | sed '$d' | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4
}

# Create a channel.
# Usage: create_channel <team_id> <name> <display_name> <type>
create_channel() {
    local team_id="$1"
    local name="$2"
    local display_name="$3"
    local type="$4"

    total=$((total + 1))

    local response http_code body
    response="$(mm_api POST /api/v4/channels "{
        \"team_id\": \"$team_id\",
        \"name\": \"$name\",
        \"display_name\": \"$display_name\",
        \"type\": \"$type\"
    }")"

    http_code="$(echo "$response" | tail -n1)"
    body="$(echo "$response" | sed '$d')"

    if [[ "$http_code" =~ ^2 ]]; then
        log "  OK   Channel $name ($http_code)"
        ok=$((ok + 1))
        echo "$body" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4
    elif echo "$body" | grep -q "already exists"; then
        log "  OK   Channel $name already exists ($http_code)"
        ok=$((ok + 1))
        get_channel_id "$team_id" "$name"
    else
        warn "  FAIL Channel $name ($http_code)"
        debug "$body"
        failed=$((failed + 1))
    fi
}

# Get channel ID by team and name.
get_channel_id() {
    local team_id="$1"
    local name="$2"
    local response
    response="$(mm_api GET "/api/v4/teams/$team_id/channels/name/$name")"
    echo "$response" | sed '$d' | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4
}

# Get existing webhook ID for a channel (if any).
# Usage: get_webhook_for_channel <channel_id>
get_webhook_for_channel() {
    local channel_id="$1"
    local response body
    response="$(mm_api GET "/api/v4/hooks/incoming")"
    body="$(echo "$response" | sed '$d')"
    # Filter by channel_id and return first matching webhook ID
    echo "$body" | jq -r --arg cid "$channel_id" '.[] | select(.channel_id == $cid) | .id' 2>/dev/null | head -1
}

# Create an incoming webhook (idempotent - reuses existing webhook for channel).
# Usage: create_webhook <channel_id> <display_name> <description>
create_webhook() {
    local channel_id="$1"
    local display_name="$2"
    local description="$3"

    total=$((total + 1))

    # Check for existing webhook on this channel
    local existing_id
    existing_id="$(get_webhook_for_channel "$channel_id")"
    if [ -n "$existing_id" ]; then
        log "  OK   Webhook $display_name already exists -> $MM_URL/hooks/$existing_id"
        ok=$((ok + 1))
        echo "$existing_id"
        return
    fi

    local response http_code body
    response="$(mm_api POST /api/v4/hooks/incoming "{
        \"channel_id\": \"$channel_id\",
        \"display_name\": \"$display_name\",
        \"description\": \"$description\"
    }")"

    http_code="$(echo "$response" | tail -n1)"
    body="$(echo "$response" | sed '$d')"

    if [[ "$http_code" =~ ^2 ]]; then
        local webhook_id
        webhook_id="$(echo "$body" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)"
        log "  OK   Webhook $display_name created ($http_code) -> $MM_URL/hooks/$webhook_id"
        ok=$((ok + 1))
        echo "$webhook_id"
    else
        warn "  FAIL Webhook $display_name ($http_code)"
        debug "$body"
        failed=$((failed + 1))
    fi
}

# Add user to team.
# Usage: add_user_to_team <team_id> <user_id>
add_user_to_team() {
    local team_id="$1"
    local user_id="$2"

    local response http_code body
    response="$(mm_api POST "/api/v4/teams/$team_id/members" "{
        \"team_id\": \"$team_id\",
        \"user_id\": \"$user_id\"
    }")"

    http_code="$(echo "$response" | tail -n1)"
    body="$(echo "$response" | sed '$d')"

    if [[ "$http_code" =~ ^2 ]] || echo "$body" | grep -q "already"; then
        debug "Added user $user_id to team $team_id"
    else
        debug "Failed to add user $user_id to team $team_id: $body"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

log "deploy-mattermost.sh — configuring Mattermost at $MM_URL"

# Load configuration
load_config

# Wait for Mattermost to be ready
wait_for_mattermost

# Create admin user (first user on fresh instance)
create_admin_user

# Authenticate
authenticate

# --- Create users ---
log ""
log "--- Creating users ---"

declare -A USER_IDS

for user in $(jq -r '.users[].username' "$MM_CONFIG"); do
    email=$(jq -r --arg u "$user" '.users[] | select(.username == $u) | .email' "$MM_CONFIG")
    first_name=$(jq -r --arg u "$user" '.users[] | select(.username == $u) | .first_name' "$MM_CONFIG")
    last_name=$(jq -r --arg u "$user" '.users[] | select(.username == $u) | .last_name' "$MM_CONFIG")
    USER_IDS[$user]="$(create_user "$user" "$email" "$MM_DEFAULT_USER_PASSWORD" "$first_name" "$last_name")"
done

# --- Create teams ---
log ""
log "--- Creating teams ---"

declare -A TEAM_IDS

for team in $(jq -r '.teams[].name' "$MM_CONFIG"); do
    display_name=$(jq -r --arg t "$team" '.teams[] | select(.name == $t) | .display_name' "$MM_CONFIG")
    team_type=$(jq -r --arg t "$team" '.teams[] | select(.name == $t) | .type' "$MM_CONFIG")
    TEAM_IDS[$team]="$(create_team "$team" "$display_name" "$team_type")"
done

# --- Create channels and webhooks ---
log ""
log "--- Creating channels and webhooks ---"

declare -A WEBHOOK_IDS

for team in $(jq -r '.teams[].name' "$MM_CONFIG"); do
    team_id="${TEAM_IDS[$team]:-}"
    if [ -z "$team_id" ]; then
        warn "Skipping channels for team $team (no team ID)"
        continue
    fi

    # Get channels for this team
    for channel in $(jq -r --arg t "$team" '.teams[] | select(.name == $t) | .channels[]' "$MM_CONFIG"); do
        # Convert channel name to display name (capitalize, replace hyphens with spaces)
        display_name="$(echo "$channel" | sed 's/-/ /g' | sed 's/\b\(.\)/\u\1/g')"

        channel_id="$(create_channel "$team_id" "$channel" "$display_name" "O")"

        # Create webhook for elastic-alerts channel
        if [ "$channel" = "elastic-alerts" ] && [ -n "$channel_id" ]; then
            WEBHOOK_IDS[$team]="$(create_webhook "$channel_id" "Elastic Alerts" "Incoming webhook for Elastic Watcher alerts")"
        fi
    done
done

# --- Add users to teams ---
log ""
log "--- Adding users to teams ---"

for team in $(jq -r '.teams[].name' "$MM_CONFIG"); do
    team_id="${TEAM_IDS[$team]:-}"
    if [ -z "$team_id" ]; then
        continue
    fi

    for user in $(jq -r --arg t "$team" '.teams[] | select(.name == $t) | .members[]' "$MM_CONFIG"); do
        user_id="${USER_IDS[$user]:-}"
        if [ -n "$user_id" ]; then
            add_user_to_team "$team_id" "$user_id"
        fi
    done
done

log "  OK   Users added to teams"

# --- Summary ---------------------------------------------------------------
log ""
log "=== Webhook URLs ==="
for team in $(jq -r '.teams[].name' "$MM_CONFIG"); do
    webhook_id="${WEBHOOK_IDS[$team]:-}"
    if [ -n "$webhook_id" ]; then
        log "  $team: $MM_URL/hooks/$webhook_id"
    fi
done

log ""
log "Done. total=$total  ok=$ok  failed=$failed"

if [ "$failed" -gt 0 ]; then
    exit 1
fi
