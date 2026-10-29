# Runbook: cutover to v3

Hard cutover, owner on site: the v2 cluster is stopped and set aside, v3 starts as a new
cluster on the same VMs. Everything v2 needs to come back stays untouched until the end
(rollback, Step 7). Spec: `docs/superpowers/specs/2026-10-29-cluster-v3-design.md`.

What carries over, and how:

| Data | Where in v2 | v3 |
|---|---|---|
| Application secrets | OpenBao on NFS (`openbao_data-openbao-0`) | exported, imported into a fresh OpenBao (Steps 1, 4) |
| Databases | PostgreSQL on nuc1 | copied by CNPG's import (`postgres/cluster.yaml`) |
| Open WebUI uploads | NFS `open-webui_open-webui-data` | same directory: the PVC name is unchanged |
| Flux's age key, k3s token | `/var/lib/microvms/kube-1/persist` | unchanged |
| Pocket-ID users and passkeys | its database | imported with it |

Commands below run from the laptop (kubectl, bao) or on nuc1 (`nuc1$`).

## Step 0: preconditions

- homelab-nix `v3` builds (`nix flake check`, nuc1 toplevel), homelab-cluster `v3` passes
  `scripts/validate.sh`.
- Garage is deployed on nuc1 (homelab-nix Task 12) and answers: `nuc1$ garage status`
  shows one healthy node; from kube-1, `curl -s -o /dev/null -w '%{http_code}'
  http://192.168.1.200:3900` prints `403`.
- The bouncer image exists: tag `bouncer-v0.1.0` pushed, CI built
  `ghcr.io/orysse/crowdsec-cilium-bouncer:0.1.0`, the GHCR package is public.
- `nuc1$ ps -eo rss,comm --sort=-rss | head -20` saved in `docs/measurements.md` (Task 2
  could not measure nuc1).

## Step 1: before

1. Save what must work again afterwards:
   ```sh
   curl -s 'http://192.168.1.200:8428/api/v1/query?query=count+by+(job)+(up)' > /tmp/v2-jobs.json
   kubectl get httproute -A -o custom-columns=NS:.metadata.namespace,HOSTS:.spec.hostnames > /tmp/v2-routes.txt
   ```
2. Export OpenBao's application secrets to nuc1's tmpfs, never to git or a disk:
   ```sh
   export BAO_ADDR=https://bao.int.abe.lc && bao login -method=oidc -path=sso/oidc
   for k in $(bao kv list -format=json kv/apps | jq -r '.[]'); do
     for s in $(bao kv list -format=json "kv/apps/$k" | jq -r '.[]'); do
       printf '%s\t%s\n' "$k$s" "$(bao kv get -format=json "kv/apps/$k$s" | jq -c .data.data)"
     done
   done | ssh nuc1 'umask 077; cat > /run/v2-secrets.tsv'
   ```
   One kind of path is dropped at import (Step 4): `*/oidc`, since the Pocket-ID operator
   now owns the OIDC clients. Everything else (Cloudflare token, SMTP and API keys,
   generated keys) keeps its path.
3. Temporary import user on nuc1's PostgreSQL, and the two credentials v3 needs, appended
   to the same file:
   ```sh
   nuc1$ pw=$(openssl rand -hex 24)
   nuc1$ sudo -u postgres psql -c "CREATE ROLE cnpg_import SUPERUSER LOGIN PASSWORD '$pw'"
   nuc1$ printf 'postgres/nuc1-import\t{"password":"%s"}\n' "$pw" >> /run/v2-secrets.tsv
   nuc1$ garage key info cnpg --show-secret    # Key ID and Secret key
   nuc1$ printf 'postgres/s3\t{"access_key_id":"%s","secret_access_key":"%s"}\n' <id> <secret> >> /run/v2-secrets.tsv
   ```
4. Every PersistentVolume to `Retain`, so nothing v2 owns can be deleted on the way:
   ```sh
   kubectl get pv -o name | xargs -I{} kubectl patch {} -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
   ```

## Step 2: freeze

