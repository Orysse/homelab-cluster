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
├─ controllers/            what installs CRDs: MetalLB, cert-manager, Datadog Operator
└─ configs/                what uses them: MetalLB IP pool, Traefik settings and security
                           headers, Let's Encrypt issuers, wildcard certificate, Datadog agent

apps/                      one app = one directory, listed in apps/kustomization.yaml
└─ site/                   plain-text page (index.txt) at the domain apex
```

Each level waits for the previous one to be ready (`dependsOn`).

## Variables from the base

The network is defined **once**, in the base's Nix topology, which publishes the
`flux-system/cluster-vars` ConfigMap. Flux substitutes these variables in
`infrastructure/configs` and `apps`:

| Variable | Value | Used for |
|---|---|---|
| `${DOMAIN}` | `abe.lc` | Ingress hosts, certificate |
| `${INGRESS_ADDRESS}` | `192.168.1.240` | Traefik's LoadBalancer IP |
| `${INGRESS_POOL}` | `192.168.1.240-192.168.1.254` | IPs MetalLB may assign |
| `${CLUSTER_NAME}` | `homelab` | Datadog cluster name and tag |
| `${DD_SITE}` | `us5.datadoghq.com` | Datadog site |

Only the `${VAR}` form is substituted (`$hostname` in nginx.conf is not). To exclude an object:
annotate it with `kustomize.toolkit.fluxcd.io/substitute: disabled`.

## Adding an app

1. `apps/<app>/<app>.yaml`: Namespace, Deployment, Service, Ingress (start from `site/`).
   Pinned image tag, `resources` always set, host `<subdomain>.${DOMAIN}`.
2. `apps/<app>/kustomization.yaml` listing that file.
3. One line in `apps/kustomization.yaml`.
4. `git push`.

HTTPS is automatic: Traefik serves the `*.abe.lc` wildcard certificate by default, redirects
HTTP to HTTPS and adds the security headers (HSTS, nosniff, frame deny, referrer policy).

## Rules

- Images and charts are **pinned** (tag / version). Never `:latest`. Renovate opens pull
  requests to update them (`renovate.json`).
- **No plaintext secrets**: the repository is public. Secrets are `*.sops.yaml` files,
  encrypted with sops (see below).
- Config files mounted from a ConfigMap go through `configMapGenerator` (hash-suffixed name,
  so pods restart when the content changes).

## Secrets (sops + age)

Write a Secret in plaintext as `<path>/<name>.sops.yaml`, then encrypt it in place:

```bash
sops --encrypt --in-place apps/<app>/<name>.sops.yaml   # encrypts data/stringData only
sops apps/<app>/<name>.sops.yaml                        # edit (decrypts/re-encrypts)
```

Recipients (`.sops.yaml`): the admin — software age key (`~/.config/sops/age/keys.txt`,
itself encrypted for the YubiKey in nix-secrets) and YubiKey — and Flux's dedicated age key,
generated on kube-1 and published by the base as `flux-system/sops-age`. If that key changes:
update it in `.sops.yaml`, then run `sops updatekeys <file>` on each secret.

## Checking locally

```bash
nix run nixpkgs#kustomize -- build apps
nix run nixpkgs#flux -- get kustomizations -A        # with the cluster's kubeconfig
```
