# Dev/qa isolation on a shared instance

`node-app` and `java-app` each run as two independent containers on the
same EC2 box — one per environment — so a dev deploy is structurally
incapable of touching qa.

**`react-external-app`/`react-support-app` are no longer part of this
Docker/EC2 layout.** Per [ADR-0038](../docs/adr/0038-portal-support-app-public-exposure-domain-cognito-and-signup.md),
both apps now build to static assets in CI and deploy straight to
S3+CloudFront (`terraform/shared/public_apps.tf`, dev environment so far —
see [parking lot #56](../docs/adr/0021-parking-lot.md)); each repo's
`.github/workflows/deploy-dev.yml` runs `npm run build` + `aws s3 sync` +
a CloudFront invalidation, no Docker image involved. The shared `react-app`
EC2 instance these two used to deploy onto is being decommissioned
([parking lot #57](../docs/adr/0021-parking-lot.md)).

## Layout

```
docker/
├── deploy.sh
├── node-app/
│   ├── dev/  { docker-compose.yml, .env.example }
│   └── qa/   { docker-compose.yml, .env.example }
└── java-app/
    ├── dev/  { docker-compose.yml, .env.example }
    └── qa/   { docker-compose.yml, .env.example }
```

Each `docker-compose.yml` is a **separate compose project** — its own
directory, its own container name, its own Docker network. There is
deliberately no single top-level compose file listing all four services:
that would make a bare `docker compose up -d` (run from the wrong
directory, or by habit) capable of restarting everything on the box at
once. Every deploy command must `cd` into one specific `<app>/<env>/`
directory first — `deploy.sh` does exactly that and nothing else.

## Host ports

| App | Env | Container port | Host port |
|---|---|---|---|
| node-app | dev | 3000 | 3001 |
| node-app | qa | 3000 | 3002 |
| java-app | dev | 8080 | 4001 |
| java-app | qa | 8080 | 4002 |

**node-app's** host ports are NLB `target_port`s — `terraform/shared`
registers them directly, since node-app receives inbound Tenant/Salesforce
calls.

**java-app's** host ports are *not* NLB targets. Per ADR-0039, Java/Spring
Batch is a nightly outbound-only worker (it calls out to each Tenant's SAP
system; it never receives inbound calls) — there's no Tenant-facing API,
Cognito scope, or NLB listener for it at all (see
`terraform/shared/java_outbound.tf`). These ports exist only for
local health checks/monitoring (e.g. Spring Boot Actuator) if the service
exposes one — not part of any routing path.

## What's actually isolated, and how

- **Process & filesystem**: separate containers, separate directories — a
  dev image pull/restart never touches the qa container's filesystem or
  process.
- **Resources**: `mem_limit`/`cpus` per service, so a dev load test can't
  starve qa of CPU/memory on the shared box.
- **Data**: separate `DB_SCHEMA` per environment (`.env.example` files) —
  point these at genuinely separate schemas on the `aiarap` instance, not
  the same one with a naming convention nobody enforces.
- **Deploy blast radius**: `deploy.sh <app> <env>` only ever operates on one
  compose project. There's no "restart everything" command in this layout.
- **What qa actually tests**: dev floats on a `:dev` tag, rebuilt on every
  merge. qa does **not** — its compose file requires an explicit
  `NODE_QA_TAG`/`JAVA_QA_TAG` (a specific commit SHA) and fails loudly if
  it's unset, so qa's environment can't silently shift out from under
  testers just because dev rebuilt. Promoting to qa is a deliberate command:
  `./deploy.sh node-app qa a1b2c3d`.

## Secrets

`.env` (committed as `.env.example`, real values gitignored) holds
non-secret config. Actual secrets are never written to a file that touches
git — `deploy.sh` pulls them from Secrets Manager
(`varunerp/<app>/<env>`) into `.env.secrets` on every deploy, which
`docker-compose.yml` also loads via `env_file`.

**Prerequisite**: `deploy.sh` needs `jq` on the deploy box — confirmed
missing in this environment when testing the script here (`jq: command not
found`); install it before relying on this on the real host. The script's
`|| touch .env.secrets` fallback means a missing/inaccessible secret
doesn't crash the deploy, just leaves that environment without secrets
until it's fixed — don't mistake a silently-empty `.env.secrets` for "no
secrets needed."

## Note on testing this

Running `deploy.sh` here (to check its error handling) made one real,
read-only call to Secrets Manager under the `tailscale_VarunERP` IAM user —
it correctly failed with `AccessDeniedException` (that user isn't
provisioned for `secretsmanager:GetSecretValue` on this path) and the
script's fallback handled it cleanly. No AWS state was read or changed;
flagging it since it did leave this session's context, unlike everything
else validated so far.
