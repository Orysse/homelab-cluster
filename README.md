# homelab-cluster

What runs **inside** the homelab's k3s cluster, applied by [Flux](https://fluxcd.io)
(GitOps): push to `main`, and the cluster converges. The machines (NUC, microVMs, k3s, the
Flux installation itself) live in [homelab-nix](https://github.com/Orysse/homelab-nix).

**New here?** Start with [docs/onboarding/](docs/onboarding/) (in French): getting access,
then deploying an app from a ready-made template. Day-to-day commands:
[docs/cheatsheet.md](docs/cheatsheet.md).

## Layout = application order

```
clusters/homelab/          Flux entry point (the FluxInstance in homelab-nix syncs it)
├─ infrastructure.yaml     infra-controllers -> infra-configs
└─ apps.yaml               apps (after infra-configs)

infrastructure/
├─ controllers/            what installs CRDs: cert-manager, External Secrets, csi-driver-nfs,
│                          local-path-provisioner, CloudNativePG, CrowdSec, Pocket-ID operator
└─ configs/                what uses them, by concern:
   ├─ network/             IP pool, L2 policy, Gateways, certificates, platform policies
   ├─ secrets/             OpenBao, the cluster secret store
   ├─ postgres/            the shared PostgreSQL cluster, its backups, one file per database
   ├─ identity/            Pocket-ID, oauth2-proxy, OIDC RBAC, Headlamp
   ├─ security/            CrowdSec (detection; bans are enforced on the hosts)
   └─ monitoring/          OpenTelemetry Collector, exporters, Grafana and its dashboards

apps/                      one app = one directory, listed in apps/kustomization.yaml
├─ site/                   plain-text page at the domain apex
├─ vitrine/                showcase site (image built in its own repository)
├─ holive/                 www.holive.fr, a portfolio (own certificate; holive.fr redirects)
├─ gatus/                  status page, status.${DOMAIN}
├─ glance/                 front page, home.int.${DOMAIN} (state read from Gatus, news feeds)
├─ headscale/              Tailscale control server, hs.${DOMAIN}
└─ open-webui/             chat UI for LLM APIs

docs/adr/                  architecture decisions
docs/onboarding/           access, deploying an app, visitor tour (French); modele/ = app template
```

Each level waits for the previous one (`dependsOn`).

## Variables from the base

The network is defined **once**, in homelab-nix's topology, which publishes the
`flux-system/cluster-vars` ConfigMap. Flux substitutes these in `infrastructure/configs` and
`apps`:

| Variable | Value | Used for |
|---|---|---|
| `${DOMAIN}` | `abe.lc` | hostnames, certificates |
| `${INGRESS_ADDRESS}` | `192.168.1.240` | public entry point (Gateway `public`) |
| `${INTERNAL_ADDRESS}` | `192.168.1.241` | internal entry point (LAN and VPN only) |
| `${INGRESS_POOL_START}`, `${INGRESS_POOL_STOP}` | `192.168.1.240`, `192.168.1.254` | LoadBalancer IPs Cilium may assign |
| `${CLUSTER_NAME}` | `homelab` | `cluster` label on metrics and logs |
| `${NFS_SERVER}`, `${NFS_SHARE}` | `192.168.1.200`, `/srv/data` | StorageClass `nfs` |
| `${MONITORING_ADDRESS}` | `192.168.1.200` | VictoriaMetrics/VictoriaLogs/Alertmanager |
| `${BACKUP_ADDRESS}` | `192.168.1.200` | S3 (Garage) for PostgreSQL backups |

Flux also rewrites `$${X}` to `${X}`, for software that does its own substitution. An
object full of `$` (a Grafana dashboard, a script) gets the annotation
`kustomize.toolkit.fluxcd.io/substitute: disabled`.

## Apps and routing

Adding an app: [docs/onboarding/02-deployer-une-app.md](docs/onboarding/02-deployer-une-app.md),
from `docs/onboarding/modele/`. In short: a directory under `apps/` with the Namespace,
Deployment, Service, HTTPRoute and network policy, one line in `apps/kustomization.yaml`.

Cilium serves the Gateways with the Envoy it already runs on each node (no ingress
controller) and announces their addresses on the LAN ([ADR 0002](docs/adr/0002-cilium-data-plane.md)).
Two Gateways in the namespace `gateway` (`infrastructure/configs/network/gateways.yaml`);
a namespace label says which one its routes may use:

| Gateway | Namespace label | Hostnames | Reachable from |
|---|---|---|---|
| `public` | `gateway-access: public` | any (`*.${DOMAIN}` certificate) | Internet (`.240`, port-forwarded) |
| `internal` | `gateway-access: internal` | `*.int.${DOMAIN}` | LAN and VPN (`.241`) |

`gateway-access: both` for an app with a public part and an internal admin UI. Anything with
an admin interface goes on `internal`. One exception: Headlamp (`k8s.${DOMAIN}`) is public
so that people can use it without the VPN; it has no rights of its own and acts with the
logged-in user's token.

TLS and the HTTP to HTTPS redirect are the Gateways' job. Security headers are set by each
route (`ResponseHeaderModifier`): Gateway API has no gateway-wide filter, so they sit next to
the app, visible. Every request is written to the Gateways' access log, in nginx's format
(CrowdSec reads it, so does VictoriaLogs).

## Network policies

A `CiliumNetworkPolicy` per namespace (`network-policy.yaml` next to each app,
`infrastructure/configs/network/policies/` for the platform): **deny by default in both
directions**, then what each component needs. Pods on the host network (Cilium,
node-exporter, NFS CSI) are not policed.

| Building block | Rule |
|---|---|
| Reached through a Gateway | `fromEntities: [ingress]` (Cilium's Envoy), on the container port |
| Cluster DNS | `toEndpoints` kube-system / `k8s-app: kube-dns`, port 53, with the `dns` rule (names in Hubble) |
| Its PostgreSQL | `toEndpoints` postgres / `cnpg.io/cluster: main`, port 5432 |
| The monitoring host | `toCIDR: ["${MONITORING_ADDRESS}/32"]` + port (outside the cluster: "world") |
| Kubernetes API | `toEntities: [kube-apiserver]`, port 6443 |
| One external name | `toFQDNs` + port, with the DNS rule above |
| Pocket-ID | `toFQDNs: auth.${DOMAIN}` and `toEntities: [ingress]`, port 443 (through the public Gateway) |
| Nothing at all | `egress: [{}]`: without any egress rule, Cilium would not deny egress |

Kubelet probes are always allowed. To write or debug one, watch the real traffic in Hubble
(`hubble.int.${DOMAIN}`, or `hubble observe --namespace <ns> --verdict DROPPED` in a
`cilium` pod).

## Secrets

| Where | For | How |
|---|---|---|
| **OpenBao** (`bao.int.${DOMAIN}`) | application secrets | `kv/apps/<namespace>/<name>`, read through External Secrets |
| **Pocket-ID operator** | OIDC clients | a `PocketIDOIDCClient` next to the app writes its credentials Secret |
| **sops** (in git) | bootstrap only: OpenBao's unseal key | `*.sops.yaml`, below |

A namespace reads and writes only `kv/apps/<its namespace>/*`: one templated policy, nothing
to configure per namespace. OpenBao's whole configuration (mounts, auth, policies, roles) is
its self-initialization, in `infrastructure/configs/secrets/openbao.yaml`
([ADR 0005](docs/adr/0005-secrets.md)). Three kinds of secrets:

- **Written by a person** (API keys, the SMTP password): in OpenBao's UI, then an
  `ExternalSecret` reads them.
- **Generated, nobody sees them** (encryption keys): an `ExternalSecret` with the
  `password` ClusterGenerator makes a candidate once, a `PushSecret` (`IfNotExists`) keeps
  it in OpenBao, an `ExternalSecret` reads it back. OpenBao holds the value, so recreating
  the objects never changes it. Example: `apps/headscale/secrets.yaml`.
- **Database credentials**: the same flow in `infrastructure/configs/postgres/databases/<app>.yaml`
  writes `kv/apps/<app>/db` (`username`, `password`); CloudNativePG sets the role's password
  from it, the app reads it like any other secret ([ADR 0006](docs/adr/0006-postgresql.md)).

**sops + age.** Write the Secret in plaintext as `<path>/<name>.sops.yaml`, then
`sops --encrypt --in-place <file>`; edit with `sops <file>`. Recipients (`.sops.yaml`): the
admin's age key and YubiKey, and Flux's age key, generated on kube-1 and published by the
base as `flux-system/sops-age`. If that key changes: update `.sops.yaml`, then
`sops updatekeys` on each file.

## Data

| What | Where | Backup |
|---|---|---|
| Databases (Pocket-ID, Headscale, Open WebUI) | CloudNativePG `main`, local volume on its node | nightly base backup + WAL to Garage (S3) on nuc1, 30 days |
| OpenBao, Open WebUI uploads | NFS from nuc1 (StorageClass `nfs`) | btrbk snapshots on nuc1 |
| Metrics, logs | VictoriaMetrics, VictoriaLogs on nuc1 | none (90 and 30 days kept) |

## Access

Everyone logs in through **Pocket-ID** (`auth.${DOMAIN}`, passkeys); its groups decide the
rights:

| Group | Kubernetes (`oidc-rbac.yaml`) | Grafana | OpenBao | Network (Headscale ACL) |
|---|---|---|---|---|
| `admins` | cluster-admin | Admin | admin | the homelab (users listed in `apps/headscale/policy.json`) |
| `visitors` | `view` (no Secrets, no exec), plus the network CRDs | Viewer | none | internal gateway and Kubernetes API only |

Pocket-ID is run by its operator; the groups are `PocketIDUserGroup`s, each app declares
its OIDC client ([ADR 0004](docs/adr/0004-oidc-clients.md)). The internal network is
reached through **Tailscale**, with our own control server (Headscale, `hs.${DOMAIN}`,
Pocket-ID login); nuc1 routes the homelab subnet. WireGuard on nuc1 stays as break-glass
for the owner's laptop.

Break-glass when Pocket-ID is down: the base's admin kubeconfig (client certificate,
`homelab-nix` context); OpenBao through the `break-glass` role (header of
`secrets/openbao.yaml`); Grafana with the chart's admin password
(`kubectl -n monitoring get secret grafana`).

## Observability

One OpenTelemetry Collector per node sends metrics and logs to VictoriaMetrics and
VictoriaLogs on nuc1, below the cluster: alerts (vmalert, on nuc1) still fire when the
cluster is down ([ADR 0007](docs/adr/0007-observability.md)). Grafana
(`grafana.int.${DOMAIN}`) keeps nothing: datasources and dashboards are provisioned. Our
dashboards: overview, network, vulnerabilities, electricity (a software estimate from RAPL).

## Scanner blocking

CrowdSec reads the Gateways' access log and the community blocklist. CrowdSec's own
firewall bouncer, on the physical hosts (homelab-nix), pulls the bans from the LAPI into
nftables and drops those addresses before they reach a VM; if CrowdSec is down, the bans
stay until they expire ([ADR 0003](docs/adr/0003-scanner-blocking.md)).
`kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli decisions list`; unban:
`cscli decisions delete --ip <ip>`. LAN, VPN and pods are whitelisted.

## Decisions

[docs/adr/](docs/adr/): one page each, context, decision, what was rejected.

## Rules

- Images and charts are **pinned** (tag / version), never `:latest`. Renovate opens pull
  requests to update them: read the release notes before merging, then follow with
  `flux get hr -A` and `flux get ks`. k3s and Cilium are updated from homelab-nix.
- **No plaintext secrets**: the repository is public.
- Config files mounted from a ConfigMap go through `configMapGenerator` (hash-suffixed name:
  pods restart when the content changes).
- Every pull request runs `scripts/validate.sh`: what Flux would apply builds, and matches
  the Kubernetes and CRD schemas. Run it before pushing.
