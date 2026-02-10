#!/bin/bash
set -euo pipefail

ES_URL="${ES_URL:-http://elasticsearch:9200}"
LOGSTASH_URL="${LOGSTASH_URL:-http://logstash:9600}"
ES_USER="${ES_USER:-elastic}"
ES_PASSWORD="${ES_PASSWORD}"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"

DATA_STREAM="logs-logstash.pipelines-app"
DLQ_BASE="/usr/share/logstash/data/dead_letter_queue"

log() { echo "[$(date -Iseconds)] $*"; }

# ─── helpers ────────────────────────────────────────────────────────────────

# human_bytes <bytes>  →  "1.2 MB"
human_bytes() {
  local b=$1
  if   [ "$b" -ge 1073741824 ]; then echo "$(awk "BEGIN{printf \"%.1f\", $b/1073741824}") GB"
  elif [ "$b" -ge 1048576 ];    then echo "$(awk "BEGIN{printf \"%.1f\", $b/1048576}") MB"
  elif [ "$b" -ge 1024 ];       then echo "$(awk "BEGIN{printf \"%.1f\", $b/1024}") KB"
  else echo "${b} B"
  fi
}

# json_arr <item> ...  →  ["item1","item2"]   (empty call → [])
json_arr() {
  if [ $# -eq 0 ]; then echo "[]"; return; fi
  local out="["
  local first=true
  for item in "$@"; do
    $first || out="${out},"
    out="${out}\"${item}\""
    first=false
  done
  echo "${out}]"
}

# ─── main loop ──────────────────────────────────────────────────────────────

while true; do
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)

  # ── 1. Fetch data sources ─────────────────────────────────────────────────
  # Defined pipelines (from .logstash index — Kibana centralized pipeline mgmt)
  defined_json=$(curl -sS -u "${ES_USER}:${ES_PASSWORD}" \
    "${ES_URL}/.logstash/_search?size=1000&_source=false" 2>/dev/null || echo "{}")
  defined_list=$(echo "$defined_json" | jq -r '[.hits.hits[]._id] | sort | .[]' 2>/dev/null || echo "")

  # Pipeline stats (from Logstash Node Stats API — rich per-pipeline metrics)
  stats_json=$(curl -sS "${LOGSTASH_URL}/_node/stats/pipelines" 2>/dev/null || echo "{}")
  running_list=$(echo "$stats_json" | jq -r '[.pipelines | keys[]] | sort | .[]' 2>/dev/null || echo "")

  # JVM & process stats (from Logstash Node Stats API)
  node_json=$(curl -sS "${LOGSTASH_URL}/_node/stats/jvm,process" 2>/dev/null || echo "{}")

  # ── 2. Compute sets ───────────────────────────────────────────────────────
  defined_arr=()
  [ -n "$defined_list" ] && while IFS= read -r p; do defined_arr+=("$p"); done <<< "$defined_list"

  running_arr=()
  [ -n "$running_list" ] && while IFS= read -r p; do running_arr+=("$p"); done <<< "$running_list"

  missing_arr=()
  for p in "${defined_arr[@]+"${defined_arr[@]}"}"; do
    found=false
    for r in "${running_arr[@]+"${running_arr[@]}"}"; do
      [ "$p" = "$r" ] && { found=true; break; }
    done
    $found || missing_arr+=("$p")
  done

  defined_count=${#defined_arr[@]}
  running_count=${#running_arr[@]}
  missing_count=${#missing_arr[@]}

  # ── 3. Build _bulk payload ────────────────────────────────────────────────
  bulk=""
  action="{\"create\":{\"_index\":\"${DATA_STREAM}\"}}"

  dlq_total_bytes=0
  dlq_total_dropped=0
  dlq_pipeline_arr=()

  # ── 3a. pipeline.stats — one event per running pipeline ────────────────
  for pid in "${running_arr[@]+"${running_arr[@]}"}"; do
    p_stats=$(echo "$stats_json" | jq -c --arg id "$pid" '.pipelines[$id]' 2>/dev/null || echo "{}")

    events_in=$(echo "$p_stats" | jq '.events.in // 0')
    events_out=$(echo "$p_stats" | jq '.events.out // 0')
    events_filtered=$(echo "$p_stats" | jq '.events.filtered // 0')
    events_duration_ms=$(echo "$p_stats" | jq '.events.duration_in_millis // 0')

    queue_type=$(echo "$p_stats" | jq -r '.queue.type // "memory"')
    queue_events=$(echo "$p_stats" | jq '.queue.events_count // 0')
    queue_bytes=$(echo "$p_stats" | jq '.queue.queue_size_in_bytes // 0')

    reloads_successes=$(echo "$p_stats" | jq '.reloads.successes // 0')
    reloads_failures=$(echo "$p_stats" | jq '.reloads.failures // 0')
    reloads_last_failure=$(echo "$p_stats" | jq -r '.reloads.last_failure_timestamp // empty' 2>/dev/null || echo "")

    # DLQ stats from API
    api_dlq_bytes=$(echo "$p_stats" | jq '.dead_letter_queue.queue_size_in_bytes // 0')
    api_dlq_dropped=$(echo "$p_stats" | jq '.dead_letter_queue.dropped_events // 0')

    # DLQ stats from filesystem (fallback — catches data from crashed pipelines)
    fs_dlq_bytes=0
    if [ -d "${DLQ_BASE}/${pid}" ]; then
      fs_dlq_bytes=$(find "${DLQ_BASE}/${pid}" -type f -name '*.log' -exec stat -c '%s' {} + 2>/dev/null | awk '{s+=$1} END {print s+0}')
    fi

    # Use the larger of API vs filesystem DLQ size
    dlq_bytes=$api_dlq_bytes
    [ "$fs_dlq_bytes" -gt "$dlq_bytes" ] 2>/dev/null && dlq_bytes=$fs_dlq_bytes
    dlq_dropped=$api_dlq_dropped

    if [ "$dlq_bytes" -gt 0 ]; then
      dlq_total_bytes=$((dlq_total_bytes + dlq_bytes))
      dlq_total_dropped=$((dlq_total_dropped + dlq_dropped))
      dlq_pipeline_arr+=("$pid")
    fi

    # Build optional field for last failure timestamp
    reloads_last_failure_field=""
    if [ -n "$reloads_last_failure" ]; then
      reloads_last_failure_field="\"logstash.pipeline.reloads_last_failure_timestamp\":\"${reloads_last_failure}\","
    fi

    event=$(cat <<EOF
{"@timestamp":"${timestamp}","event.action":"pipeline.stats","event.dataset":"logstash.pipelines","logstash.pipeline.id":"${pid}","logstash.pipeline.status":"running","logstash.pipeline.events_in":${events_in},"logstash.pipeline.events_out":${events_out},"logstash.pipeline.events_filtered":${events_filtered},"logstash.pipeline.events_duration_ms":${events_duration_ms},"logstash.pipeline.queue_type":"${queue_type}","logstash.pipeline.queue_events":${queue_events},"logstash.pipeline.queue_size_bytes":${queue_bytes},"logstash.pipeline.reloads_successes":${reloads_successes},"logstash.pipeline.reloads_failures":${reloads_failures},${reloads_last_failure_field}"logstash.pipeline.dlq_size_bytes":${dlq_bytes},"logstash.pipeline.dlq_dropped_events":${dlq_dropped},"data_stream":{"type":"logs","dataset":"logstash.pipelines","namespace":"app"}}
EOF
)
    bulk="${bulk}${action}\n${event}\n"
  done

  # ── 3b. pipeline.stats — one event per missing pipeline ────────────────
  for pid in "${missing_arr[@]+"${missing_arr[@]}"}"; do
    # Check filesystem DLQ for missing pipelines too
    fs_dlq_bytes=0
    if [ -d "${DLQ_BASE}/${pid}" ]; then
      fs_dlq_bytes=$(find "${DLQ_BASE}/${pid}" -type f -name '*.log' -exec stat -c '%s' {} + 2>/dev/null | awk '{s+=$1} END {print s+0}')
    fi
    if [ "$fs_dlq_bytes" -gt 0 ]; then
      dlq_total_bytes=$((dlq_total_bytes + fs_dlq_bytes))
      dlq_pipeline_arr+=("$pid")
    fi

    event=$(cat <<EOF
{"@timestamp":"${timestamp}","event.action":"pipeline.stats","event.dataset":"logstash.pipelines","logstash.pipeline.id":"${pid}","logstash.pipeline.status":"missing","logstash.pipeline.events_in":0,"logstash.pipeline.events_out":0,"logstash.pipeline.events_filtered":0,"logstash.pipeline.events_duration_ms":0,"logstash.pipeline.queue_type":"none","logstash.pipeline.queue_events":0,"logstash.pipeline.queue_size_bytes":0,"logstash.pipeline.reloads_successes":0,"logstash.pipeline.reloads_failures":0,"logstash.pipeline.dlq_size_bytes":${fs_dlq_bytes},"logstash.pipeline.dlq_dropped_events":0,"data_stream":{"type":"logs","dataset":"logstash.pipelines","namespace":"app"}}
EOF
)
    bulk="${bulk}${action}\n${event}\n"
  done

  # ── 3c. pipeline.dlq — one event per pipeline with DLQ data ────────────
  # Re-scan all DLQ dirs (catches pipelines no longer defined/running)
  if [ -d "$DLQ_BASE" ]; then
    for dlq_dir in "$DLQ_BASE"/*/; do
      [ -d "$dlq_dir" ] || continue
      pid=$(basename "$dlq_dir")
      fs_dlq_bytes=$(find "$dlq_dir" -type f -name '*.log' -exec stat -c '%s' {} + 2>/dev/null | awk '{s+=$1} END {print s+0}')
      [ "$fs_dlq_bytes" -eq 0 ] && continue

      # Get API stats if available
      api_dlq_bytes=$(echo "$stats_json" | jq -c --arg id "$pid" '.pipelines[$id].dead_letter_queue.queue_size_in_bytes // 0' 2>/dev/null || echo 0)
      api_dlq_dropped=$(echo "$stats_json" | jq -c --arg id "$pid" '.pipelines[$id].dead_letter_queue.dropped_events // 0' 2>/dev/null || echo 0)
      dlq_bytes=$api_dlq_bytes
      [ "$fs_dlq_bytes" -gt "$dlq_bytes" ] 2>/dev/null && dlq_bytes=$fs_dlq_bytes
      dlq_dropped=$api_dlq_dropped
      dlq_human=$(human_bytes "$dlq_bytes")

      event=$(cat <<EOF
{"@timestamp":"${timestamp}","event.action":"pipeline.dlq","event.dataset":"logstash.pipelines","logstash.pipeline.id":"${pid}","logstash.dlq.size_bytes":${dlq_bytes},"logstash.dlq.dropped_events":${dlq_dropped},"logstash.dlq.size_human":"${dlq_human}","data_stream":{"type":"logs","dataset":"logstash.pipelines","namespace":"app"}}
EOF
)
      bulk="${bulk}${action}\n${event}\n"
    done
  fi

  # ── 3d. instance.health — overall status ───────────────────────────────
  jvm_heap_used_pct=$(echo "$node_json" | jq '.jvm.mem.heap_used_percent // 0' 2>/dev/null || echo 0)
  process_cpu_pct=$(echo "$node_json" | jq '.process.cpu.percent // 0' 2>/dev/null || echo 0)

  status="green"
  [ "$dlq_total_bytes" -gt 0 ] && status="yellow"
  [ "$missing_count" -gt 0 ] && status="yellow"
  [ "$running_count" -eq 0 ] && [ "$defined_count" -gt 0 ] && status="red"

  missing_json=$(json_arr "${missing_arr[@]+"${missing_arr[@]}"}")
  dlq_pipelines_json=$(json_arr "${dlq_pipeline_arr[@]+"${dlq_pipeline_arr[@]}"}")

  event=$(cat <<EOF
{"@timestamp":"${timestamp}","event.action":"instance.health","event.dataset":"logstash.pipelines","logstash.instance.status":"${status}","logstash.instance.pipelines_defined":${defined_count},"logstash.instance.pipelines_running":${running_count},"logstash.instance.pipelines_missing":${missing_json},"logstash.instance.dlq_total_bytes":${dlq_total_bytes},"logstash.instance.dlq_total_dropped_events":${dlq_total_dropped},"logstash.instance.dlq_pipelines":${dlq_pipelines_json},"logstash.instance.jvm_heap_used_percent":${jvm_heap_used_pct},"logstash.instance.process_cpu_percent":${process_cpu_pct},"data_stream":{"type":"logs","dataset":"logstash.pipelines","namespace":"app"}}
EOF
)
  bulk="${bulk}${action}\n${event}\n"

  # ── 4. Send _bulk request ─────────────────────────────────────────────────
  bulk_response=$(printf '%b' "$bulk" | curl -sS -u "${ES_USER}:${ES_PASSWORD}" \
    -X POST "${ES_URL}/_bulk" \
    -H "Content-Type: application/x-ndjson" \
    --data-binary @- 2>/dev/null || echo '{"errors":true}')

  bulk_errors=$(echo "$bulk_response" | jq '.errors' 2>/dev/null || echo "true")
  if [ "$bulk_errors" = "true" ]; then
    error_detail=$(echo "$bulk_response" | jq -r '[.items[]? | select(.create.error) | .create.error.reason] | first // "unknown"' 2>/dev/null || echo "unknown")
    log "WARN bulk index had errors: ${error_detail}"
  fi

  # ── 5. Console log ────────────────────────────────────────────────────────
  pipeline_count=$((running_count + missing_count))
  log "status=${status} defined=${defined_count} running=${running_count} missing=${missing_count}${missing_arr:+ ($(IFS=,; echo "${missing_arr[*]}"))} dlq_bytes=${dlq_total_bytes}${dlq_pipeline_arr:+ ($(IFS=,; echo "${dlq_pipeline_arr[*]}"))} jvm_heap=${jvm_heap_used_pct}% cpu=${process_cpu_pct}% events=${pipeline_count}"

  sleep "$CHECK_INTERVAL"
done
