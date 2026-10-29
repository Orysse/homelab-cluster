# Cluster v3: design

Date: 2026-10-29. Status: draft, awaiting the owner's approval.

## Intent

The cluster works, but it grew by accretion: Cilium and Traefik both sit in the data path,
MetalLB does what Cilium already can, CrowdSec hangs off a Traefik plugin downloaded at
start, four tools handle secrets. v3 is a near-complete rethink of `homelab-cluster` (and
of the services running directly on nuc1) that keeps **the same purpose** and changes any
**means** that has a better, more modern answer.

Readers of the code: recruiters and platform engineers (they see the repository, not the
running cluster). What they should take away: a clean, coherent
cluster where each component has one job, each choice is argued, and the whole thing fits
small hardware. Side goal: use less CPU and RAM than today.

## Guiding principle

**Everything in its most natural and clearest form.** No abstraction for its own sake.
Uniformity is not a goal: an app with a good upstream chart uses a HelmRelease, a small
app without one is plain manifests (Deployment, Service, HTTPRoute, policy). A shared
kustomize component is allowed only where it makes reading easier (e.g. a deny-by-default
policy baseline). A reader must understand any file without knowing a hidden convention.
No in-house CRD layer (kro, Crossplane and similar were considered and rejected for this
reason).

Experimental components are welcome when they bring something real, provided they are
documented (an ADR stating why, and the fallback) and do not make the cluster fragile.

## Goals

- Same services as today for the kept apps (list below), same access model (Pocket-ID
  groups `admins` / `visitors`, Lenny as cluster admin, Headscale VPN, public vs internal
  gateways).
- One data plane: Cilium does CNI, kube-proxy replacement, load-balancer IPs, Gateway API
  and network policy.
- Ready for 4 hosts: today nuc1 alone; within months, three NUC7 added. Going from 1 to 4
  hosts must be "add entries to the topology", not a redesign.
- Monitoring answers: state of the host and the cluster (with alerts), and good-looking
  dashboards. Electricity cost is a secondary goal (see Observability).
- Measurably lighter than today (RAM and CPU per node, measured before and after).

## Non-goals

- Changing the layer below: NixOS microVMs (microvm.nix) stay, k3s stays, Tailscale stays.
- Distributed tracing (the apps are not instrumented; it would be decoration).
- Zero-downtime migration.
- A new repository: v3 is a rewrite **in `homelab-cluster`**, history kept.

## Anti-goals (failure even if it works)

- An abstraction layer a reader has to learn before reading an app.
- Trendy tools stacked for show, or two tools doing one job.
- Something experimental that leaves the cluster broken when a recruiter looks at it.
- Busting the hardware budget (see constraints): the 2026-10-11 memory collapse must not
  repeat.

## Constraints

- **Hardware today**: nuc1, NUC10i7FNH, 6 cores / 12 threads, 16 GB RAM, 500 GB NVMe.
  Three microVMs (kube-1 server 4000 MB, kube-2/3 agents 3500 MB, 2 vCPU each).
- **Hardware soon**: three NUC7, probably 16 GB RAM and 500 GB each (to confirm when
  bought), **weak CPUs** (likely 2 cores / 4 threads). CPU, more than RAM, becomes the
  scarce resource: every per-node agent counts.
