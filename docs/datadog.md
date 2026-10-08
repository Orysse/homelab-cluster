# Datadog roadmap

How to take the homelab's Datadog setup from "agent installed" to something worth demoing:
every layer observed, one story from `git push` to a request trace, alerts that mean
something, and all of it as code.

Phases are ordered by value per effort. Each item says **where** it lives in the repos.

## Where we are (2026-10-08, evening)

| Layer | Collected | How |
|---|---|---|
| nuc1 (host) | system metrics, disk (real partitions only), journald logs, systemd unit states (VMs, virtiofsd, sshd, networkd, DDNS timer), WireGuard peers (`homelab.wireguard.peer.*`) | `homelab-nix/modules/host/datadog.nix`, `datadog-wireguard.nix` |
| Nodes, pods, containers | metrics, logs (all containers), live processes, orchestrator explorer, k8s events | `infrastructure/configs/datadog-agent.yaml` |
| Cluster state | kube-state-metrics core, OOM kills | same |
| cert-manager | `cert_manager.*` | agent auto-config |
| Flux | `fluxcd.*` (durations, errors), per-object state `kubernetes_state_customresource.flux_resource_info`, deploy events (`source:flux`) | `extraConfd`, `collectCrMetrics`, `flux-datadog.yaml` |
| Gatus | `gatus.*` | pod annotation (openmetrics) |
| Traefik | `traefik_mesh.*` metrics (official integration), JSON access logs with real client IPs, OTLP traces (`service:traefik`) | `datadog-agent.yaml`, `traefik.yaml` |
| CoreDNS | `coredns.*` | `extraConfd` (k3s image name) |
| Apps | `env`, `service`, `version` (= image tag) on site, vitrine, gatus | each app's `kustomization.yaml` |
| Alerts | 10 monitors in `datadog-monitors.yaml` (applied once the operator's monitor controller is on) | |

Not there yet: synthetic tests, real-user data, SLOs, dashboards in code, security signals,
control plane and etcd metrics. MetalLB is not collected.

Constraints to keep in mind:
- **RAM**: nodes are at 50–66% of 3–4 GB. The node agent uses ~100–140 MB, the cluster agent
  ~230 MB. Anything using **system-probe** (NPM, USM, CWS) adds roughly 150–300 MB per node.
  Enable those one at a time and watch `kubectl top nodes`.
- **Plan**: APM, logs, synthetics, RUM, NPM, CSM and SIEM are separate products. On a trial,
  everything works for 14 days; on the free plan, metrics keep 1 day and most of these
  stop. Check *Plan & Usage* before building on a product.
- **Custom metrics** are what gets expensive: `prometheusScrape` sends every series of every
  annotated pod. Prefer official integrations, and restrict what generic scraping collects.

---

## Phase 0 — Foundations (do first, everything else relies on it)

### 0.1 Unified service tagging
Datadog joins metrics, logs, traces and RUM through three tags: `env`, `service`,
`version`. Without them, nothing correlates.

- `env:homelab` everywhere: add it to `spec.global.tags` in `datadog-agent.yaml` and to the
  nuc1 agent's tags.
- On every app (Deployment metadata **and** pod template labels):
  ```yaml
  labels:
    tags.datadoghq.com/env: homelab
    tags.datadoghq.com/service: vitrine
    tags.datadoghq.com/version: "0.3.0"     # same value as the image tag
  ```
  The agent turns these into tags on the pod's metrics and logs, and injects `DD_ENV`,
  `DD_SERVICE`, `DD_VERSION` when APM is on. Renovate bumps the image tag; keep `version`
  in sync (same line or a kustomize `replacements`).
- Add the labels to the template in `README.md` ("Adding an app") so new apps get them.

### 0.2 Fix what is broken
- nuc1 disk check error (`homelab-nix/modules/host/datadog.nix`): likely btrfs
  subvolumes/virtual filesystems. Exclude pseudo filesystems (`file_system_exclude`) or
  mount points under `/var/lib/microvms/*/` that are not real disks.
- `agent status` on each node and the cluster agent should show no check in `[ERROR]`.

### 0.3 Rein in generic scraping
`prometheusScrape` is convenient but sends everything as custom metrics.
- Check *Metrics → Summary*, filter on `traefik_`, `metallb_`, `gatus.`: count series.
- Move to explicit configs with a `metrics:` allow-list (`prometheusScrape.additionalConfigs`
  or per-pod `ad.datadoghq.com/<container>.checks` annotations), then disable
  `enableServiceEndpoints` if nothing needs it.

**Done when**: *Infrastructure → Host Map* shows nuc1 + 3 nodes with no check errors, and
filtering any dashboard on `env:homelab service:vitrine` returns that app's data.

---

## Phase 1 — Coverage of every layer

### 1.1 Kubernetes control plane and k3s
- `features.controlPlaneMonitoring.enabled: true`, plus check what k3s exposes
  (apiserver metrics via the `kubernetes.default` endpoint, scheduler/controller-manager
  bind to localhost in k3s, so they may need `--kube-*-arg=bind-address=` flags in
  `homelab-nix/modules/k3s/node.nix`).
- etcd: k3s exposes embedded etcd metrics with `--etcd-expose-metrics` (server flag, Nix).
  Then the `etcd` integration on kube-1 (ad config or a cluster check). Restrict to node
  IPs; port 2381 should not be reachable from the VPN (same pattern as the audit fixes).
- CoreDNS: the agent ships an auto-config; confirm `coredns` shows in `agent status`.
- `features.oomKill.enabled: true` and `features.helmCheck.enabled: true` (Helm releases as
  metrics/events, covers the k3s Traefik release too).

### 1.2 Flux: "is git applied?"
Flux 2.9 controllers no longer export a ready/not-ready gauge (`gotk_reconcile_condition` is
gone; only `gotk_reconcile_duration_seconds` and controller-runtime counters remain).
Resource state comes from **kube-state-metrics custom resource metrics**:

```yaml
# datadog-agent.yaml
features:
  kubeStateMetricsCore:
    enabled: true
    collectCrMetrics:
      - groupVersionKind: { group: kustomize.toolkit.fluxcd.io, version: v1, kind: Kustomization }
        resourcePlural: kustomizations
        metricNamePrefix: gotk
        metrics:
          - name: resource_info
            help: Flux resource state
            each:
              type: Info
              info:
                labelsFromPath:
                  name: [metadata, name]
                  exported_namespace: [metadata, namespace]
                  ready: [status, conditions, "[type=Ready]", status]
                  revision: [status, lastAppliedRevision]
                  suspended: [spec, suspend]
    # same block for HelmRelease (helm.toolkit.fluxcd.io/v2) and GitRepository
    # (source.toolkit.fluxcd.io/v1)
```
This mirrors Flux's own monitoring example (`fluxcd/flux2-monitoring-example`,
kube-state-metrics config), which yields `gotk_resource_info{ready="True|False"}`. Verify the resulting metric names in
*Metrics → Summary* before writing monitors on them.

