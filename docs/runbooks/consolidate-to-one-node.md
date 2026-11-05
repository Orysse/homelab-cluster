# Runbook: three VMs to one (`kube-1..3` to `kube-0`)

The v3 cluster has run on three VMs since the cutover of 2026-10-29
(`docs/runbooks/v3-cutover.md`, already done). This moves it to one VM, `kube-0`
(`192.168.1.210`, 9216 MB, 12 vCPU), on a **new k3s**: new etcd, new CA, new node. About
30 minutes of downtime. Owner on site, with `kubectl`, `flux` and `ssh root@192.168.1.200`.
Commands marked `nuc1$` run on nuc1.

What carries over:

| State | Where it is now | How it moves |
|---|---|---|
| OpenBao, Open WebUI files | NFS on nuc1 (`/srv/data/<namespace>_<pvc>`, Retain) | nothing: the new PVCs get the same directory names |
| Flux's age key, SSH host keys, k3s token | `kube-1/persist` on nuc1; the token in `/var/lib/homelab/k3s-token` | copied to `kube-0/persist` before the first boot |
| PostgreSQL: Pocket-ID, Headscale, Open WebUI | CNPG `main-1` on `kube-2`'s local volume | dumped to nuc1's PostgreSQL; CNPG imports from there (`cluster.yaml`) |
| PostgreSQL: Umami, Grafana (`monitoring`) | nuc1's own PostgreSQL (not in CNPG) | nothing: untouched |
| Everything else | etcd | rebuilt by Flux from git |

The v2 backups (`kube-1/k3s-data.img.v2-backup`, `/srv/data/v2-backup-*`) stay untouched:
every new backup below has a different suffix, because `mv` overwrites without asking.

## Step 0: before, no downtime

1. `nuc1$ df -h /var/lib/microvms` shows more than 60 GB free (two new images:
   32 GiB sparse, 20 GiB sparse) and `nuc1$ garage status` shows one healthy node.
2. homelab-nix: a clean checkout of the commit to deploy (not a working tree with
   uncommitted changes), `nix flake check` passes, and
   `nix build .#nixosConfigurations.nuc1.config.system.build.toplevel` succeeds.
   `nix eval .#nixosConfigurations.nuc1.config.microvm.vms.kube-0.config.config.microvm.mem`
   prints `9216`.
3. homelab-cluster: the branch to merge is one fast-forward ahead of `main`
   (`git rev-list --count main..v3` is 1) and `scripts/validate.sh` passes.
4. Nothing to export: OpenBao's data stays on NFS and unseals itself with the key in
   sops. Check the NFS directories exist: `nuc1$ ls -d /srv/data/openbao_data-openbao-0
   /srv/data/open-webui_open-webui-data`.

## Step 1: freeze writes and dump PostgreSQL

1. Stop Flux and the three apps that write to CNPG:
   ```sh
   flux suspend kustomization --all -n flux-system
   for ns in pocket-id headscale open-webui; do kubectl -n $ns scale deploy --all --replicas 0; done
   ```
   Pocket-ID and Headscale are unreachable from here on (VPN, SSO login).
2. Dump the three databases to nuc1, readable by root only (Umami and Grafana are not in
   CNPG: a `pg_dump` of them fails with "database does not exist", which is expected):
   ```sh
   ssh root@192.168.1.200 'umask 077; mkdir -p /root/pg-migrate'
   for db in pocket-id headscale open-webui; do
     kubectl -n postgres exec main-1 -c postgres -- pg_dump -Fc -d $db | ssh root@192.168.1.200 "umask 077; cat > /root/pg-migrate/$db.dump"
   done
   ssh root@192.168.1.200 'ls -l /root/pg-migrate'
   ```
   Three files, none empty. If a `pg_dump` fails, scale the deployments back to what they
   were and stop here: nothing has changed yet.
3. On nuc1, put the dumps in place of the old copies (from 2026-10-29) of the three
   databases. CNPG imports from them in Step 4. The old copies are renamed, not dropped.
   The dumps are root-only: feed them to `postgres` through stdin.
   ```sh
   nuc1$ cd /root/pg-migrate
   nuc1$ for db in pocket-id headscale open-webui; do
     runuser -u postgres -- psql -v ON_ERROR_STOP=1 -c "ALTER DATABASE \"$db\" RENAME TO \"${db}_v2old\""
     runuser -u postgres -- psql -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"$db\" OWNER \"$db\" TEMPLATE template0 ENCODING 'UTF8' LOCALE 'en_US.UTF-8'"
     runuser -u postgres -- pg_restore --no-owner --no-acl --role="$db" --exit-on-error -d "$db" < "$db.dump"
   done
   ```
   Compare the row counts with the live cluster (`users` in pocket-id, `nodes` in headscale,
   `chat` in open-webui). The old `cnpg_import` role and its OpenBao password are reused:
   if the import fails in Step 4 on authentication, set the role's password again and
   update `postgres/nuc1-import` in OpenBao.

## Step 2: stop and set aside

