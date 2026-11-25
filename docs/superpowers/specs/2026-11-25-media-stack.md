# Films and series: Radarr, Sonarr, Prowlarr, Jellyfin, Seerr (draft)

Status: draft, 2026-11-25. Nothing deployed. Same pattern as `apps/music` (D35 for the NAS).

## What

A new namespace `media` (`apps/media/`), five apps, one volume on the family NAS.

| App | Role | Host | Login |
|---|---|---|---|
| Radarr | films wanted, import | `radarr.int.${DOMAIN}` | oauth2-proxy, `admins` |
| Sonarr | series wanted, import | `sonarr.int.${DOMAIN}` | oauth2-proxy, `admins` |
| Prowlarr | indexers, synced to both | `prowlarr.int.${DOMAIN}` | oauth2-proxy, `admins` |
| Jellyfin | watching | `jellyfin.${DOMAIN}` (public) | Pocket-ID through the SSO plugin; local password kept for native apps |
| Seerr | requests (to Radarr, Sonarr) | `seerr.${DOMAIN}` (public) | oauth2-proxy, `admins`, `users`, `family` |

## Storage

- NFS export `192.168.1.151:/volume1/ABEL` (rule already on the NAS), NFSv4.1, same mount
  options as `music-nas`. One layout, so a download is hardlinked into the library inside one
  mount: `downloads/`, `films/`, `series/` (names to confirm against what ABEL already holds).
- Two static PVs on the same export (a PV binds to one claim): `abel-nas` for `media`,
  `abel-nas-music` for the `music` namespace, where qBittorrent runs (below).
- Jellyfin mounts `films/` and `series/` read-only.
- App state on class `local`: SQLite for Radarr, Sonarr, Prowlarr, Seerr (1 Gi each), Jellyfin
  config and metadata (10 Gi). Not on NFS (D32). Unlike Lidarr there is no PostgreSQL: a lost
  `local` volume loses the lists of what to re-fetch. Open: back them up, or move to CloudNativePG.

## Downloads

- qBittorrent stays the one in `music` (gluetun, AirVPN, one tunnel): its pod also mounts
  `abel-nas-music` (new claim in `music`), at `/abel`. No second VPN key.
- Radarr and Sonarr call it over the cluster network (`qbittorrent.music:8080`), categories
  `radarr` and `sonarr`. Remote path mapping once in each app: `/abel/downloads` to the
  downloads directory of their own mount.
- Prowlarr goes out directly (searches only, not downloads): the indexers see the home IP.

## Network and access

- Per-pod `CiliumNetworkPolicy`, default deny, as in `apps/music/network-policy.yaml`. Radarr and
  Sonarr: from their proxies, Prowlarr and Seerr; to qBittorrent (`music`), Prowlarr, Jellyfin
  (library refresh), DNS, 443/80 world. qBittorrent's policy gets an ingress from the `media`
  apps (cross-namespace, matched on namespace label).
- Public: two new listeners in `infrastructure/configs/network/gateways.yaml` (`jellyfin`,
  `seerr`); namespace label `gateway-access: both`. Router forwarding unchanged (80/443).
- Jellyfin is Internet-facing with its own login: no oauth2-proxy in front, because native apps
  cannot do the browser flow. This is the weakest point: the SSO plugin (9p4/jellyfin-plugin-sso)
  is unofficial, to be pinned by commit and reviewed. No registration, no anonymous access,
  strong password on every local account.
- Seerr: login through the proxy first; Seerr's own Jellyfin login after. OIDC support in Seerr
  itself is not checked.
- Pocket-ID clients through `PocketIDOIDCClient` (as `auth.yaml`); one cookie key per proxy.

## Sizing (estimates, not measured: gate before merge)

Limits: Radarr 512 Mi, Sonarr 512 Mi, Prowlarr 256 Mi, Seerr 512 Mi, Jellyfin 1.5 Gi (ffmpeg
bursts). About 1.2 Gi requested, 3.3 Gi at the limits. kube-0 is 9216 MB with zram swap and eviction
at 300 Mi; the 2026-10-11 collapse says to check first. Needed: `kubectl top nodes` and `free -m`
on kube-0 at the time of deploy. No VM resize without the owner's OK.

Jellyfin transcodes on the CPU: the microVM has no iGPU. Direct play only is the goal; transcodes
get a limit (one at a time) in Jellyfin's settings. To confirm: which clients (TV, phone, browser).

## Open

- Layout of ABEL today (existing folders), quota, NAS user/squash (as `Music-Abel`: all mapped
  to admin, apps write as 1000).
- Image tags (linuxserver Radarr, Sonarr, Prowlarr; Jellyfin; Seerr) pinned at write time, then Renovate.
- Backups of the SQLite state (see Storage).
- Who gets a Jellyfin account, and the `users`/`family` Pocket-ID groups for Seerr.
- Legal side of what Radarr and Sonarr fetch is the owner's call; nothing here assumes content.

## Steps

1. Memory check on kube-0; confirm ABEL layout.
2. `apps/media/`: namespace, `nas.yaml`, the five apps, auth, network policies; `abel-nas-music`
   and the mount in `music/qbittorrent.yaml`; gateway listeners; `apps/kustomization.yaml`.
3. Commit, Flux applies. Check: PV bound, pods ready, a hardlink test from `downloads/` to `films/`.
4. By hand once: qBittorrent categories and path mapping, Prowlarr to Radarr and Sonarr, Jellyfin
   libraries, SSO plugin, Seerr to Radarr, Sonarr, Jellyfin.
