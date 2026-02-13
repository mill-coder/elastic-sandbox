# Logstash monitoring & debugging dashboard

Design reference for the `logstash monitoring & debugging` Kibana dashboard.
This file is intended for Claude Code to re-read when adapting, extending, or debugging the dashboard.

## Identifiers

| Object | Type | ID |
|---|---|---|
| Dashboard | `dashboard` | `f8a015a7-5bdf-489a-8db4-19944db6be5c` |
| Saved search: logs | `search` | `d68ddd93-d89d-4740-9d72-9671b6214f13` |
| Saved search: errors | `search` | `e8f1a2b3-c4d5-6e7f-8a9b-0c1d2e3f4a5b` |
| Data view | `index-pattern` | `org-logs` (title: `Logs - *`, pattern: `logs-*`) |
| Tag: logstash | `tag` | `6e751479-2e7a-4317-b905-dd982259aa82` |
| Tag: monitoring | `tag` | `dd4aa858-6dcb-4606-9bcd-823e0a268631` |

NDJSON file: `logstash-monitoring.ndjson` (same directory as this file).

## Data sources

### `logs-logstash.pipelines-app` — Pipeline health metrics

Produced by the pipeline health checker sidecar (`logstash/scripts/logstash-pipelines-healthchecker.sh`).
Emits documents every ~10 seconds via `_bulk` into the `logs-logstash.pipelines-app` data stream.

Two event types, distinguished by `event.action`:

**`event.action: instance.health`** — one document per check cycle, instance-wide summary.

| Field | Type | Description |
|---|---|---|
| `logstash.instance.status` | keyword | `green`, `yellow`, or `red` |
| `logstash.instance.pipelines_defined` | long | Pipelines registered in `.logstash` index |
| `logstash.instance.pipelines_running` | long | Pipelines running in Logstash |
| `logstash.instance.pipelines_missing` | keyword[] | IDs of defined-but-not-running pipelines |
| `logstash.instance.jvm_heap_used_percent` | long | JVM heap usage percentage |
| `logstash.instance.process_cpu_percent` | long | Process CPU usage percentage |
| `logstash.instance.dlq_total_bytes` | long | Total DLQ size across all pipelines |
| `logstash.instance.dlq_total_dropped_events` | long | Total DLQ dropped events |
| `logstash.instance.dlq_pipelines` | keyword[] | Pipeline IDs with non-empty DLQs |

**`event.action: pipeline.stats`** — one document per pipeline per check cycle.

| Field | Type | Description |
|---|---|---|
| `logstash.pipeline.id` | keyword | Pipeline identifier |
| `logstash.pipeline.status` | keyword | `running` or `missing` |
| `logstash.pipeline.events_in` | long | Cumulative events received |
| `logstash.pipeline.events_out` | long | Cumulative events emitted |
| `logstash.pipeline.events_filtered` | long | Cumulative events filtered |
| `logstash.pipeline.events_duration_ms` | long | Cumulative processing time (ms) |
| `logstash.pipeline.queue_type` | keyword | `memory` or `persisted` |
| `logstash.pipeline.queue_events` | long | Events currently in queue |
| `logstash.pipeline.queue_size_bytes` | long | Queue size in bytes |
| `logstash.pipeline.reloads_successes` | long | Successful pipeline reloads |
| `logstash.pipeline.reloads_failures` | long | Failed pipeline reloads |
| `logstash.pipeline.dlq_size_bytes` | long | DLQ size for this pipeline |
| `logstash.pipeline.dlq_dropped_events` | long | DLQ dropped events for this pipeline |

### `logs-logstash.log-app` — Logstash JSON logs

Collected by the standalone Elastic Agent (`logstash/elastic-agent/elastic-agent.yml`).
Reads `/var/log/logstash/logstash-json.log` with field transformations.

| Field | Type | Description |
|---|---|---|
| `@timestamp` | date | Event timestamp (from `timeMillis`) |
| `log.level` | keyword | `ERROR`, `WARN`, `INFO`, `DEBUG`, `TRACE` |
| `log.logger` | keyword | Logger name (e.g., `logstash.codecs.json`) |
| `message` | text (+`.keyword`) | Log message (copied from `logEvent.message`) |
| `pipeline.id` | keyword | Pipeline that produced the log (absent on instance-level logs) |
| `plugin.id` | keyword | Plugin that produced the log (only on plugin-specific logs) |
| `process.thread.name` | keyword | Thread that produced the log |

## Field formatters (data view)

The `org-logs` data view includes a `fieldFormatMap` with color formatters for visual differentiation:

