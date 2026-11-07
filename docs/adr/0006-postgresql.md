# ADR 0006: PostgreSQL on CloudNativePG

Status: accepted (2026-10-29). Checked at cutover (runbook): import, first backup, a restore.

## Context

In v2, PostgreSQL ran on nuc1 (homelab-nix `host/postgres.nix`), outside the cluster. OpenBao's
database engine owned the app users' passwords through static roles. Backups were btrbk
snapshots of the `@db` subvolume, on the same disk. Three apps keep a database in v3:
Pocket-ID, Headscale and Open WebUI (Umami goes; Grafana keeps no state).

## Decision

- **CloudNativePG**, operator plus Barman Cloud plugin (`infrastructure/controllers/`).
  The database becomes a cluster object with its backups, its roles and its databases
  declared next to it (`infrastructure/configs/postgres/`).
- **One shared `Cluster` `main`**, not one per app: three small databases do not justify
  three PostgreSQL processes on nodes with about 1 GB free each. One database and one role
  per app, named after its namespace. Apps connect to `main-rw.postgres.svc:5432`.
- **One instance, on a local volume** (StorageClass `local`, local-path-provisioner on a
  block volume per VM, `Retain`). PostgreSQL wants a real disk: NFS breaks its locking, and
  virtiofs gives weak `fsync` guarantees. The volume is tied to its node; losing that node
  means restoring from backup. A second instance (streaming replica) comes with the NUC7s:
  `instances: 2`, nothing else changes.
- **Backups off the cluster's disks**: base backup every night at 03:00, WAL archived
  continuously, both gzipped to Garage (S3) on the backup host, kept 30 days. Point-in-time
  recovery is possible to any moment in that window. Garage's directory is itself snapshotted
  read-only by btrbk, so a deletion through the S3 key cannot reach the snapshots.
- **Credentials: OpenBao is the source of truth, CNPG applies them.** For each app
  (`databases/<app>.yaml`): a `Password` generator makes a candidate once; a `PushSecret`
  (`IfNotExists`) stores it at `kv/apps/<app>/db`; an `ExternalSecret` reads it back as the
  Secret the managed role uses. Recreating any of these objects never changes a password:
  the generator's new candidate is discarded because OpenBao already holds one. The app
  reads the same `kv/apps/<ns>/db` through the cluster store, like any other secret. The
  writes into other namespaces' paths use a dedicated OpenBao role, `postgres-writer`,
  limited to `kv/apps/+/db`.
- **No rotation.** OpenBao's database engine rotated passwords; nothing here does. These are
  in-cluster credentials, reachable only from the owning namespace (network policy) and
  never seen by a person. A rotation is: delete `kv/apps/<app>/db`, the flow above makes a
  new one, the app restarts.

## Cutover

`bootstrap.initdb.import` (`monolith`) copies the three databases and their roles from
nuc1, through a temporary superuser (`cnpg_import`) whose password sits in OpenBao at
`kv/apps/postgres/nuc1-import`. The managed roles then set the new passwords. The import
block, the external cluster, its Secret and the network rule to nuc1 are removed after the
cutover; so is PostgreSQL on nuc1, once a restore test has passed.

## Not chosen

- PostgreSQL on nuc1 kept as is: the database would stay outside what the cluster declares,
  with backups on the same disk.
- One CNPG cluster per app: the idiomatic CNPG shape, three times the memory.
- OpenBao's database engine on top of CNPG: two owners for the same roles.
