# ADR 0005: Secrets: OpenBao configured by self-initialization only

Status: accepted (2026-10-29).

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

## Second test (Task 15, the real configuration, OpenBao 2.7.1 run locally)

- The full `initialize` set ran on empty storage: `kv/apps`, auth `kubernetes` and `sso`,
  roles `namespace-secrets`, `postgres-writer`, `sso-config`, `break-glass`, and the
  templated policy carrying the real mount accessor.
- **A failed initialization is final.** A request whose data cannot be evaluated (a file
  that does not exist) fails the whole initialization even with `allow_failure = true`,
  which covers only the request itself. The server stops, and on every later start it
  refuses to unseal (`self-initialization failed: refusing to unseal`). Nothing in the
  `initialize` blocks may depend on another app.
- Writing `auth/sso/config` fetches the issuer's discovery document, so it cannot run
  before Pocket-ID answers, and Pocket-ID starts after OpenBao (its secrets live there).
- `bao operator generate-root` is refused (403), and the static seal has no recovery keys:
  there is no root-token break-glass.

## Decision

- **No vault-config-operator.** Everything static is declared in `initialize` blocks of
  the OpenBao HelmRelease values (`infrastructure/configs/secrets/openbao.yaml`):
  - `kv/apps` KV v2;
  - Kubernetes auth, role `namespace-secrets` (ServiceAccount `default`, every namespace)
    with the templated policy: create, read and update on the namespace's own
    `kv/apps/<ns>/*`, no delete. Write access serves generated secrets (below);
  - role `postgres-writer` for `postgres/openbao-writer`, policy `db-writer` (create and
    update on `kv/apps/data/+/db`);
  - auth `sso` (OIDC) and its role `admin`, bound to Pocket-ID group `admins`;
  - role `break-glass` for the ServiceAccount `openbao/break-glass`, policy `admin`.
- **OIDC client settings by a Job.** `sso-config` (`secrets/sso.yaml`) waits for Pocket-ID's
  discovery document, logs in with role `sso-config` (update on `auth/sso/config` only)
  and writes the client id and secret from the Secret the Pocket-ID operator creates
  (ADR 0004). Bootstrapping needs no person.
- **Generated secrets nobody sees**: an `ExternalSecret` with a `Password` generator in the
  app's namespace (`refreshInterval: "0"`, generated once), pushed to `kv/apps/<ns>/<name>`
  by a `PushSecret` with `updatePolicy: IfNotExists`. The value survives a cluster rebuild
  in OpenBao.
- **Unseal**: unchanged, the static seal with its key in sops (`unseal.sops.yaml`).
- **Changes after initialization**: self-init runs only once. A change goes into the
  `initialize` blocks (so a rebuild reproduces it) and, by hand, into the running instance
  (`bao` CLI as an `admins` member). The `admin` policy grants writes on
  `sys/policies/acl/*`, `auth/kubernetes/role/*`, `sys/mounts/*` and `auth/sso/*` for that.
  Rare by design: adding an app needs nothing here.
- **Break-glass** (Pocket-ID down): a cluster-admin logs in as `openbao/break-glass`
  (`bao write auth/kubernetes/login role=break-glass jwt=$(kubectl -n openbao create token
  break-glass)`). It grants nothing a cluster-admin does not already have: they can read the
  unseal key.