- VM sizes and configuration may be changed for v3 (owner's OK, 2026-10-29), keeping the
  host's performance in mind. Measure before resizing.
- All hosts on the same LAN (192.168.1.0/24). Router forwards TCP 80/443 to the public
  ingress IP, UDP 51820 and 41641 to nuc1.
- Domain `abe.lc` (Cloudflare DNS, DNS-01 certificates), plus `holive.fr`.
- Network variables still come from homelab-nix's topology (`flux-system/cluster-vars`).

## Decisions taken with the owner

### Kubernetes distribution

**k3s, stripped to upstream Kubernetes.** Disable everything k3s bundles that the platform
declares itself: Traefik, servicelb, local-storage, metrics-server if unused, flannel,
kube-proxy (already done for the last two). k3s is then a distribution choice, not a
shortcut. RKE2 was considered (the owner likes it): rejected because its separate
control-plane processes cost roughly +0.5 to 1 GB on the server and +100 to 200 MB per
agent (estimate, not measured), which eats the savings of v3, for CIS/FIPS benefits that
matter little here. Write it as an ADR.

### Topology

- Target: control plane HA with three k3s servers on three **different hosts** once the
  NUC7 arrive (etcd quorum survives the loss of a machine). Today's three VMs on one host
  protect from nothing.
- On a NUC7: one VM, at most two (each VM has a fixed cost: kernel, kubelet, Cilium).
- The design must work today with nuc1 alone.

### Network

- **Cilium Gateway API** (its embedded Envoy) replaces Traefik. Two Gateways as today:
  `public` (Internet, port-forwarded IP) and `internal` (`*.int.${DOMAIN}`, LAN and VPN).
  Keep the namespace-label rule for which gateway a namespace may use.
- **Cilium LB-IPAM + L2 announcements** replace MetalLB. Same addresses (`.240` public,
  `.241` internal, pool `.240-.254`).
- TLS, HTTP to HTTPS redirect and security headers move from Traefik entry points to the
  Gateways / HTTPRoute filters.
- **Network policies**: keep today's model (one `CiliumNetworkPolicy` per namespace, deny
  by default in both directions, then what each component needs). It is already good.
- The real client IP must still reach the logs and the ban logic.

### Blocking scanners

The owner wants the **effect** (scanners and bots blocked), not CrowdSec as such.
CrowdSec stays as the **detection** side only: the community blocklist does most of the
work, local scenarios on the Envoy access logs catch the rest (droppable if too
CPU-heavy). **Enforcement moves into Cilium**: ban decisions synced into a
`CiliumCIDRGroup` referenced by a clusterwide policy denying ingress from those CIDRs, so
banned traffic is dropped in eBPF before reaching Envoy. No plugin or bouncer in the
request path. Putting the public sites behind Cloudflare's proxy was rejected (moves the
effort out of the cluster, and Headscale cannot be proxied).

### Deployment

**Flux stays**, managed by the **Flux Operator** (`FluxInstance`) instead of manifests
generated by Nix. Same daily workflow: push to `main`, the cluster converges. Renovate
stays.

### Secrets

Scaling here means **more machines**, not more people writing secrets.

- **OpenBao** stays the source of application secrets, with the templated policy
  "a namespace reads only `kv/apps/<ns>/*`".
- **External Secrets** stays the bridge to pods.
- **sops** only for bootstrap (OpenBao unseal key, Flux's age key) and nothing else.
- **vault-config-operator goes.** OpenBao's configuration (engines, policies, roles)
  becomes declarative another way, e.g. OpenBao's declarative self-initialization (2.4+);
  check what it covers.
- **OIDC client credentials are no longer copied by hand**: a Pocket-ID operator (if a
  maintained one exists; otherwise a small controller) creates the client from an object
  in git and writes its credentials where the app reads them.
- PostgreSQL credentials: from CloudNativePG (see below) rather than OpenBao's database
  engine, unless OpenBao rotation keeps a clear advantage. Builder's call, argued.

### Data

- **PostgreSQL moves into the cluster with CloudNativePG.** One instance today, a replica
  on a NUC7 later by changing one number. Local disk (CNPG replicates itself, no NFS, no
  replicated block storage under it). Continuous backups (WAL archiving + base backups) to
  S3. Target: **Garage on the owner's Synology NAS**, which will come later (probably
  after the NUC7). Until then: Garage as a NixOS service on nuc1, outside the VMs, on its
  own btrfs subvolume included in btrbk snapshots. It protects against losing the
  cluster, not the disk, which is no worse than today. Moving to the NAS is a change of
  endpoint. One database per app, as today.
- Small app files (open-webui uploads, gatus state) stay on NFS for now. Replicated block
  storage (Piraeus/LINSTOR, DRBD in the kernel, light on CPU) only with the NUC7, and only
  if those files still justify it. Longhorn (CPU-heavy) and Mayastor (pins cores) ruled
  out.
- The PostgreSQL service on nuc1 goes once data is migrated.

### Observability

