# homelab-cluster

What runs **inside** the homelab's k3s cluster, applied by [Flux](https://fluxcd.io)
(GitOps): push to `main`, and the cluster converges. No manual `kubectl apply`.

The machines (NUC, microVMs, k3s, Flux installation) live in the base repository,
`homelab-nix`, written in Nix.

## Layout = application order

```
clusters/homelab/          Flux entry point (the base points here)
├─ infrastructure.yaml     infra-controllers -> infra-configs
└─ apps.yaml               apps (after infra-configs)

infrastructure/
├─ controllers/            what installs CRDs: MetalLB, cert-manager, csi-driver-nfs,
│                          External Secrets, vault-config-operator
└─ configs/                what uses them: MetalLB IP pool, Traefik settings, Gateways,
                           security headers, Let's Encrypt issuers, wildcard certificate,
                           storage class, monitoring (Alloy, kube-state-metrics, node-exporter,
                           Grafana), OpenBao, Pocket-ID, Headlamp, OIDC RBAC

apps/                      one app = one directory, listed in apps/kustomization.yaml
├─ site/                   plain-text page (index.txt) at the domain apex
├─ vitrine/                showcase site (image built in its own repository)
├─ gatus/                  status page at status.${DOMAIN}
├─ umami/                  web analytics for vitrine (tracker public, dashboard internal)
└─ holive/                 www.holive.fr, a portfolio (own certificate and listeners; holive.fr redirects)
```

Each level waits for the previous one to be ready (`dependsOn`).

## Variables from the base

The network is defined **once**, in the base's Nix topology, which publishes the
`flux-system/cluster-vars` ConfigMap. Flux substitutes these variables in
`infrastructure/configs` and `apps`:

| Variable | Value | Used for |
|---|---|---|
| `${DOMAIN}` | `abe.lc` | HTTPRoute hostnames, certificate |
| `${INGRESS_ADDRESS}` | `192.168.1.240` | Traefik's LoadBalancer IP |
| `${INTERNAL_ADDRESS}` | `192.168.1.241` | Traefik's internal IP (LAN/VPN only) |
| `${INGRESS_POOL}` | `192.168.1.240-192.168.1.254` | IPs MetalLB may assign |
| `${CLUSTER_NAME}` | `homelab` | `cluster` label on metrics and logs |
| `${NFS_SERVER}`, `${NFS_SHARE}` | `192.168.1.200`, `/srv/data` | StorageClass `nfs` (volumes on the storage host) |
| `${MONITORING_ADDRESS}` | `192.168.1.200` | Where Alloy pushes metrics and logs; Grafana's data sources |
| `${DATABASE_ADDRESS}` | `192.168.1.200` | PostgreSQL for the apps (credentials from OpenBao) |

Only the `${VAR}` form is substituted (`$hostname` in nginx.conf is not). To exclude an object:
annotate it with `kustomize.toolkit.fluxcd.io/substitute: disabled`.

## Adding an app

1. `apps/<app>/<app>.yaml`: Namespace (label `gateway-access: public`), Deployment, Service,
   HTTPRoute attached to `kube-system/public` (start from `site/`). Pinned image tag,
   `resources` always set, hostname `<subdomain>.${DOMAIN}`.
2. `apps/<app>/network-policy.yaml` (see *Network policies*; start from `umami/`).
3. `apps/<app>/kustomization.yaml` listing those files, plus the `replacements` block
   that sets `app.kubernetes.io/version` from the image tag (copy it from `vitrine/`).
4. One line in `apps/kustomization.yaml`.
5. `git push`.

Two Gateways, in `infrastructure/configs/gateway.yaml`:

| Gateway | Namespace label | Hostnames | Reachable from |
|---|---|---|---|
| `public` | `gateway-access: public` | any | Internet (`.240`, port-forwarded) |
| `internal` | `gateway-access: internal` | `*.int.${DOMAIN}` | LAN and VPN (`.241`) |

