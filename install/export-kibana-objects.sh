#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# export-kibana-objects.sh — Export a Kibana saved object (and all its deep
# dependencies) as NDJSON via the Saved Objects Export API.
#
# Usage:
#   export-kibana-objects.sh <type> <id> <output-file>
#
# Example:
#   set -a && source install/local/.env && set +a
#   KB_URL=http://localhost:5601 bash install/export-kibana-objects.sh \
#     dashboard f8a015a7-5bdf-489a-8db4-19944db6be5c \
#     logstash/definitions-local/kibana/saved-objects/logstash-monitoring.ndjson
#
# Environment variables:
#   KB_URL             Kibana base URL (default: http://localhost:5601)
#   ELASTIC_USER       Auth user (default: elastic)
#   ELASTIC_PASSWORD   Auth password (required)
#   SPACE              Kibana space ID (optional — uses /s/{space}/api/...)
# ---------------------------------------------------------------------------

KB_URL="${KB_URL:-http://localhost:5601}"
ELASTIC_USER="${ELASTIC_USER:-elastic}"
ELASTIC_PASSWORD="${ELASTIC_PASSWORD:?ELASTIC_PASSWORD must be set}"
SPACE="${SPACE:-}"

log()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

if [ $# -lt 3 ]; then
    warn "Usage: $0 <type> <id> <output-file>"
    warn "  e.g. $0 dashboard abc-123 path/to/output.ndjson"
    exit 1
fi

OBJ_TYPE="$1"
OBJ_ID="$2"
OUTPUT_FILE="$3"

# Build API URL (space-aware)
API_PREFIX=""
if [ -n "$SPACE" ]; then
    API_PREFIX="/s/${SPACE}"
fi
EXPORT_URL="${KB_URL}${API_PREFIX}/api/saved_objects/_export"

# Build JSON payload
PAYLOAD="$(cat <<EOF
{
  "objects": [{ "type": "${OBJ_TYPE}", "id": "${OBJ_ID}" }],
  "includeReferencesDeep": true
}
EOF
)"

log "Exporting ${OBJ_TYPE}/${OBJ_ID} from ${EXPORT_URL} ..."

# Ensure output directory exists
mkdir -p "$(dirname "$OUTPUT_FILE")"

# Call the export API
HTTP_CODE="$(curl -sS -w '%{http_code}' \
    -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "kbn-xsrf: true" \
    -d "$PAYLOAD" \
    -o "$OUTPUT_FILE" \
    "$EXPORT_URL")"

if [[ "$HTTP_CODE" =~ ^2 ]]; then
    LINES="$(wc -l < "$OUTPUT_FILE")"
    log "OK — exported $LINES objects to $OUTPUT_FILE ($HTTP_CODE)"
else
    warn "FAIL — HTTP $HTTP_CODE"
    warn "Response:"
    cat "$OUTPUT_FILE" >&2
    rm -f "$OUTPUT_FILE"
    exit 1
fi
