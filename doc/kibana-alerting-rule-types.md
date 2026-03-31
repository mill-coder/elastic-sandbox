# Kibana alerting rule types

Reference catalog of the 21 non-Stack-Monitoring alerting rule types available in Kibana 8.x.

**Scope:** Elastic 8.x with Platinum/Enterprise license. The 14 Stack Monitoring rule types (cluster health, node resources, version mismatches, etc.) are excluded. They monitor the Elastic infrastructure itself, not user workloads.

## Summary table

| Rule type | Category | What it monitors | Data prerequisites | Stack prerequisites | Kibana privilege | Status |
|-----------|----------|------------------|--------------------|---------------------|------------------|--------|
| Elasticsearch query | Stack Alerts | Matches from any ES query (DSL, KQL, ES\|QL, Lucene) | Any index or data stream | None (base ES + Kibana) | `Stack Rules: All` | GA |
| Index threshold | Stack Alerts | Aggregated metric crossing a threshold | Any index with a time field | None | `Stack Rules: All` | GA |
| Transform health | Stack Alerts | Transform operational issues (stopped, not indexing) | Running transforms | Transforms feature | `Stack Rules: All` | GA |
| Tracking containment | Stack Alerts | Entity entering/exiting geographic boundaries | `geo_point`/`geo_shape` indices + boundary index | None | `Stack Rules: All` | Disabled (requires geo data) |
| Custom threshold | Observability | Any Observability metric crossing a threshold (with equations, group-by) | Any data view (logs, metrics, APM) | None | `Observability: All` or `Stack Rules: All` | GA |
| Inventory | Infrastructure | Host/pod/container metric thresholds | Metrics from Elastic Agent or Metricbeat (`metrics-*`) | Infrastructure app configured | `Infrastructure: All` | GA |
| Metric threshold | Infrastructure | General metric aggregation thresholds | Metrics indices (configured in Infra app Settings) | Infrastructure app configured | `Infrastructure: All` | GA |
| Log threshold | Logs | Log document count or ratio conditions | Log indices (`logs-*`, configured in Logs app Settings) | None | `Logs: All` | GA |
| APM Anomaly | APM | Anomalous latency, throughput, or error rate on a service | APM data (OTel agents -> collector -> APM Server) | ML nodes + APM integration | `APM: All` + `ML: All` | GA (requires ML) |
| Error count threshold | APM | Error count exceeding a threshold per service | APM error data (`logs-apm.*`) | APM integration | `APM: All` | GA |
| Failed transaction rate | APM | Transaction failure percentage exceeding a threshold | APM transaction data (`traces-apm.*`) | APM integration | `APM: All` | GA |
| Latency threshold | APM | Transaction latency (avg, p95, p99) exceeding a threshold | APM transaction data (`traces-apm.*`) | APM integration | `APM: All` | GA |
| Synthetics monitor status | Synthetics | Monitor is down (failed checks across locations) | Synthetics monitors running (Private Locations or managed) | Fleet + Elastic Agent | `Uptime/Synthetics: All` | GA |
| Synthetics TLS certificate | Synthetics | TLS certificate expiring or too old | HTTP/TCP Synthetics monitors with TLS | Fleet + Elastic Agent | `Uptime/Synthetics: All` | GA |
| Uptime monitor status | Synthetics | Heartbeat monitor is down | Heartbeat data (`heartbeat-*`) | Heartbeat deployed | `Uptime/Synthetics: All` | Deprecated 8.15 |
| Uptime TLS | Synthetics | Uptime monitor TLS certificate expiring | Heartbeat TLS data | Heartbeat deployed | `Uptime/Synthetics: All` | Deprecated 8.15 |
| Uptime TLS (Legacy) | Synthetics | Same as Uptime TLS (older implementation) | Heartbeat TLS data | Heartbeat deployed | `Uptime/Synthetics: All` | Deprecated 8.15 |
| Uptime Duration Anomaly | Synthetics | Anomalous monitor response duration | Heartbeat data | ML nodes + Heartbeat | `Uptime/Synthetics: All` + `ML: All` | Disabled (requires ML + Heartbeat) |
| Anomaly detection | Machine Learning | ML job results matching a condition (score threshold) | Anomaly detection job running | ML nodes | `ML: All` | GA (requires ML jobs) |
| Anomaly detection jobs health | Machine Learning | ML job operational issues (datafeed stopped, memory, errors) | Anomaly detection jobs | ML nodes | `ML: All` | GA (requires ML jobs) |
| SLO burn rate | SLOs | Error budget burn rate exceeding threshold | SLO defined (backed by APM or custom metric data) | Transform + ingest nodes, SLO feature | `SLOs: All` | GA (requires SLO definitions) |

