# Music automation: from "wanted" to the DAP

Status: implemented 2026-11-07 (manifests in apps/music/). Owner's needs and the migration: memory of 2026-11-06/07; the
library (544 albums, 6,659 files, 211 GiB) is clean and synced to the FiiO M21.

## Goal

An album the owner wants ends up tagged, with cover and lyrics, in `library/`, then on the
M21, without a manual step when the match is certain. Sources: Lidarr's wanted list
(torrents, Soulseek), CD rips and purchases dropped by hand.

## The one rule

**beets is the only writer into `library/`.** Lidarr, qBittorrent and slskd never write
there. Everything else follows from this rule.

## Flow

```
Lidarr (wanted: artists, albums)                     owner: CD rips, purchases
  ├─ qBittorrent ── downloads/torrents/complete/          │
  └─ you ── slskd UI ── downloads/slskd/                   inbox/
                             │                             │
               beets CronJob (quiet, certain matches only) ┘
                             │
                         library/ ── Syncthing (send only) ── M21 (receive only)
                             │    └─ Navidrome (read only)
                   Lidarr rescans: album present, no longer wanted
```

Layout of the `music` PVC (one volume, 300Gi quota):

| Path | Writer | Notes |
|---|---|---|
| `library/` | beets | read by Lidarr, Navidrome, Syncthing, slskd (shared) |
| `downloads/torrents/{incomplete,complete}/` | qBittorrent | seeding source, deleted by qBittorrent after the share limit |
| `downloads/slskd/` | slskd | emptied by beets (move) |
| `inbox/` | the owner | emptied by beets (move) |

## Components

### beets CronJob (new)

- Every 5 minutes, `concurrencyPolicy: Forbid`. Not event-driven: the SeaweedFS FUSE mount
  sends no inotify events (seen with Syncthing), and a webhook from slskd/qBittorrent would
  need a listener and RBAC to start a Job, for a few minutes saved.