Then **deploy markers**: Flux's notification-controller can post events to Datadog.
```yaml
apiVersion: notification.toolkit.fluxcd.io/v1beta3
kind: Provider
metadata: { name: datadog, namespace: flux-system }
spec:
  type: datadog
  address: https://api.${DD_SITE}            # i.e. https://api.us5.datadoghq.com
  secretRef: { name: datadog-flux }          # key "token" = API key (sops)
---
apiVersion: notification.toolkit.fluxcd.io/v1beta3
kind: Alert
metadata: { name: datadog, namespace: flux-system }
spec:
  providerRef: { name: datadog }
  eventSeverity: info
  eventSources:
    - { kind: Kustomization, name: "*" }
    - { kind: HelmRelease, name: "*", namespace: "*" }
```
Every applied commit becomes a Datadog event. Overlay `sources:flux` on any timeseries and
you see exactly which push changed the curve. Lives in `clusters/homelab/` or
`infrastructure/configs/` (needs `${DD_SITE}`, so configs).

### 1.3 Traefik (the edge)
- **Access logs** as JSON: in `traefik.yaml` values, `logs.access.enabled: true`,
  `logs.access.format: json`. Annotate the Traefik pod so logs get `source:traefik`
  (`deployment.podAnnotations` → `ad.datadoghq.com/traefik.logs:
  '[{"source":"traefik","service":"traefik"}]'`): Datadog's Traefik pipeline parses them
  (status, duration, router, client IP). Add exclusion filters for health checks.
