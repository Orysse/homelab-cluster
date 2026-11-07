# SeaweedFS spike (design item 25, phase 4a)

Applied by hand on 2026-11-05 in namespace `seaweedfs-spike`, no Flux Kustomization points here.
Charts: seaweedfs 4.52.0 (app 4.52), seaweedfs-csi-driver 0.2.44. Filer metadata in a scratch
CNPG cluster (`pg.yaml`), data and master state on the host subvolume `@seaweed`
(virtiofs, `/var/lib/seaweed` in the VM).

Install: `kubectl apply -f namespace.yaml -f pg.yaml`, then the two `helm install` lines in
`values.yaml` and `csi-values.yaml`. Remove: `kubectl delete ns seaweedfs-spike`.

| # | Criterion | Result |
|---|---|---|
| 1 | hardlink + atomic rename in one mount | pass (`test-1-hardlink.yaml`) |
| 2 | Navidrome scans 10 000 files | pass: 13 s, 0 errors, 1000 folders x 10 tracks (`test-2-navidrome.yaml`) |
| 3 | Syncthing sees a file written by another pod | pass, inotify mode: indexed within 12 s with a 3600 s rescan interval. Same node only; a write from another node is untested (one node) (`test-3-syncthing.yaml`) |
| 4 | RAM of master + filer + volume + CSI pods < 1.5 GB | idle ~380 MiB, during the Navidrome scan ~690 MiB, peak ~1.5 GiB while qBittorrent wrote 4 GB (csi-mount 1.1 GiB, filer 170 MiB). Back to ~380 MiB once idle. Not capped yet: the chart has `cacheCapacityMB` and `concurrentWriters` |
| 5 | uninstall + reinstall keeps the files | pass: same sha256 before and after (`test-5-read.yaml`) |
| 6 | multi-GB torrent | pass: qBittorrent 5.0.4, Debian DVD 3.99 GB at ~80 MB/s, full recheck 100 % (`test-6-qbittorrent.yaml`) |

Findings for items 26 and 29:
- The volume server is a StatefulSet in the chart, not a DaemonSet: fine for one node, a
  DaemonSet of our own (`volume-daemonset.yaml`) is needed before a second host.
- Master state and logs default to `hostPath` on the VM's tmpfs root (`/ssd`, `/storage`):
  set `master.data` to hostPath `/var/lib/seaweed`, `master.logs` and `filer.data/logs` to
  emptyDir (see `values.yaml`).
- The chart's size guard is `volume.minFreeSpacePercent` (default 1), not an absolute
  `-minFreeSpace`: the item 26 value has to be a percentage.
- A folder created by hand in Syncthing needs `.stfolder` in it first (marker missing).
- The CSI chart runs a privileged mount service (FUSE) next to the node plugin: the
  namespace needs pod security `privileged`.
