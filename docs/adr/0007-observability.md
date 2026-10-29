# ADR 0007: Observability with the OpenTelemetry Collector

Status: accepted (2026-10-29). Series and log fields compared with v2 at cutover.

## Context

v2 collected with Grafana Alloy, one per node (649 MB for three, the largest agent after
Cilium: `docs/measurements.md`). It scraped Prometheus endpoints, read container logs and
shipped both to VictoriaMetrics and VictoriaLogs on nuc1, where vmalert evaluates the
alert rules. Those stores and the rules stay: they live below the cluster, so alerts still
fire when the cluster is down.

## Decision

- **OpenTelemetry Collector** (`otelcol-k8s` distribution, DaemonSet), one per node, each
  handling only its own node, as Alloy did. Same scrape jobs: annotated pods, CoreDNS,
  Hubble, kube-state-metrics (`honor_labels`), kubelet and cAdvisor (API server, etcd and
  workqueue histogram buckets dropped), plus `cilium-envoy`, new: the Gateways' HTTP
  statistics. Logs: `filelog` on `/var/log/pods` with the `container` operator, read
  positions kept on the node (`file_storage`), `app` from the pod label (`k8sattributes`).
- **OTLP all the way.** Metrics to VictoriaMetrics' `/opentelemetry` endpoint, logs to
  VictoriaLogs' `/insert/opentelemetry`. No Prometheus remote-write: the vendor-neutral
  protocol is the one both stores speak, and the `otelcol-k8s` distribution does not ship
  the remote-write exporter.
- **Prometheus names and labels kept**, because the alert rules on nuc1 use them
  (`up{job="kubelet"}`, `instance`, `namespace`, `node`). The Prometheus receiver keeps
  metric names as scraped but moves `job` and `instance` to the resource, and
  VictoriaMetrics would turn every resource attribute into a label with a dotted name. A
  `transform` processor puts `job`, `instance` and `cluster` back on each data point and
  clears the resource. Logs keep v2's fields: `namespace`, `pod`, `container`, `app`,
  `node`, `cluster` (stream fields `namespace,pod,container`).
- **Grafana keeps nothing**: SQLite on an emptyDir, datasources and dashboards provisioned,
  login through Pocket-ID (its client declared next to it, ADR 0004). Its PostgreSQL
  database in v2 held no state worth keeping.
- **Dashboards**: `Vue d'ensemble` (nuc1 and the cluster on one page), `Réseau` (Gateways,
  drops, bans, the Gateways' access log), `Vulnérabilités` (Trivy on nuc1), generated from
  `.jq` sources; community dashboards (node exporter, Kubernetes, Cilium, Hubble,
  CloudNativePG, Flux) at pinned revisions.
- **Alerts** stay in vmalert on nuc1 (homelab-nix): Tetragon's rules go with Tetragon, and
  a stale PostgreSQL backup (over 30 hours) alerts.

## Not chosen

- Keep Alloy: it works, but it is a Grafana-specific pipeline language; the collector's
  configuration is the industry's common one, and its receivers cover the same ground.
- `otel/opentelemetry-collector-contrib` for the remote-write exporter: a larger image for
  a protocol the stores do not need.
- Tracing: no app here emits traces worth storing (spec).