- **Metrics**: replace the generic scrape with an allow-list of
  `traefik_entrypoint_requests_total`, `traefik_router_requests_total`,
  `traefik_service_request_duration_seconds`, `traefik_tls_certs_not_after`, open
  connections.
- **Traces**: Traefik 3 exports OTLP. Enable the agent's OTLP receiver
  (`features.otlp.receiver.protocols.grpc.enabled: true`) and APM (`features.apm.enabled`),
  then set Traefik's `tracing.otlp.grpc.endpoint` to the node-local agent. Every request
  gets an edge span, even into apps that are not instrumented.

### 1.4 nuc1 and the VMs
- `systemd` integration on nuc1: watch `microvm@kube-{1,2,3}.service`, `ddclient`,
  `systemd-networkd`, `sshd`. A dead VM shows as a failed unit, not just a missing host.
- `journald` logs from nuc1 (sshd auth, wireguard, nixos-rebuild activations).
- `btrfs` integration for the host disk.
- WireGuard: no official integration. Options: `prometheus-wireguard-exporter` on nuc1
  scraped by the agent, or a small custom check (`wg show wg0 latest-handshakes`). Gives
  "laptop connected", last handshake, bytes per peer.
- A **host no-data monitor on nuc1**: if the NUC dies, nothing inside it can alert.

**Done when**: one click from a node, a pod, a route or a Flux Kustomization leads to its
metrics, logs and events, and every layer from the NUC to the HTTP route has data.

---

## Phase 2 — Outside-in and user view

### 2.1 Synthetic tests (external vantage point)
Gatus checks from inside the house (hairpin through the Livebox). It cannot see a dead
router, ISP outage or DNS issue. Synthetics can.
- API tests (HTTP) on `abe.lc`, `vitrine.abe.lc`, `status.abe.lc`: status 200, response
  time, from 2 locations (one EU, one US), every 5–15 minutes (they are billed per run).
- SSL test on `abe.lc`: alert at < 14 days.
- DNS test: `abe.lc` resolves, CAA present.
- One browser test on vitrine (page loads, CV link works), low frequency.
- Gatus keeps value as the internal view: an internal-OK / external-KO split means
  network/ISP, not the cluster.

### 2.2 RUM on vitrine
- Browser SDK in the Astro site (separate repo): `applicationId` and `clientToken` are
  public by design. Set `service: vitrine`, `env: homelab`, `version` from the build.
- Core Web Vitals, JS errors, page views per country. Session Replay with
  `defaultPrivacyLevel: mask`.
- **Consent**: RUM sets cookies; for EU visitors either ask consent
  (`trackingConsent: "not-granted"` until accepted) or document it clearly. Keep it clean
  since the site is your CV.
- `allowedTracingUrls` later, when vitrine calls a backend: links RUM sessions to APM
  traces.

### 2.3 SLOs
- `abe.lc availability` (synthetic-based, 99.5% over 30 days).
- `vitrine latency` (metric-based: share of Traefik requests under 300 ms, 99%).
- SLO widgets on the dashboard and a burn-rate monitor on each (fast and slow windows)
  instead of raw thresholds.

---

## Phase 3 — Alerting that means something

Rules: every monitor has an owner (you), a notification channel, a message saying what to
do (link to `docs/cheatsheet.md`), and should only fire when you would act.

Notification channel: the Datadog mobile app (push, free with the account) or a Discord/
Slack webhook integration. Email as fallback.

