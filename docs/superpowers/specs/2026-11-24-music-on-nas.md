# Music library on the family NAS (draft)

Status: draft, 2026-11-24. Revises D32 (homelab-nix) for the music library only: D35.

## Why

- nuc1's disk (465 GB btrfs, shared with the OS, kube-0's images and Garage) went full on
  2026-11-23. SeaweedFS stopped writing under 10% free, then a vacuum made it worse: btrbk
  snapshots of `@seaweed` keep every rewritten volume (~85 GB held). D32 says `@seaweed` is
  not snapshotted; it is (daily and hourly).
- In-place tag writes on the SeaweedFS FUSE mount corrupted ~2-3% of the files they touched
  under load (136 FLACs found on 2026-11-23).
- D32's goal was capacity beyond nuc1. A NAS on the same LAN gives that today.

## What

- The family NAS: Synology, RAID, `192.168.1.151`, same LAN as nuc1 (0.8 ms).
- A shared folder `homelab-music`, quota 1 TB, NFSv4.1, exported to kube-0 (`192.168.1.210`)
  only, read-write, squash "map all users to admin" (apps write as uid 1000), `sys` security,
  non-privileged ports allowed.
- homelab-nix: kube-0 gets the NFS client (`boot.supportedFilesystems.nfs`); the VPN routes
  `192.168.1.151/32` (Tailscale and WireGuard), and the Headscale ACL lets admins reach it.
- homelab-cluster: a static `PersistentVolume` (`nfs:` volume, `192.168.1.151:<export>`,
  RWX) bound to a new PVC `music-nas` in `music`. Same layout as today: `library/`,
  `downloads/`, `inbox/`, `aurral/`.
- What stays off NFS: SQLite and small app state (Navidrome, beets' library.db, Aurral's
  /config) stay on class `local`.

## Migration

1. NAS ready (folder, quota, NFS rule); export path known.
2. Deploy homelab-nix (NFS client, routes); approve the new route in Headscale.
3. PV/PVC `music-nas`; one Job copies the volume (rsync, low priority, one stream) from the
   SeaweedFS `music` PVC. SeaweedFS can stay read-only: the copy only reads it.
4. Check: file count, total size, a decode pass (ffmpeg) on a sample and on what the repair
   replaced.
5. Switch every claim (Navidrome, beets, slskd/qBittorrent, Lidarr, Syncthing, Aurral, init
   job) from `music` to `music-nas`; one commit, Flux restarts them.
6. After a week without trouble: delete the `music` PVC; nuc1 gets ~240 GB back once btrbk's
   `@seaweed` snapshots expire. SeaweedFS stays for later bulk files, or goes (open).

## Risks

- The NAS is not ours: when it is off or updating, the library is gone and pods with the mount
  hang until it is back (hard mount). Navidrome then shows errors; nothing is lost.
- NFS trusts the client IP: limited to kube-0 on the LAN. Anyone on the LAN who takes
  `.210` could write to the share.
- Backups: the NAS has RAID, not a backup. nuc1's `@seaweed` snapshots no longer cover the
  music. Open: Synology snapshots (if the volume is btrfs) or Hyper Backup.
- beets still rewrites tags in place, now over NFS: no FUSE layer, no snapshot bloat on nuc1;
  to be watched with a decode pass after the first imports.

## Open

- Export path and whether the NAS volume is btrfs (snapshots).
- Keep or remove SeaweedFS once the music is off it.
