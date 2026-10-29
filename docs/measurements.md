# Resource measurements

Before/after numbers for the v3 rewrite (`docs/superpowers/specs/2026-10-29-cluster-v3-design.md`).
Source: VictoriaMetrics on nuc1 (`http://192.168.1.200:8428`), 7-day window ending
2026-10-29. Memory in MB (10^6 bytes). The "v3" column is filled 7 days after the cutover,
with the same queries.

## Nodes

| Node | MemAvailable p50 | MemAvailable min | Swap used (now) | CPU busy p50 | CPU busy p95 | Pods | v3 |
|---|---|---|---|---|---|---|---|
| kube-1 (4000 MB, server) | 1026 | 737 | 274 | 13% | 14% | 12 | |
| kube-2 (3500 MB) | 1518 | 1269 | 175 | 11% | 11% | 31 | |
| kube-3 (3500 MB) | 1183 | 897 | 1361 | 33% | 41% | 23 | |
| nuc1 (host, 16 468 MB) | 4781 | 3030 | 2954 | 15% | 17% | | |

```
quantile_over_time(0.5, node_memory_MemAvailable_bytes[7d])
min_over_time(node_memory_MemAvailable_bytes[7d])
node_memory_SwapTotal_bytes - node_memory_SwapFree_bytes
quantile_over_time(0.5|0.95, (1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])))[7d:5m])
count by (node) (kube_pod_info)
```

kube-3 runs at about 3x the CPU of the other two and has 1.4 GB in zram swap.

## Namespaces (memory working set, average over 7 days, whole cluster)

| Namespace | MB | v3 |
|---|---|---|
| kube-system | 1664 | |
| monitoring | 989 | |
| open-webui | 440 | |
| crowdsec | 180 | |
| metallb-system | 178 | |
| flux-system | 176 | |
| external-secrets | 155 | |
| umami | 130 | |
| cert-manager | 111 | |
| headplane | 101 | |
| openbao | 90 | |
| opencost | 85 | |
| vault-config-operator | 69 | |
| pocket-id | 41 | |
| headlamp | 23 | |

```
avg_over_time((sum by (namespace) (container_memory_working_set_bytes{container!="",container!="POD"}))[7d:10m])
```

CPU per namespace is low everywhere (7-day average): monitoring 0.11 cores, kube-system
0.11, openbao, flux-system and crowdsec 0.03 each, the rest at or below 0.01.

## Per-node agents (memory, sum of the three nodes, average over 7 days)

| Container | MB | In v3 |
|---|---|---|
| cilium-agent | 844 | stays |
| alloy | 649 | replaced by the OpenTelemetry Collector |
| tetragon | 263 | removed |
| speaker (MetalLB) | 121 | removed (Cilium L2 announcements) |
| crowdsec-agent | 113 | depends on ADR 0003 |
| traefik | 80 | removed (Cilium Gateway) |
| cilium-envoy | 57 | stays, now carries Gateway traffic |

```
avg_over_time((sum by (container) (container_memory_working_set_bytes{container=~"..."}))[7d:10m])
```

Not measured: per-process RSS on nuc1 (microVMs, PostgreSQL, VictoriaMetrics,
VictoriaLogs). There is no process exporter, and this session had no SSH access to the
host. To add before the cutover: `ps -eo rss,comm --sort=-rss | head` on nuc1.
