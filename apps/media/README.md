# Films and series: what the repository holds, and what it does not

Three kinds of settings:

- **Declared**: Kubernetes objects, environment variables, files copied at every start. The
  repository wins.
- **In the app's database, backed up**: set by hand once in the UI, kept in the cluster
  PostgreSQL (barman to Garage, then R2). Listed below with the expected values, so a restored or
  rebuilt app can be checked against this page.
- **In the app's `local` volume, not backed up**: lost if kube-0's disk is lost.

Internal URLs: every Service listens on port 80 and forwards to the app's own port, so inside
the cluster an app is `http://<service>.<namespace>.svc.cluster.local` with no port.

## Secrets (OpenBao, kv/apps/media/*)

| Entry | What | Written by |
|---|---|---|
| `media/db` | PostgreSQL role `media` (Radarr, Sonarr, Prowlarr) | generated (`infrastructure/configs/postgres/databases/media.yaml`) |
| `media/arr-keys` | API keys `radarr`, `sonarr`, `prowlarr` | generated (`secrets.yaml`), injected as `<App>__Auth__ApiKey` |

A key typed into another app (Prowlarr, Seerr, Jellyfin's connection in Radarr and Sonarr) is
read from `media/arr-keys`. Rotating a key = changing it in OpenBao, restarting the app, then
retyping it where it is used.

## Prowlarr (database `prowlarr`)

Set by hand once:

- Settings > Indexers > Indexer Proxies:
  - HTTP, name `vpn`, tag `vpn`, host `qbittorrent.music.svc.cluster.local`, port `8888`, no
    login (gluetun's HTTP proxy: searches and their DNS go through the VPN).
  - FlareSolverr, tag `flaresolverr`, host `http://qbittorrent.music.svc.cluster.local:8191`.
- Indexers: `1337x`, tags `vpn` and `flaresolverr`. Every indexer gets `vpn`; an untagged one
  goes out with the home IP.
- Settings > Apps: Radarr `http://radarr.media.svc.cluster.local`, Sonarr
  `http://sonarr.media.svc.cluster.local`, Prowlarr server `http://prowlarr.media.svc.cluster.local`,
  keys from `media/arr-keys`.

## Radarr (database `radarr`) and Sonarr (database `sonarr`)

Set by hand once, in each:

- Root folder: `/data/films` (Radarr), `/data/series` (Sonarr).
- Download client qBittorrent: host `qbittorrent.music.svc.cluster.local`, port `80`, no
  login, category `radarr` / `sonarr`.
- Remote path mapping: host `qbittorrent.music.svc.cluster.local`, remote `/abel/`, local `/data/`.
- Quality profile used by Seerr: `HD-1080p`.
- Connect > Emby / Jellyfin: host `jellyfin.media.svc.cluster.local`, port `80`, Jellyfin API
  key (created in Jellyfin, see below), "Update library" on import.
- After a fresh database: Library Import of `/data/films` and `/data/series` to find what is
  already on the NAS.

## qBittorrent (namespace `music`, `apps/music/qbittorrent.yaml`)

Declared: the whole `qBittorrent.conf` and `categories.json` (ConfigMap `qbittorrent-conf`):
interface `tun0`, automatic torrent management, default folder `/abel/downloads`, categories
`radarr` and `sonarr`, port 2417, WebUI open to the pods' subnet only.
Not backed up: the list of torrents (`local` volume). Lost torrents are found again by Radarr
and Sonarr if still wanted.

## Jellyfin (`local` volume, not backed up)

Set by hand: admin account, libraries `Films` (`/data/films`) and `Series` (`/data/series`),
metadata language French / country France, trickplay and chapter images off, hardware
acceleration none, Networking > Known proxies `10.42.0.251`, API key for Radarr, Sonarr and
Seerr. Users each keep a Jellyfin password: Seerr logs in through it.
Lost with the volume: all of the above, users and watch history.

## Seerr (`local` volume, not backed up)

Set by hand: Jellyfin `jellyfin.media.svc.cluster.local` port `80`; Radarr and Sonarr servers
(host `<app>.media.svc.cluster.local`, port `80`, keys from `media/arr-keys`, profile
`HD-1080p`, root folders as above). Lost with the volume: these settings, users, requests.

## Restore

PostgreSQL restores as a whole cluster from barman (ADR 0006), not one database at a time. To
get one app's database back without touching the others: bootstrap a temporary CNPG Cluster
from the backup, `pg_dump` that database from it, `pg_restore` it into `main`, delete the
temporary Cluster. Not rehearsed yet.