1. homelab-cluster: merge `v3` into `main` locally, **do not push yet**.
2. Stop the VMs, last agent first: `nuc1$ systemctl stop microvm@kube-3 microvm@kube-2 microvm@kube-1`.
3. Set v2 aside (rename, never delete):
   ```sh
   nuc1$ for n in kube-1 kube-2 kube-3; do mv /var/lib/microvms/$n/k3s-data.img /var/lib/microvms/$n/k3s-data.img.v2-backup; done
   nuc1$ mv /srv/data/openbao_data-openbao-0 /srv/data/v2-backup-openbao_data-openbao-0
   ```
   The second line matters: the new OpenBao's volume has the same name, and on the old
   (already initialized) storage its self-initialization would never run.

## Step 3: deploy

1. homelab-nix: `nix run .#deploy-rs -- .#nuc1` from `v3`. The VMs may start during
   activation; if not, start kube-1, wait for `kubectl get nodes` (admin kubeconfig, new
   CA: copy `/etc/rancher/k3s/k3s.yaml` from kube-1) to show it Ready, then kube-2, kube-3.
2. Restart the Cilium operator once the Cilium chart has been applied (ADR 0002, finding 1):
   `kubectl -n kube-system rollout restart deploy/cilium-operator`. Nodes turn Ready.
3. Check the Gateway API CRDs came from the k3s manifest:
   `kubectl get crd gateways.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}'` prints `v1.5.1`.
4. Push homelab-cluster `main`. The FluxInstance reconciles `infra-controllers`, then
   `infra-configs`, then `apps`: `flux get kustomizations -w`.

## Step 4: seed OpenBao (right after it reports unsealed)

1. `kubectl -n openbao get pod openbao-0` Running; `kubectl -n openbao exec openbao-0 --
   bao status` shows `Sealed false`. The cluster's own login does not exist yet: use the
   break-glass role (ADR 0005):
   ```sh
   kubectl -n openbao port-forward svc/openbao 8200 &
   export BAO_ADDR=http://127.0.0.1:8200
   export BAO_TOKEN=$(bao write -field=token auth/kubernetes/login role=break-glass \
     jwt="$(kubectl -n openbao create token break-glass)")
   ```
2. Import, skipping the OIDC entries, then destroy the file:
   ```sh
   ssh nuc1 'cat /run/v2-secrets.tsv' | grep -v -P '^[^\t]*/oidc\t' | while IFS=$'\t' read -r path json; do
     echo "$json" | bao kv put "kv/apps/$path" -
   done
   ssh nuc1 'shred -u /run/v2-secrets.tsv'
   ```
3. Generated secrets may have been pushed before the import (PushSecret `IfNotExists`
   found nothing); the import replaced them with v2's. Make every consumer read again,
   then restart the three apps that cache them:
   ```sh
   kubectl get externalsecret -A -o json | jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"' |
     while read ns n; do kubectl -n $ns annotate externalsecret $n force-sync=$(date +%s) --overwrite; done
   kubectl -n pocket-id rollout restart deploy
   kubectl -n headscale rollout restart deploy/headscale
   kubectl -n open-webui rollout restart deploy/open-webui
   ```
4. CNPG: `kubectl cnpg status -n postgres main` shows the import done and the cluster
   healthy; then `kubectl -n postgres get backups` shows the first backup `completed`.
5. Pocket-ID operator (ADR 0004, first live run): `kubectl get pocketidinstance -A`,
   `kubectl get pocketidoidcclient -A` all Ready; each app namespace has its
   `*-oidc-credentials` (or renamed) Secret. The `sso-config` Job in `openbao` completes.
   If the operator fails here: fallback in ADR 0004.

## Step 5: verify, from outside

- Every hostname from `/tmp/v2-routes.txt` answers over HTTPS with a valid certificate;
  `https://holive.fr` redirects to `https://www.holive.fr`; `http://` redirects to `https://`.
- L2 announcements (ADR 0002, finding 5): from a LAN machine, `arping -c 3 192.168.1.240`
  and `.241` answer with a node's MAC; stop the VM holding the lease, another node takes
  it within a few seconds.
- Client IP (ADR 0002, finding 4): a request from a phone on 4G appears in the Gateway's
  access log (Grafana, Réseau, last panel) with the phone's public address.