An app with both a public part and an admin UI labels its namespace `gateway-access: both`
(e.g. Umami: tracker on `public`, dashboard on `internal`).
Anything with an admin interface goes on `internal`. The Traefik dashboard is at
`traefik.int.${DOMAIN}`. Hubble UI (Cilium's network flows, installed by the base): `hubble.int.${DOMAIN}`. One exception: Headlamp (`k8s.${DOMAIN}`) is public so that
people without the VPN can use it. It has no rights of its own: it acts with the
logged-in user's Pocket-ID token, so their RBAC applies.

HTTPS is automatic: the `public` Gateway (Gateway API, served by Traefik) terminates TLS
with the `*.abe.lc` wildcard certificate; Traefik redirects
HTTP to HTTPS and adds the security headers (HSTS, nosniff, frame deny, referrer policy).

## Network policies

Cilium (installed by the base) enforces a `CiliumNetworkPolicy` per namespace
(`network-policy.yaml` next to each app, `infrastructure/configs/network-policies/` for the
platform): **deny by default in both directions**, then what each component needs. Every pod
is covered; pods on the host network (Cilium, MetalLB speakers, node-exporter, NFS CSI) are
not Cilium endpoints and are not policed.

| Building block | Rule |
|---|---|
| Reached through Traefik | `fromEndpoints` kube-system / `app.kubernetes.io/name: traefik`, on the container port |
| Cluster DNS | `toEndpoints` kube-system / `k8s-app: kube-dns`, port 53, with the `dns` rule (names in Hubble) |
| PostgreSQL, VictoriaMetrics… on nuc1 | `toCIDR: ["${DATABASE_ADDRESS}/32"]` + port (the host is outside the cluster: "world") |
| Kubernetes API | `toEntities: [kube-apiserver]`, port 6443 |
| Admission webhook | `fromEntities: [kube-apiserver]` on the webhook port |
| Pocket-ID, any HTTPS | `toEntities: [world]`, port 443 (`auth.${DOMAIN}` goes out through the public address) |
| Nothing at all | `egress: [{}]`: without any egress rule, Cilium would not deny egress |

Kubelet probes (`reserved:host`) are always allowed. To write or debug one, watch the real
traffic in Hubble (`hubble.int.${DOMAIN}`, or `hubble observe --namespace <ns> --verdict
DROPPED` in a `cilium` pod). For a new policy, `cilium-dbg config PolicyAuditMode=true` on the
agents makes drops visible as `AUDIT` without enforcing them (reset when the agent restarts).

## Rules

- Images and charts are **pinned** (tag / version). Never `:latest`. Renovate opens pull
  requests to update them (`renovate.json`).
- **No plaintext secrets**: the repository is public. App secrets live in OpenBao,
  bootstrap secrets are `*.sops.yaml` files (see *Secrets*).
- Config files mounted from a ConfigMap go through `configMapGenerator` (hash-suffixed name,
  so pods restart when the content changes).

## Secrets

Two layers:

| Where | For | How |
|---|---|---|
| **sops** (in git) | Bootstrap only: OpenBao's unseal key, OpenBao's initial PostgreSQL password (rotated away at once) | Below, *sops + age* |
| **OpenBao** (`bao.int.${DOMAIN}`) | Application secrets | `kv/apps/<namespace>/<name>`, read through External Secrets |

### Application secrets (OpenBao)

A namespace can only read `kv/apps/<its own namespace>/*` (templated policy, nothing to
configure per namespace). Write the secret in the UI (method *OIDC*, mount path `sso/oidc`:
Pocket-ID login, group `admins`), then in the app:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: { name: db, namespace: myapp }
spec:
  refreshInterval: 1h
  secretStoreRef: { kind: ClusterSecretStore, name: openbao }
  target: { name: db }                    # the Kubernetes Secret it creates
  data:
    - secretKey: password
      remoteRef: { key: myapp/db, property: password }   # kv/apps/myapp/db
```

Logins are Pocket-ID everywhere (OpenBao, Grafana: group `admins`). Break-glass when
Pocket-ID is down, for a cluster-admin: OpenBao with the operator's identity
(`infrastructure/configs/openbao/config.yaml`), Grafana with the chart's generated admin
password (`kubectl -n monitoring get secret grafana`).

OpenBao's own configuration (engines, policies, roles, users) is in
`infrastructure/configs/openbao/config.yaml`, applied by vault-config-operator. Each object
has two conditions (`ReconcileFailed` from an earlier attempt can linger next to
`ReconcileSuccessful: True`): read both.

### sops + age

Write a Secret in plaintext as `<path>/<name>.sops.yaml`, then encrypt it in place:

```bash
sops --encrypt --in-place apps/<app>/<name>.sops.yaml   # encrypts data/stringData only
sops apps/<app>/<name>.sops.yaml                        # edit (decrypts/re-encrypts)
```

Recipients (`.sops.yaml`): the admin — software age key (`~/.config/sops/age/keys.txt`,
itself encrypted for the YubiKey in nix-secrets) and YubiKey — and Flux's dedicated age key,
generated on kube-1 and published by the base as `flux-system/sops-age`. If that key changes:
update it in `.sops.yaml`, then run `sops updatekeys <file>` on each secret.

## Access

Everyone logs in through **Pocket-ID** (`auth.${DOMAIN}`, passkeys). Its groups decide the
rights: `admins` is cluster-admin (`infrastructure/configs/oidc-rbac.yaml`), admin in
Grafana and OpenBao. OIDC clients are created in Pocket-ID's admin UI; their secrets go to
OpenBao (`kv/apps/<namespace>/oidc`, keys `client_id`, `client_secret`).

| What | Where | How |
|---|---|---|
| Kubernetes API | `kubectl` | context `homelab-oidc`: [kubelogin](https://github.com/int128/kubelogin) opens the browser, the API server checks the token (users and groups prefixed `oidc:`) |
| Kubernetes console | `k8s.${DOMAIN}` | Headlamp, with the user's own token |
| Secrets | `bao.int.${DOMAIN}` | OpenBao UI, method *OIDC*, mount path `sso/oidc` |
| Dashboards | `grafana.int.${DOMAIN}` | Grafana, automatic Pocket-ID login |

Break-glass when Pocket-ID is down: the base's admin kubeconfig (client certificate,
`homelab-nix` context), then the per-app procedures in *Secrets* above.

Onboarding a new admin (in French): `docs/onboarding/` (getting access, exposing a service).
Add them to the Pocket-ID group `admins`; their VPN peer goes in the homelab-nix topology.

## Updates

[Renovate](https://docs.renovatebot.com) opens a pull request for every new chart version
(HelmRelease) and image tag (`renovate.json`). Before merging: read the release notes (major
versions especially) and check that the chart's values did not move. After merging, follow
it with `flux get hr -A` and `flux get ks`. k3s (and the Traefik it bundles), the nodes and
the host are updated from `homelab-nix`.

## Checking locally

```bash
nix run nixpkgs#kustomize -- build apps
nix run nixpkgs#flux -- get kustomizations -A        # with the cluster's kubeconfig
```