**Kibana privilege notes:**
- All rule types additionally require `Actions and Connectors: All` to attach notification actions (e.g. Mattermost webhooks).
- Rules use an API key capturing the creator's privileges at creation time. If a user with fewer privileges later edits the rule, it may stop working.
- `Stack Rules: All` is the most basic privilegeit covers ES Query, Index Threshold, Transform Health, and Tracking Containment.

## Stack Alerts

### Elasticsearch query

The most flexible rule type. Runs an arbitrary Elasticsearch query on a schedule and fires when the match count crosses a threshold.

**Use case:** Detect specific log patterns, error signatures, missing heartbeats, or any condition expressible as an ES query. Works on any index or data stream.

**Data:** User-specified index pattern + time field. Supports Query DSL, KQL, Lucene, and ES|QL.

**Limits:**
- Only `query`, `fields`, `_source`, and `runtime_mappings` are used from DSLno full aggregation pipelines.
- Grouping is limited to 4 fields (terms/multi-terms aggregation).
- Requires query expertise for complex conditions.

**Overlaps:** Can replicate most of what Index Threshold and Log Threshold do, but with more effort. For simple "count > N" scenarios, Index Threshold or Custom Threshold are easier to configure.

### Index threshold

Aggregates a metric (count, avg, sum, min, max) over a time window and fires when it crosses a threshold.

**Use case:** Simple numeric threshold alertse.g. "alert if error count in the last 5 minutes exceeds 100". Works on any index with a time field.

**Data:** User-specified index + time field. Supports KQL filtering.

**Limits:**
- Only 5 aggregation types (count, average, sum, min, max)no percentiles, no cardinality.
- No custom equations or multi-condition logic.
- Group-by requires specifying max group count upfront.

**Overlaps:** Largely subsumed by Custom Threshold (which adds equations, group-by, and more aggregation types). Still useful for alerting on non-Observability indices where Custom Threshold's data view requirement is inconvenient.

### Transform health

Monitors continuous transforms for operational issues (not started, not indexing, unhealthy).

**Use case:** Catch silent transform failures before downstream dashboards or alerts go stale.

**Data:** Transform status metadata (no user index needed).

**Limits:** Only monitors transform healthdoes not inspect transform output data. Only useful if you run transforms.

### Tracking containment

Fires when entities enter or exit geographic boundaries.

**Use case:** Geofencingasset tracking, fleet management, compliance zones. Requires geo-enriched data.

**Data:** Entities index with `geo_point`/`geo_shape` + date + entity identifier; static boundaries index with `geo_shape`.

**Limits:** Entity data must be recent (within check interval). Boundaries are snapshot at rule creation. Niche use caseunlikely to be relevant for log/trace/Synthetics workloads.

## ObservabilityCustom threshold

Elastic's strategic convergence rule type. Works across logs, metrics, and APM data using a unified interface.

**Use case:** Alert when any Observability metric reaches a valuelog error spikes, APM latency, metric anomalies. Supports multiple conditions combined with equations, group-by on multiple fields.

