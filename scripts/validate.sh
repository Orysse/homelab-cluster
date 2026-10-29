#!/usr/bin/env bash
# Builds every path a Flux Kustomization in clusters/homelab/ points at, the way Flux would
# (kustomize, then ${VAR} substitution with stand-ins for flux-system/cluster-vars), and
# validates the result against the Kubernetes schemas and the CRDs catalog.
# Needs kustomize, kubeconform, flux and yq: `nix shell nixpkgs#kustomize
# nixpkgs#kubeconform nixpkgs#fluxcd nixpkgs#yq-go -c ./scripts/validate.sh`.
# Encrypted *.sops.yaml Secrets are validated without their `sops` block.
set -euo pipefail
cd "$(dirname "$0")/.."

# Stand-ins for flux-system/cluster-vars (homelab-nix: modules/k3s/flux.nix).
export CLUSTER_NAME=homelab DOMAIN=example.org
export INGRESS_ADDRESS=192.0.2.240 INTERNAL_ADDRESS=192.0.2.241 LAPI_ADDRESS=192.0.2.242 INGRESS_POOL_START=192.0.2.240 INGRESS_POOL_STOP=192.0.2.254
export NFS_SERVER=192.0.2.200 NFS_SHARE=/srv/data
export MONITORING_ADDRESS=192.0.2.200 BACKUP_ADDRESS=192.0.2.200

catalog='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
status=0
for path in $(yq -N '.spec.path' clusters/homelab/*.yaml); do
  echo "== ${path}"
  if ! kustomize build "${path}" \
      | flux envsubst \
      | yq 'del(.sops)' \
      | kubeconform -strict -summary -ignore-missing-schemas \
          -schema-location default -schema-location "${catalog}"; then
    status=1
  fi
done
exit "${status}"
