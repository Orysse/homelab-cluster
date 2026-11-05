# ADR 0008: storage classes, SeaweedFS for bulk files

Status: accepted (2026-11-05). Checked by a spike (`spikes/seaweedfs/`), then deployed.

## Context

Until v3 the default StorageClass was `nfs` (a directory per volume on nuc1, snapshotted by
btrbk). It could not hold a music library that grows with each new host, SQLite and
PostgreSQL do not belong on it, and it tied every volume to nuc1's NFS server. The library
(Lidarr, qBittorrent, Navidrome, Syncthing) needed one shared, growable volume that works
across hosts.

## Decision

- **Which class to use.**
  - `local` (default): local-path on the VM's own disk. For PostgreSQL, SQLite and any small
    state. Tied to its node, `Retain`; the data survives a VM restart.
  - `seaweedfs` (ReadWriteMany, `Retain`): bulk shared files, today the music library
    (`apps/music`, one PVC with `library/` and `downloads/` so a hardlink stays in one
    mount). **Never SQLite or PostgreSQL on it** (FUSE, no reliable locking).
- **SeaweedFS** (`infrastructure/storage/`): one master, one filer with its metadata in the
  CloudNativePG database `seaweedfs`, a volume server, the CSI driver. Volume data and the
  master's state are on the host subvolume `@seaweed` (virtiofs into the VM, nocow, outside
  btrbk), so the files outlive the VM and the cluster. No replication (`000`): losing a host
  loses the files on its disk, not the others; the music is re-fetched (Lidarr) or restored
  from the DAP.
- **OpenBao** moved off NFS to the host subvolume `@openbao`, snapshotted hourly by btrbk and
  copied daily, encrypted, to Cloudflare R2 (homelab-nix D31, D32). NFS is gone.

## Spike (2026-11-05), six criteria

Hardlink and rename inside one mount: pass. Navidrome scan of 10 000 files: 13 s, no error.
Syncthing sees another pod's write within 12 s (same node only). Memory of master, filer,
volume server and CSI pods: about 380 MiB idle, about 1.5 GiB at the peak of a 4 GB torrent
(the CSI mount cache, then released; capped at 1.5 GiB in the release). Uninstall and
reinstall against the same database and subvolume: files intact (same sha256). A 4 GB
torrent through qBittorrent: complete, every piece verified.

## Consequences

- The chart's volume server is a StatefulSet (one replica): enough for one host. With a
  second host it must become a DaemonSet of our own, one volume server per node, with the
  host's own free-space floor.
- The filer database is in the main CNPG cluster: restoring that cluster restores the
  directory tree (`homelab-nix docs/runbooks/bootstrap.md`).
- The FUSE client buffers writes (the CSI mount service): a memory limit that is too low
  fails the pods' I/O. Watch it when the library grows.
- Rejected: Longhorn and Ceph (replicated block storage in the VMs, RAM), Piraeus/DRBD,
  JuiceFS over Garage, mergerfs over per-host shares, a sparse disk image for the library.