**`log.level`** — colored text badge:
| Value | Text | Background |
|---|---|---|
| ERROR | white `#ffffff` | red `#bd271e` |
| WARN | black `#000000` | amber `#f5a700` |
| INFO | white `#ffffff` | blue `#006bb4` |
| DEBUG | black `#000000` | gray `#d3dae6` |

**`logstash.instance.status`** — colored text:
| Value | Text | Background |
|---|---|---|
| green | white `#ffffff` | teal `#00BFB3` |
| yellow | black `#000000` | amber `#FEC514` |
| red | white `#ffffff` | red `#BD271E` |

**`logstash.pipeline.status`** — colored text:
| Value | Text | Background |
|---|---|---|
| running | white `#ffffff` | teal `#00BFB3` |
| missing | white `#ffffff` | red `#BD271E` |

These formatters apply everywhere the data view is used (saved searches, Lens tables).

## Dashboard layout

Grid: 48 columns. Panel positions use `(x, y, w, h)`.

### Row 1: Status bar — y=0, h=4

| Panel | Vis type | Grid | Data | Details |
|---|---|---|---|---|
| Pipeline Health | `lnsMetric` | 0,0,14,4 | pipelines / instance.health | Combined card. Primary: `logstash.instance.status` (string last_value). Secondary: `logstash.instance.pipelines_running`. |
| DLQ Bytes | `lnsMetric` | 14,0,7,4 | pipelines / instance.health | `logstash.instance.dlq_total_bytes` |
| DLQ Dropped | `lnsMetric` | 21,0,7,4 | pipelines / instance.health | `logstash.instance.dlq_total_dropped_events` |
| Quick Links | `markdown` | 28,0,20,4 | n/a | Links to Manage Pipelines, Ingest Pipelines |

All metric panels use `last_value` sorted by `@timestamp` with inline filters:
- `data_stream.dataset: logstash.pipelines`
- `event.action: instance.health`

### Row 2: Pipeline stats table — y=4, h=8

| Panel | Vis type | Grid | Details |
|---|---|---|---|
| Pipeline Stats | `lnsDatatable` | 0,4,48,8 | Filtered to `event.action: pipeline.stats` |

Columns (all `last_value` except the bucket):
1. `logstash.pipeline.id` — Top values bucket (split rows), ordered by events_in desc
2. `logstash.pipeline.status` — string last_value (colored via field formatter)
3. `logstash.pipeline.events_in`
4. `logstash.pipeline.events_out`
5. `logstash.pipeline.events_filtered`
6. `logstash.pipeline.events_duration_ms`
7. `logstash.pipeline.reloads_failures`
8. `logstash.pipeline.dlq_size_bytes`
9. `logstash.pipeline.dlq_dropped_events`

### Row 3: Time series charts — y=12, h=10

| Panel | Vis type | Grid | Details |
|---|---|---|---|
| Events In/Out Over Time | `lnsXY` (line) | 0,12,28,10 | Filtered to `pipeline.stats`. X: date_histogram. Y: last_value `events_in`, `events_out`. Split by `logstash.pipeline.id` (top 10). |
| Errors Over Time by Pipeline | `lnsXY` (bar_stacked) | 28,12,20,10 | Filtered to `logstash.log` + `log.level: ERROR`. X: date_histogram. Y: count. Split by `pipeline.id` (top 10). Shows error spikes per pipeline. |

### Row 4: Error summary table — y=22, h=8

| Panel | Vis type | Grid | Details |
|---|---|---|---|
| Top Errors by Pipeline | `lnsDatatable` | 0,22,48,8 | Filtered to `logstash.log` + `log.level: ERROR`. Full-width. Groups duplicate errors by pipeline/plugin combination. |

Columns:
1. `pipeline.id` — Top values bucket (top 10)
2. `plugin.id` — Top values bucket (top 10)
3. `message.keyword` — Top values bucket (top 10)
4. count

Note: `message` is a `text` field — the `message.keyword` sub-field (ignore_above: 2048) must be used for terms aggregation.

### Row 5: Recent errors — y=30, h=14

| Panel | Vis type | Grid | Details |
|---|---|---|---|
| Recent Errors | Saved search | 0,30,48,14 | References saved search `e8f1a2b3` ("logstash errors"). Filtered to `data_stream.dataset: logstash.log` + `log.level: ERROR`. Columns: `pipeline.id`, `plugin.id`, `log.logger`, `message`. Sorted by `@timestamp` desc. Expandable rows for full error text. |

### Row 6: All logs — y=44, h=20

| Panel | Vis type | Grid | Details |
|---|---|---|---|
| Logstash Logs | Saved search | 0,44,48,20 | References saved search `d68ddd93` ("logstash logs"). Columns: `log.level`, `pipeline.id`, `plugin.id`, `log.logger`, `message`. Filtered to `data_stream.dataset: logstash.log`. Sorted by `@timestamp` desc. `log.level` cells are color-coded via field formatter. |