| Monitor | Type | Condition (adapt names after checking Metrics Summary) |
|---|---|---|
| nuc1 down | host / no data | `datadog.agent.up` on `host:nuc1`, no data 5 min |
| Node not ready | metric | `kubernetes_state.node.by_condition{condition:ready,status:true}` < 1 per node |
| Pod crash-looping | metric | `kubernetes_state.container.status_report.count.waiting{reason:crashloopbackoff}` > 0 for 10 min |
| Deployment degraded | metric | `replicas_available < replicas_desired` for 15 min, by `kube_deployment` |
| OOM kill | event/metric | `oom_kill.oom_process.count` > 0 |
| Flux not applying | metric | Kustomization / HelmRelease ready=False for 15 min (KSM CR metric, 1.2) |
| Flux reconcile errors | metric | `controller_runtime_reconcile_errors_total` rate > 0 for 30 min |
| Certificate expiring | metric | `cert_manager.certificate.expiration_timestamp - now()` < 14 days |
| Site down (outside) | synthetic | 2 locations failing |
| Status check failing (inside) | metric | Gatus endpoint success = 0 for 5 min, by endpoint |
| Disk filling | forecast | `system.disk.in_use` on nuc1, forecast > 90% within 7 days |
| Node memory | metric | `kubernetes.memory.usage / kubernetes_state.node.memory_allocatable` > 90% for 15 min |
| SLO burn | SLO | burn rate 14x over 1h, 2x over 24h |

Also:
- **Downtimes** during planned work (`nixos-rebuild switch` that restarts a VM).
- `renotify_interval` on critical ones, recovery notifications on.
- A monitor tagged `team:homelab`, `env:homelab`, to filter the Monitors page.

---

## Phase 4 — Dashboards

### 4.1 One overview, top-down
`Homelab — Overview`, readable on a phone, organised by layer, worst problems first:

1. **Status row**: monitor summary (alerting monitors), SLO widgets, synthetic results,
   certificate days left, last Flux applied revision (event stream `sources:flux`).
2. **Edge** (Traefik): requests/s by route, 4xx/5xx ratio, p95 latency by route, TLS
   handshakes.
3. **Apps**: per `service`: replicas, restarts, CPU/RAM vs requests/limits, RUM page
   views and LCP for vitrine.
4. **GitOps**: Kustomizations/HelmReleases ready (query value per object), reconcile
   duration p95, errors, deploy events overlaid.
5. **Cluster**: node CPU/RAM vs allocatable, pods per node, pending pods, etcd leader
   changes and fsync latency.
6. **Host**: nuc1 CPU, RAM split (host vs VMs), disk, network (br0, wg0), VM unit states,
   WireGuard handshakes.

Template variables: `node`, `kube_namespace`, `service`. Event overlay: `sources:flux` on
every timeseries. A Note widget at the top with links: status page, Traefik dashboard,
repos, cheatsheet.

Keep the out-of-the-box dashboards (Kubernetes, Flux, cert-manager, Traefik) for drill-
down; the overview links to them.

### 4.2 Dashboards and monitors as code
- Datadog Operator (already installed): enable the `DatadogMonitor` and `DatadogDashboard`
  controllers in `infrastructure/controllers/datadog-operator.yaml`
  (`datadogMonitor.enabled`, `datadogDashboard.enabled`,
  `datadogCRDs.crds.datadogDashboards`, `site`, `apiKeyExistingSecret` and
  `appKeyExistingSecret: datadog-secret`). Needs an **application key** (`app-key` in
  `datadog-secret.sops.yaml`), scoped to dashboards/monitors read+write. Add the key to
  the secret **before** enabling, or the operator pod (which also manages the agents)
  fails to start.
- Workflow: build the dashboard in the UI, *Export → JSON*, paste the widgets into a
  `DatadogDashboard` manifest under `infrastructure/configs/datadog/`. The UI becomes a
  sketchpad, git the source of truth. Same for monitors (`DatadogMonitor`).
- The `DatadogDashboard` CRD is young: if a widget type is not accepted, keep that
  dashboard as exported JSON in the repo and apply it with the API instead.

---

## Phase 5 — Deeper (pick by interest and RAM)