- **Storage and alerting stay outside the cluster, on nuc1**: VictoriaMetrics,
  VictoriaLogs, vmalert, Alertmanager, Healthchecks.io heartbeat, alert emails. The watcher
  does not live inside what it watches. Unchanged.
- **Collection: OpenTelemetry Collector** (DaemonSet, plus what is needed for cluster-level
  metrics) replaces Alloy. Pipeline readable as standard OTel.
- **Electricity (secondary, last phase): Kepler**, software estimate (no smart plug).
  Scope: the NUCs only, one flat kWh price as a parameter; no NAS/router, no time-of-day
  tariff. RAPL is not visible inside
  microVMs, so measure on each host, attribute to VMs, then split to pods (e.g. by CPU
  share in a recording rule). Add a constant for what RAPL does not see (PSU, disk, NIC),
  labelled honestly as an estimate on the dashboard. Output: cost in € per month, per
  host, per namespace.
- **Hubble** for network visibility (UI and metrics).
- **Grafana** on the internal gateway only (`admins` edit, `visitors` read-only); nothing
  observability-related is public. Recruiters read the code, not live dashboards;
  `visitors` are mostly friends, occasionally a recruiter.
- **Grafana** with a small set of polished dashboards as code: overview (host + cluster),
  electricity, network.

### Apps

| App | v3 |
|---|---|
| site | kept; nginx replaced by `static-web-server` |
| vitrine, holive | kept as is (own images) |
| gatus | kept |
| glance | kept |
| headscale | kept (policy, tags such as `tag:gamehost` unchanged) |
| open-webui | kept, without Chroma (document search is off anyway) |
| umami, oxymore, opencost, headplane | removed |

Platform:

| Component | v3 |
|---|---|
| Pocket-ID | kept, plus an operator for OIDC clients |
| oauth2-proxy | only as a reverse proxy in front of UIs without native OIDC (Hubble UI); apps with native OIDC (Grafana, OpenBao, Headlamp) use it directly |
| Headlamp | kept |
| cert-manager, External Secrets, csi-driver-nfs | kept |
| Traefik, MetalLB, vault-config-operator, Tetragon, Alloy | removed |
| CrowdSec | detection only, enforcement in Cilium |

### Migration

Hard cutover is acceptable: everything may go down temporarily, the owner works on site.
Rebuild from scratch rather than transform in place. Data to carry over:

- Pocket-ID users and passkeys (otherwise everyone re-registers);
- OpenBao secrets (export before shutting down);
- Headscale state (registered nodes; otherwise every device reconnects);
- open-webui and gatus data; any database still in use.

## Left to the builder

- Order of the work, phasing, and how to spike the risky parts first. Suggested spikes:
  CrowdSec to `CiliumCIDRGroup` at community-blocklist scale (tens of thousands of IPs:
  check Cilium's ipcache/policy limits and update cost); Cilium Gateway with L2
  announcements keeping the client IP; Kepler attribution through microVMs.
- Whether a maintained CrowdSec-to-Cilium bouncer and a Pocket-ID operator exist, or a
  small controller must be written.
- VM sizes and count on nuc1 for v3, measured, within the host's 16 GB.
- Where Grafana runs (an earlier plan moved it to nuc1 to free cluster memory; keep or
  revisit, argued).
- Repository layout, as long as it follows the guiding principle and the README explains
  it.
- Whether k3s's metrics-server and CoreDNS stay bundled or are declared.
- ADRs: one per significant choice above (distribution, data plane, scanner blocking,
  secrets, PostgreSQL, observability), short.
- Before/after measurements of RAM and CPU per node, written into the docs.

## Calls made by Claude, to check

- Grafana dashboards: three (overview, electricity, network).
- PostgreSQL credentials from CNPG instead of OpenBao's database engine (builder may keep
  OpenBao if argued).
- NFS kept for small app files until the NUC7 arrive.
- No tracing.
- Control plane: one k3s server today (already embedded etcd, `clusterInit`); the NUC7
  bring two more servers joining that etcd. No three-server rehearsal on nuc1 (it would
  cost RAM and protect from nothing on one host).
- If the `CiliumCIDRGroup` spike fails at full community-blocklist scale: enforce a
  trimmed list (local decisions plus the highest-value community lists) in Cilium. The ban
  never goes back into the request path.