- A folder is imported once nothing in it changed for 10 minutes (a download, Soularr's
  move or the owner's copy still in progress).
- `import.quiet: yes`, `quiet_fallback: skip`: only matches above beets' strong threshold
  are imported; the rest is left in place, untouched. `incremental: yes` remembers every
  folder seen, imported or skipped, so a run with nothing new costs a directory listing
  and a skipped folder is not retried by the CronJob.
- Two modes:
  - `inbox/` and `downloads/slskd/`: `--move`; beets prunes the emptied folder (its
    `clutter` list: covers, cue, log, nfo).
  - `downloads/torrents/complete/`: `--copy`. A hardlink would share the inode, and beets
    writing tags would corrupt the torrent's data (hash check fails, seeding breaks). The
    copy costs the album's size twice until qBittorrent drops the torrent.
- Manual pass on leftovers ("skip" lines in `/config/import.log`): CronJob suspended, a Job
  created from it with `sleep`, `beet import -I --move <folder>` interactively (commands in
  `apps/music/beets.yaml`).
- After a run that imported, beets asks Lidarr for a `RescanFolders` (API, key in
  `kv/apps/music/lidarr`): without it Lidarr sees the album only on its own rescan, and
  Soularr, which reads "missing" from Lidarr, would fetch it again.
- Keeps the one-off pod's PVC `beets-config` (`library.db`, `state.pickle`) and config.
- Image: `ghcr.io/linuxserver/beets:2.14.1-ls359`, command overridden (no s6, runs as
  1000, `/lsiopy/bin/beet`). Covers resized with ImageMagick (in the image; no Pillow).

### Lidarr (exists, reconfigure)

- Root folder `/data/library`. **Completed Download Handling off**, rename tracks off,
  tag writing "never": Lidarr only tracks what is wanted and sees, on its rescan, that the
  album arrived (beets writes the MusicBrainz IDs it reads).
- Quality profile: FLAC wanted, MP3 320 allowed, cutoff FLAC (takes MP3 only when no FLAC
  exists, upgrades later).
- Settings live in its PostgreSQL database (set in the UI, not in manifests).
- Metadata profile: albums and EPs (no singles, compilations, live).
- Download client: Soularr/slskd only at first (see qBittorrent). No indexer, no Prowlarr.
- Artists are added by hand, never by an import list (owner: genres must not pick
  artists). First artist monitored: Massive Attack.
- Downloads left in Lidarr's queue as "waiting to import" are expected (CDH off); they
  disappear when qBittorrent removes the torrent.

### qBittorrent (exists, running behind AirVPN since 2026-11-07)

- Not a Lidarr download client at first: the owner has no tracker yet, and Soulseek covers
  the need without one. Torrents are added by hand in its UI, category `music`; beets
  imports them like the others. Lidarr + Prowlarr come later, if Soulseek falls short.

- Category `music`, save path `downloads/torrents/complete`, incomplete path
  `downloads/torrents/incomplete`.
- Share limit: ratio 1.0 or 14 days, then **remove torrent and files** (bounds the double
  copy).

### slskd (new)

- **Same pod as qBittorrent**, behind the same gluetun: one tunnel, one AirVPN key. A
  second pod would need a second AirVPN device/key (two tunnels with one key collide).
  Cost: restarting one restarts the other. The Deployment keeps its name.
- Soulseek listen port 54429 (AirVPN forwarded, TCP): gluetun `FIREWALL_VPN_INPUT_PORTS`
  becomes `2417,54429`; API/UI 5030 added to `FIREWALL_INPUT_PORTS`.
- Shares `library/` read-only (subPath mount `readOnly`), downloads to `downloads/slskd/`.
- Soulseek account (username/password) and the API key for Soularr: OpenBao
  `kv/apps/music/slskd`, ExternalSecret. UI `slskd.int.${DOMAIN}`, internal only, with its
  own login (as qBittorrent): slskd cannot trust a proxy header, and an oauth2-proxy would
  mean one more Pocket-ID client. API key limited to pod addresses (`cidr=10.42.0.0/16`).

### Soularr (dropped 2026-11-07)

**Dropped**: it skips only albums in Lidarr's queue, so it re-grabbed every album beets had not imported yet (85 GB for Massive Attack in one evening). slskd is used by hand from its UI; the notes below are kept for history.

- On-demand CronJob (suspended; one `soularr.py` pass per manual job: a loop re-grabbed albums beets had not imported yet, 2026-11-07), image `ghcr.io/mrusse/soularr` pinned.
- Reads Lidarr's wanted list, searches and downloads through slskd's API.
- **`disable_sync = True`**: Soularr does not ask Lidarr to import (beets does).
- `config.ini` rendered by the ExternalSecret (Lidarr and slskd API keys,
  `kv/apps/music/soularr`). Its data dir (failed-import denylist): `emptyDir`.
  shortcut: the denylist is lost on restart; a small PVC if it re-downloads junk.

### Network policies (update `network-policy.yaml`)

- qbittorrent pod (now with slskd): ingress 5030 from the Gateway and Soularr.
- Soularr: egress to Lidarr 8686 and slskd 5030, DNS.
- beets: egress DNS and 443 (MusicBrainz, Cover Art Archive, iTunes, LRCLIB).
- Lidarr: ingress 8686 from Soularr.


## Capacity

- The host alert `HostDiskFilling` (btrfs > 85%, homelab-nix `_alert-rules.nix`) covers
  `@seaweed`: same pool. Today 71% (332/465 GiB); 85% leaves ~63 GiB.
- Not covered: the PVC quota (300Gi): writes fail with ENOSPC before the disk fills. A
  stuck beets/qBittorrent is the symptom; raise the PVC (it is a quota, not an allocation).
- If the library outgrows nuc1: move to the NAS (owner, 2026-11-07), not an SSD.

## Memory

Measure free memory on kube-0 before deploying (collapse of 2026-10-11). Expected requests:
slskd ~150 Mi (.NET), Soularr ~50 Mi, beets ~200 Mi for a few minutes per run.

## Out of scope (named, not built)

- replaygain, smart playlists (never tried), `.lrc` side files (lyrics are embedded).
- A notification when `inbox/` has leftovers.
- Prowlarr and torrent indexers (until Soulseek falls short).
- Following labels: Lidarr has no MusicBrainz-label import list.

## Discovery (Navidrome, exists)

- Recommendations without auto-adding: Navidrome's Last.fm agent shows similar artists and
  bios on each artist page (an API key, no scrobbling: `ND_LASTFM_ENABLED`,
  `ND_LASTFM_APIKEY`, `ND_LASTFM_SECRET`; option names to verify). The owner adds the artists
  they like in Lidarr by hand. Key in OpenBao `kv/apps/music/lastfm`.

## Decisions (owner, 2026-11-07)

- Quiet beets import, certain matches only; the rest by hand.
- Torrents copied into the library, dropped by qBittorrent after the share limit.
- slskd in the qBittorrent pod; Soularr does not trigger Lidarr imports.
- EPs wanted; artists added by hand; recommendations shown, never auto-added.
- No tracker for now: Soulseek first.