## Panel construction patterns

All Lens panels are **inline** (embedded in the dashboard, not saved as separate objects).
Each panel follows this structure inside `panelsJSON`:

```
{
  "type": "lens",
  "embeddableConfig": {
    "filters": [...],               // panel-level filters (dataset + event.action)
    "query": {"query": "", "language": "kuery"},
    "attributes": {
      "visualizationType": "lnsMetric" | "lnsDatatable" | "lnsXY",
      "type": "lens",
      "references": [{"type": "index-pattern", "id": "org-logs", "name": "indexpattern-datasource-layer-{layerId}"}],
      "state": {
        "visualization": { ... },    // visualization-specific config
        "filters": [...],            // duplicated from embeddableConfig
        "datasourceStates": {
          "formBased": {
            "layers": {
              "{layerId}": {
                "columns": { ... },  // column definitions
                "columnOrder": [...]
              }
            }
          }
        }
      }
    }
  },
  "panelIndex": "{panelId}",
  "gridData": {"i": "{panelId}", "x": ..., "y": ..., "w": ..., "h": ...}
}
```

Dashboard-level references must include one entry per Lens panel:
```
{"id": "org-logs", "name": "{panelId}:indexpattern-datasource-layer-{layerId}", "type": "index-pattern"}
```

The markdown panel uses `type: "visualization"` with `savedVis.type: "markdown"` and needs no index-pattern references.

Each saved search panel uses `type: "search"` with `panelRefName` and needs dashboard-level references for:
1. The search object itself: `{panelId}:panel_{panelId}` → search ID
2. The search source index: `{panelId}:kibanaSavedObjectMeta.searchSourceJSON.index` → org-logs
3. Each filter's index: `{panelId}:kibanaSavedObjectMeta.searchSourceJSON.filter[N].meta.index` → org-logs

## Filter patterns

Pipelines data (instance health):
```json
{"meta": {"key": "data_stream.dataset", "params": {"query": "logstash.pipelines"}, "type": "phrase"},
 "query": {"match_phrase": {"data_stream.dataset": "logstash.pipelines"}}}
{"meta": {"key": "event.action", "params": {"query": "instance.health"}, "type": "phrase"},
 "query": {"match_phrase": {"event.action": "instance.health"}}}
```

Pipelines data (pipeline stats): same dataset filter + `event.action: pipeline.stats`.

Logstash logs:
```json
{"meta": {"key": "data_stream.dataset", "params": {"query": "logstash.log"}, "type": "phrase"},
 "query": {"match_phrase": {"data_stream.dataset": "logstash.log"}}}
```

Error-only: add `log.level: ERROR` filter.

## How to modify

### Regeneration approach

The dashboard NDJSON is generated by a Python script (`/tmp/build-dashboard.py`). To modify:

1. Edit the NDJSON directly (for small changes), or
2. Modify the generation script and re-run, or
3. Modify the dashboard in Kibana UI, then re-export:
   ```bash
   curl -s -u elastic:changeme \
     -X POST "http://localhost:5601/api/saved_objects/_export" \
     -H "kbn-xsrf: true" -H "Content-Type: application/json" \
     -d '{"objects":[{"type":"dashboard","id":"f8a015a7-5bdf-489a-8db4-19944db6be5c"}],"includeReferencesDeep":true}' \
     -o logstash/definitions-local/kibana/saved-objects/logstash-monitoring.ndjson
   ```

### Import

```bash
curl -s -u elastic:changeme \
  -X POST "http://localhost:5601/api/saved_objects/_import?overwrite=true" \
  -H "kbn-xsrf: true" \
  -F file=@logstash/definitions-local/kibana/saved-objects/logstash-monitoring.ndjson
```

After importing via API while Kibana is already open, click **Reset** on the "Unsaved changes" banner (or clear `sessionStorage` and hard-reload) — the Kibana SPA caches the old dashboard state.

### Adding a new metric panel

1. Choose a unique panel ID and layer ID
2. Add the column definition with `operationType: "last_value"`, `sourceField`, and a `filter` for field existence
3. Add the panel entry to `panelsJSON` with correct `gridData`
4. Add a dashboard-level reference: `{panelId}:indexpattern-datasource-layer-{layerId}` -> `org-logs`
5. Adjust `gridData` of neighboring panels if needed to fit within the 48-column grid

### Adding a new data field

If the health checker gains new fields:
1. Update `logstash/scripts/logstash-pipelines-healthchecker.sh` to emit the field
2. Add the field to this document's field tables
3. Add a panel or table column referencing the new field
4. Re-import the dashboard