**Data:** Any data view (logs-*, metrics-*, traces-apm-*, or custom). User selects the data view and defines aggregation conditions.

**Configuration highlights:**
- Aggregation types: Average, Max, Min, Cardinality, Count, Sum, Percentile, Rate.
- Custom equations using basic math and boolean logic across multiple metrics.
- Group-by on composite fields (up to 3).
- Configurable no-data handling (recover, trigger, or ignore).

**Limits:**
- Preview chart limitations for complex aggregations.
- Group-by capped at 3 fields.
- Requires an existing data view (cannot target raw index patterns directly like ES Query).

**Overlaps:** This is the most important overlap to understand:
- **Replaces Log Threshold** for most log-based alerting (with more flexibility).
- **Replaces Metric Threshold** for most metric-based alerting.
- **Replaces Inventory** for host/container alerting (though Inventory has a topology-aware UI).
- **Can cover APM alerting** on APM metric indices, but dedicated APM rules are simpler for service-specific thresholds.

## Infrastructure

### Inventory

Alert when infrastructure metrics (CPU, memory, disk, network) exceed thresholds for hosts, Kubernetes pods, Docker containers, or AWS resources.

**Use case:** Host-level or container-level resource alerting with a topology-aware selection UI.

**Data:** Metrics from Elastic Agent system integration or Metricbeat (`metrics-system.*`, `metrics-kubernetes.*`, `metrics-docker.*`). Index pattern is derived from Infrastructure app Settingsnot configurable per rule.

**Limits:**
- Cannot set index pattern per rulealways uses the global Infrastructure app setting.
- Limited to the predefined resource types (hosts, pods, containers, AWS).
- Being converged into Custom Threshold.

**Overlaps:** Custom Threshold can replicate most Inventory conditions. Inventory's advantage is the topology-aware UI for selecting specific hosts/pods.

### Metric threshold

General-purpose metric alerting from the Infrastructure app.

**Use case:** Alert on any metric aggregation (not limited to predefined resource types like Inventory). Useful for custom metrics collected via Elastic Agent.

**Data:** Metrics indices from Infrastructure app Settings. Index pattern is derived at execution time, not stored per rule.

**Limits:**
- Index pattern not configurable per rule (same as Inventory).
- Being converged into Custom Threshold.

**Overlaps:** Custom Threshold is strictly more capable. Metric Threshold is a simpler interface for straightforward single-metric conditions.

## LogsLog threshold

Alert based on log document counts or ratio conditions.

**Use case:** "Alert if error logs exceed 50 in 5 minutes" or "Alert if the ratio of errors to total logs exceeds 10%". Supports group-by to alert per-host or per-service.

**Data:** Log indices configured in Logs app Settings (`logs-*` by default). Index pattern is inferred, not set per rule.

**Limits:**
- Critical: when group-by fields are used but no documents contain those fields in the time window, the rule **cannot fire**meaning it cannot detect when a host stops sending logs entirely.
- Ratio rules return no alert when dividing by zero.
- High-cardinality group-by fields hurt performance.
- Index pattern not configurable per rule.

**Overlaps:** Custom Threshold handles all Log Threshold use cases and adds equations, more aggregation types, and explicit data view selection. Log Threshold's ratio feature is its unique advantage, but Custom Threshold can approximate it with equations.

## APM & User Experience

All four APM rule types require APM data flowing through the APM integration (in this case: OTel agents -> collector -> Elastic APM Server). They operate on APM-specific indices (`traces-apm-*`, `logs-apm.error-*`, `metrics-apm.*`).

### APM Anomaly

Uses machine learning to detect anomalous latency, throughput, or failed transaction rate on a service.

**Use case:** Catch service degradations that don't cross a fixed threshold but are unusual for the time of day or traffic pattern.

**Data:** APM transaction and metric data. ML jobs are created automatically per service/environment.

