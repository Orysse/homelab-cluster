# ADR 0004: OIDC clients declared in git

Status: draft (2026-10-29). Finalized in Task 17.

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
so the Pocket-ID Deployment becomes a `PocketIDInstance`.

## Decision: go

- Pocket-ID is deployed through a `PocketIDInstance`, database on CNPG (`spec.databaseUrl`;
  how to pass it from a Secret is checked in Task 17).
- Each app declares its `PocketIDOIDCClient` in its own namespace, next to its
  Deployment. The app reads the credentials Secret directly, with no copy through OpenBao.
  This is the operator's natural flow; checking that the Secret lands in the client's
  namespace is Task 17's first check.
- `kubernetes` (public) and `headlamp` are adopted with their current `clientID`, so the
  homelab-nix topology does not change. The other clients are adopted by name. Their
  secrets change at cutover, which does not matter since the apps read the new Secret.
- The `admins` and `visitors` groups become `PocketIDUserGroup`s. Users and their passkeys
  stay managed by people, not by git.

The live trial (plan Step 2) did not run: the operator wants its own instance, so it
cannot be tried against v2's Pocket-ID without migrating it. It is tried at cutover.
Fallback if it fails then: Pocket-ID as a plain Deployment, clients created in the UI,
credentials in `kv/apps/<ns>/oidc` (the v2 flow).