- Pocket-ID login with an existing passkey; `kubectl` through kubelogin (update the
  kubeconfig's CA: `docs/onboarding/kubeconfig.yaml` and `~/.kube/configs/homelab-oidc.yaml`);
  Headlamp; Grafana; OpenBao UI login through Pocket-ID.
- Headscale: an existing device reconnects without registering again (same noise key). It is served by TLS passthrough (TLSRoute on the public Gateway, listener `headscale`): check `kubectl -n gateway get gateway public` shows no listener conflict, that `hs.abe.lc` and the HTTPS wildcard listener share 443 (`curl -I https://hs.abe.lc/health` and `curl -I https://auth.abe.lc` both answer), and `tailscale status` on a client. Cilium may reject TLS and HTTPS on one port: then give Headscale its own LoadBalancer IP.
- Open WebUI: existing chats are there.
- Policies: `hubble observe --verdict DROPPED --since 15m` shows nothing legitimate. In
  particular, pods reaching `auth.abe.lc` (OpenBao, oauth2-proxy, Headlamp, Headscale,
  Open WebUI): if the drop shows another identity than `ingress` or `world`, fix their
  egress rule (Tasks 15, 17).

## Step 6: verify, inside

- Local volume survives a VM restart (Task 11): write a file in the PostgreSQL volume's
  pod (`kubectl -n postgres exec main-1 -- touch /var/lib/postgresql/data/canary`),
  `nuc1$ systemctl restart microvm@<its node>`, the file is still there.
- OpenBao (Task 15): `bao secrets list` shows `kv/apps/`, `bao auth list` shows
  `kubernetes/` and `sso/`. `kubectl -n openbao delete pod openbao-0`: within 2 minutes
  `bao status` is `Sealed false` with nobody unsealing, and `kubectl -n gatus get
  externalsecret` is Ready.
- CNPG (Task 16): `bao kv get kv/apps/headscale/db` shows a username and password; record
  the password's hash, `kubectl -n postgres delete externalsecret headscale-db-generated
  headscale-db`, let Flux recreate them: the Secret and OpenBao's value are unchanged.
  Restore test: a `Cluster` `restore-test` bootstrapped from `ObjectStore` `garage` reaches
  Ready and holds Pocket-ID's tables; delete it.
- Bans (Task 18): `kubectl -n crowdsec exec deploy/crowdsec-lapi -- cscli decisions add
  --ip <LAN test host> --duration 10m`; within 40 s the test host times out on
  `https://abe.lc` and Hubble shows the drop; `cscli decisions delete --ip <test host>`
  restores it. Then LAPI down for 2 minutes (`kubectl -n crowdsec scale deploy/crowdsec-lapi
  --replicas 0`): the groups' `resourceVersion` does not change, `bouncer_sync_errors_total`
  rises; scale back to 1.
- Scale (Task 4, deferred here): let the community blocklist load; `kubectl get
  ciliumcidrgroups -l crowdsec.net/banned=true` totals its size. Watch `cilium-agent`
  memory and CPU per node for an hour (Grafana, Détails, Cilium). Record the result in
  ADR 0003; if the agents suffer, lower the list or move enforcement to the host firewall.
- Monitoring (Task 19): `count by (job) (up{cluster="homelab"})` lists the jobs of
  `/tmp/v2-jobs.json` (minus alloy, traefik, tetragon, opencost; plus otel-collector,
  cilium-envoy, cloudnative-pg); vmalert on nuc1 shows no rule in error; VictoriaLogs
  `{namespace="gatus"}` returns lines from the last 5 minutes.

## Step 7: rollback (only if Steps 4 and 5 fail and cannot be fixed in the session)

1. Stop the three VMs.
2. Put v2 back: `k3s-data.img.v2-backup` -> `k3s-data.img` on each node (remove the v3
   image first), and `/srv/data/v2-backup-openbao_data-openbao-0` -> `/srv/data/openbao_data-openbao-0`.
3. Deploy homelab-nix `main` (v2). Do not push homelab-cluster `main`, or reset it to the
   pre-merge commit and push.
4. nuc1's PostgreSQL was only read: v2's data is intact. Drop the import user:
   `nuc1$ sudo -u postgres psql -c 'DROP ROLE cnpg_import'`.

## Step 8: after

- `DROP ROLE cnpg_import` on nuc1 (Task 22 removes the import block and PostgreSQL on nuc1
  once a restore test passed).
- Keep the `.v2-backup` images and directory for a week, then delete them.
- Commit this runbook with a "done on <date>" line and every deviation.