**Limits:**
- Requires ML nodes running in the cluster.
- Needs a baseline period (typically 2+ weeks) before anomaly detection is meaningful.
- Severity levels (critical, major, minor, warning) control sensitivity but can be noisy initially.

**Overlaps:** The three threshold-based APM rules below are simpler and don't require ML. Use APM Anomaly when fixed thresholds don't capture the expected behavior well (e.g. traffic varies by time of day).

### Error count threshold

**Use case:** Alert when the number of errors in a service exceeds a fixed count. Simple and direct.

**Data:** APM error documents. Filterable by service, environment, error grouping key, transaction type/name.

**Limits:** Only counts errorsno rate normalization. A spike in traffic will increase absolute error counts even if the error rate is unchanged. For rate-based alerting, use Failed Transaction Rate instead.

### Failed transaction rate threshold

**Use case:** Alert when the percentage of failed transactions exceeds a threshold (e.g. >5%). Rate-based, so it normalizes for traffic volume.

**Data:** APM transaction data. Filterable by service, type, environment, name.

**Limits:** Measures transaction-level failuresnot individual error events. A single transaction producing multiple errors still counts as one failure.

**Overlaps:** Error Count and Failed Transaction Rate address related but different signals. Error Count catches absolute spikes; Failed Transaction Rate catches proportion changes. Both are useful.

### Latency threshold

**Use case:** Alert when transaction latency (average, p95, or p99) exceeds a threshold in milliseconds.

**Data:** APM transaction data. Filterable by service, type, environment, name. Supports grouping by a field.

**Limits:** Fixed thresholds may not suit services with variable traffic patternsconsider APM Anomaly for those cases.

**Overlaps:** Custom Threshold can also alert on APM latency metrics, but this dedicated rule provides a simpler, APM-aware configuration UI.

## Synthetics & Uptime

### Synthetics monitor status

**Use case:** Alert when a Synthetics monitor (HTTP, TCP, ICMP, or browser) is down. Evaluates check results across locations and fires when enough locations report failures.

**Data:** Synthetics check results from monitors configured in the Synthetics app. Monitors run on Elastic's managed infrastructure or on Private Locations (Fleet + Elastic Agent with `elastic-agent-complete` image).

**Configuration highlights:**
- Filter by monitor type, location, tags, or KQL.
- Condition: number of down checks relative to total checks or time range.
- Minimum locations threshold to avoid single-location false positives.
- Flapping detection to suppress noisy on/off alerts.
- Alert on no data (pending monitors).

**Limits:** Check scheduling is best-effortmonitors run as close to the defined interval as capacity allows.

**Sandbox context:** The Fleet module already deploys `.monitor` files (HTTP health checks) via `deploy-fleet.sh`. These Synthetics monitors would be the data source for this rule type.

### Synthetics TLS certificate

**Use case:** Alert when a TLS certificate from an HTTP or TCP Synthetics monitor is about to expire or has exceeded an age limit.

**Data:** TLS certificate metadata collected by HTTP/TCP monitors only (browser monitors excluded).

**Configuration highlights:**
- Expiration threshold: "certificate expires within X days" (e.g. 30 days).
- Age limit: "certificate older than X days" (e.g. 365 days).
- Filterable by monitor, location, tags.

**Limits:** Only works with HTTP and TCP monitor typesbrowser monitors do not expose TLS metadata.

### Deprecated Uptime types

The following rule types are **deprecated since Elastic 8.15** and replaced by their Synthetics equivalents:

- **Uptime monitor status**replaced by Synthetics monitor status
- **Uptime TLS**replaced by Synthetics TLS certificate
- **Uptime TLS (Legacy)**older implementation, also replaced
- **Uptime Duration Anomaly**requires ML + Heartbeat, disabled by default

