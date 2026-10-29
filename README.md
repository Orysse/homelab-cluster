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
   ├─ security/            CrowdSec, its bouncer, the deny policy
   └─ monitoring/          OpenTelemetry Collector, exporters, Grafana and its dashboards

apps/                      one app = one directory, listed in apps/kustomization.yaml
├─ site/                   plain-text page at the domain apex
├─ vitrine/                showcase site (image built in its own repository)
├─ holive/                 www.holive.fr, a portfolio (own certificate; holive.fr redirects)
├─ gatus/                  status page, status.${DOMAIN}
├─ glance/                 front page, home.int.${DOMAIN} (state read from Gatus, news feeds)
├─ headscale/              Tailscale control server, hs.${DOMAIN}
└─ open-webui/             chat UI for LLM APIs

tools/crowdsec-cilium-bouncer/   CrowdSec decisions -> CiliumCIDRGroups (Go)
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

Two Gateways (`infrastructure/configs/gateway.yaml`); a namespace label says which one its
routes may use:

| Gateway | Namespace label | Hostnames | Reachable from |
|---|---|---|---|
| `public` | `gateway-access: public` | any (`*.${DOMAIN}` certificate) | Internet (`.240`, port-forwarded) |
| `internal` | `gateway-access: internal` | `*.int.${DOMAIN}` | LAN and VPN (`.241`) |

`gateway-access: both` for an app with a public part and an internal admin UI. Anything with
an admin interface goes on `internal`. One exception: Headlamp (`k8s.${DOMAIN}`) is public
so that people can use it without the VPN; it has no rights of its own and acts with the
logged-in user's token.

TLS, the HTTP to HTTPS redirect, the security headers and the CrowdSec bouncer are applied by
Traefik's entry points (`infrastructure/configs/traefik.yaml`): apps need nothing for them.

## Network policies

A `CiliumNetworkPolicy` per namespace (`network-policy.yaml` next to each app,
`infrastructure/configs/network-policies/` for the platform): **deny by default in both
directions**, then what each component needs. Pods on the host network (Cilium, MetalLB
speakers, node-exporter, NFS CSI, Tetragon) are not policed.

| Building block | Rule |
|---|---|
| Reached through Traefik | `fromEndpoints` kube-system / `app.kubernetes.io/name: traefik`, on the container port |
| Cluster DNS | `toEndpoints` kube-system / `k8s-app: kube-dns`, port 53, with the `dns` rule (names in Hubble) |
| PostgreSQL, VictoriaMetrics on nuc1 | `toCIDR: ["${DATABASE_ADDRESS}/32"]` + port (outside the cluster: "world") |
| Kubernetes API | `toEntities: [kube-apiserver]`, port 6443 |
| One external name | `toFQDNs` + port, with the DNS rule above |
| Pocket-ID, any HTTPS | `toEntities: [world]`, port 443 (`auth.${DOMAIN}` goes out through the public address) |
| Nothing at all | `egress: [{}]`: without any egress rule, Cilium would not deny egress |

Kubelet probes are always allowed. To write or debug one, watch the real traffic in Hubble
(`hubble.int.${DOMAIN}`, or `hubble observe --namespace <ns> --verdict DROPPED` in a
`cilium` pod).

## Secrets

| Where | For | How |
|---|---|---|
| **OpenBao** (`bao.int.${DOMAIN}`) | application secrets | `kv/apps/<namespace>/<name>`, read through External Secrets |
| **sops** (in git) | bootstrap only: OpenBao's unseal key and initial PostgreSQL password | `*.sops.yaml`, below |

A namespace reads only `kv/apps/<its namespace>/*` and its own PostgreSQL credentials
(`database/postgres/static-creds/<namespace>`): templated policy, nothing to configure per
namespace. Secrets nobody needs to see (encryption keys) are generated by
vault-config-operator (`RandomSecret`); app databases get a static role in
`infrastructure/configs/openbao/database.yaml`, whose password OpenBao sets and rotates.
Examples: `apps/umami/secrets.yaml`, and the onboarding guide.

OpenBao's own configuration (engines, policies, roles) is in
`infrastructure/configs/openbao/config.yaml`, applied by vault-config-operator. Each object
has two conditions (`ReconcileFailed` from an earlier attempt can linger next to
`ReconcileSuccessful: True`): read both.

**sops + age.** Write the Secret in plaintext as `<path>/<name>.sops.yaml`, then
`sops --encrypt --in-place <file>`; edit with `sops <file>`. Recipients (`.sops.yaml`): the
admin's age key and YubiKey, and Flux's age key, generated on kube-1 and published by the
base as `flux-system/sops-age`. If that key changes: update `.sops.yaml`, then
`sops updatekeys` on each file.

## Access

Everyone logs in through **Pocket-ID** (`auth.${DOMAIN}`, passkeys); its groups decide the
rights:

| Group | Kubernetes (`oidc-rbac.yaml`) | Grafana | OpenBao | Network (Headscale ACL) |
|---|---|---|---|---|
| `admins` | cluster-admin | Admin | admin | the homelab (users listed in `apps/headscale/policy.json`) |
| `visitors` | `view` (no Secrets, no exec), plus the network CRDs | Viewer | none | internal gateway and Kubernetes API only |

The internal network is reached through **Tailscale**, with our own control server
(Headscale, `hs.${DOMAIN}`, Pocket-ID login); nuc1 routes the homelab subnet. WireGuard on
nuc1 stays as break-glass for the owner's laptop. OIDC clients are created in Pocket-ID's
admin UI; their secrets go to OpenBao (`kv/apps/<namespace>/oidc`, keys `client_id`,
`client_secret`).

Break-glass when Pocket-ID is down: the base's admin kubeconfig (client certificate,
`homelab-nix` context); OpenBao with the operator's identity (see `openbao/config.yaml`);
Grafana with the chart's admin password (`kubectl -n monitoring get secret grafana`).

## Runtime security

| What | Sees | Where to look |
|---|---|---|
| **CrowdSec** (`configs/crowdsec/`) | Traefik's access logs (scans, brute force, CVE probes) and the community blocklist; the Traefik bouncer answers 403 to banned IPs on the public entry point | `kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli decisions list` |
| **Tetragon** (`configs/tetragon.yaml`) | every process started in a pod, credential reads, writes under `/etc` | VictoriaLogs (namespace `kube-system`, container `export-stdout`); alerts `SuspiciousExecInPod`, `SensitiveFileAccessInPod` |

Unban an IP: `cscli decisions delete --ip <ip>`. LAN, VPN and pods are never checked by the
bouncer, and it fails open if CrowdSec is down.

## Rules

- Images and charts are **pinned** (tag / version), never `:latest`. Renovate opens pull
  requests to update them: read the release notes before merging, then follow with
  `flux get hr -A` and `flux get ks`. k3s and the Traefik it bundles are updated from
  homelab-nix.
- **No plaintext secrets**: the repository is public.
- Config files mounted from a ConfigMap go through `configMapGenerator` (hash-suffixed name:
  pods restart when the content changes).
- Before pushing: `kubectl kustomize apps > /dev/null` (and `infrastructure/configs`).
