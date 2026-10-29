# crowdsec-cilium-bouncer

Streams ban decisions from a CrowdSec LAPI and writes them into `CiliumCIDRGroup`s.
A Cilium network policy selects the groups by label and drops the traffic before it
reaches the Gateway. Why it exists: [ADR 0003](../../docs/adr/0003-scanner-blocking.md).

## Behaviour

- Decisions with scope `Ip` or `Range` and type `ban` are kept in memory, updated from
  the LAPI stream every 10 s. A single address becomes a `/32` or `/128`.
- Every `SYNC_INTERVAL`, the prefixes are deduplicated, sorted and cut into chunks of
  `CHUNK_SIZE`. Chunk `n` goes into the group `<GROUP_PREFIX><n>`. A group whose content
  did not change is not written; surplus groups are deleted.
- Groups carry `crowdsec.net/banned: "true"` (for policies) and
  `app.kubernetes.io/managed-by: crowdsec-cilium-bouncer` (for the bouncer). Groups
  without the second label are never touched.
- **Fail-static**: until LAPI has answered once, and whenever a sync fails, the groups
  keep their last content. A LAPI outage never lifts the bans.

## Configuration

| Variable | Default | |
|---|---|---|
| `CROWDSEC_LAPI_URL` | (required) | e.g. `http://crowdsec-service.crowdsec:8080` |
| `CROWDSEC_BOUNCER_KEY_FILE` | (required) | file holding the bouncer API key |
| `CHUNK_SIZE` | `1000` | prefixes per group |
| `GROUP_PREFIX` | `crowdsec-banned-` | |
| `SYNC_INTERVAL` | `30s` | |

RBAC: `get`, `list`, `create`, `update`, `delete` on `ciliumcidrgroups.cilium.io`.

Metrics on `:9090/metrics`: `bouncer_banned_prefixes`, `bouncer_groups`,
`bouncer_sync_errors_total`.

## Development

```sh
go test ./...
```

A `bouncer-v<semver>` tag builds `ghcr.io/orysse/crowdsec-cilium-bouncer:<semver>`.
