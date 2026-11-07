# ADR 0001: k3s, stripped to upstream Kubernetes

Status: accepted (2026-10-29).

## Context

The cluster runs in three microVMs on one NUC (homelab-nix), with about 1 GB of free memory
per node (`docs/measurements.md`). Three NUC7s, low on CPU, are coming. The distribution
has to stay small, and the platform on top of it has to be the platform's own, not what a
distribution happens to bundle.

## Decision

k3s, with everything it bundles that the platform declares itself turned off:

| k3s component | v3 |
|---|---|
| flannel, kube-proxy | off since v2: Cilium (CNI, kube-proxy replacement) |
| servicelb | off: Cilium LB-IPAM and L2 announcements (ADR 0002) |
| Traefik | off: Cilium's Gateway API (ADR 0002) |
| local-storage | off: local-path-provisioner declared in homelab-cluster, on a volume per VM |
| CoreDNS, metrics-server | kept: plain upstream components, nothing to configure |
| embedded etcd | kept (`clusterInit`): one server today, the NUC7s join as servers |

What is left is upstream Kubernetes in one binary, configured from Nix (homelab-nix
`k3s/node.nix`), with the Gateway API CRDs and Cilium as k3s manifests and charts.

## Rejected

- **RKE2** (the owner likes it): its control plane runs as separate static pods, about
  +0.5 to 1 GB on the server and +100 to 200 MB per agent (estimate, not measured). That
  eats the memory v3 saves, for CIS and FIPS profiles that matter little in a homelab.
- **Talos, k0s**: they replace the layer below too, and that layer (NixOS microVMs) is
  staying.
- **kubeadm**: the same upstream Kubernetes, more parts to assemble by hand.

## Consequences

- k3s upgrades come from nixpkgs, one minor at a time (`k3s_1_36`, then the next).
- The NUC7s add servers to the same etcd: three servers on three machines, quorum survives
  a machine. No three-server rehearsal on nuc1 (it would cost memory and protect from
  nothing on one host).
- Fallback: re-enabling a bundled component is one line in `k3s/node.nix`'s `disable` list.