For greenfield deployments (like this sandbox), use the Synthetics rule types directly. Migration from Uptime to Synthetics is documented in the [Elastic Observability Labs guide](https://www.elastic.co/observability-labs/blog/uptime-to-synthetics-guide).

## Machine Learning & SLOs

These rule types are available with a Platinum license but require additional setup before they can be used.

### Anomaly detection / Anomaly detection jobs health

**Use case:** Alert on ML anomaly detection results (score above threshold) or on job operational issues (datafeed stopped, memory limit, data delays).

**Prerequisites:** ML nodes in the cluster + at least one anomaly detection job created and running. These are general-purpose ML alertsnot tied to a specific data type.

**When to consider:** Once you have established data patterns and want to move beyond fixed thresholds to behavioral anomaly detection across any data set.

### SLO burn rate

**Use case:** Alert when the SLO error budget is being consumed faster than sustainable. Uses a dual lookback window (long + short period) to detect both slow burns and sudden spikes.

**Prerequisites:** SLO definitions must exist first (each SLO auto-creates its own burn rate rule). SLOs require transform + ingest node roles. SLO data sources can be APM transaction metrics, custom KQL queries, or histogram metrics.

**When to consider:** Once services have well-defined availability or latency targets and you want to shift from reactive threshold alerting to proactive error budget management.

## Overlap and consolidation

### Custom threshold vs Log threshold vs Metric threshold vs Inventory

Elastic is converging on **Custom Threshold** as the unified rule type for Observability alerting. The older types (Log Threshold, Metric Threshold, Inventory) are not yet deprecated but receive no new features.

| Capability | Custom Threshold | Log Threshold | Metric Threshold | Inventory |
|------------|-----------------|---------------|------------------|-----------|
| Data source | Any data view | Logs app setting | Infra app setting | Infra app setting |
| Aggregations | 8 types + equations | Count + ratio | Standard | Standard |
| Group-by | Up to 3 fields | Multiple fields | Limited | By resource type |
| Multi-condition | Yes (with equations) | Yes (AND) | Yes (AND) | Yes (AND) |
| No-data handling | Configurable | No | No | No |
| Index per rule | Via data view | No | No | No |

**Recommendation:** Prefer Custom Threshold for new rules. Use the older types only when their specialized UI provides clear value (e.g. Inventory's topology view for host selection).

### Synthetics vs Uptime

Uptime (Heartbeat-based) is deprecated since 8.15. Synthetics is the replacement, offering:
- Browser-based monitoring (not just lightweight HTTP/TCP/ICMP)
- Managed global testing infrastructure (no self-hosted Heartbeat needed)
- Private Locations via Fleet (what this sandbox uses)
- Richer alerting (monitor status + TLS in a unified Synthetics app)

For greenfield setups, go directly to Synthetics.

### ES Query vs Index Threshold vs Custom Threshold

These three rule types can all alert on "count of documents matching a condition":

| Aspect | ES Query | Index Threshold | Custom Threshold |
|--------|----------|-----------------|------------------|
| Query power | Full DSL / KQL / ES\|QL | KQL filter only | KQL filter only |
| Aggregations | Count + basic via DSL | 5 types | 8 types + equations |
| Index selection | Per rule (any index) | Per rule (any index) | Via data view |
| Group-by | Up to 4 fields | Limited | Up to 3 fields |
| Ease of use | Low (query expertise) | High | Medium |
| Deployable as code | Yes (.alert files) | Yes (.alert files) | Not yet |

**Guidance:**
- **ES Query** for complex conditions, non-Observability indices, or when you need full query DSL.
- **Custom Threshold** for standard Observability alerting (logs, metrics, APM) with a good balance of power and usability.
- **Index Threshold** for simple "count > N" on any index when ES Query is overkill.

### APM rules vs Custom Threshold for APM data

The four dedicated APM rules (Anomaly, Error Count, Failed Transaction Rate, Latency) and Custom Threshold can both alert on APM data:

| Aspect | Dedicated APM rules | Custom Threshold on APM data |
|--------|--------------------|-----------------------------|
| Setup complexity | Low (service-aware UI) | Medium (must know APM metric fields) |
| Pre-built defaults | Yes (e.g. 1500ms latency) | No |
| ML anomaly support | Yes (APM Anomaly) | No |
| Multi-signal correlation | No (one metric per rule) | Yes (equations across metrics) |
| Grouping flexibility | By service/environment | By any field (up to 3) |

**Guidance:** Start with dedicated APM rules for per-service alerting. Graduate to Custom Threshold when you need multi-signal correlation (e.g. "alert when latency > X AND error rate > Y").

## Iteration #1 recommendation

Given the current data landscape (logs via Logstash, REST API traces via OTel -> APM, Synthetics coming soon), the following starter set provides immediate value and builds a foundation for future iterations.

### Recommended starter set

| Rule type | Why | Data source |
|-----------|-----|-------------|
| **Elasticsearch query** | Already deployed, most flexible, covers edge cases and non-standard indices | Any index |
| **Custom threshold** | Strategic choicesingle rule type for logs and APM data, replaces Log/Metric threshold going forward | `logs-*`, `traces-apm-*`, `metrics-*` |
| **Synthetics monitor status** | Direct replacement for Kuma HTTP health checks, native integration with Synthetics monitors already defined in `.monitor` files | `synthetics-*` |

### What this unlocks

- **Immediate value:** Log anomaly alerting (Custom Threshold on `logs-*`), HTTP health check replacement (Synthetics), trace-aware alerting (Custom Threshold on APM data).
- **Foundation:** Custom Threshold establishes the pattern that scales to metrics and more APM use cases in iteration #2.

### Iteration #2 APM-specific rules

Once APM data patterns are established and teams are familiar with alerting:

- **Error count threshold**simple per-service error spike detection
- **Failed transaction rate**percentage-based, normalizes for traffic volume
- **Latency threshold**p95/p99 latency alerting per service
- **APM Anomaly**ML-based behavioral detection (needs 2+ weeks of baseline data)

Since OTel traces are already flowing into APM, these are low-hanging fruit. The dedicated APM rules offer a simpler UX than Custom Threshold for service-specific alerting.

### Iteration #3+Advanced capabilities

- **ML Anomaly detection**behavioral alerting across any data set (requires defining ML jobs)
- **SLO burn rate**error budget management (requires SLO definitions)
- **Infrastructure rules**once system metrics collection is added via Elastic Agent

## References

- [Elastic alerting rule types](https://www.elastic.co/docs/explore-analyze/alerts-cases/alerts/rule-types)
- [ES Query rule](https://www.elastic.co/docs/explore-analyze/alerting/alerts/rule-type-es-query)
- [Index Threshold rule](https://www.elastic.co/docs/explore-analyze/alerts-cases/alerts/rule-type-index-threshold)
- [Custom Threshold rule](https://www.elastic.co/docs/solutions/observability/incident-management/create-custom-threshold-rule)
- [Log Threshold rule](https://www.elastic.co/guide/en/observability/current/logs-threshold-alert.html)
- [APM alerting](https://www.elastic.co/docs/solutions/observability/apm/create-apm-rules-alerts)
- [Synthetics monitor status rule](https://www.elastic.co/guide/en/observability/current/monitor-status-alert.html)
- [Synthetics TLS certificate rule](https://www.elastic.co/docs/solutions/observability/incident-management/create-tls-certificate-rule)
- [ML anomaly detection alerts](https://www.elastic.co/docs/explore-analyze/machine-learning/anomaly-detection/ml-configuring-alerts)
- [SLO burn rate rule](https://www.elastic.co/docs/solutions/observability/incident-management/create-an-slo-burn-rate-rule)
- [Kibana alerting privileges](https://www.elastic.co/docs/deploy-manage/users-roles/cluster-or-deployment-auth/kibana-privileges)
- [Uptime to Synthetics migration](https://www.elastic.co/observability-labs/blog/uptime-to-synthetics-guide)