1. `nuc1$ systemctl stop microvm@kube-3 microvm@kube-2 microvm@kube-1`
2. Set the three VMs' state aside, with a suffix that does not exist yet:
   ```sh
   nuc1$ for n in kube-1 kube-2 kube-3; do
     ls /var/lib/microvms/$n/k3s-data.img.3vm-backup 2>&1 | grep -q 'No such' || { echo "backup exists for $n, stop"; break; }
     mv /var/lib/microvms/$n/k3s-data.img /var/lib/microvms/$n/k3s-data.img.3vm-backup
   done
   ```
   `local.img` stays where it is (CNPG's old data, kept for rollback).
3. Give `kube-0` its persistent state **before its first boot**. It is a copy: `kube-1`
   keeps its own for the rollback.
   ```sh
   nuc1$ mkdir -p /var/lib/microvms/kube-0 && cp -a /var/lib/microvms/kube-1/persist /var/lib/microvms/kube-0/persist
   nuc1$ ls /var/lib/microvms/kube-0/persist
   ```
   It must list `flux-age.key`; without it `flux-sops.nix` generates a new key and every
   sops secret in this repository stops decrypting.

## Step 3: deploy

1. homelab-cluster: `git checkout main && git merge --ff-only v3 && git push origin main`.
   Flux is suspended on the old cluster, so nothing applies it yet; the new cluster's Flux
   finds it at its first start.
2. homelab-nix, from the clean checkout: `nix run .#deploy-rs -- .#nuc1`. The activation
   removes `kube-1..3` (already stopped) and starts `kube-0`. If deploy-rs reports a
   magic rollback, stop and read why before retrying.
3. `nuc1$ systemctl status microvm@kube-0`, then wait for the node:
   `ssh root@192.168.1.210 k3s kubectl get nodes` shows `kube-0` `Ready`
   (about 3 minutes). Copy `/etc/rancher/k3s/k3s.yaml` from `kube-0` for the new CA and
   fix your kubeconfigs (`.211` to `.210`; `docs/onboarding/kubeconfig.yaml` is in git).
4. `kubectl -n kube-system rollout restart deploy/cilium-operator` once the Cilium chart is
   applied (ADR 0002, finding 1). Then `flux get kustomizations -w`: `infra-controllers`,
   `infra-configs`, `apps` become `Ready`.

## Step 4: databases and apps

1. `kubectl cnpg status -n postgres main`: the import has run and the cluster is healthy;
   `kubectl -n postgres get backups` shows a first backup `completed`.
2. Umami and Grafana read nuc1's PostgreSQL, which Step 1 did not touch: their data is
   there, nothing to restore.
3. Pocket-ID: `kubectl get pocketidinstance,pocketidoidcclient -A` all Ready, and its UI shows
   one group `admins` (with you in it) and one `visitors` (a duplicate or an empty group
   locks you out of kubectl, OpenBao and Grafana: break-glass, ADR 0005).
4. Every ExternalSecret `Ready`, and each deployment at its git replica count (the scale-down
   in Step 1 lived in the old cluster's etcd only).

## Step 5: verify

- Every hostname answers over HTTPS with a valid certificate (cert-manager issues them
  again; the first minutes may serve the self-signed one); `https://holive.fr` redirects
  to `https://www.holive.fr`.
- `arping -c 3 192.168.1.240` and `.241` answer with `kube-0`'s MAC.
- Tailscale: an existing device reconnects without registering again; the ACL reaches
  `192.168.1.210:6443`. Pocket-ID login with a passkey; `kubectl` through kubelogin;
  Headlamp, Grafana, the OpenBao UI.
- Open WebUI: existing chats are there.
- `hubble observe --verdict DROPPED --since 15m` shows nothing legitimate.
- `nuc1$ grep -E 'MemAvailable|SwapFree' /proc/meminfo` and `free -m` in `kube-0`: record
  them in `docs/measurements.md` (v3 columns), and again after 7 days.

## Rollback (while the backups are in place)

1. `nuc1$ systemctl stop microvm@kube-0`.
2. homelab-cluster: `git revert` the commit and push (a plain push, no force):
   the old cluster's Flux is suspended, so resume it only after step 4.
3. homelab-nix: `nuc1$ nixos-rebuild switch --rollback`, which brings `kube-1..3` back
   in the configuration. Put each image back:
   `nuc1$ for n in kube-1 kube-2 kube-3; do mv /var/lib/microvms/$n/k3s-data.img.3vm-backup /var/lib/microvms/$n/k3s-data.img; done`.
4. `nuc1$ systemctl start microvm@kube-1 microvm@kube-2 microvm@kube-3`, wait for the nodes,
   then `flux resume kustomization --all -n flux-system` and scale the five namespaces'
   deployments back up (the git replica counts).
5. Databases written since Step 1 are in the new cluster only; the old `main-1` has its
   state from Step 1. Say so before relying on a rollback after a day of use.

## After

- `nuc1$ shred -u /root/pg-migrate/*.dump` once Step 5 passes, drop the renamed
  `pocket-id_v2old`, `headscale_v2old` and `open-webui_v2old` databases, and
  `runuser -u postgres -- psql -c 'DROP ROLE cnpg_import'` once nothing needs it.
- After a week: delete `*.3vm-backup`, `kube-1..3/local.img`, `/var/lib/microvms/kube-2`
  and `kube-3`. Never the `.v2-backup` files before you are sure v2 is not coming back.
- Commit this runbook with a "done on <date>" line and every deviation.