| Feature | What it gives here | Cost |
|---|---|---|
| **USM** (`features.usm`) | RED metrics (requests, errors, latency) for every HTTP service via eBPF, no code change | system-probe RAM |
| **NPM** (`features.npm`, `collectDNSStats`) | flow map: pod ↔ pod, VM ↔ VM over flannel-wg, DNS errors, retransmits | system-probe RAM |
| **APM + SSI** (`features.apm.instrumentation`) | auto-instrumentation of Python/Node/Java/.NET/Ruby/PHP pods via the admission controller | per-app memory |
| **Demo app** | small API instrumented with ddtrace + a Postgres (CloudNativePG) → traces, DBM, profiling, error tracking | one app |
| **CSM** (`features.cspm`, `features.cws`, `features.sbom`) | CIS benchmark for k3s, runtime threat detection, image vulnerabilities | system-probe RAM, product |
| **Cloud SIEM** | detection rules on sshd/WireGuard/Traefik logs (brute force, scans) | product |
| **Sensitive Data Scanner** | scrub tokens/IPs from logs | product |
| **Log-based metrics** | requests by status/route from Traefik logs, kept 15 months as metrics | custom metrics |
| **Remote Configuration** | change agent settings from the UI | none |

Suggested order: USM (biggest "wow" for no code) → demo app with APM → NPM → CSM.

---

## The demo story (what to show in 5 minutes)

1. **Overview dashboard**: all green, SLOs, last deploy event.
2. Push a change (e.g. a vitrine version bump from Renovate).
3. The Flux event appears on the dashboard; the `version` tag changes; Traefik latency
   and RUM split by version.
4. Break something on purpose (wrong image tag): Flux Kustomization not ready → monitor
   fires on the phone with a link to the runbook; synthetic still OK because the old
   ReplicaSet serves (explain why).
5. Open a Traefik trace → app span → logs of that exact request (trace/log correlation via
   unified tagging).
6. Show that all of it (agent config, monitors, dashboard) is in git, applied by Flux.

Be ready to explain: node agent vs cluster agent vs cluster checks, autodiscovery
(annotations, `ad_identifiers`), DogStatsD vs OTLP vs openmetrics, unified service
tagging, tag cardinality and why custom metrics cost, monitor types (metric, anomaly,
forecast, composite, SLO burn rate).

---

## Checklist

- [x] 0.1 `env:homelab` + unified service tags on site, vitrine, gatus
- [x] 0.2 nuc1 disk check fixed, no `[ERROR]` checks
- [x] 0.3 generic scrape replaced by official integrations (Traefik, CoreDNS)
- [ ] 1.1 control plane, etcd (oomKill done)
- [x] 1.2 Flux CR metrics + Datadog notification provider (deploy events)
- [x] 1.3 Traefik JSON access logs, metric allow-list, OTLP traces
- [x] 1.4 nuc1 systemd, journald, WireGuard, host no-data monitor (btrfs skipped: needs a Python integration)
- [ ] 2.1 synthetics (API, SSL, DNS, one browser test)
- [ ] 2.2 RUM on vitrine, with consent
- [ ] 2.3 two SLOs with burn-rate monitors
- [ ] 3 monitors in git (done), operator controller + app key, Notification Rule for team:homelab
- [ ] 4.1 overview dashboard
- [ ] 4.2 application key, operator controllers, dashboard and monitors in git
- [ ] 5 USM, then demo app with APM

## Lessons learned

- **The operator can only grant RBAC it holds.** `collectCrMetrics` on Flux objects made the
  operator add rules to the kube-state-metrics role; without `list/watch` on HelmReleases
  itself, *every* reconcile failed and no agent change was applied, silently. The read role
  is bound to the operator (`datadog-ksm-flux`). After any DatadogAgent change, check
  `kubectl -n datadog logs deploy/datadog-operator | grep "Reconciler error"`.
- **Validate before pushing**: `kubectl apply --dry-run=server` catches CRD schema errors
  (e.g. the required `info.path`) that `kustomize build` does not.
- **Autodiscovery matches the short image name**: k3s ships `rancher/mirrored-*` images, so
  the CoreDNS and Traefik auto-configs never matched.
- **`externalTrafficPolicy: Local`** on Traefik's Services, or every client IP in the access
  logs is a cluster address.
- **The NixOS agent module** assumes packaging paths (`/opt/datadog-agent/run`): `run_path`,
  `logs_config.run_path` and `dogstatsd_socket` are set explicitly.
- **Leader leases**: after restarting the cluster agent or the operator, the new pod waits
  for the old lease to expire (about a minute) before doing anything.
