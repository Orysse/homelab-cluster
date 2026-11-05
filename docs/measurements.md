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

## Three VMs to one: before (2026-11-05, same 7-day window, nuc1 up 11 days)

Memory in MB. "Used" is `MemTotal - MemAvailable`, so it leaves out pages in swap. Each VM
appears as two series in VictoriaMetrics (two label sets); the larger value is kept.

| Node | MemTotal | Used, max 7d | Used, p95 7d | Swap used (now) | CPU busy p95 |
|---|---|---|---|---|---|
| kube-1 (server) | 4007 | 2923 | 2895 | 622 | 23% |
| kube-2 | 3491 | 2483 | 2434 | 1026 | 13% |
| kube-3 | 3043 | 2387 | 2364 | 0 | 37% |
| Sum of the three VMs | 10 541 | 7793 | 7693 | 1648 | |
| nuc1 (host) | 16 468 | 12 265 | 11 903 | 3817 | 16% |

On nuc1, 7075 MB are shared memory (the guests' RAM, backed by memfd) and 1.3 GB of zram
holds 3.2 GB of swapped pages: kube-3 has only 770 MB of its RAM resident, the rest
is in the host's swap. The "after" columns are filled 7 days after the cutover, with the
same queries plus:

```
max_over_time((node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes)[7d:10m])
quantile_over_time(0.95, (node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes)[7d:10m])
```

## Host services on nuc1 (2026-11-05)

Read over SSH as root, read-only. PSS (`smaps_rollup` of the unit's processes) is memory
actually held by the unit; cgroup is `memory.current` (includes page cache); peak is
`MemoryPeak` since boot (11 days).

| Unit | PSS | cgroup | Peak |
|---|---|---|---|
| victoriametrics | 319 | 344 | 945 |
| victorialogs | 123 | 156 | 447 |
| garage | 34 | 63 | 89 |
| alertmanager | 27 | 41 | 56 |
| tailscaled | 26 | 52 | 65 |
| vmalert-homelab | 22 | 31 | 39 |
| crowdsec-firewall-bouncer | 19 | 27 | |
| prometheus-node-exporter | 16 | 21 | |
| prometheus-smartctl-exporter | 13 | 26 | |
| systemd-journal-upload | 9 | 2 | |
| postgresql | 4 | 18 | 128 |
| prometheus-wireguard-exporter | 1 | 3 | |
| trivy-scan (daily, 04:42) | not running | | 1368 |
| btrbk-data (hourly) | not running | | 17 |

Per VM, QEMU itself holds 1 to 4 MB of anonymous memory beyond the guest's RAM
(`RssAnon`); the guest RAM is shared memory, split in `smaps` between `qemu` and
`virtiofsd`, so the PSS of `microvm@*` and `microvm-virtiofsd@*` must not be read as the
VM's footprint. All non-VM processes together hold 588 MB of anonymous memory; the kernel's
slab is 378 MB.

## Sizing of kube-0 (approved by the owner, 2026-11-05)

Reserves on nuc1 (input to the derived-memory rule): base 1024, QEMU 128 per VM,
victoriametrics 768, victorialogs 384, garage 128, trivy 1280, other host services 384;
total 4096. Ceiling of the rule on a 16 384 MB host: 12 288.

| | MB |
|---|---|
The three VMs above already run v3 (since the cutover of 2026-10-29), so the 7693 MB are
v3's. The namespace table further up is v2's and is not used here.

| | MB |
|---|---|
| The three VMs, p95 "used" | 7693 |
| Three nodes become one: two fewer kernels, k3s agents, kubelets and containerd (about 900 each, estimated) and two fewer cilium-agents (844 / 3 = 281 each, measured above) | about -2360 |
| Used by one node | about 5300 |
| Pages swapped out inside the VMs now (cold, may not all come back) | 0 to 1650 |
| Need today | 5300 to 6900 |
| Phase 4: SeaweedFS (design cap 1500) and the music stack (estimate, not measured) | about 2300 |
| Need after phase 4 | 7600 to 9200 |

Decision (approved by the owner on 2026-11-05, on the first version of this table, which
started from v2's figures and gave 5.4 and 7.7 GB): `kube-0` gets **9216 MB** and 12 vCPU
(nuc1's cores). With the corrected range, 9216 covers the need after phase 4 with 0 to 20%
to spare, and leaves 3 GB on the host after the reserves. The rule's ceiling is 12 288, so
a larger size stays possible, at the cost of restarting `kube-0` (the only node): measure
after the migration and again after phase 4 before choosing. Floor for the assertion:
**6912** (9216 minus 25%). Larger is not free: without a balloon a guest's page cache fills
its RAM and the host cannot take it back, which is how kube-3 ended up in the host's swap.
Each size change needs the owner's approval.

Estimated, not measured: the 900 MB per node (k3s agent, kubelet, containerd, kernel), the
music stack's memory, and how much of the 1650 MB in swap is hot.

## SeaweedFS spike (2026-11-05)

Master + filer + volume + CSI pods: ~380 MiB idle, ~690 MiB during a 10 000-file Navidrome scan, ~1.5 GiB peak while a 4 GB torrent was written (the CSI mount cache, 1.1 GiB, then released). Details: `spikes/seaweedfs/README.md`.
