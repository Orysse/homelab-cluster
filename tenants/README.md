# Tenants

A tenant is a namespace on the homelab cluster for a friend, who deploys what they want
in it. The platform side (this directory) only sets the guardrails:

| What | Where | Effect |
|---|---|---|
| Namespace, quota, defaults | `<name>/<name>.yaml` | 1 CPU / 1 GiB requested, 2 CPU / 2 GiB max, 20 pods, 10 GiB of NFS storage |
| Pod Security `restricted` | namespace label | no root, no privileged containers, no host access |
| NetworkPolicy `tenant-baseline` | `<name>/<name>.yaml` | reachable only from Traefik (and Alloy for metrics); may reach the Internet, never the LAN or other namespaces |
| Role `tenant-admin` | `platform.yaml` | everything in the namespace, except network policies, quotas and routing objects other than HTTPRoutes |
| Policy `tenant-flux-impersonation` | `platform.yaml` | the tenant's Flux objects run as a service account of the namespace |
| Policy `tenant-no-externalname` | `platform.yaml` | no `ExternalName` services (would let Traefik publish a platform service) |
| Gateway listeners | `infrastructure/configs/gateway.yaml` | the tenant's routes only serve the tenant's hostnames |
| VPN peer with an access list | homelab-nix topology | Kubernetes API only, no SSH, no LAN |

Identity: a Pocket-ID group `tenant-<name>`; the API server sees it as `oidc:tenant-<name>`.

## Adding a tenant

1. Copy `lenny/`, rename it (namespace, group, hostnames), add it to `kustomization.yaml`.
2. Two listeners on the `public` Gateway (`infrastructure/configs/gateway.yaml`).
3. Pocket-ID (admin UI): user, group `tenant-<name>`, invitation. If the `kubernetes` and
   `headlamp` OIDC clients are restricted to some groups, add this one.
4. When they send their WireGuard public key: a peer with `access` in the homelab-nix topology,
   then deploy nuc1.
5. Give them the guides in `<name>/` (getting started, exposing a service).

## Checking the guardrails

```bash
as="--as=oidc:lenny --as-group=oidc:tenant-lenny"
kubectl $as -n lenny auth can-i create deployments            # yes
kubectl $as -n lenny auth can-i create networkpolicies        # no
kubectl $as -n monitoring auth can-i get pods                 # no
kubectl $as auth can-i list namespaces                        # yes (names only)
```
