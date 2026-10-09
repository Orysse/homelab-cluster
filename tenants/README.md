# Tenants

A tenant is a namespace on the homelab cluster for a friend, who deploys what they want
in it. The platform side (this directory) only sets the guardrails:

| What | Where | Effect |
|---|---|---|
| Namespace, quota, defaults | `<name>/<name>.yaml` | 1 CPU / 1 GiB requested, 2 CPU / 2 GiB max, 20 pods, 5 GiB of disk |
| Pod Security `restricted` | namespace label | no root, no privileged containers, no host access |
| NetworkPolicy `tenant-baseline` | `<name>/<name>.yaml` | reachable only from Traefik; may reach the Internet, never the LAN or other namespaces |
| Role `tenant-admin` | `platform.yaml` | everything in the namespace, except network policies, quotas and routing objects other than HTTPRoutes |
| Flux impersonation policy | `platform.yaml` | the tenant's Flux objects run as a service account of the namespace |
| Gateway listener | `infrastructure/configs/gateway.yaml` | the tenant's routes only serve the tenant's hostnames |
| VPN peer with an access list | homelab-nix topology | Kubernetes API only, no SSH, no LAN |

Adding a tenant: copy `lenny/`, rename, add it to `kustomization.yaml`, add two listeners
to the Gateway, a group `tenant-<name>` in Authelia (`auth/authelia-users.sops.yaml`) and a
VPN peer with `access` in the homelab-nix topology.

---

# Onboarding (for the tenant)

You get the namespace **`lenny`** and the hostnames **`lenny.abe.lc`** and
**`*.lenny.abe.lc`**, with HTTPS certificates already provisioned.

## 1. Send Abel two things (never a password or a private key)

```bash
# a. Your login: pick a password, send the HASH it prints
nix run nixpkgs#authelia -- crypto hash generate argon2
# b. Your VPN key: keep privatekey, send publickey
wg genkey | tee privatekey | wg pubkey > publickey
```

Abel sends back your VPN address and the cluster's CA certificate.

## 2. VPN

```ini
[Interface]
PrivateKey = <content of privatekey>
Address = <your VPN address>/32

[Peer]
PublicKey = TNugHNt2qsBT5T/3ac1HWzXFzrw24rWu1l0uCKZhWEM=
Endpoint = vpn.abe.lc:51820
AllowedIPs = 192.168.1.211/32
PersistentKeepalive = 25
```

Only the Kubernetes API (`192.168.1.211:6443`) is reachable through it.

## 3. kubectl

Install the `oidc-login` plugin (`kubelogin` in nixpkgs, or `kubectl krew install
oidc-login`), then use this kubeconfig:

```yaml
apiVersion: v1
kind: Config
clusters:
  - name: homelab
    cluster:
      server: https://192.168.1.211:6443
      certificate-authority-data: <from Abel>
users:
  - name: lenny
    user:
      exec:
        apiVersion: client.authentication.k8s.io/v1
        command: kubectl
        args:
          - oidc-login
          - get-token
          - --oidc-issuer-url=https://auth.abe.lc
          - --oidc-client-id=kubernetes
          - --oidc-extra-scope=profile
          - --oidc-extra-scope=email
          - --oidc-extra-scope=groups
        interactiveMode: IfAvailable
contexts:
  - name: homelab
    context: { cluster: homelab, user: lenny, namespace: lenny }
current-context: homelab
```

The first `kubectl get pods` opens https://auth.abe.lc in your browser. The first login asks
you to register a second factor (security key or TOTP app): the confirmation code comes from
Abel (no mail server).

## 4. Publish something

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: site
  namespace: lenny
spec:
  parentRefs:
    - name: public
      namespace: kube-system
      sectionName: lenny              # or lenny-subdomains for *.lenny.abe.lc
  hostnames: [lenny.abe.lc]
  rules:
    - backendRefs:
        - name: site                  # your Service
          port: 80
```

HTTPS, HTTP→HTTPS redirect and security headers are automatic.

## 5. GitOps (optional)

Your own repository, applied by the cluster's Flux, as the `flux` service account:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata: { name: mine, namespace: lenny }
spec:
  url: https://github.com/<you>/<repo>
  ref: { branch: main }
  interval: 5m
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata: { name: mine, namespace: lenny }
spec:
  serviceAccountName: flux            # required in a tenant namespace
  sourceRef: { kind: GitRepository, name: mine }
  path: ./
  prune: true
  interval: 10m
```

Deploy notifications: a Flux `Provider` of type `discord` (webhook in a Secret) and an
`Alert` in your namespace.

## Good to know

- Containers must run as non-root, without privileges (Pod Security `restricted`).
- Set `resources` on your containers, or the namespace defaults apply (256 MiB max).
- **Storage is not backed up yet.** Keep anything important elsewhere.
- Your pods cannot reach the home network; they can reach the Internet.
- The platform's monitoring (Datadog) collects your pods' logs and metrics.
- No `LoadBalancer` or `NodePort` services: everything goes through your HTTPRoutes.
