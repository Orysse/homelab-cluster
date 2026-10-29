# ADR 0004: OIDC clients declared in git

Status: accepted (2026-10-29). Tried live at cutover.

## Context

In v2, every OIDC client (Grafana, Headlamp, Headscale, open-webui, oauth2-proxy,
OpenBao) was created by hand in Pocket-ID's UI. Its secret was then copied into OpenBao
`kv/apps/<ns>/oidc`, and the app read it back through External Secrets. Two of the clients
are pinned in homelab-nix's topology (`oidc.audiences`): `kubernetes` (public) and
`headlamp`.

## Option found

[aclerici38/pocket-id-operator](https://github.com/aclerici38/pocket-id-operator)
(Apache-2.0, Helm chart 0.16.x, frequent releases, docs at pocket-id-operator.pages.dev).
CRDs: `PocketIDInstance` (the operator deploys Pocket-ID itself), `PocketIDUser`,
`PocketIDUserGroup`, `PocketIDOIDCClient`, `PocketIDAPI`.

`PocketIDOIDCClient` covers what we need:
- `callbackUrls`, `logoutCallbackUrls`, `isPublic`, `pkceEnabled`;
- `allowedUserGroups`, which takes a `PocketIDUserGroup` or an existing group by
  `groupName`;
- a fixed `clientID`, immutable;
- a credentials Secret named `<name>-oidc-credentials` by default, with keys
  `client_id`, `client_secret`, `issuer_url` and the discovery URLs.

It **adopts** existing clients, matched by `clientID`, then by `name`. Adoption generates
a new secret.

Risks: a young project, with code partly AI-written (the author says so). It supports only
Pocket-ID `>=2.14 <3.0`: outside that range the operator exits and crash-loops, so
Renovate must not bump Pocket-ID to 3.x without the operator. It deploys Pocket-ID itself,
so the Pocket-ID Deployment becomes a `PocketIDInstance`. (It can also adopt an existing
Pocket-ID through `spec.external`; this ADR first said it could not.)

## Decision: go

- Pocket-ID is deployed through a `PocketIDInstance` (`identity/pocket-id`), with typed
  settings (SMTP, email notifications, sign-ups, UI) instead of environment variables, its
  database on CNPG (`databaseUrl.valueFrom`, from `kv/apps/pocket-id/db`) and its
  encryption key generated in the cluster and kept in OpenBao (ADR 0005). Stateless: files
  in the database. The operator creates its HTTPRoute.
- Each app declares its `PocketIDOIDCClient` in its own namespace, next to its Deployment,
  and mounts the Secret the operator writes there. No copy through OpenBao. Where a chart
  expects other key names (Headlamp), `spec.secret.keys` renames them.
- `kubernetes` (kubectl, public) and `headlamp` are adopted with their current `clientID`,
  so the homelab-nix topology does not change. The others are adopted by name; their
  secrets change at cutover, which does not matter since the apps read the new Secret.
- OpenBao's client: the Secret is read by the `sso-config` Job, not by OpenBao's
  self-initialization (ADR 0005).
- `admins` and `visitors` are `PocketIDUserGroup`s; clients list them in
  `allowedUserGroups`. Members and their passkeys stay managed by people, not by git.
- Renovate holds Pocket-ID below 3.0 (`renovate.json`).

Fallback if the operator fails at cutover: Pocket-ID as a plain Deployment, clients created
in the UI, credentials in `kv/apps/<ns>/oidc` (the v2 flow), or `spec.external` to keep the
client objects against a hand-run Pocket-ID.
