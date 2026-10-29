# ADR 0005: Secrets: OpenBao configured by self-initialization only

Status: draft (spike results, 2026-10-29). Finalized in Task 15.

## Context

In v2, OpenBao's self-initialization only enabled Kubernetes auth and gave
vault-config-operator a role. The operator then managed everything else as CRDs: the
`kv/apps` mount, the `namespace-secrets` policy and role, the `admin` policy, the `sso`
OIDC auth, the database engine and its static roles, and `RandomSecret`s. That is one
more controller (about 70 MB) and a second way to configure OpenBao.

v3 changes what OpenBao has to hold:
- the database engine goes, since CNPG owns the PostgreSQL roles (Task 16);
- OIDC client secrets come from the Pocket-ID operator (ADR 0004);
- generated secrets come from External Secrets' `Password` generator plus a `PushSecret`
  `IfNotExists` into `kv/apps/<ns>/<name>`.

What is left is static: a KV mount, Kubernetes auth, a templated policy, a writer policy
for the `postgres` namespace, human OIDC login and an admin policy. None of it changes
when an app is added.

## Spike (OpenBao 2.7.1, throwaway pod, pebbledb on emptyDir, static seal)

- `storage "file"` no longer exists in 2.7, so use `pebbledb` (as v2 does). `disable_mlock`
  is unknown and only warned about.
- **Self-init requests can use earlier responses.** A `read` of `sys/auth/kubernetes`
  followed by a policy whose text is built with `eval_source = "template"`
  (`{{ .responses.<initialize>.<request>.data.accessor }}`) produced the templated policy
  `kv/apps/data/{{identity.entity.aliases.<accessor>.metadata.service_account_namespace}}/*`.
  The `initialize` and `request` names used in a template must not contain `-` (Go
  template field access).
- Result, logged in as `spike/default` through role `namespace-secrets`:
  `kv/apps/spike/test` was readable, `kv/apps/other/test` was refused (403).
- The root token was revoked at the end of initialization, and no error was logged.

## Decision

- **No vault-config-operator.** Everything is declared in `initialize` blocks of the
  OpenBao HelmRelease values:
  - `kv/apps` KV v2;
  - Kubernetes auth, with role `namespace-secrets` (ServiceAccount `default`, every
    namespace) and the templated read policy above, plus `kv/apps/metadata/...` list;
  - role `postgres-writer` for `postgres/openbao-writer`, policy `db-writer` (create/update
    on `kv/apps/data/+/db`);
  - OIDC auth `sso` for Pocket-ID group `admins`, with policy `admin`.
- **OIDC client secret at init**: the Pocket-ID operator's Secret
  `openbao-oidc-credentials` (ADR 0004) is mounted into the OpenBao pod as a required
  volume. The pod therefore starts only once the client exists, and self-init reads it
  with `eval_source = "file"`. The `sso` requests use `allow_failure = true`, so a
  Pocket-ID outage at first start does not block the secrets everything else needs.
  Human login can then be fixed by hand.
- **Unseal**: unchanged, the static seal with its key in sops (`unseal.sops.yaml`).
- **Changes after initialization**: self-init runs only once, on empty storage. A change
  goes both into the `initialize` blocks (so a rebuild reproduces it) and, by hand, into
  the running instance (`bao` CLI as an `admins` member). To allow that, the `admin`
  policy grants writes on `sys/policies/acl/*`, `auth/kubernetes/role/*` and `sys/mounts/*`
  (in v2 it was read-only, because the operator wrote). Rare by design: adding an app
  needs nothing here.
- **Break-glass** (Pocket-ID down): no operator role and no root token survives.
  `bao operator generate-root` with the static seal (authenticated recovery flow) is
  documented in the runbook, together with how to run it.
