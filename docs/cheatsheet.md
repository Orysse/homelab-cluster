# Cheatsheet

Day-to-day commands for this cluster. Kubeconfig: `~/.kube/configs/homelab-nix.yaml`
(context `homelab-nix`); `flux`, `kubectl`, `k9s`, `helm`, `sops` come from the `infra`
flavor of the laptop config.

> Flux is installed by the **base** (homelab-nix, Helm chart `flux2`), not by
> `flux bootstrap`. Never run `flux bootstrap`, `flux install` or `flux uninstall` here:
> the base owns the controllers, the `homelab-cluster` GitRepository and the `cluster`
> Kustomization.

## Deploy

The normal path is `git push` to `main`. Flux polls every few minutes; to apply now:

```bash
flux reconcile source git homelab-cluster          # fetch the new commit
flux reconcile ks apps --with-source               # fetch + apply one level
flux reconcile ks infra-configs --with-source
```

Order is `infra-controllers` -> `infra-configs` -> `apps` (`dependsOn`): reconciling `apps`
does not re-apply infra.

## Status

```bash
flux check                                  # controllers and CRDs healthy
flux get ks                                 # Kustomizations: revision, ready, message
flux get sources git                        # last fetched commit
flux get hr -A                              # Helm releases (MetalLB, cert-manager, Datadog)
flux get all -A                             # everything
flux tree ks apps                           # what a Kustomization manages
```

`REVISION` should match `git log -1 --format=%h origin/main`.

## When something is not deployed

```bash
flux get ks                                 # READY=False? read MESSAGE
flux events -A --types=Warning              # recent failures
flux logs --level=error --since=1h          # controller errors
flux logs --kind=Kustomization --name=apps  # one object's logs
kubectl -n flux-system describe ks apps
```

Usual causes:

| Symptom | Cause |
|---|---|
| New app missing, `apps` Ready | Not listed in `apps/kustomization.yaml`, or that change not pushed |
| `kustomize build failed` | YAML/kustomization error: run `kustomize build apps` locally |
| `variable substitution failed` / empty value | `${VAR}` not in `cluster-vars` (defined in homelab-nix topology) |
| `sops ... failed to decrypt` | File not encrypted for Flux's key: `sops updatekeys <file>` |
| `dependency 'infra-configs' is not ready` | Fix the earlier level first |
| HelmRelease `install retries exhausted` | `flux logs --kind=HelmRelease --name=<n> -n <ns>`, then fix and push |
| Object deleted by hand comes back | Expected: Flux re-applies git. Change git instead |

## Before pushing

```bash
kustomize build apps > /dev/null                          # or nix run nixpkgs#kustomize --
kustomize build infrastructure/configs > /dev/null
flux diff ks apps --path ./apps                           # what would change in the cluster
```

## Pause / resume

```bash
flux suspend ks apps        # stop reconciling (e.g. to test a manual change)
flux resume ks apps         # re-apply git, undoing manual changes
flux suspend hr datadog-operator -n datadog
```

A suspended object shows `SUSPENDED=True` in `flux get`. Do not leave it that way.

## Helm releases

```bash
flux get hr -A
flux reconcile hr metallb -n metallb-system --with-source
helm -n cert-manager history cert-manager
```

Traefik is **not** a Flux HelmRelease: k3s installs it, we only override its values
(`infrastructure/configs/traefik.yaml`, HelmChartConfig). Its upgrades run as a Job:

```bash
kubectl -n kube-system get jobs | grep helm-install-traefik
kubectl -n kube-system logs job/helm-install-traefik
```

## Secrets (sops)

```bash
sops apps/<app>/<name>.sops.yaml                       # edit (decrypts/re-encrypts)
sops --encrypt --in-place apps/<app>/<name>.sops.yaml  # encrypt a new plaintext Secret
sops updatekeys apps/<app>/<name>.sops.yaml            # after a .sops.yaml recipient change
kubectl -n flux-system get secret sops-age             # Flux's key, published by the base
```

## Routing and TLS

```bash
kubectl get gateway -A                      # public (.240) and internal (.241), PROGRAMMED=True
kubectl get httproute -A
kubectl -n <ns> describe httproute <name>   # Accepted / ResolvedRefs conditions
kubectl -n kube-system get certificate wildcard
kubectl get certificaterequest,order,challenge -A   # stuck certificate
```

HTTPRoute `Accepted=False, NotAllowedByListeners`: namespace label `gateway-access` missing
or wrong (`public` / `internal`).

## Quick checks

```bash
curl -sI https://abe.lc
curl -s -o /dev/null -w '%{http_code}\n' https://traefik.int.abe.lc/dashboard/   # LAN/VPN only
```

Status page: https://status.abe.lc. Traefik dashboard: https://traefik.int.abe.lc/dashboard/.

## k9s

`k9s` then `:` + resource: `:ks` Kustomizations, `:hr` HelmReleases, `:gitrepo`,
`:httproute`, `:gateway`, `:certificate`. `l` logs, `d` describe, `0` all namespaces.
