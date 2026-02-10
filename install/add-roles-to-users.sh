#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# add-roles-to-users.sh — Merge additional roles into existing ES users.
#
# Reads *.roles files from a directory. Each file:
#   Filename (without extension) = username
#   Content  = one role name per line (blank lines and #-comments ignored)
#
# For each file the script GETs the user's current roles, merges the new
# roles (deduplicated), and PUTs the updated roles array back.
# ---------------------------------------------------------------------------

ROLES_DIR="${1:?Usage: add-roles-to-users.sh <roles-directory>}"

ES_URL="${ES_URL:-http://localhost:9200}"
ELASTIC_USER="${ELASTIC_USER:-elastic}"
ELASTIC_PASSWORD="${ELASTIC_PASSWORD:?ELASTIC_PASSWORD must be set}"
VERBOSE="${VERBOSE:-false}"

total=0
ok=0
skipped=0
failed=0

log()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

log "add-roles-to-users.sh — dir=$ROLES_DIR  ES=$ES_URL"
log ""
log "--- Role assignments ---"

for roles_file in "$ROLES_DIR"/*.roles; do
    [ -e "$roles_file" ] || continue

    username="$(basename "$roles_file" .roles)"
    total=$((total + 1))

    # Read desired roles (skip blanks and comments)
    new_roles=()
    while IFS= read -r line; do
        line="$(echo "$line" | tr -d '\r')"
        [[ -z "$line" || "$line" == \#* ]] && continue
        new_roles+=("$line")
    done < "$roles_file"

    if [ ${#new_roles[@]} -eq 0 ]; then
        log "  SKIP $username (no roles in file)"
        skipped=$((skipped + 1))
        continue
    fi

    # GET current user
    curl_out="$(curl -sS -w '\n%{http_code}' \
        -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
        "${ES_URL}/_security/user/${username}" 2>&1)" || true

    http_code="$(echo "$curl_out" | tail -n1)"
    response_body="$(echo "$curl_out" | sed '$d')"

    if ! [[ "$http_code" =~ ^2 ]]; then
        warn "  FAIL $username — cannot fetch user ($http_code)"
        if [ "$VERBOSE" = "true" ]; then
            warn "       $response_body"
        fi
        failed=$((failed + 1))
        continue
    fi

    # Extract current roles as JSON array
    current_roles_json="$(echo "$response_body" | jq -r --arg u "$username" '.[$u].roles // []')"

    # Merge: combine current roles + new roles, deduplicate
    merged_roles_json="$(jq -n \
        --argjson current "$current_roles_json" \
        --argjson new "$(printf '%s\n' "${new_roles[@]}" | jq -R . | jq -s .)" \
        '$current + $new | unique')"

    # Skip if nothing changed
    if [ "$(echo "$current_roles_json" | jq -S .)" = "$(echo "$merged_roles_json" | jq -S .)" ]; then
        log "  OK   $username (roles already present)"
        ok=$((ok + 1))
        continue
    fi

    # PUT updated roles
    put_body="{\"roles\": $merged_roles_json}"
    curl_out="$(curl -sS -w '\n%{http_code}' \
        -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
        -X PUT \
        -H "Content-Type: application/json" \
        -d "$put_body" \
        "${ES_URL}/_security/user/${username}" 2>&1)" || true

    http_code="$(echo "$curl_out" | tail -n1)"
    response_body="$(echo "$curl_out" | sed '$d')"

    if [[ "$http_code" =~ ^2 ]]; then
        log "  OK   $username ($http_code)"
        ok=$((ok + 1))
    else
        warn "  FAIL $username ($http_code)"
        if [ "$VERBOSE" = "true" ]; then
            warn "       $response_body"
        fi
        failed=$((failed + 1))
    fi
done

log ""
log "Done. total=$total  ok=$ok  skipped=$skipped  failed=$failed"

if [ "$failed" -gt 0 ]; then
    exit 1
fi
